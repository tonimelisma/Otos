import Foundation
import OSLog

/// System-Trash coordinator guide.
///
/// This actor owns the lossless serial filesystem command lifecycle. It snapshots
/// catalog-proven members, acquires the Store's root namespace lease, moves companions
/// before primaries with `FileManager.trashItem`, and returns per-path truth. It never
/// deletes permanently, reads bytes, or guesses companion membership. The injected
/// executor is the test boundary for fault injection; production uses system Trash.
actor MediaTrashCoordinator {
    typealias TrashExecutor = @Sendable (URL) throws -> Void

    private let store: CatalogStore
    private let trashExecutor: TrashExecutor

    init(store: CatalogStore, trashExecutor: @escaping TrashExecutor = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }) {
        self.store = store
        self.trashExecutor = trashExecutor
    }

    func moveToTrash(_ items: [MediaTrashItem]) async -> MediaTrashBatchResult {
        var leases: [LibraryRootPath: RootNamespaceMutationLease] = [:]
        for item in items where item.root.kind != .deviceMTP && leases[item.root.path] == nil {
            if let lease = await store.acquireNamespaceMutationLease(
                for: item.root.path,
                owner: .mediaTrash
            ) {
                leases[item.root.path] = lease
            }
        }
        return await moveToTrash(items, leases: leases)
    }

    /// Acquires every target-root lease before Store snapshots physical members.
    /// This prevents a reorganization or import publication from changing the
    /// path membership between the catalog read and the filesystem command.
    func moveToTrash(for ids: [MediaAssetID]) async throws -> MediaTrashBatchResult {
        var leases: [LibraryRootPath: RootNamespaceMutationLease] = [:]
        for rootPath in Set(ids.map(\.libraryRootPath)).sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let lease = await store.acquireNamespaceMutationLease(
                for: rootPath,
                owner: .mediaTrash
            ) else {
                for acquired in leases.values {
                    _ = await store.releaseNamespaceMutationLease(acquired)
                }
                throw CatalogStoreError.catalogUnavailable
            }
            leases[rootPath] = lease
        }

        do {
            let items = try await store.mediaTrashItems(for: ids)
            return await moveToTrash(items, leases: leases)
        } catch {
            for lease in leases.values {
                _ = await store.releaseNamespaceMutationLease(lease)
            }
            throw error
        }
    }

    private func moveToTrash(
        _ items: [MediaTrashItem],
        leases: [LibraryRootPath: RootNamespaceMutationLease]
    ) async -> MediaTrashBatchResult {
        var results: [MediaTrashPathResult] = []
        for item in items {
            guard item.root.kind != .deviceMTP,
                  let lease = leases[item.root.path]
            else {
                results.append(contentsOf: item.members.map { member in
                    MediaTrashPathResult(
                        id: item.id,
                        rootPath: item.root.path,
                        relativePath: member.relativePath,
                        role: member.role,
                        succeeded: false
                    )
                })
                continue
            }

            for member in item.members.sorted(by: Self.memberOrder) {
                guard await store.ownsNamespaceMutationLease(lease) else {
                    results.append(MediaTrashPathResult(
                        id: item.id,
                        rootPath: item.root.path,
                        relativePath: member.relativePath,
                        role: member.role,
                        succeeded: false
                    ))
                    continue
                }
                let url = item.root.path.url.appending(path: member.relativePath.rawValue)
                let succeeded: Bool
                do {
                    try trashExecutor(url)
                    succeeded = true
                } catch {
                    succeeded = false
                    OtosLog.catalog.error(
                        "op=mediaTrash.path failed role=\(String(describing: member.role), privacy: .public)"
                    )
                }
                results.append(MediaTrashPathResult(
                    id: item.id,
                    rootPath: item.root.path,
                    relativePath: member.relativePath,
                    role: member.role,
                    succeeded: succeeded
                ))
            }
        }
        for lease in leases.values {
            _ = await store.releaseNamespaceMutationLease(lease)
        }
        return MediaTrashBatchResult(items: items, paths: results)
    }

    private static func memberOrder(
        _ left: MediaTrashMember,
        _ right: MediaTrashMember
    ) -> Bool {
        switch (left.role, right.role) {
        case (.companion, .primary): true
        case (.primary, .companion): false
        case (.companion, .companion), (.primary, .primary):
            left.relativePath.rawValue < right.relativePath.rawValue
        }
    }
}
