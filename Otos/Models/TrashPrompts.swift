import Foundation

/// Copy for the Move to Trash failure alert (DES-076). Titles state the bounded
/// outcome; the message line says what Otos did about it.
nonisolated enum TrashAlertCopy {
    static let moveFailedOne = "This Item Couldn't Be Moved to Trash"
    static let moveFailedMany = "Some Items Couldn't Be Moved to Trash"
    static let moveDetail = "The affected items are back in Otos and selected."
    static let putBackFailedOne = "This Item Couldn't Be Put Back"
    static let putBackFailedMany = "Some Items Couldn't Be Put Back"
    static let putBackDetail = "They’re no longer in the Trash, or a file now has their name."
}

/// The question the trash queue asks when items cannot reach the Trash (Plan 0104
/// D3/D4): delete them immediately, or not. The title names the destructive act with
/// its count (DES-036); the message states why and that it cannot be undone.
nonisolated struct TrashDecisionPrompt: Equatable, Sendable {
    let decision: MediaTrashCoordinator.Decision

    var title: String {
        let ids = decision.ids
        if ids.count == 1, let only = ids.first {
            let name = URL(fileURLWithPath: only.relativePath.rawValue).lastPathComponent
            return "Delete “\(name)” Immediately?"
        }
        return "Delete \(ids.count) Items Immediately?"
    }

    var message: String {
        let one = decision.ids.count == 1
        switch decision {
        case .downloadFailed:
            return one
                ? "It couldn’t be downloaded, so it can’t be moved to the Trash. You can’t undo this."
                : "They couldn’t be downloaded, so they can’t be moved to the Trash. You can’t undo this."
        case .diskFloor:
            return one
                ? "There isn’t enough free space to download it so it can be moved to the Trash. You can’t undo this."
                : "There isn’t enough free space to download them so they can be moved to the Trash. You can’t undo this."
        }
    }

    static let deleteTitle = "Delete"
}
