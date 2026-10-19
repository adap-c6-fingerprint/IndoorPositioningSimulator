import Foundation
import XCTest
@testable import IndoorPositioningSimulation

final class IndoorPositioningSimulationTests: XCTestCase {
    func testGeographicProjectionRoundTripsWithinBuildingScale() {
        let reference = LocalCoordinateReference(
            origin: GeographicCoordinate(latitude: 36.014267, longitude: 129.325778)
        )
        let coordinate = GeographicCoordinate(latitude: 36.0144, longitude: 129.3260)
        let roundTrip = reference.unproject(reference.project(coordinate))

        XCTAssertEqual(roundTrip.latitude, coordinate.latitude, accuracy: 0.000_000_1)
        XCTAssertEqual(roundTrip.longitude, coordinate.longitude, accuracy: 0.000_000_1)
    }

    func testPortableScenarioRoundTripsAndProducesPositionSample() throws {
        let scenario = makeScenario()
        let data = try IMDFScenarioCodec.encode(scenario)
        let decoded = try IMDFScenarioCodec.decode(data)
        let simulator = try decoded.makeSimulator()
        let sample = try XCTUnwrap(simulator.snapshot.positionSample(
            coordinateReference: decoded.coordinateReference,
            levelOrdinal: decoded.map.levelOrdinal
        ))

        XCTAssertEqual(decoded, scenario)
        XCTAssertEqual(sample.levelOrdinal, 4)
        XCTAssertEqual(sample.coordinate.latitude, 36.014267, accuracy: 0.000_001)
        XCTAssertEqual(sample.coordinate.longitude, 129.325778, accuracy: 0.000_001)
    }

    func testMovementAndAnchorEditingAreAppIndependent() throws {
        var simulator = try makeScenario().makeSimulator()
        let moved = simulator.move(.east)
        let edited = simulator.moveAnchor(
            id: "WIFI-NW",
            to: MeterPoint(east: -3, north: 4)
        )

        XCTAssertEqual(moved.actualPosition, MeterPoint(east: 1, north: 0))
        XCTAssertNotNil(edited.estimate)
        XCTAssertEqual(
            simulator.radioEnvironment.anchors.first { $0.id == "WIFI-NW" }?.position,
            MeterPoint(east: -3, north: 4)
        )
    }

    func testIndoorWiFiRangeAndAccuracyDegradeWithDistance() throws {
        let accessPoint = RadioAnchor(
            id: "WIFI-TEST",
            kind: .wifi,
            position: MeterPoint(east: 0, north: 0),
            referenceRSSI: -40,
            pathLossExponent: 3
        )

        XCTAssertEqual(
            accessPoint.rssi(at: MeterPoint(east: 1, north: 0)),
            -40,
            accuracy: 0.001
        )
        XCTAssertEqual(
            accessPoint.rssi(at: MeterPoint(east: 10, north: 0)),
            -70,
            accuracy: 0.001
        )
        XCTAssertLessThan(
            accessPoint.rssi(at: MeterPoint(east: 30, north: 0)),
            -84
        )

        let nearby = SimulationRadioQualityAssessment(
            wifiRSSI: [-50, -52, -54, -56, -58, -60],
            bluetoothRSSI: []
        )
        let distant = SimulationRadioQualityAssessment(
            wifiRSSI: [-78, -80, -82, -84, -86, -88],
            bluetoothRSSI: []
        )
        let outOfRange = SimulationRadioQualityAssessment(
            wifiRSSI: [-91, -92, -93, -94, -94, -95],
            bluetoothRSSI: []
        )

        XCTAssertEqual(nearby.coverage, .sufficient)
        XCTAssertEqual(distant.coverage, .limited)
        XCTAssertEqual(outOfRange.coverage, .insufficient)
        XCTAssertGreaterThan(
            try XCTUnwrap(distant.estimatedHorizontalAccuracyMeters),
            try XCTUnwrap(nearby.estimatedHorizontalAccuracyMeters)
        )
        XCTAssertNil(outOfRange.estimatedHorizontalAccuracyMeters)
    }

