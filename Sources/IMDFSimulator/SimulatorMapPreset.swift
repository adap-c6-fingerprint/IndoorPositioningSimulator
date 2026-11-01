import Foundation

enum SimulatorMapPreset: String, CaseIterable, Identifiable {
    case c5
    case library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .c5: "C5"
        case .library: "도서관"
        }
    }
}
