import Foundation

public struct IMDFPolygon: Equatable, Sendable {
    public let rings: [[GeographicCoordinate]]

    public init(rings: [[GeographicCoordinate]]) {
        self.rings = rings
    }

    public func contains(_ coordinate: GeographicCoordinate) -> Bool {
        guard let exterior = rings.first,
              Self.ring(exterior, contains: coordinate)
        else { return false }
        return !rings.dropFirst().contains { Self.ring($0, contains: coordinate) }
    }

    public var approximateCenter: GeographicCoordinate? {
        guard let exterior = rings.first, !exterior.isEmpty else { return nil }
        let vertices = exterior.count > 1 && exterior.first == exterior.last
            ? Array(exterior.dropLast())
            : exterior
        guard !vertices.isEmpty else { return nil }
        let latitude = vertices.reduce(0) { $0 + $1.latitude } / Double(vertices.count)
        let longitude = vertices.reduce(0) { $0 + $1.longitude } / Double(vertices.count)
        return GeographicCoordinate(latitude: latitude, longitude: longitude)
    }

    private static func ring(
        _ ring: [GeographicCoordinate],
        contains point: GeographicCoordinate
    ) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var previous = ring[ring.count - 1]
        for current in ring {
            let crossesLatitude = (current.latitude > point.latitude)
                != (previous.latitude > point.latitude)
            if crossesLatitude {
                let longitudeAtLatitude = (previous.longitude - current.longitude)
                    * (point.latitude - current.latitude)
                    / (previous.latitude - current.latitude)
                    + current.longitude
                if point.longitude < longitudeAtLatitude { inside.toggle() }
            }
            previous = current
        }
        return inside
    }
}

public struct IMDFMapUnit: Identifiable, Equatable, Sendable {
    public let id: String
    public let levelID: String
    public let category: String
    public let name: String?
    public let polygons: [IMDFPolygon]
}

public struct IMDFMapFixture: Identifiable, Equatable, Sendable {
    public let id: String
    public let levelID: String
    public let category: String
    public let name: String?
    public let polygons: [IMDFPolygon]
}

public struct IMDFMapLevel: Identifiable, Equatable, Sendable {
    public let id: String
    public let ordinal: Int
    public let name: String
    public let shortName: String?
    public let polygons: [IMDFPolygon]
    public let units: [IMDFMapUnit]
    public let fixtures: [IMDFMapFixture]

    public var allCoordinates: [GeographicCoordinate] {
        let levelCoordinates = polygons.flatMap(\.rings).flatMap { $0 }
        let unitCoordinates = units.flatMap(\.polygons).flatMap(\.rings).flatMap { $0 }
        let fixtureCoordinates = fixtures.flatMap(\.polygons).flatMap(\.rings).flatMap { $0 }
        if !levelCoordinates.isEmpty { return levelCoordinates }
        return unitCoordinates + fixtureCoordinates
    }

    public func isNavigable(_ coordinate: GeographicCoordinate) -> Bool {
        guard polygons.contains(where: { $0.contains(coordinate) }) else { return false }
        let isInsideWall = units
            .filter { $0.category == "structure" }
            .flatMap(\.polygons)
            .contains { $0.contains(coordinate) }
        guard !isInsideWall else { return false }
        return !fixtures.flatMap(\.polygons).contains { $0.contains(coordinate) }
    }

    public func verticalConnector(containing coordinate: GeographicCoordinate) -> IMDFMapUnit? {
        let categories = Set(["elevator", "stairs", "escalator"])
        return units.first { unit in
            categories.contains(unit.category)
                && unit.polygons.contains { $0.contains(coordinate) }
        }
    }

    public func suggestedNavigableCoordinate() -> GeographicCoordinate? {
        let preferredCategories = ["walkway", "lobby", "room", "office"]
        for category in preferredCategories {
            for unit in units where unit.category == category {
                for polygon in unit.polygons {
                    if let center = polygon.approximateCenter, isNavigable(center) {
                        return center
                    }
                }
            }
        }
        for polygon in polygons {
            if let center = polygon.approximateCenter, isNavigable(center) {
                return center
            }
        }
        return allCoordinates.first(where: isNavigable)
    }

