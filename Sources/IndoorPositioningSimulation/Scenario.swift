import Foundation

public struct IMDFMapReference: Codable, Equatable, Sendable {
    public let venueID: String?
    public let venueName: String
    public let manifestVersion: String?
    public let levelID: String
    public let levelOrdinal: Int

    public init(
        venueID: String?,
        venueName: String,
        manifestVersion: String?,
        levelID: String,
        levelOrdinal: Int
    ) {
        self.venueID = venueID
        self.venueName = venueName
        self.manifestVersion = manifestVersion
        self.levelID = levelID
        self.levelOrdinal = levelOrdinal
    }
}

public struct ScenarioRadioAnchor: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let kind: RadioAnchorKind
    public let position: IndoorCoordinate
    public let referenceRSSI: Double
    public let pathLossExponent: Double

    public init(
        id: String,
        kind: RadioAnchorKind,
        position: IndoorCoordinate,
        referenceRSSI: Double = -40,
        pathLossExponent: Double = 2.1
    ) {
        self.id = id
        self.kind = kind
        self.position = position
        self.referenceRSSI = referenceRSSI
        self.pathLossExponent = pathLossExponent
    }
}

/// Portable, app-independent simulator input.
///
/// Geographic positions and IMDF level ordinals are the public contract.
/// The local meter frame is serialized only to make RF calculations
/// deterministic across different consuming apps.
public struct IMDFSimulationScenario: Identifiable, Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "1.0"

    public let schemaVersion: String
    public let id: UUID
    public var name: String
    public let map: IMDFMapReference
    public let coordinateReference: LocalCoordinateReference
    public let localBounds: SimulationBounds
    public var initialPosition: IndoorCoordinate
    public var anchors: [ScenarioRadioAnchor]
    public var movementStep: Double
    public var fingerprintGridSpacing: Double
    public var minimumVisibleRSSI: Double

    public init(
        id: UUID = UUID(),
        name: String,
        map: IMDFMapReference,
        coordinateReference: LocalCoordinateReference,
        localBounds: SimulationBounds,
        initialPosition: IndoorCoordinate,
        anchors: [ScenarioRadioAnchor],
        movementStep: Double = 1,
        fingerprintGridSpacing: Double = 1,
        minimumVisibleRSSI: Double = -95
    ) {
        precondition(!anchors.isEmpty)
        precondition(initialPosition.levelOrdinal == map.levelOrdinal)
        precondition(anchors.allSatisfy { $0.position.levelOrdinal == map.levelOrdinal })
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        self.map = map
        self.coordinateReference = coordinateReference
        self.localBounds = localBounds
        self.initialPosition = initialPosition
        self.anchors = anchors
        self.movementStep = movementStep
        self.fingerprintGridSpacing = fingerprintGridSpacing
        self.minimumVisibleRSSI = minimumVisibleRSSI
    }

    public func makeSimulator(
        calculatesEstimate: Bool = true
    ) throws -> WiFiIndoorPositioningSimulator {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw IMDFScenarioError.unsupportedSchemaVersion(schemaVersion)
        }
        guard !anchors.isEmpty else { throw IMDFScenarioError.missingRadioAnchors }
        guard initialPosition.levelOrdinal == map.levelOrdinal,
              anchors.allSatisfy({ $0.position.levelOrdinal == map.levelOrdinal })
        else {
            throw IMDFScenarioError.levelMismatch
        }

        let radioAnchors = anchors.map { anchor in
            RadioAnchor(
                id: anchor.id,
                kind: anchor.kind,
                position: coordinateReference.project(anchor.position.coordinate),
                referenceRSSI: anchor.referenceRSSI,
                pathLossExponent: anchor.pathLossExponent
            )
        }
        return WiFiIndoorPositioningSimulator(
            initialPosition: coordinateReference.project(initialPosition.coordinate),
            movementStep: movementStep,
            bounds: localBounds,
            radioEnvironment: SimulatedRadioEnvironment(
                anchors: radioAnchors,
                minimumVisibleRSSI: minimumVisibleRSSI
            ),
            fingerprintGridSpacing: fingerprintGridSpacing,
            calculatesEstimate: calculatesEstimate
        )
    }
}

public enum IMDFScenarioError: Error, Equatable, LocalizedError {
    case unsupportedSchemaVersion(String)
    case missingRadioAnchors
    case levelMismatch

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "지원하지 않는 시나리오 버전입니다: \(version)"
        case .missingRadioAnchors:
            "시나리오에 Wi-Fi 또는 비콘이 없습니다."
        case .levelMismatch:
            "시나리오의 위치와 신호원은 같은 IMDF 층에 있어야 합니다."
        }
    }
}

public struct IndoorPositionSample: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case simulatedRSSIFingerprint
    }

    public let coordinate: GeographicCoordinate
    public let levelOrdinal: Int
    public let horizontalAccuracy: Double
    public let heading: Double
    public let source: Source

    public init(
        coordinate: GeographicCoordinate,
        levelOrdinal: Int,
        horizontalAccuracy: Double,
        heading: Double,
        source: Source = .simulatedRSSIFingerprint
    ) {
        self.coordinate = coordinate
        self.levelOrdinal = levelOrdinal
        self.horizontalAccuracy = horizontalAccuracy
        self.heading = heading
        self.source = source
    }
}

public extension SimulationSnapshot {
    func positionSample(
        coordinateReference: LocalCoordinateReference,
        levelOrdinal: Int
    ) -> IndoorPositionSample? {
        guard let estimate else { return nil }
        return IndoorPositionSample(
            coordinate: coordinateReference.unproject(estimate.position),
            levelOrdinal: levelOrdinal,
            horizontalAccuracy: estimate.horizontalAccuracy,
            heading: heading
        )
    }
}

public enum IMDFScenarioCodec {
    public static func encode(_ scenario: IMDFSimulationScenario) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(scenario)
    }

    public static func decode(_ data: Data) throws -> IMDFSimulationScenario {
        let scenario = try JSONDecoder().decode(IMDFSimulationScenario.self, from: data)
        guard scenario.schemaVersion == IMDFSimulationScenario.currentSchemaVersion else {
            throw IMDFScenarioError.unsupportedSchemaVersion(scenario.schemaVersion)
        }
        return scenario
    }
}
