import Foundation

/// Recoverable deletion value boundary.
///
/// These values describe only catalog-proven physical membership. The trash
/// coordinator never discovers same-basename files and never carries media bytes.
nonisolated enum MediaTrashMemberRole: Equatable, Sendable {
    case companion
    case primary
}

nonisolated struct MediaTrashMember: Equatable, Sendable {
    let relativePath: MediaRelativePath
    let role: MediaTrashMemberRole
    /// Cataloged size, a filesystem fact read without touching bytes. Used only to
    /// account the download a dataless member needs before it can be trashed.
    var byteSize: Int64?
}

/// Identity of one Move to Trash command: when the user issued it, in Unix
/// milliseconds, the same convention as `ImportBatchID`. Every item the command
/// hid carries it until the item is trashed, dropped, or the command is undone.
nonisolated struct MediaTrashBatchID: Hashable, Sendable, Comparable {
    let unixMilliseconds: Int64

    init(unixMilliseconds: Int64) {
        self.unixMilliseconds = unixMilliseconds
    }

    init(date: Date = Date()) {
        unixMilliseconds = Int64((date.timeIntervalSince1970 * 1000.0).rounded(.down))
    }

    static func < (lhs: MediaTrashBatchID, rhs: MediaTrashBatchID) -> Bool {
        lhs.unixMilliseconds < rhs.unixMilliseconds
    }
}

/// A cataloged item the user moved to the Trash that is not yet in the Trash.
/// The file still exists, so the row and all its overlay are kept; the item is
/// excluded from every user-facing media query while it carries `batch`.
nonisolated struct PendingTrashItem: Equatable, Sendable {
    let batch: MediaTrashBatchID
    let item: MediaTrashItem
}

nonisolated struct MediaTrashItem: Equatable, Sendable {
    let id: MediaAssetID
    let root: LibraryRoot
    let members: [MediaTrashMember]
}

nonisolated struct MediaTrashPathResult: Equatable, Sendable {
    let id: MediaAssetID
    let rootPath: LibraryRootPath
    let relativePath: MediaRelativePath
    let role: MediaTrashMemberRole
    let succeeded: Bool
}
