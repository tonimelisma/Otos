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
                : "There isn’t enough free space to download them so they can be moved to the Trash. "
                + "You can’t undo this."
        }
    }

    static let deleteTitle = "Delete"
}

/// The question a Move to Trash asks when it must download more than
/// `thresholdBytes` of cloud-only items first (Plan 0104). Downloading is what keeps
/// them restorable from the Trash. Only bytes that need downloading count: the cost the
/// user is being told about. The title names the act with its size and count (DES-036);
/// the act is the user's own, so its button is not destructive-styled.
nonisolated struct LargeTrashDownloadPrompt: Equatable, Sendable {
    static let thresholdBytes: Int64 = 100_000_000

    let ids: [MediaAssetID]
    let bytes: Int64

    /// Whether a command needing `bytes` of downloads must ask first.
    static func asks(bytes: Int64, preference: Bool) -> Bool {
        preference && bytes > thresholdBytes
    }

    var title: String {
        let size = ImportBarByteFormat.string(bytes: bytes)
        if ids.count == 1, let only = ids.first {
            let name = URL(fileURLWithPath: only.relativePath.rawValue).lastPathComponent
            return "Download \(size) to Move “\(name)” to Trash?"
        }
        return "Download \(size) to Move \(ids.count) Items to Trash?"
    }

    var message: String {
        "Cloud-only items are downloaded first so you can restore them from the Trash. "
            + "They’re hidden in Otos until they’re moved."
    }

    static let confirmTitle = "Download and Move to Trash"
}
