import Foundation

/// Result of a user-initiated removable-volume eject intent.
nonisolated enum RemovableEjectOutcome: Equatable {
    case ejected
    case busy(displayName: String)
    case failed(description: String)
}
