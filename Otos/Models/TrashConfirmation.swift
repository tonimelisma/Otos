import Foundation

/// The confirmation Move to Trash asks before anything leaves the library (APP-027).
/// Lightroom confirms every Delete; Otos confirms the one act that changes the user's
/// files. The title carries the count and scope (DES-036), and the message states the
/// only fact that matters: the items go to the system Trash and can be put back.
nonisolated struct TrashConfirmation: Equatable, Sendable {
    let ids: [MediaAssetID]

    var count: Int {
        ids.count
    }

    var title: String {
        if ids.count == 1, let only = ids.first {
            let name = URL(fileURLWithPath: only.relativePath.rawValue).lastPathComponent
            return "Move “\(name)” to Trash?"
        }
        return "Move \(ids.count) Items to Trash?"
    }

    var message: String {
        ids.count == 1
            ? "The item moves to the Trash and can be put back from Finder."
            : "The items move to the Trash and can be put back from Finder."
    }

    static let confirmTitle = "Move to Trash"
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