    public func coordinateReference() throws -> LocalCoordinateReference {
        guard let first = allCoordinates.first else { throw IMDFArchiveError.missingGeometry }
        let bounds = allCoordinates.dropFirst().reduce(
            (first.latitude, first.latitude, first.longitude, first.longitude)
        ) { partial, coordinate in
            (
                min(partial.0, coordinate.latitude),
                max(partial.1, coordinate.latitude),
                min(partial.2, coordinate.longitude),
                max(partial.3, coordinate.longitude)
            )
        }
        return LocalCoordinateReference(
            origin: GeographicCoordinate(
                latitude: (bounds.0 + bounds.1) / 2,
                longitude: (bounds.2 + bounds.3) / 2
            )
        )
    }

    public func localBounds(padding: Double = 2) throws -> SimulationBounds {
        let reference = try coordinateReference()
        let points = allCoordinates.map(reference.project)
        guard let first = points.first else { throw IMDFArchiveError.missingGeometry }
        let bounds = points.dropFirst().reduce(
            (first.east, first.east, first.north, first.north)
        ) { partial, point in
            (
                min(partial.0, point.east),
                max(partial.1, point.east),
                min(partial.2, point.north),
                max(partial.3, point.north)
            )
        }
        return SimulationBounds(
            minimumEast: bounds.0 - padding,
            maximumEast: bounds.1 + padding,
            minimumNorth: bounds.2 - padding,
            maximumNorth: bounds.3 + padding
        )
    }
}

public struct IMDFMap: Equatable, Sendable {
    public let venueID: String?
    public let venueName: String
    public let manifestVersion: String?
    public let levels: [IMDFMapLevel]
    public let sourceDirectory: URL
}

public enum IMDFArchiveError: Error, LocalizedError {
    case archiveRootNotFound
    case missingRequiredFile(String)
    case invalidFeatureCollection(String)
    case missingGeometry

    public var errorDescription: String? {
        switch self {
        case .archiveRootNotFound:
            "IMDF의 manifest.json 또는 level.geojson을 찾지 못했습니다."
        case .missingRequiredFile(let name):
            "필수 IMDF 파일이 없습니다: \(name)"
        case .invalidFeatureCollection(let name):
            "IMDF GeoJSON을 해석할 수 없습니다: \(name)"
        case .missingGeometry:
            "선택한 IMDF 층에 표시 가능한 geometry가 없습니다."
        }
    }
}

public enum IMDFArchiveLoader {
    public static func load(from directory: URL) throws -> IMDFMap {
        let root = try resolveArchiveRoot(from: directory)
        let levelsURL = root.appendingPathComponent("level.geojson")
        guard FileManager.default.fileExists(atPath: levelsURL.path) else {
            throw IMDFArchiveError.missingRequiredFile("level.geojson")
        }

        let rawLevels: RawFeatureCollection<RawLevelProperties> = try decode(levelsURL)
        let unitsURL = root.appendingPathComponent("unit.geojson")
        let rawUnits: RawFeatureCollection<RawUnitProperties>
        if FileManager.default.fileExists(atPath: unitsURL.path) {
            rawUnits = try decode(unitsURL)
        } else {
            rawUnits = RawFeatureCollection(features: [])
        }

        let units = rawUnits.features.compactMap { feature -> IMDFMapUnit? in
            guard let geometry = feature.geometry else { return nil }
            return IMDFMapUnit(
                id: feature.id,
                levelID: feature.properties.levelID,
                category: feature.properties.category,
                name: feature.properties.name?.bestValue,
                polygons: geometry.polygons
            )
        }
        let unitsByLevel = Dictionary(grouping: units, by: \.levelID)

        let fixturesURL = root.appendingPathComponent("fixture.geojson")
        let rawFixtures: RawFeatureCollection<RawFixtureProperties>
        if FileManager.default.fileExists(atPath: fixturesURL.path) {
            rawFixtures = try decode(fixturesURL)
        } else {
            rawFixtures = RawFeatureCollection(features: [])
        }
        let fixtures = rawFixtures.features.compactMap { feature -> IMDFMapFixture? in
            guard let geometry = feature.geometry else { return nil }
            return IMDFMapFixture(
                id: feature.id,
                levelID: feature.properties.levelID,
                category: feature.properties.category,
                name: feature.properties.name?.bestValue,
                polygons: geometry.polygons
            )
        }
        let fixturesByLevel = Dictionary(grouping: fixtures, by: \.levelID)

        let levels = rawLevels.features.compactMap { feature -> IMDFMapLevel? in
            guard let geometry = feature.geometry else { return nil }
            return IMDFMapLevel(
                id: feature.id,
                ordinal: feature.properties.ordinal,
                name: feature.properties.name?.bestValue
                    ?? feature.properties.shortName?.bestValue
                    ?? "Level \(feature.properties.ordinal)",
                shortName: feature.properties.shortName?.bestValue,
                polygons: geometry.polygons,
                units: unitsByLevel[feature.id] ?? [],
                fixtures: fixturesByLevel[feature.id] ?? []
            )
        }
        .sorted { $0.ordinal < $1.ordinal }

        guard !levels.isEmpty else {
            throw IMDFArchiveError.invalidFeatureCollection("level.geojson")
        }

        let venueURL = root.appendingPathComponent("venue.geojson")
        let venue: RawFeature<RawVenueProperties>? = if FileManager.default.fileExists(
            atPath: venueURL.path
        ) {
            try decode(RawFeatureCollection<RawVenueProperties>.self, venueURL).features.first
        } else {
            nil
        }
        let manifestURL = root.appendingPathComponent("manifest.json")
        let manifest = try? decode(RawManifest.self, manifestURL)

        return IMDFMap(
            venueID: venue?.id,
            venueName: venue?.properties.name?.bestValue ?? root.lastPathComponent,
            manifestVersion: manifest?.version,
            levels: levels,
            sourceDirectory: root
        )
    }

