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
