import Foundation
import IndoorPositioningSimulation
import Testing
@testable import IMDFSimulator

@MainActor
struct SimulatorMapSwitchingTests {
    @Test("길찾기 QA 모드를 재실행해도 유지하고 Wi-Fi 측위로 다시 전환할 수 있다")
    func remembersPositioningMode() throws {
        try withFixture { defaults, _, _ in
            let model = SimulatorAppModel(defaults: defaults, startsServices: false)
            #expect(model.positioningMode == .radioBased)
            model.usesRadioPositioning = false
            let reopened = SimulatorAppModel(defaults: defaults, startsServices: false)
            #expect(reopened.positioningMode == .groundTruth)
            reopened.usesRadioPositioning = true
            let reopenedAgain = SimulatorAppModel(defaults: defaults, startsServices: false)
            #expect(reopenedAgain.positioningMode == .radioBased)
        }
    }

    @Test("등록한 두 도면 경로를 다음 실행에서도 사용한다")
    func remembersRegistrations() throws {
        try withFixture { defaults, first, second in
            let model = SimulatorAppModel(defaults: defaults, startsServices: false)
            model.loadIMDF(at: first, preset: .c5)
            model.loadIMDF(at: second, preset: .library)
            #expect(model.errorMessage == nil)
            let reopened = SimulatorAppModel(defaults: defaults, startsServices: false)
            reopened.openMap(.c5)
            #expect(reopened.map?.venueName == "Test C5")
            #expect(reopened.selectedMapPreset == .c5)
            reopened.openMap(.library)
            #expect(reopened.map?.venueName == "Test Library")
            #expect(reopened.selectedMapPreset == .library)
        }
    }

    @Test("같은 층 ID를 쓰는 다른 도면도 층·사용자 위치·신호원 배치를 따로 복원한다")
    func restoresEachMapSession() throws {
        try withFixture { defaults, first, second in
            let model = SimulatorAppModel(defaults: defaults, startsServices: false)
            model.loadIMDF(at: first, preset: .c5)
            model.selectLevel(try #require(model.map?.levels.first))
            model.move(.east)
            model.addAnchor(kind: .wifi)
            let firstPosition = try #require(model.snapshot?.actualPosition)
            let firstAnchors = model.scenario?.anchors
            model.beginMoving(.north)
            model.loadIMDF(at: second, preset: .library)
            #expect(!model.isWalking)
            #expect(model.selectedLevel?.ordinal == 4)
            model.move(.south)
            let secondPosition = try #require(model.snapshot?.actualPosition)
            model.openMap(.c5)
            #expect(model.selectedLevel?.ordinal == 2)
            #expect(try #require(model.snapshot?.actualPosition).distance(to: firstPosition) < 0.000_001)
            #expect(model.scenario?.anchors == firstAnchors)
            model.openMap(.library)
            #expect(model.selectedLevel?.ordinal == 4)
            #expect(try #require(model.snapshot?.actualPosition).distance(to: secondPosition) < 0.000_001)
            #expect(model.scenario?.anchors.count == 8)
        }
    }

    @Test("새 도면 등록이 실패하면 기존 지도·위치·등록 경로를 보존한다")
    func keepsCurrentMapOnFailure() throws {
        try withFixture { defaults, first, second in
            let model = SimulatorAppModel(defaults: defaults, startsServices: false)
            model.loadIMDF(at: first, preset: .c5)
            model.move(.east)
            let position = model.snapshot?.actualPosition
            let paths = model.mapPaths
            model.loadIMDF(at: second.appendingPathComponent("missing"), preset: .c5)
            #expect(model.errorMessage != nil)
            #expect(model.map?.venueName == "Test C5")
            #expect(model.snapshot?.actualPosition == position)
            #expect(model.selectedMapPreset == .c5)
            #expect(model.mapPaths == paths)
            model.openMap(.c5)
            #expect(model.errorMessage == nil)
        }
    }

    private func withFixture(_ body: (UserDefaults, URL, URL) throws -> Void) throws {
        let suite = "SimulatorMapSwitchingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let first = try mapFixture(in: root.appendingPathComponent("C5"), name: "Test C5", longitude: 129.325)
        let second = try mapFixture(in: root.appendingPathComponent("Library"), name: "Test Library", longitude: 129.324)
        try body(defaults, first, second)
    }

    private func mapFixture(in directory: URL, name: String, longitude: Double) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ring = [[longitude, 36.012], [longitude + 0.0003, 36.012],
                    [longitude + 0.0003, 36.0123], [longitude, 36.0123], [longitude, 36.012]]
        let levels: [[String: Any]] = [2, 4].map { ordinal in
            ["type": "Feature", "id": "level-\(ordinal)",
             "properties": ["ordinal": ordinal, "name": ["ko": "\(ordinal + 1)층"]],
             "geometry": ["type": "Polygon", "coordinates": [ring]]]
        }
        let venue: [String: Any] = ["type": "Feature", "id": name,
                                    "properties": ["name": ["ko": name]], "geometry": NSNull()]
        for (filename, features) in [("level.geojson", levels), ("venue.geojson", [venue])] {
            let data = try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features])
            try data.write(to: directory.appendingPathComponent(filename))
        }
        return directory
    }
}