    func testSensorNoiseIsReproducibleAndChangesOverTime() throws {
        let scenario = makeScenario()
        let simulator = try scenario.makeSimulator(calculatesEstimate: false)
        let sessionID = try XCTUnwrap(
            UUID(uuidString: "C02B4EC4-99A3-41E3-8BB9-4678E35A6B08")
        )
        var firstGenerator = SimulatedSensorGenerator(
            sessionID: sessionID,
            noiseProfile: .realisticIndoor,
            noiseSeed: 42
        )
        var secondGenerator = SimulatedSensorGenerator(
            sessionID: sessionID,
            noiseProfile: .realisticIndoor,
            noiseSeed: 42
        )
        var cleanGenerator = SimulatedSensorGenerator(
            sessionID: sessionID,
            noiseProfile: .none,
            noiseSeed: 42
        )

        func frame(from generator: inout SimulatedSensorGenerator) -> SimulationSensorFrame {
            generator.makeFrame(
                position: scenario.initialPosition,
                localPosition: simulator.actualPosition,
                headingDegrees: 0,
                walking: false,
                radioEnvironment: simulator.radioEnvironment,
                deltaTime: 1
            )
        }

        let first = frame(from: &firstGenerator)
        let repeated = frame(from: &secondGenerator)
        let clean = frame(from: &cleanGenerator)
        let later = frame(from: &firstGenerator)

        XCTAssertEqual(first.wifi, repeated.wifi)
        XCTAssertEqual(first.bluetooth, repeated.bluetooth)
        XCTAssertEqual(first.motion, repeated.motion)
        XCTAssertNotEqual(first.wifi.first?.rssiDBM, clean.wifi.first?.rssiDBM)
        XCTAssertNotEqual(first.motion.userAccelerationG, clean.motion.userAccelerationG)
        XCTAssertNotEqual(first.wifi.first?.rssiDBM, later.wifi.first?.rssiDBM)
    }

    func testStationaryRadioNoiseChangesLessThanWalkingNoise() throws {
        let scenario = makeScenario()
        let simulator = try scenario.makeSimulator(calculatesEstimate: false)
        let sessionID = try XCTUnwrap(
            UUID(uuidString: "C02B4EC4-99A3-41E3-8BB9-4678E35A6B08")
        )
        var stationaryGenerator = SimulatedSensorGenerator(
            sessionID: sessionID,
            noiseProfile: .realisticIndoor,
            noiseSeed: 42
        )
        var walkingGenerator = SimulatedSensorGenerator(
            sessionID: sessionID,
            noiseProfile: .realisticIndoor,
            noiseSeed: 42
        )

        func wifiSeries(
            from generator: inout SimulatedSensorGenerator,
            walking: Bool
        ) throws -> [Double] {
            try (0..<30).map { _ in
                let frame = generator.makeFrame(
                    position: scenario.initialPosition,
                    localPosition: simulator.actualPosition,
                    headingDegrees: 0,
                    walking: walking,
                    radioEnvironment: simulator.radioEnvironment,
                    deltaTime: 1
                )
                return try XCTUnwrap(
                    frame.wifi.first { $0.ssid == "WIFI-NW" }?.rssiDBM
                )
            }
        }

        func meanAbsoluteStep(_ values: [Double]) -> Double {
            let steps = zip(values, values.dropFirst()).map { abs($1 - $0) }
            return steps.reduce(0, +) / Double(steps.count)
        }

        let stationary = try wifiSeries(from: &stationaryGenerator, walking: false)
        let walking = try wifiSeries(from: &walkingGenerator, walking: true)

        XCTAssertLessThan(meanAbsoluteStep(stationary), meanAbsoluteStep(walking) * 0.25)
    }

    func testGroundTruthModeSuppressesNoiseAndSurvivesTransportEncoding() throws {
        let scenario = makeScenario()
        let simulator = try scenario.makeSimulator(calculatesEstimate: false)
        var generator = SimulatedSensorGenerator(
            noiseProfile: .realisticIndoor,
            noiseSeed: 42
        )

        let frame = generator.makeFrame(
            position: scenario.initialPosition,
            localPosition: simulator.actualPosition,
            headingDegrees: 0,
            walking: false,
            positioningMode: .groundTruth,
            radioEnvironment: simulator.radioEnvironment,
            deltaTime: 1
        )
        let anchor = try XCTUnwrap(
            simulator.radioEnvironment.anchors.first { $0.id == "WIFI-NW" }
        )
        let observation = try XCTUnwrap(
            frame.wifi.first { $0.ssid == anchor.id }
        )

        XCTAssertEqual(frame.positioningMode, .groundTruth)
        XCTAssertEqual(
            observation.rssiDBM,
            anchor.rssi(at: simulator.actualPosition),
            accuracy: 0.000_001
        )
        XCTAssertEqual(frame.motion.userAccelerationG, .init(x: 0, y: 0, z: 0))
        XCTAssertEqual(frame.motion.gravityG, .init(x: 0, y: 0, z: -1))
        XCTAssertEqual(frame.motion.rotationRateRadiansPerSecond, .init(x: 0, y: 0, z: 0))
        XCTAssertEqual(frame.motion.magneticHeadingDegrees, 0)

        let encoded = try JSONEncoder().encode(frame)
        XCTAssertEqual(
            try JSONDecoder().decode(SimulationSensorFrame.self, from: encoded),
            frame
        )
    }