    private static func resolveArchiveRoot(from url: URL) throws -> URL {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw IMDFArchiveError.archiveRootNotFound }

        if FileManager.default.fileExists(
            atPath: url.appendingPathComponent("level.geojson").path
        ) {
            return url
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw IMDFArchiveError.archiveRootNotFound
        }

        for case let candidate as URL in enumerator
        where candidate.lastPathComponent == "level.geojson" {
            return candidate.deletingLastPathComponent()
        }
        throw IMDFArchiveError.archiveRootNotFound
    }

    private static func decode<T: Decodable>(_ url: URL) throws -> T {
        try decode(T.self, url)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}

private struct RawManifest: Decodable {
    let version: String?
}

private struct RawFeatureCollection<Properties: Decodable>: Decodable {
    let features: [RawFeature<Properties>]
}

private struct RawFeature<Properties: Decodable>: Decodable {
    let id: String
    let properties: Properties
    let geometry: RawGeometry?
}

private struct RawLevelProperties: Decodable {
    let ordinal: Int
    let name: RawLocalizedString?
    let shortName: RawLocalizedString?

    enum CodingKeys: String, CodingKey {
        case ordinal
        case name
        case shortName = "short_name"
    }
}

private struct RawUnitProperties: Decodable {
    let category: String
    let name: RawLocalizedString?
    let levelID: String

    enum CodingKeys: String, CodingKey {
        case category
        case name
        case levelID = "level_id"
    }
}

private struct RawFixtureProperties: Decodable {
    let category: String
    let name: RawLocalizedString?
    let levelID: String

    enum CodingKeys: String, CodingKey {
        case category
        case name
        case levelID = "level_id"
    }
}

private struct RawVenueProperties: Decodable {
    let name: RawLocalizedString?
}

private struct RawLocalizedString: Decodable {
    let values: [String: String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            values = ["und": value]
        } else {
            values = try container.decode([String: String].self)
        }
    }

    var bestValue: String? {
        let language = Locale.current.language.languageCode?.identifier
        return language.flatMap { values[$0] }
            ?? values["en"]
            ?? values["und"]
            ?? values.keys.sorted().compactMap { values[$0] }.first
    }
}

private struct RawGeometry: Decodable {
    let polygons: [IMDFPolygon]

    enum CodingKeys: String, CodingKey {
        case type
        case coordinates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "Polygon":
            let coordinates = try container.decode([[[Double]]].self, forKey: .coordinates)
            polygons = [Self.makePolygon(coordinates)]
        case "MultiPolygon":
            let coordinates = try container.decode([[[[Double]]]].self, forKey: .coordinates)
            polygons = coordinates.map(Self.makePolygon)
        default:
            polygons = []
        }
    }

    private static func makePolygon(_ coordinates: [[[Double]]]) -> IMDFPolygon {
        IMDFPolygon(
            rings: coordinates.map { ring in
                ring.compactMap { pair in
                    guard pair.count >= 2 else { return nil }
                    return GeographicCoordinate(latitude: pair[1], longitude: pair[0])
                }
            }
        )
    }
}
