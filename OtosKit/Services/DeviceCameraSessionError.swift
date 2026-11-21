import Foundation

nonisolated enum DeviceCameraSessionError: LocalizedError {
    case disconnected
    case openTimedOut
    case catalogTimedOut
    case catalogUnstable(Int)
    case itemUnavailable(String)
    /// A ranged read did not deliver its bytes.
    ///
    /// Distinct from `itemUnavailable`, which is a fact about the catalog. This is a fact
    /// about the transport, and the distinction is load-bearing: a metadata read that
    /// cannot tell "I could not read this" from "there is nothing here" reports the second
    /// and names a file from the wrong date.
    case rangedReadFailed(String)

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
        case let .rangedReadFailed(detail):
            "The camera could not answer a ranged read: \(detail)."
        case let .itemUnavailable(path):
            "The camera item is unavailable: \(path)"
        }
    }
}
