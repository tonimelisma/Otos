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

nonisolated struct MediaTrashBatchResult: Equatable, Sendable {
    let items: [MediaTrashItem]
    let paths: [MediaTrashPathResult]

    var successfulPaths: [MediaTrashPathResult] {
        paths.filter(\.succeeded)
    }

    var failedItems: [MediaTrashItem] {
        items.filter { item in
            paths.contains { result in
                result.id == item.id && !result.succeeded
            }
        }
    }

    var movedItemCount: Int {
        items.filter { item in
            paths.contains { result in
                result.id == item.id && result.role == .primary && result.succeeded
            }
        }.count
    }
}
