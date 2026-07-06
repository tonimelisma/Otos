import Foundation

nonisolated enum DeviceCameraSessionError: LocalizedError {
    case disconnected
    case openTimedOut
    case catalogTimedOut
    case itemUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .disconnected:
            "The camera disconnected."
        case .openTimedOut:
            "The camera session did not open in time."
        case .catalogTimedOut:
            "The camera catalog did not finish in time."
        case let .itemUnavailable(path):
            "The camera item is unavailable: \(path)"
        }
    }
}
