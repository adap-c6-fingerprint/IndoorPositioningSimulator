@preconcurrency import Network
import Foundation

public enum SimulationTransportDefaults {
    public static let host = "127.0.0.1"
    public static let port: UInt16 = 57_575
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

/// TCP publisher hosted by the Mac controller. Multiple Simulator apps may
/// subscribe at once; reconnecting an app creates a new connection without
/// resetting the controller session.
@MainActor
public final class SimulationSessionServer {
    public var onClientCountChanged: (@MainActor (Int) -> Void)?
    public private(set) var connectedClientCount = 0

    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "IndoorPositioningSimulation.server")
    private var listener: NWListener?
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
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.accept(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else { return }
            Task { @MainActor [weak self] in
                self?.stop()
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        publishClientCount()
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
