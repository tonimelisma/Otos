import Foundation

nonisolated enum DeviceCameraSessionError: LocalizedError {
    case disconnected
    case openTimedOut
    case catalogTimedOut
    case catalogUnstable(Int)
    case itemUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .disconnected:
            "The camera disconnected."
        case .openTimedOut:
            "The camera session did not open in time."
        case .catalogTimedOut:
            "The camera catalog did not finish in time."
        case let .catalogUnstable(count):
            "The camera catalog did not become stable; partial item count: \(count)."
        case let .itemUnavailable(path):
            "The camera item is unavailable: \(path)"
        }
    }
}
