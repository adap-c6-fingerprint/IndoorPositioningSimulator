import Foundation
@preconcurrency import Network
import Testing
@testable import IndoorPositioningSimulation

@MainActor
struct SimulationServerLifecycleTests {
    @Test("포트 충돌을 표시하고 기존 서버 종료 뒤 같은 객체로 다시 연결할 수 있다")
    func recoversFromPortConflict() async throws {
        let first = try SimulationSessionServer(port: 0)
        try first.start()
        defer { first.stop() }
        try await waitUntil { first.state == .listening }
        let port = try #require(first.listeningPort)
        let second = try SimulationSessionServer(port: port)
        defer { second.stop() }
        var states: [SimulationServerState] = []
        second.onStateChanged = { states.append($0) }
        try second.start()
        try await waitUntil {
            if case .failed = second.state { return true }
            return false
        }
        if case .failed(let message) = second.state {
            #expect(message.contains("다른 컨트롤러"))
        }
        await first.stopAndWait()
        try await second.restart()
        try await waitUntil { second.state == .listening }
        #expect(second.listeningPort == port)
        #expect(states.contains(.starting))
        #expect(states.last == .listening)
        let client = NWConnection(host: "127.0.0.1", port: try #require(NWEndpoint.Port(rawValue: port)), using: .tcp)
        client.start(queue: DispatchQueue(label: "SimulationServerLifecycleTests.client"))
        defer { client.cancel() }
        try await waitUntil {
            if case .ready = client.state { return second.connectedClientCount == 1 }
            return false
        }
        try await second.restart()
        try await waitUntil { second.state == .listening }
        #expect(second.listeningPort == port)
        #expect(second.connectedClientCount == 0)
        second.stop()
        #expect(second.state == .stopped)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("서버 상태가 제한 시간 내에 바뀌지 않았습니다.")
        throw WaitError.timedOut
    }

    private enum WaitError: Error { case timedOut }
}
