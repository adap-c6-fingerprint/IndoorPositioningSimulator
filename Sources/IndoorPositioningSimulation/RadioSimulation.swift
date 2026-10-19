import Foundation

public enum SimulationMovementDirection: String, Codable, Sendable {
    case north
    case south
    case east
    case west

    public var heading: Double {
        switch self {
        case .north: 0
        case .east: 90
        case .south: 180
        case .west: 270
        }
    }
}

public enum RadioAnchorKind: String, Codable, Equatable, Sendable {
    case wifi
    case beacon
}

public struct RadioAnchor: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let kind: RadioAnchorKind
    public let position: MeterPoint
    public let referenceRSSI: Double
    public let pathLossExponent: Double

    public init(
        id: String,
        kind: RadioAnchorKind,
        position: MeterPoint,
        referenceRSSI: Double = -40,
        pathLossExponent: Double = 2.1
    ) {
        precondition(pathLossExponent > 0)
        self.id = id
        self.kind = kind
        self.position = position
        self.referenceRSSI = referenceRSSI
        self.pathLossExponent = pathLossExponent
    }

    public func rssi(at position: MeterPoint) -> Double {
        let distance = max(position.distance(to: self.position), 1)
        return referenceRSSI - (10 * pathLossExponent * log10(distance))
    }

    public func moved(to position: MeterPoint) -> Self {
        Self(
            id: id,
            kind: kind,
            position: position,
            referenceRSSI: referenceRSSI,
            pathLossExponent: pathLossExponent
        )
    }
}

public struct WiFiReading: Codable, Equatable, Sendable {
    public let accessPointID: String
    public let rssi: Double

    public init(accessPointID: String, rssi: Double) {
        self.accessPointID = accessPointID
        self.rssi = rssi
    }
}

public struct SimulatedRadioEnvironment: Codable, Equatable, Sendable {
    public let anchors: [RadioAnchor]
    public let minimumVisibleRSSI: Double

    public init(anchors: [RadioAnchor], minimumVisibleRSSI: Double = -95) {
        precondition(!anchors.isEmpty)
        self.anchors = anchors
        self.minimumVisibleRSSI = minimumVisibleRSSI
    }

    public func scan(at position: MeterPoint) -> [WiFiReading] {
        anchors
            .map { anchor in
                WiFiReading(
                    accessPointID: anchor.id,
                    rssi: anchor.rssi(at: position)
                )
            }
            .filter { $0.rssi >= minimumVisibleRSSI }
            .sorted { $0.rssi > $1.rssi }
    }
}

public struct PositionEstimate: Codable, Equatable, Sendable {
    public let position: MeterPoint
    public let horizontalAccuracy: Double
    public let rootMeanSquareRSSIError: Double

    public init(
        position: MeterPoint,
        horizontalAccuracy: Double,
        rootMeanSquareRSSIError: Double
    ) {
        self.position = position
        self.horizontalAccuracy = horizontalAccuracy
        self.rootMeanSquareRSSIError = rootMeanSquareRSSIError
    }
}

public struct RSSIFingerprintGridEstimator: Sendable {
    public let radioEnvironment: SimulatedRadioEnvironment
    public let bounds: SimulationBounds
    public let gridSpacing: Double

    public init(
        radioEnvironment: SimulatedRadioEnvironment,
        bounds: SimulationBounds,
        gridSpacing: Double = 1
    ) {
        precondition(gridSpacing > 0)
        self.radioEnvironment = radioEnvironment
        self.bounds = bounds
        self.gridSpacing = gridSpacing
    }

    public func estimate(from readings: [WiFiReading]) -> PositionEstimate? {
        guard !readings.isEmpty else { return nil }
        let observedRSSI = Dictionary(
            uniqueKeysWithValues: readings.map { ($0.accessPointID, $0.rssi) }
        )
        var bestPoint: MeterPoint?
        var bestMeanSquaredError = Double.greatestFiniteMagnitude
        var north = bounds.minimumNorth

        while north <= bounds.maximumNorth + gridSpacing / 2 {
            var east = bounds.minimumEast
            while east <= bounds.maximumEast + gridSpacing / 2 {
                let candidate = MeterPoint(east: east, north: north)
                let squaredErrors = radioEnvironment.scan(at: candidate).compactMap { expected -> Double? in
                    guard let observed = observedRSSI[expected.accessPointID] else { return nil }
                    let difference = observed - expected.rssi
                    return difference * difference
                }

                if !squaredErrors.isEmpty {
                    let error = squaredErrors.reduce(0, +) / Double(squaredErrors.count)
                    if error < bestMeanSquaredError {
                        bestMeanSquaredError = error
                        bestPoint = candidate
                    }
                }
                east += gridSpacing
            }
            north += gridSpacing
        }

        guard let bestPoint else { return nil }
        let rootMeanSquareError = sqrt(bestMeanSquaredError)
        return PositionEstimate(
            position: bestPoint,
            horizontalAccuracy: max(gridSpacing, gridSpacing + rootMeanSquareError * 0.5),
            rootMeanSquareRSSIError: rootMeanSquareError
        )
    }
}

