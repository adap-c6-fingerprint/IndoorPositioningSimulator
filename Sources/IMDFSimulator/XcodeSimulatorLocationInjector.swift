import Foundation
import IndoorPositioningSimulation

struct BootedXcodeSimulator: Identifiable, Hashable, Sendable {
    let id: String
    let name: String

    var displayName: String { name + " · " + String(id.prefix(8)) }
}

/// Uses the public Simulator command-line interface to update Core Location for
/// one selected iOS Simulator. This is the only system-level channel; radio and
/// motion observations still travel through the Swift client package.
final class XcodeSimulatorLocationInjector: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "IndoorPositioningSimulator.simctl-location",
        qos: .userInitiated
    )

    func bootedSimulators() async throws -> [BootedXcodeSimulator] {
        let data = try await run([
            "simctl",
            "list",
            "devices",
            "booted",
            "--json"
        ])
        let response = try JSONDecoder().decode(SimctlDeviceList.self, from: data)
        return response.devices.values
            .flatMap { $0 }
            .filter { $0.state == "Booted" && $0.isAvailable != false }
            .map { BootedXcodeSimulator(id: $0.udid, name: $0.name) }
            .sorted {
                let comparison = $0.name.localizedStandardCompare($1.name)
                return comparison == .orderedSame
                    ? $0.id < $1.id
                    : comparison == .orderedAscending
            }
    }

    func setLocation(
        _ coordinate: GeographicCoordinate,
        simulatorID: String
    ) async throws {
        _ = try await run([
            "simctl",
            "location",
            simulatorID,
            "set",
            "\(coordinate.latitude),\(coordinate.longitude)"
        ])
    }

    private func run(_ arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                process.arguments = arguments
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let message = String(data: data, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        throw XcodeSimulatorLocationError.commandFailed(
                            message?.isEmpty == false ? message! : "simctl 종료 코드 \(process.terminationStatus)"
                        )
                    }
                    let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private struct SimctlDeviceList: Decodable {
    let devices: [String: [SimctlDevice]]
}

private struct SimctlDevice: Decodable {
    let name: String
    let udid: String
    let state: String
    let isAvailable: Bool?
}

private enum XcodeSimulatorLocationError: Error, LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            "Xcode Simulator 위치를 갱신하지 못했습니다: \(message)"
        }
    }
}
