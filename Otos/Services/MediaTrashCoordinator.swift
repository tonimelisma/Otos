import Foundation
import OSLog
import UniformTypeIdentifiers

/// System-Trash coordinator guide.
///
/// This actor owns the lossless serial filesystem command lifecycle. It snapshots
/// catalog-proven members, acquires the Store's root namespace lease, moves companions
/// before primaries with `FileManager.trashItem`, and returns per-path truth. It never
/// deletes permanently or guesses companion membership. The injected status, requester,
/// and executor are the test boundary for fault injection; production uses system Trash.
///
/// A dataless cloud placeholder cannot leave its File Provider domain, so `trashItem`
/// refuses it (`NSFeatureUnsupportedError`). Each dataless member is therefore
/// deliberately materialized through the shared `MaterializationCoordinator` at
/// `command` priority first — ahead of enrichment, behind on-screen work, and under the
/// bounded persistence so a stuck provider fails the member instead of holding the lease
/// and the serial trash command forever — and the lease is revalidated after that await. A member that does not become local fails truthfully;
/// there is no permanent-delete fallback.
actor MediaTrashCoordinator {
    typealias TrashExecutor = @Sendable (URL) throws -> Void
    typealias StatusReader = @Sendable (URL) -> FileMaterializationStatus

    private let store: CatalogStore
    private let materializationRequester: (any MaterializationRequesting)?
    private let status: StatusReader
    private let trashExecutor: TrashExecutor

    init(
        store: CatalogStore,
        materializationRequester: (any MaterializationRequesting)?,
        status: @escaping StatusReader = { FileMaterialization.status(of: $0) },
        trashExecutor: @escaping TrashExecutor = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) {
        self.store = store
        self.materializationRequester = materializationRequester
        self.status = status
        self.trashExecutor = trashExecutor
    }

    func moveToTrash(_ items: [MediaTrashItem]) async -> MediaTrashBatchResult {
        var leases: [LibraryRootPath: RootNamespaceMutationLease] = [:]
        for item in items where item.root.kind != .deviceMTP && leases[item.root.path] == nil {
            if case let .acquired(lease) = await store.acquireNamespaceMutationLease(
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
            guard case let .acquired(lease) = await store.acquireNamespaceMutationLease(
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
                let url = item.root.path.url.appending(path: member.relativePath.rawValue)
                let succeeded = await moveMember(member, of: item, at: url, lease: lease)
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

    /// Materializes a dataless member, then trashes it. The lease is revalidated after
    /// the materialization await: the actor suspended, and the lease can end meanwhile
    /// (for example when the root is removed), which must stop the move.
    private func moveMember(
        _ member: MediaTrashMember,
        of item: MediaTrashItem,
        at url: URL,
        lease: RootNamespaceMutationLease
    ) async -> Bool {
        let path = member.relativePath.rawValue
        guard await materializeIfDataless(member, of: item, at: url) else {
            return false
        }
        guard await store.ownsNamespaceMutationLease(lease) else {
            OtosLog.catalog.error(
                """
                op=mediaTrash.path failed reason=leaseLost \
                role=\(String(describing: member.role), privacy: .public) path=\(path, privacy: .public)
                """
            )
            return false
        }
        do {
            try trashExecutor(url)
            return true
        } catch {
            let nsError = error as NSError
            let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)
                .map { "\($0.domain)/\($0.code)" } ?? "none"
            OtosLog.catalog.error(
                """
                op=mediaTrash.path failed reason=trashItem \
                errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) \
                underlying=\(underlying, privacy: .public) \
                role=\(String(describing: member.role), privacy: .public) path=\(path, privacy: .public)
                """
            )
            return false
        }
    }

    /// Deliberately materializes a dataless member through the shared coordinator.
    /// Returns true when the member is local (or already was) and may be trashed.
    private func materializeIfDataless(
        _ member: MediaTrashMember,
        of item: MediaTrashItem,
        at url: URL
    ) async -> Bool {
        guard status(url) == .dataless else {
            return true
        }
        let path = member.relativePath.rawValue
        guard let materializationRequester else {
            OtosLog.catalog.error(
                """
                op=mediaTrash.path failed reason=noMaterializer \
                role=\(String(describing: member.role), privacy: .public) path=\(path, privacy: .public)
                """
            )
            return false
        }
        OtosLog.catalog.notice(
            """
            op=mediaTrash.path phase=materialize \
            role=\(String(describing: member.role), privacy: .public) path=\(path, privacy: .public)
            """
        )
        let result = await materializationRequester.materialize(MaterializationCoordinator.Request(
            id: MediaAssetID(libraryRootPath: item.root.path, relativePath: member.relativePath),
            sourceSize: nil,
            isVideo: UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true,
            priority: .command
        ))
        guard result.isMaterialized else {
            OtosLog.catalog.error(
                """
                op=mediaTrash.path failed reason=notMaterialized \
                outcome=\(result.outcome.diagnosticDescription, privacy: .public) \
                elapsedMs=\(result.elapsedMs, privacy: .public) \
                role=\(String(describing: member.role), privacy: .public) path=\(path, privacy: .public)
                """
            )
            return false
        }
        return true
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
