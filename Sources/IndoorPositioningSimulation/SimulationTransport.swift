@preconcurrency import Network
import Foundation

public enum SimulationTransportDefaults {
    public static let host = "127.0.0.1"
    public static let port: UInt16 = 57_575
    public static let serviceType = "_indoor-sim._tcp"
}

public enum SimulationTransportError: Error, LocalizedError {
    case invalidPort(UInt16)
    case frameTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            "사용할 수 없는 시뮬레이션 포트입니다: \(port)"
        case .frameTooLarge:
            "시뮬레이션 센서 프레임이 전송 한도를 초과했습니다."
        }
    }
}

public enum SimulationServerState: Equatable, Sendable {
    case stopped
    case starting
    case listening
    case failed(String)
}

/// TCP publisher hosted by the Mac controller. Simulator and physical-device apps may
/// subscribe at once; reconnecting an app creates a new connection without
/// resetting the controller session.
@MainActor
public final class SimulationSessionServer {
    public var onClientCountChanged: (@MainActor (Int) -> Void)?
    public var onError: (@MainActor (NWError) -> Void)?
    public var onStateChanged: (@MainActor (SimulationServerState) -> Void)?
    public private(set) var connectedClientCount = 0
    public private(set) var state: SimulationServerState = .stopped {
        didSet { if state != oldValue { onStateChanged?(state) } }
    }
    public var listeningPort: UInt16? { listener?.port?.rawValue }

    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "IndoorPositioningSimulation.server")
    private var listener: NWListener?
    private var shutdownTask: Task<Void, Never>?
    private var lifecycleGeneration = 0
    private var connections: [UUID: NWConnection] = [:]

    public init(port: UInt16 = SimulationTransportDefaults.port) throws {
        guard let port = NWEndpoint.Port(rawValue: port) else {
            throw SimulationTransportError.invalidPort(port)
        }
        self.port = port
    }

    deinit {
        listener?.cancel()
        connections.values.forEach { $0.cancel() }
    }

    public func start() throws {
        guard listener == nil else { return }
        let listener = try NWListener(using: .tcp, on: port)
        lifecycleGeneration += 1
        listener.service = NWListener.Service(type: SimulationTransportDefaults.serviceType)
        state = .starting
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            Task { @MainActor [weak self] in
                guard let self, let listener, self.listener === listener else {
                    connection.cancel()
                    return
                }
                self.accept(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor [weak self] in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.state = .listening
                case .failed(let error), .waiting(let error):
                    self.stop()
                    let message: String
                    if case .posix(.EADDRINUSE) = error {
                        message = "다른 컨트롤러가 연결을 사용 중입니다. 기존 앱을 ⌘Q로 종료한 뒤 다시 연결하세요."
                    } else {
                        message = error.localizedDescription
                    }
                    self.state = .failed(message)
                    self.onError?(error)
                default:
                    break
                }
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        lifecycleGeneration += 1
        if let listener {
            self.listener = nil
            let completion = AsyncStream<Void> { continuation in
                listener.stateUpdateHandler = { state in
                    if case .cancelled = state { continuation.finish() }
                }
                listener.cancel()
            }
            let previous = shutdownTask
            shutdownTask = Task {
                await previous?.value
                for await _ in completion { }
            }
        }
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        publishClientCount()
        state = .stopped
    }

    public func stopAndWait() async {
        stop()
        await shutdownTask?.value
    }

    /// Wait for the old listening socket to close before binding the same port.
    public func restart() async throws {
        stop()
        let generation = lifecycleGeneration
        await shutdownTask?.value
        try Task.checkCancellation()
        guard generation == lifecycleGeneration else { throw CancellationError() }
        try start()
    }

    public func broadcast(_ frame: SimulationSensorFrame) throws {
        let payload = try Self.encode(frame)
        for (id, connection) in connections {
            connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                guard error != nil else { return }
                Task { @MainActor [weak self] in
                    self?.removeConnection(id)
                }
            })
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in
                    self?.removeConnection(id)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        publishClientCount()
    }

    private func removeConnection(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
        publishClientCount()
    }

    private func publishClientCount() {
        connectedClientCount = connections.count
        onClientCountChanged?(connectedClientCount)
    }

    private static func encode(_ frame: SimulationSensorFrame) throws -> Data {
        let body = try JSONEncoder().encode(frame)
        guard body.count <= Int(UInt32.max) else {
            throw SimulationTransportError.frameTooLarge
        }
        var length = UInt32(body.count).bigEndian
        var result = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        result.append(body)
        return result
    }
}