public struct SimulationSnapshot: Equatable, Sendable {
    public let actualPosition: MeterPoint
    public let estimate: PositionEstimate?
    public let readings: [WiFiReading]
    public let heading: Double
}

public struct WiFiIndoorPositioningSimulator: Sendable {
    public private(set) var actualPosition: MeterPoint
    public private(set) var heading: Double
    public let movementStep: Double
    public let bounds: SimulationBounds
    public let calculatesEstimate: Bool
    public private(set) var radioEnvironment: SimulatedRadioEnvironment
    public private(set) var estimator: RSSIFingerprintGridEstimator

    public init(
        initialPosition: MeterPoint,
        heading: Double = 0,
        movementStep: Double = 1,
        bounds: SimulationBounds,
        radioEnvironment: SimulatedRadioEnvironment,
        fingerprintGridSpacing: Double = 1,
        calculatesEstimate: Bool = true
    ) {
        precondition(movementStep > 0)
        actualPosition = bounds.clamped(initialPosition)
        self.heading = heading
        self.movementStep = movementStep
        self.bounds = bounds
        self.calculatesEstimate = calculatesEstimate
        self.radioEnvironment = radioEnvironment
        estimator = RSSIFingerprintGridEstimator(
            radioEnvironment: radioEnvironment,
            bounds: bounds,
            gridSpacing: fingerprintGridSpacing
        )
    }

    public var snapshot: SimulationSnapshot { makeSnapshot() }

    @discardableResult
    public mutating func moveAnchor(id: String, to position: MeterPoint) -> SimulationSnapshot {
        let clampedPosition = bounds.clamped(position)
        let anchors = radioEnvironment.anchors.map {
            $0.id == id ? $0.moved(to: clampedPosition) : $0
        }
        guard anchors != radioEnvironment.anchors else { return makeSnapshot() }
        replaceAnchors(anchors)
        return makeSnapshot()
    }

    @discardableResult
    public mutating func replaceAnchors(_ anchors: [RadioAnchor]) -> SimulationSnapshot {
        guard !anchors.isEmpty else { return makeSnapshot() }
        radioEnvironment = SimulatedRadioEnvironment(
            anchors: anchors,
            minimumVisibleRSSI: radioEnvironment.minimumVisibleRSSI
        )
        estimator = RSSIFingerprintGridEstimator(
            radioEnvironment: radioEnvironment,
            bounds: bounds,
            gridSpacing: estimator.gridSpacing
        )
        return makeSnapshot()
    }

    @discardableResult
    public mutating func moveUser(to position: MeterPoint) -> SimulationSnapshot {
        actualPosition = bounds.clamped(position)
        return makeSnapshot()
    }

    @discardableResult
    public mutating func move(_ direction: SimulationMovementDirection) -> SimulationSnapshot {
        move(direction, distance: movementStep)
    }

    @discardableResult
    public mutating func move(
        _ direction: SimulationMovementDirection,
        distance: Double
    ) -> SimulationSnapshot {
        precondition(distance >= 0)
        let proposedPosition = switch direction {
        case .north: MeterPoint(east: actualPosition.east, north: actualPosition.north + distance)
        case .south: MeterPoint(east: actualPosition.east, north: actualPosition.north - distance)
        case .east: MeterPoint(east: actualPosition.east + distance, north: actualPosition.north)
        case .west: MeterPoint(east: actualPosition.east - distance, north: actualPosition.north)
        }
        actualPosition = bounds.clamped(proposedPosition)
        heading = direction.heading
        return makeSnapshot()
    }

    @discardableResult
    public mutating func face(_ direction: SimulationMovementDirection) -> SimulationSnapshot {
        heading = direction.heading
        return makeSnapshot()
    }

    private func makeSnapshot() -> SimulationSnapshot {
        let readings = radioEnvironment.scan(at: actualPosition)
        return SimulationSnapshot(
            actualPosition: actualPosition,
            estimate: calculatesEstimate ? estimator.estimate(from: readings) : nil,
            readings: readings,
            heading: heading
        )
    }
}