    func testFramesWithoutPositioningModeDefaultToRadioBased() throws {
        let scenario = makeScenario()
        let simulator = try scenario.makeSimulator(calculatesEstimate: false)
        var generator = SimulatedSensorGenerator(noiseProfile: .none)
        let frame = generator.makeFrame(
            position: scenario.initialPosition,
            localPosition: simulator.actualPosition,
            headingDegrees: 0,
            walking: false,
            radioEnvironment: simulator.radioEnvironment,
            deltaTime: 1
        )
        let encoded = try JSONEncoder().encode(frame)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "positioningMode")
        let legacyFrame = try JSONDecoder().decode(
            SimulationSensorFrame.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(legacyFrame.positioningMode, .radioBased)
    }

    func testSensorFrameContainsRawSignalsAndNoCalculatedBlueDot() throws {
        let scenario = makeScenario()
        let simulator = try scenario.makeSimulator(calculatesEstimate: false)
        var generator = SimulatedSensorGenerator(initialHeadingDegrees: 0)
        let frame = generator.makeFrame(
            position: scenario.initialPosition,
            localPosition: simulator.actualPosition,
            headingDegrees: 90,
            walking: true,
            radioEnvironment: simulator.radioEnvironment,
            deltaTime: 0.02
        )

        XCTAssertNil(simulator.snapshot.estimate)
        XCTAssertEqual(frame.positioningMode, .radioBased)
        XCTAssertEqual(frame.wifi.count, 2)
        XCTAssertEqual(frame.bluetooth.count, 2)
        XCTAssertEqual(frame.device.headingDegrees, 90)
        XCTAssertEqual(frame.device.speedMetersPerSecond, 1.125)
        XCTAssertEqual(frame.motion.timestamp, 0.02, accuracy: 0.000_001)
        XCTAssertGreaterThan(frame.motion.rotationRateRadiansPerSecond.z, 0)

        let nextFrame = generator.makeFrame(
            position: scenario.initialPosition,
            localPosition: simulator.actualPosition,
            headingDegrees: 90,
            walking: true,
            radioEnvironment: simulator.radioEnvironment,
            deltaTime: 0.02
        )
        XCTAssertEqual(nextFrame.wifi.first?.observedAt, frame.wifi.first?.observedAt)
        XCTAssertEqual(
            nextFrame.bluetooth.first?.observedAt,
            frame.bluetooth.first?.observedAt
        )
        XCTAssertGreaterThan(nextFrame.motion.timestamp, frame.motion.timestamp)

        let encoded = try JSONEncoder().encode(frame)
        XCTAssertEqual(try JSONDecoder().decode(SimulationSensorFrame.self, from: encoded), frame)
    }

    func testLevelRejectsWallsAndFixturesAsNavigableSpace() {
        let coordinate: (Double, Double) -> GeographicCoordinate = {
            GeographicCoordinate(latitude: $1, longitude: $0)
        }
        let square: (Double, Double, Double, Double) -> IMDFPolygon = { minX, minY, maxX, maxY in
            IMDFPolygon(rings: [[
                coordinate(minX, minY),
                coordinate(maxX, minY),
                coordinate(maxX, maxY),
                coordinate(minX, maxY),
                coordinate(minX, minY)
            ]])
        }
        let level = IMDFMapLevel(
            id: "level",
            ordinal: 0,
            name: "Ground",
            shortName: "G",
            polygons: [square(0, 0, 1, 1)],
            units: [
                IMDFMapUnit(
                    id: "wall",
                    levelID: "level",
                    category: "structure",
                    name: nil,
                    polygons: [square(0.4, 0, 0.6, 1)]
                )
            ],
            fixtures: [
                IMDFMapFixture(
                    id: "desk",
                    levelID: "level",
                    category: "desk",
                    name: nil,
                    polygons: [square(0.7, 0.7, 0.9, 0.9)]
                )
            ]
        )

        XCTAssertTrue(level.isNavigable(coordinate(0.2, 0.2)))
        XCTAssertFalse(level.isNavigable(coordinate(0.5, 0.5)))
        XCTAssertFalse(level.isNavigable(coordinate(0.8, 0.8)))
        XCTAssertFalse(level.isNavigable(coordinate(1.2, 0.5)))
    }

