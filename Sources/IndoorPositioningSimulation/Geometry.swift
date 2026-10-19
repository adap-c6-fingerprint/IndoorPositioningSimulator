import Foundation

public struct MeterPoint: Codable, Equatable, Hashable, Sendable {
    public let east: Double
    public let north: Double

    public init(east: Double, north: Double) {
        self.east = east
        self.north = north
    }

    public func distance(to other: MeterPoint) -> Double {
        hypot(east - other.east, north - other.north)
    }
}

public struct GeographicCoordinate: Codable, Equatable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        precondition((-90...90).contains(latitude))
        precondition((-180...180).contains(longitude))
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct IndoorCoordinate: Codable, Equatable, Hashable, Sendable {
    public let coordinate: GeographicCoordinate
    public let levelOrdinal: Int

    public init(coordinate: GeographicCoordinate, levelOrdinal: Int) {
        self.coordinate = coordinate
        self.levelOrdinal = levelOrdinal
    }
}

/// A local east/north projection intended for a single venue-sized area.
///
/// Scenario files keep WGS84 coordinates. RF calculations use this projection
/// internally so consuming apps never need to share an app-specific map origin.
public struct LocalCoordinateReference: Codable, Equatable, Sendable {
    public let origin: GeographicCoordinate

    public init(origin: GeographicCoordinate) {
        self.origin = origin
    }

    public func project(_ coordinate: GeographicCoordinate) -> MeterPoint {
        let earthRadius = 6_378_137.0
        let originLatitudeRadians = origin.latitude * .pi / 180
        let latitudeDelta = (coordinate.latitude - origin.latitude) * .pi / 180
        let longitudeDelta = (coordinate.longitude - origin.longitude) * .pi / 180

        return MeterPoint(
            east: longitudeDelta * cos(originLatitudeRadians) * earthRadius,
            north: latitudeDelta * earthRadius
        )
    }

    public func unproject(_ point: MeterPoint) -> GeographicCoordinate {
        let earthRadius = 6_378_137.0
        let originLatitudeRadians = origin.latitude * .pi / 180
        let latitude = origin.latitude + (point.north / earthRadius) * 180 / .pi
        let longitude = origin.longitude
            + (point.east / (earthRadius * cos(originLatitudeRadians))) * 180 / .pi

        return GeographicCoordinate(latitude: latitude, longitude: longitude)
    }
}

public struct SimulationBounds: Codable, Equatable, Sendable {
    public let minimumEast: Double
    public let maximumEast: Double
    public let minimumNorth: Double
    public let maximumNorth: Double

    public init(
        minimumEast: Double,
        maximumEast: Double,
        minimumNorth: Double,
        maximumNorth: Double
    ) {
        precondition(minimumEast <= maximumEast)
        precondition(minimumNorth <= maximumNorth)
        self.minimumEast = minimumEast
        self.maximumEast = maximumEast
        self.minimumNorth = minimumNorth
        self.maximumNorth = maximumNorth
    }

    public func clamped(_ point: MeterPoint) -> MeterPoint {
        MeterPoint(
            east: min(max(point.east, minimumEast), maximumEast),
            north: min(max(point.north, minimumNorth), maximumNorth)
        )
    }

    public var center: MeterPoint {
        MeterPoint(
            east: (minimumEast + maximumEast) / 2,
            north: (minimumNorth + maximumNorth) / 2
        )
    }
}