/// Reconnecting localhost client used by iOS Simulator apps. The connection is
/// intentionally independent of any map or positioning SDK.
public final class SimulationSessionClient: @unchecked Sendable {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "IndoorPositioningSimulation.client")
    private var connection: NWConnection?
    private var continuations: [UUID: AsyncStream<SimulationSensorFrame>.Continuation] = [:]
    private var receiveBuffer = Data()
    private var running = false

    public init(
        host: String = SimulationTransportDefaults.host,
        port: UInt16 = SimulationTransportDefaults.port
    ) throws {
        guard let port = NWEndpoint.Port(rawValue: port) else {
            throw SimulationTransportError.invalidPort(port)
        }
        self.host = NWEndpoint.Host(host)
        self.port = port
    }

    deinit {
        connection?.cancel()
        continuations.values.forEach { $0.finish() }
    }

    public func frames() -> AsyncStream<SimulationSensorFrame> {
        AsyncStream(bufferingPolicy: .bufferingNewest(5)) { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in
                self?.queue.async { [weak self] in
                    self?.removeContinuationOnQueue(id)
                }
            }
            queue.async { [weak self] in
                guard let self else { return }
                self.continuations[id] = continuation
                self.running = true
                self.connectOnQueue()
            }
        }
    }

    public func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    private func connectOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard running, connection == nil else { return }
        let connection = NWConnection(host: host, port: port, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            self.queue.async {
                guard self.connection === connection else { return }
                switch state {
                case .ready:
                    self.receiveOnQueue(from: connection)
                case .failed, .cancelled:
                    self.scheduleReconnectOnQueue(connection)
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    private func receiveOnQueue(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            self.queue.async {
                guard self.connection === connection else { return }
                if let data, !data.isEmpty {
                    self.receiveBuffer.append(data)
                    self.decodeBufferedFramesOnQueue()
                }
                if isComplete || error != nil {
                    self.scheduleReconnectOnQueue(connection)
                } else {
                    self.receiveOnQueue(from: connection)
                }
            }
        }
    }

    private func decodeBufferedFramesOnQueue() {
        let headerSize = MemoryLayout<UInt32>.size
        while receiveBuffer.count >= headerSize {
            let length = receiveBuffer.prefix(headerSize).reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            let frameLength = Int(length)
            guard receiveBuffer.count >= headerSize + frameLength else { return }
            let body = receiveBuffer.subdata(in: headerSize..<(headerSize + frameLength))
            receiveBuffer.removeSubrange(0..<(headerSize + frameLength))
            guard let frame = try? JSONDecoder().decode(
                SimulationSensorFrame.self,
                from: body
            ), frame.schemaVersion == SimulationSensorFrame.currentSchemaVersion
            else { continue }
            continuations.values.forEach { $0.yield(frame) }
        }
    }

    private func scheduleReconnectOnQueue(_ previousConnection: NWConnection) {
        guard connection === previousConnection else { return }
        previousConnection.cancel()
        connection = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        guard running else { return }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.connectOnQueue()
        }
    }

    private func stopOnQueue() {
        running = false
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll(keepingCapacity: false)
        continuations.values.forEach { $0.finish() }
        continuations.removeAll()
    }

    private func removeContinuationOnQueue(_ id: UUID) {
        continuations.removeValue(forKey: id)
        if continuations.isEmpty {
            running = false
            connection?.cancel()
            connection = nil
            receiveBuffer.removeAll(keepingCapacity: false)
        }
    }
}

extension SimulationSessionClient: SimulatedWiFiSignalSource {
    public func observations() -> AsyncStream<[SimulatedWiFiObservation]> {
        mapDistinctFrames { $0.wifi }
    }
}

extension SimulationSessionClient: SimulatedBluetoothSignalSource {
    public func observations() -> AsyncStream<[SimulatedBluetoothObservation]> {
        mapDistinctFrames { $0.bluetooth }
    }
}

extension SimulationSessionClient: SimulatedMotionSource {
    public func samples() -> AsyncStream<SimulatedMotionSample> {
        mapFrames { $0.motion }
    }
}

private extension SimulationSessionClient {
    func mapDistinctFrames<Value: Equatable & Sendable>(
        _ transform: @escaping @Sendable (SimulationSensorFrame) -> Value
    ) -> AsyncStream<Value> {
        AsyncStream(bufferingPolicy: .bufferingNewest(5)) { continuation in
            let task = Task {
                var previous: Value?
                for await frame in frames() {
                    let value = transform(frame)
                    guard value != previous else { continue }
                    previous = value
                    continuation.yield(value)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func mapFrames<Value: Sendable>(
        _ transform: @escaping @Sendable (SimulationSensorFrame) -> Value
    ) -> AsyncStream<Value> {
        AsyncStream(bufferingPolicy: .bufferingNewest(5)) { continuation in
            let task = Task {
                for await frame in frames() {
                    continuation.yield(transform(frame))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