    func testLoadsGenericIMDFDirectoryAndGroupsUnitsByLevel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try write("""
        {"version":"1.0.0"}
        """, named: "manifest.json", to: directory)
        try write("""
        {"type":"FeatureCollection","features":[{
          "type":"Feature","id":"venue-1","feature_type":"venue",
          "properties":{"name":{"en":"Test Venue"}},
          "geometry":{"type":"Polygon","coordinates":[[[129.0,36.0],[129.001,36.0],[129.001,36.001],[129.0,36.0]]]}
        }]}
        """, named: "venue.geojson", to: directory)
        try write("""
        {"type":"FeatureCollection","features":[{
          "type":"Feature","id":"level-1","feature_type":"level",
          "properties":{"ordinal":0,"name":{"en":"Ground"},"short_name":{"en":"G"}},
          "geometry":{"type":"Polygon","coordinates":[[[129.0,36.0],[129.001,36.0],[129.001,36.001],[129.0,36.0]]]}
        }]}
        """, named: "level.geojson", to: directory)
        try write("""
        {"type":"FeatureCollection","features":[{
          "type":"Feature","id":"unit-1","feature_type":"unit",
          "properties":{"category":"walkway","name":null,"level_id":"level-1"},
          "geometry":{"type":"Polygon","coordinates":[[[129.0,36.0],[129.0005,36.0],[129.0005,36.0005],[129.0,36.0]]]}
        }]}
        """, named: "unit.geojson", to: directory)

        let map = try IMDFArchiveLoader.load(from: directory)

        XCTAssertEqual(map.venueID, "venue-1")
        XCTAssertEqual(map.venueName, "Test Venue")
        XCTAssertEqual(map.levels.map(\.ordinal), [0])
        XCTAssertEqual(map.levels.first?.units.map(\.id), ["unit-1"])
        XCTAssertEqual(map.levels.first?.fixtures.count, 0)
        XCTAssertGreaterThan(try XCTUnwrap(map.levels.first).localBounds().maximumEast, 0)
    }

    private func makeScenario() -> IMDFSimulationScenario {
        let origin = GeographicCoordinate(latitude: 36.014267, longitude: 129.325778)
        let reference = LocalCoordinateReference(origin: origin)
        let bounds = SimulationBounds(
            minimumEast: -10,
            maximumEast: 10,
            minimumNorth: -10,
            maximumNorth: 10
        )
        let indoor: (MeterPoint) -> IndoorCoordinate = { point in
            IndoorCoordinate(coordinate: reference.unproject(point), levelOrdinal: 4)
        }
        return IMDFSimulationScenario(
            name: "Portable Test",
            map: IMDFMapReference(
                venueID: "venue-1",
                venueName: "Test Venue",
                manifestVersion: "1.0.0",
                levelID: "level-5",
                levelOrdinal: 4
            ),
            coordinateReference: reference,
            localBounds: bounds,
            initialPosition: indoor(.init(east: 0, north: 0)),
            anchors: [
                .init(id: "WIFI-NW", kind: .wifi, position: indoor(.init(east: -8, north: 8))),
                .init(id: "WIFI-NE", kind: .wifi, position: indoor(.init(east: 8, north: 8))),
                .init(id: "BEACON-SW", kind: .beacon, position: indoor(.init(east: -8, north: -8))),
                .init(id: "BEACON-SE", kind: .beacon, position: indoor(.init(east: 8, north: -8)))
            ]
        )
    }

    private func write(_ value: String, named name: String, to directory: URL) throws {
        try XCTUnwrap(value.data(using: .utf8)).write(
            to: directory.appendingPathComponent(name)
        )
    }
}
