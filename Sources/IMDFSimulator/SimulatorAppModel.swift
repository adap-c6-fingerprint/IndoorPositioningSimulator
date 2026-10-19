import AppKit
import Foundation
import IndoorPositioningSimulation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class SimulatorAppModel {
    /// 1.5x the original 0.75m/s QA walking profile.
    static let walkingSpeedMetersPerSecond = 1.125
    private static let lastIMDFPathKey = "IndoorSensorSimulator.lastIMDFPath"
    private static let selectedSimulatorIDKey = "IndoorSensorSimulator.selectedSimulatorID"

    enum Selection: Equatable {
        case user
        case anchor(String)
    }

    private(set) var map: IMDFMap?
    private(set) var selectedLevel: IMDFMapLevel?
    private(set) var scenario: IMDFSimulationScenario?
    private(set) var simulator: WiFiIndoorPositioningSimulator?
    private(set) var snapshot: SimulationSnapshot?
    private(set) var latestFrame: SimulationSensorFrame?
    private(set) var connectedClientCount = 0
    private(set) var bootedSimulators: [BootedXcodeSimulator] = []
    private(set) var coreLocationStatus = "대기 중"
    var injectsCoreLocation = true
    var usesRadioPositioning = true {
        didSet {
            guard usesRadioPositioning != oldValue else { return }
            sensorGenerator.invalidateRadioObservations()
            publishFrame(
                deltaTime: 1 / SimulatedSensorGenerator.defaultMotionFrequencyHertz
            )
        }
    }
    var appliesSensorNoise = true {
        didSet {
            sensorGenerator.setNoiseProfile(
                appliesSensorNoise ? .realisticIndoor : .none
            )
            publishFrame(
                deltaTime: 1 / SimulatedSensorGenerator.defaultMotionFrequencyHertz
            )
        }
    }
    var selectedSimulatorID: String? {
        didSet {
            guard selectedSimulatorID != oldValue else { return }
            UserDefaults.standard.set(
                selectedSimulatorID,
                forKey: Self.selectedSimulatorIDKey
            )
        }
    }
    var selection: Selection = .user
    var errorMessage: String?

    private var temporaryDirectories: [URL] = []
    private var scenariosByLevelID: [String: IMDFSimulationScenario] = [:]
    private var didLoadCommandLineIMDF = false
    private var activeDirections: [SimulationMovementDirection] = []
    private var clockTask: Task<Void, Never>?
    private var coreLocationTask: Task<Void, Never>?
    private var lastCoreLocationPush = Date.distantPast
    private var sensorGenerator = SimulatedSensorGenerator()
    private let locationInjector = XcodeSimulatorLocationInjector()
    private var sessionServer: SimulationSessionServer?

    init() {
        selectedSimulatorID = UserDefaults.standard.string(
            forKey: Self.selectedSimulatorIDKey
        )
        do {
            let server = try SimulationSessionServer()
            server.onClientCountChanged = { [weak self] count in
                self?.connectedClientCount = count
            }
            try server.start()
            sessionServer = server
        } catch {
            errorMessage = error.localizedDescription
        }
        startClock()
        Task { @MainActor [weak self] in
            await self?.refreshBootedSimulators()
        }
    }

    var selectedAnchor: RadioAnchor? {
        guard case .anchor(let id) = selection else { return nil }
        return simulator?.radioEnvironment.anchors.first { $0.id == id }
    }

    var isWalking: Bool { !activeDirections.isEmpty }

    var positioningMode: SimulationPositioningMode {
        usesRadioPositioning ? .radioBased : .groundTruth
    }

    var selectedSimulator: BootedXcodeSimulator? {
        bootedSimulators.first { $0.id == selectedSimulatorID }
    }

    var isReadyToMove: Bool {
        map != nil && simulator != nil
    }

    var currentVerticalConnectorName: String? {
        guard let level = selectedLevel,
              let scenario,
              let simulator
        else { return nil }
        let coordinate = scenario.coordinateReference.unproject(simulator.actualPosition)
        return level.verticalConnector(containing: coordinate)?.category
    }

    func loadCommandLineIMDFIfNeeded() {
        guard !didLoadCommandLineIMDF else { return }
        didLoadCommandLineIMDF = true
        let path = ProcessInfo.processInfo.environment["IMDF_SIMULATOR_SOURCE"]
            ?? ProcessInfo.processInfo.arguments.dropFirst().first
            ?? UserDefaults.standard.string(forKey: Self.lastIMDFPathKey)
        guard let path, FileManager.default.fileExists(atPath: path) else { return }
        loadIMDF(at: URL(fileURLWithPath: path))
    }

    func refreshBootedSimulators() async {
        do {
            let devices = try await locationInjector.bootedSimulators()
            bootedSimulators = devices
            if !devices.contains(where: { $0.id == selectedSimulatorID }) {
                selectedSimulatorID = devices.first?.id
            }
            if devices.isEmpty {
                coreLocationStatus = "실행 중인 iOS Simulator가 없습니다."
            } else if let selectedSimulator {
                coreLocationStatus = "\(selectedSimulator.name)에 전달 준비"
            }
        } catch {
            bootedSimulators = []
            selectedSimulatorID = nil
            coreLocationStatus = "iOS Simulator 목록을 읽지 못했습니다."
        }
    }

    func chooseIMDF() {
        let panel = NSOpenPanel()
        panel.title = "IMDF 폴더 또는 ZIP 열기"
        panel.prompt = "열기"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadIMDF(at: url)
    }

    func chooseScenario() {
        let panel = NSOpenPanel()
        panel.title = "시뮬레이션 시나리오 열기"
        panel.prompt = "열기"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let decoded = try IMDFScenarioCodec.decode(Data(contentsOf: url))
            if let map,
               let venueID = map.venueID,
               let scenarioVenueID = decoded.map.venueID,
               venueID != scenarioVenueID
            {
                throw SimulatorAppError.scenarioVenueMismatch
            }
            scenario = decoded
            scenariosByLevelID[decoded.map.levelID] = decoded
            simulator = try decoded.makeSimulator(calculatesEstimate: false)
            snapshot = simulator?.snapshot
            if let map {
                selectedLevel = map.levels.first { $0.id == decoded.map.levelID }
                    ?? map.levels.first { $0.ordinal == decoded.map.levelOrdinal }
            }
            selection = .user
            errorMessage = nil
            publishFrame(deltaTime: 1 / SimulatedSensorGenerator.defaultMotionFrequencyHertz)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveScenario() {
        guard var scenario, let simulator else { return }
        scenario = scenario.updated(from: simulator)

        let panel = NSSavePanel()
        panel.title = "시뮬레이션 시나리오 저장"
        panel.nameFieldStringValue = "\(sanitized(scenario.name)).indoor-sim.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try IMDFScenarioCodec.encode(scenario).write(to: url, options: .atomic)
            self.scenario = scenario
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadIMDF(at sourceURL: URL) {
        do {
            let directory = try resolveIMDFDirectory(sourceURL)
            let decodedMap = try IMDFArchiveLoader.load(from: directory)
            scenariosByLevelID.removeAll()
            map = decodedMap
            let initialLevel = decodedMap.levels.first { $0.ordinal == 4 }
                ?? decodedMap.levels.first
            guard let initialLevel else { throw IMDFArchiveError.missingGeometry }
            try configureDefaultScenario(for: initialLevel, in: decodedMap)
            UserDefaults.standard.set(sourceURL.path, forKey: Self.lastIMDFPathKey)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectLevel(_ level: IMDFMapLevel) {
        guard let map else { return }
        do {
            try configureDefaultScenario(for: level, in: map)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func move(_ direction: SimulationMovementDirection) {
        move(direction, distance: Self.walkingSpeedMetersPerSecond)
        publishFrame(deltaTime: 1)
    }

    func beginMoving(_ direction: SimulationMovementDirection) {
        activeDirections.removeAll { $0 == direction }
        activeDirections.append(direction)
    }

    func endMoving(_ direction: SimulationMovementDirection) {
        activeDirections.removeAll { $0 == direction }
    }

    func nudge(_ direction: SimulationMovementDirection) {
        move(direction, distance: 0.2)
        publishFrame(deltaTime: 1 / SimulatedSensorGenerator.defaultMotionFrequencyHertz)
    }

    func moveUser(to position: MeterPoint) {
        guard var simulator,
              canTravel(from: simulator.actualPosition, to: position)
        else { return }
        snapshot = simulator.moveUser(to: position)
        self.simulator = simulator
        selection = .user
        synchronizeScenario()
        publishFrame(deltaTime: 1 / SimulatedSensorGenerator.defaultMotionFrequencyHertz)
    }

    func moveAnchor(id: String, to position: MeterPoint) {
        guard var simulator else { return }
        snapshot = simulator.moveAnchor(id: id, to: position)
        self.simulator = simulator
        selection = .anchor(id)
        synchronizeScenario()
        sensorGenerator.invalidateRadioObservations()
        publishFrame(deltaTime: 1 / SimulatedSensorGenerator.defaultMotionFrequencyHertz)
    }

    func addAnchor(kind: RadioAnchorKind) {
        guard var simulator else { return }
        let prefix = kind == .wifi ? "WIFI" : "BEACON"
        let existingIDs = Set(simulator.radioEnvironment.anchors.map(\.id))
        var index = simulator.radioEnvironment.anchors.count + 1
        while existingIDs.contains("\(prefix)-\(index)") { index += 1 }
        let anchor = RadioAnchor(
            id: "\(prefix)-\(index)",
            kind: kind,
            position: simulator.actualPosition,
            referenceRSSI: kind == .wifi ? -40 : -45,
            pathLossExponent: kind == .wifi ? 3.0 : 2.2
        )
        snapshot = simulator.replaceAnchors(simulator.radioEnvironment.anchors + [anchor])
        self.simulator = simulator
        selection = .anchor(anchor.id)
        synchronizeScenario()
        sensorGenerator.invalidateRadioObservations()
        publishFrame(deltaTime: 1 / SimulatedSensorGenerator.defaultMotionFrequencyHertz)
    }

    func removeSelectedAnchor() {
        guard case .anchor(let id) = selection,
              var simulator,
              simulator.radioEnvironment.anchors.count > 1
        else { return }
        let anchors = simulator.radioEnvironment.anchors.filter { $0.id != id }
        snapshot = simulator.replaceAnchors(anchors)
        self.simulator = simulator
        selection = .user
        synchronizeScenario()
        sensorGenerator.invalidateRadioObservations()
        publishFrame(deltaTime: 1 / SimulatedSensorGenerator.defaultMotionFrequencyHertz)
    }

    func updateSelectedAnchor(referenceRSSI: Double? = nil, pathLossExponent: Double? = nil) {
        guard let selectedAnchor, var simulator else { return }
        let anchors = simulator.radioEnvironment.anchors.map { anchor in
            guard anchor.id == selectedAnchor.id else { return anchor }
            return RadioAnchor(
                id: anchor.id,
                kind: anchor.kind,
                position: anchor.position,
                referenceRSSI: referenceRSSI ?? anchor.referenceRSSI,
                pathLossExponent: pathLossExponent ?? anchor.pathLossExponent
            )
        }
        snapshot = simulator.replaceAnchors(anchors)
        self.simulator = simulator
        synchronizeScenario()
        sensorGenerator.invalidateRadioObservations()
        publishFrame(deltaTime: 1 / SimulatedSensorGenerator.defaultMotionFrequencyHertz)
    }

    func transitionFloor(by offset: Int) {
        guard offset != 0,
              let map,
              let selectedLevel,
              let scenario,
              let simulator,
              let sourceIndex = map.levels.firstIndex(where: { $0.id == selectedLevel.id })
        else { return }

        let currentCoordinate = scenario.coordinateReference.unproject(simulator.actualPosition)
        guard let connector = selectedLevel.verticalConnector(containing: currentCoordinate) else {
            errorMessage = "엘리베이터·계단·에스컬레이터 영역에서만 층을 이동할 수 있습니다."
            return
        }

        let targetIndex = sourceIndex + offset
        guard map.levels.indices.contains(targetIndex) else { return }
        let targetLevel = map.levels[targetIndex]
        let targetConnector = targetLevel.units.first { $0.category == connector.category }
        let targetCoordinate = targetConnector?.polygons.first?.approximateCenter
            ?? targetLevel.suggestedNavigableCoordinate()

        do {
            try configureDefaultScenario(
                for: targetLevel,
                in: map,
                initialCoordinate: targetCoordinate
            )
            publishFrame(deltaTime: 1 / SimulatedSensorGenerator.defaultMotionFrequencyHertz)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func configureDefaultScenario(
        for level: IMDFMapLevel,
        in map: IMDFMap,
        initialCoordinate: GeographicCoordinate? = nil
    ) throws {
        let reference = try level.coordinateReference()
        let bounds = try level.localBounds()

        if var cachedScenario = scenariosByLevelID[level.id] {
            if let initialCoordinate {
                cachedScenario.initialPosition = IndoorCoordinate(
                    coordinate: initialCoordinate,
                    levelOrdinal: level.ordinal
                )
            }
            selectedLevel = level
            scenario = cachedScenario
            simulator = try cachedScenario.makeSimulator(calculatesEstimate: false)
            snapshot = simulator?.snapshot
            selection = .user
            scenariosByLevelID[level.id] = cachedScenario
            sensorGenerator.invalidateRadioObservations()
            publishFrame(deltaTime: 1 / SimulatedSensorGenerator.defaultMotionFrequencyHertz)
            return
        }

        let width = bounds.maximumEast - bounds.minimumEast
        let height = bounds.maximumNorth - bounds.minimumNorth
        let insetEast = max(2, width * 0.15)
        let insetNorth = max(2, height * 0.15)
        let west = bounds.minimumEast + insetEast
        let east = bounds.maximumEast - insetEast
        let south = bounds.minimumNorth + insetNorth
        let north = bounds.maximumNorth - insetNorth
        let middleNorth = (bounds.minimumNorth + bounds.maximumNorth) / 2
        let middleEast = (bounds.minimumEast + bounds.maximumEast) / 2
        let localAnchors: [(String, RadioAnchorKind, MeterPoint)] = [
            ("WIFI-NW", .wifi, MeterPoint(east: west, north: north)),
            ("WIFI-NE", .wifi, MeterPoint(east: east, north: north)),
            ("WIFI-MW", .wifi, MeterPoint(east: west, north: middleNorth)),
            ("WIFI-ME", .wifi, MeterPoint(east: east, north: middleNorth)),
            ("WIFI-SW", .wifi, MeterPoint(east: west, north: south)),
            ("WIFI-SE", .wifi, MeterPoint(east: east, north: south)),
            ("BEACON-N", .beacon, MeterPoint(
                east: middleEast,
                north: bounds.minimumNorth + height * 0.67
            )),
            ("BEACON-S", .beacon, MeterPoint(
                east: middleEast,
                north: bounds.minimumNorth + height * 0.33
            ))
        ]
        let indoorPosition: (MeterPoint) -> IndoorCoordinate = { point in
            IndoorCoordinate(
                coordinate: reference.unproject(point),
                levelOrdinal: level.ordinal
            )
        }
        let mapReference = IMDFMapReference(
            venueID: map.venueID,
            venueName: map.venueName,
            manifestVersion: map.manifestVersion,
            levelID: level.id,
            levelOrdinal: level.ordinal
        )
        let scenario = IMDFSimulationScenario(
            name: "\(map.venueName) · \(level.shortName ?? level.name)",
            map: mapReference,
            coordinateReference: reference,
            localBounds: bounds,
            initialPosition: IndoorCoordinate(
                coordinate: initialCoordinate
                    ?? level.suggestedNavigableCoordinate()
                    ?? reference.unproject(bounds.center),
                levelOrdinal: level.ordinal
            ),
            anchors: localAnchors.map { id, kind, point in
                ScenarioRadioAnchor(
                    id: id,
                    kind: kind,
                    position: indoorPosition(point),
                    referenceRSSI: kind == .wifi ? -40 : -45,
                    pathLossExponent: kind == .wifi ? 3.0 : 2.2
                )
            }
        )
        selectedLevel = level
        self.scenario = scenario
        scenariosByLevelID[level.id] = scenario
        simulator = try scenario.makeSimulator(calculatesEstimate: false)
        snapshot = simulator?.snapshot
        selection = .user
        sensorGenerator.invalidateRadioObservations()
        publishFrame(deltaTime: 1 / SimulatedSensorGenerator.defaultMotionFrequencyHertz)
    }

    private func synchronizeScenario() {
        guard let simulator else { return }
        scenario = scenario?.updated(from: simulator)
        if let scenario {
            scenariosByLevelID[scenario.map.levelID] = scenario
        }
    }

    private func startClock() {
        clockTask = Task { @MainActor [weak self] in
            var previousDate = Date()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(20))
                } catch {
                    return
                }
                guard let self else { return }
                let currentDate = Date()
                let deltaTime = min(max(currentDate.timeIntervalSince(previousDate), 0.001), 0.1)
                previousDate = currentDate

                if let direction = self.activeDirections.last {
                    self.move(
                        direction,
                        distance: Self.walkingSpeedMetersPerSecond * deltaTime
                    )
                }
                self.publishFrame(deltaTime: deltaTime)
            }
        }
    }

    private func move(_ direction: SimulationMovementDirection, distance: Double) {
        guard var simulator else { return }
        let proposed = switch direction {
        case .north:
            MeterPoint(
                east: simulator.actualPosition.east,
                north: simulator.actualPosition.north + distance
            )
        case .south:
            MeterPoint(
                east: simulator.actualPosition.east,
                north: simulator.actualPosition.north - distance
            )
        case .east:
            MeterPoint(
                east: simulator.actualPosition.east + distance,
                north: simulator.actualPosition.north
            )
        case .west:
            MeterPoint(
                east: simulator.actualPosition.east - distance,
                north: simulator.actualPosition.north
            )
        }

        if canOccupy(proposed) {
            snapshot = simulator.move(direction, distance: distance)
        } else {
            snapshot = simulator.face(direction)
        }
        self.simulator = simulator
        synchronizeScenario()
    }

    private func canOccupy(_ point: MeterPoint) -> Bool {
        guard let level = selectedLevel,
              let scenario
        else { return false }
        return level.isNavigable(scenario.coordinateReference.unproject(point))
    }

    private func canTravel(from start: MeterPoint, to end: MeterPoint) -> Bool {
        let distance = start.distance(to: end)
        let sampleCount = max(1, Int(ceil(distance / 0.1)))
        return (1...sampleCount).allSatisfy { index in
            let progress = Double(index) / Double(sampleCount)
            return canOccupy(MeterPoint(
                east: start.east + (end.east - start.east) * progress,
                north: start.north + (end.north - start.north) * progress
            ))
        }
    }

    private func publishFrame(deltaTime: TimeInterval) {
        guard let scenario,
              let simulator
        else { return }
        let coordinate = scenario.coordinateReference.unproject(simulator.actualPosition)
        let position = IndoorCoordinate(
            coordinate: coordinate,
            levelOrdinal: scenario.map.levelOrdinal
        )
        let frame = sensorGenerator.makeFrame(
            position: position,
            localPosition: simulator.actualPosition,
            headingDegrees: simulator.heading,
            walking: isWalking,
            positioningMode: positioningMode,
            speedMetersPerSecond: Self.walkingSpeedMetersPerSecond,
            radioEnvironment: simulator.radioEnvironment,
            deltaTime: deltaTime
        )
        latestFrame = frame
        do {
            try sessionServer?.broadcast(frame)
        } catch {
            errorMessage = error.localizedDescription
        }
        pushCoreLocationIfNeeded(coordinate)
    }

    private func pushCoreLocationIfNeeded(_ coordinate: GeographicCoordinate) {
        guard injectsCoreLocation,
              let selectedSimulatorID,
              coreLocationTask == nil,
              Date().timeIntervalSince(lastCoreLocationPush) >= 0.2
        else { return }
        lastCoreLocationPush = Date()
        coreLocationTask = Task { @MainActor [weak self, locationInjector] in
            defer { self?.coreLocationTask = nil }
            do {
                try await locationInjector.setLocation(
                    coordinate,
                    simulatorID: selectedSimulatorID
                )
                let name = self?.selectedSimulator?.name ?? "선택한 Simulator"
                self?.coreLocationStatus = "\(name)에 전달 중"
            } catch {
                self?.coreLocationStatus = "위치 전달 실패 · Simulator를 새로고침하세요."
            }
        }
    }

    private func resolveIMDFDirectory(_ sourceURL: URL) throws -> URL {
        let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true { return sourceURL }
        guard sourceURL.pathExtension.lowercased() == "zip" else {
            throw SimulatorAppError.unsupportedIMDFSource
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("imdf-simulator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", sourceURL.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SimulatorAppError.cannotExtractArchive
        }
        temporaryDirectories.append(destination)
        return destination
    }

    private func sanitized(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "-")
    }
}

private extension IMDFSimulationScenario {
    func updated(from simulator: WiFiIndoorPositioningSimulator) -> Self {
        var result = self
        result.initialPosition = IndoorCoordinate(
            coordinate: coordinateReference.unproject(simulator.actualPosition),
            levelOrdinal: map.levelOrdinal
        )
        result.anchors = simulator.radioEnvironment.anchors.map { anchor in
            ScenarioRadioAnchor(
                id: anchor.id,
                kind: anchor.kind,
                position: IndoorCoordinate(
                    coordinate: coordinateReference.unproject(anchor.position),
                    levelOrdinal: map.levelOrdinal
                ),
                referenceRSSI: anchor.referenceRSSI,
                pathLossExponent: anchor.pathLossExponent
            )
        }
        return result
    }
}

private enum SimulatorAppError: Error, LocalizedError {
    case unsupportedIMDFSource
    case cannotExtractArchive
    case scenarioVenueMismatch

    var errorDescription: String? {
        switch self {
        case .unsupportedIMDFSource:
            "IMDF 폴더 또는 ZIP 파일을 선택해주세요."
        case .cannotExtractArchive:
            "IMDF ZIP 파일을 풀 수 없습니다."
        case .scenarioVenueMismatch:
            "열려 있는 IMDF와 시나리오의 venue ID가 다릅니다."
        }
    }
}
