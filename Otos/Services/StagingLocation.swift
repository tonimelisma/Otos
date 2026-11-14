import Darwin
import Foundation
import Synchronization

/// The folders a staging root's originals are copied into, one per kind that stages them
/// (`LibraryRootKind.stagingContainer`). Separate containers keep one kind's trees out of
/// another's listing; every container follows the same ownership and sweep rules.
nonisolated enum StagingContainer: String, CaseIterable, Sendable {
    /// A camera's originals, copied from the device over ImageCapture.
    case device = "DeviceStaging"
    /// An Immich account's originals, downloaded from its server (ADR 0046 §2).
    case remote = "RemoteStaging"
}

/// Where a catalog's staging containers are: one folder holding a folder per
/// `StagingContainer`. The one answer to "where is this source's staging folder": the
/// `CatalogStore` derives it from its `Location` (`CatalogStore.stagingContainers`) and every
/// reader — the camera monitor and its sessions, the Store's roots, the sweeps, the quit
/// check, an import's release of a staged file — asks that one value.
///
/// The app's is under Caches, named by its bundle identifier as its Application Support data
/// is, so a dev build (`net.melisma.Otos.dev`) and the installed app never share a container
/// and never sweep each other's trees (ADR 0030). Staging is a rebuildable transfer cache,
/// not overlay: these bytes exist only until the item they belong to is imported or the app
/// quits. Time Machine leaves Caches out of every backup itself (`tmutil isexcluded`), so
/// no tree here is marked excluded from backup.
///
/// A staging root's path is a function of this and the source's identity
/// (`sessionRoot(in:identity:)`), never a fact of its own: the catalog stores it because
/// asset identity is the path (ADR 0008), and `CatalogStore` re-derives it from this value at
/// every load, so a root never points at a folder outside its build's container (ADR 0046).
nonisolated struct StagingContainers: Equatable, Sendable {
    let base: URL

    /// An app's containers: `Caches/<bundle identifier>/`.
    static func application(bundleIdentifier: String) -> StagingContainers {
        let caches = (try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return StagingContainers(base: caches.appending(path: bundleIdentifier, directoryHint: .isDirectory))
    }

    func url(_ container: StagingContainer) -> URL {
        base.appending(path: container.rawValue, directoryHint: .isDirectory)
    }

    /// Every container's folder.
    var urls: [URL] {
        StagingContainer.allCases.map(url)
    }

    /// Where the root for `identity` lives in `container`.
    func sessionRoot(in container: StagingContainer, identity: DeviceIdentity) -> URL {
        StagingLocation.sessionRootURL(identity: identity, inContainer: url(container))
    }

    /// Deletes every tree in these containers no live instance holds
    /// (`StagingLocation.sweepUnownedStaging`).
    func sweepUnowned() {
        StagingLocation.sweepUnownedStaging(inContainers: urls)
    }

    /// Whether this process has staged a file in these containers
    /// (`StagingLocation.hasStagedBytes`).
    func hasStagedBytes() -> Bool {
        StagingLocation.hasStagedBytes(inContainers: urls)
    }

    /// Frees one staged file in these containers (`StagingLocation.releaseStagedFile`).
    func releaseStagedFile(at url: URL) {
        StagingLocation.releaseStagedFile(at: url, inContainers: urls)
    }
}

/// The mechanics of staged trees: a tree's path in a container, its ownership lock, the
/// sweep, placing a download and releasing a staged file. Which containers is never decided
/// here: every caller passes the catalog's `StagingContainers`.
///
/// Two types built this path independently before — `DeviceStagingRegistry` for its sweeps
/// and `DeviceCameraSession` for its own root — so "where is staging?" had two answers, and
/// changing one would have silently diverged from the other. One owner; both ask it.
///
/// ## The path is stable, and that is a correctness requirement
///
/// `<container>/<identity>/` is keyed by the source, not by the process. It briefly was
/// not: an earlier fix put the process instance in the path so a launch sweep could not
/// delete a peer's in-flight staging. That worked, and broke something bigger — asset
/// identity *is* the filesystem path (ADR 0008), so a per-launch path made every camera item
/// a new asset on every launch. All overlay keyed to it was recreated each run: catalog rows,
/// and thumbnails, whose deterministic names hash the root. Measured on a 991-item card:
/// 9,997 thumbnail files against 9,304 rows, and a camera's thumbnails not surviving a
/// restart. That contradicts the overlay-lifecycle invariant, which keeps overlay for as long
/// as the item exists.
///
/// ## Ownership is a lock, not a name
///
/// The sweep still must not delete what a live instance is using, and that question is asked
/// of the kernel rather than encoded in a path: each attached camera and each Immich account
/// the process holds keeps an exclusive `flock` on `<identity>/.otos-owner` for as long as it
/// is in use, and the sweep deletes a tree only if it can take that lock.
///
/// Crash-safety falls out for free, which is why this is a lock and not a PID file or a
/// timestamp: the kernel releases an `flock` when the holder dies, however it dies. Verified
/// against SIGKILL — a killed holder's lock is immediately acquirable, so the next launch
/// collects exactly the trees whose owners are gone, with no stale state to reconcile and
/// nothing to time out.
///
/// The lock decides *deletion only*, never use. Two instances with the same camera attached
/// both stage normally; only one of them is responsible for cleaning up.
nonisolated enum StagingLocation {
    /// Locks held for the sources this process uses — cameras attached, Immich accounts
    /// held — keyed by session root path.
    ///
    /// Held open for the life of each; closing the descriptor is what releases the claim.
    private static let ownedDescriptors = Mutex<[String: Int32]>([:])

    private static let ownerMarkerName = ".otos-owner"

    /// Where one source's bytes go. Stable across launches for the same source. A path only:
    /// deriving it touches nothing on disk, and the tree is made by the claim that uses it
    /// (`claimOwnership(of:)`).
    static func sessionRootURL(identity: DeviceIdentity, inContainer container: URL) -> URL {
        container.appending(path: CameraSourceMonitor.sanitize(identity.rawValue), directoryHint: .isDirectory)
    }

    /// Claims one staging tree, named by its path, for as long as this process uses it: an
    /// attached camera's, an Immich account's held signed in or not.
    ///
    /// Best-effort by design: a failed claim means another instance will do the cleaning, not
    /// that staging cannot be used. Returning early rather than throwing keeps attach working
    /// in the pathological case of two instances sharing a camera.
    @discardableResult
    static func claimOwnership(of root: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            // Without the folder the marker cannot be opened, so the claim reports false.
            OtosLog.fileAccess.errorOperation("source.staging", phase: "createFailed", fields: [
                "path": root.path(percentEncoded: false),
                "error": String(describing: error),
            ])
        }
        let marker = root.appending(path: ownerMarkerName, directoryHint: .notDirectory)
        let key = root.standardizedFileURL.path(percentEncoded: false)
        return ownedDescriptors.withLock { owned in
            guard owned[key] == nil else { return true }
            let descriptor = open(marker.path(percentEncoded: false), O_CREAT | O_RDWR, 0o644)
            guard descriptor >= 0 else { return false }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor)
                return false
            }
            owned[key] = descriptor
            return true
        }
    }

    /// Drops every claim this process holds, so the sweep that follows can collect its trees.
    ///
    /// Quit releases first and then sweeps, which is why sweeping and quitting are the same
    /// operation rather than two: an instance that has let go of its locks is
    /// indistinguishable from one that has exited, and that is exactly the state quit wants.
    static func releaseOwnership() {
        ownedDescriptors.withLock { owned in
            for descriptor in owned.values {
                flock(descriptor, LOCK_UN)
                close(descriptor)
            }
            owned.removeAll()
        }
    }

    /// Drops this process's claim on one tree: its account is gone, and its tree with it.
    static func releaseOwnership(of root: URL) {
        let key = root.standardizedFileURL.path(percentEncoded: false)
        ownedDescriptors.withLock { owned in
            guard let descriptor = owned.removeValue(forKey: key) else {
                return
            }
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    /// Deletes every staging tree, in every container, that no live instance is holding.
    ///
    /// The crash backstop and the quit path, in one function. A tree whose lock can be taken
    /// has no live owner — either its process exited cleanly, or it died and the kernel
    /// released the lock for it — so its bytes belong to a session that is over.
    static func sweepUnownedStaging(inContainers containers: [URL]) {
        let contents = containers.flatMap { container in
            (try? FileManager.default.contentsOfDirectory(
                at: container,
                includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []
        }
        var removed = 0
        var skipped = 0
        var failed = 0
        for tree in contents {
            let marker = tree.appending(path: ownerMarkerName, directoryHint: .notDirectory)
            let descriptor = open(marker.path(percentEncoded: false), O_CREAT | O_RDWR, 0o644)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                skipped += 1
                continue
            }
            do {
                try FileManager.default.removeItem(at: tree)
                removed += 1
            } catch where ErrorDiagnostics.isMissingFile(error) {
                removed += 1
            } catch {
                failed += 1
                OtosLog.fileAccess.errorOperation("source.staging", phase: "sweepRemoveFailed", fields: [
                    "path": tree.path(percentEncoded: false),
                    "error": String(describing: error),
                ])
            }
        }
        OtosLog.fileAccess.noticeOperation("source.staging", phase: "sweepUnowned", fields: [
            "removed": "\(removed)",
            "skippedLive": "\(skipped)",
            "failed": "\(failed)",
        ])
    }

    /// Whether this process has staged anything worth clearing.
    ///
    /// Looks for an actual file, not merely a directory entry. Attaching a camera creates its
    /// tree whether or not anything is staged into it — and since ranged reads became the
    /// normal path, that is the common case. Counting entries reported "there are bytes to
    /// clear" for every session that had seen a camera, so quit deferred termination and
    /// showed a clearing window to delete nothing.
    ///
    /// Enumerating stops at the first file, so this stays cheap when there genuinely are tens
    /// of gigabytes below it.
    static func hasStagedBytes(inContainers containers: [URL]) -> Bool {
        let roots = ownedDescriptors.withLock { Array($0.keys) }
        for path in roots where isInsideStaging(URL(fileURLWithPath: path, isDirectory: true), inContainers: containers) {
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: path, isDirectory: true),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let url as URL in enumerator
                where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            {
                return true
            }
        }
        return false
    }

    /// Frees one staged file once its copy is durably in the library.
    ///
    /// Synchronous and `nonisolated` on purpose. Routing this through the `@MainActor`
    /// registry made every settled entry hop to the main actor to delete a file — MainActor
    /// gravity in the hot import path, which measurably delayed the journal recovery that
    /// every `MediaOperationCoordinator.start()` awaits.
    ///
    /// Containment is proven before deleting, not assumed: this takes a path, and a path
    /// wrong by one component would be a delete inside the user's own media.
    static func releaseStagedFile(at url: URL, inContainers containers: [URL]) {
        guard isInsideStaging(url, inContainers: containers) else {
            OtosLog.fileAccess.errorOperation("source.staging", phase: "releaseRefused", fields: [
                "reason": "outsideStagingRoot",
                "path": url.path(percentEncoded: false),
            ])
            return
        }
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return
        }
        let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        do {
            try FileManager.default.removeItem(at: url)
            OtosLog.fileAccess.noticeOperation("source.staging", phase: "released", fields: [
                "bytes": bytes.flatMap(\.self).map { "\($0)" } ?? "unknown",
            ])
        } catch {
            OtosLog.fileAccess.errorOperation("source.staging", phase: "releaseFailed", fields: [
                "error": String(describing: error),
            ])
        }
    }

    /// Moves a downloaded original to `destination` inside a staging container: into its
    /// folder under a hidden name first, then renamed over the final name, so a reader
    /// never sees half a file (ADR 0046 §4). Containment in `stagingRoot` — the root's own
    /// staging folder, which is its path for a kind that stages originals — is proven
    /// first, as for release: a path wrong by one component would be a write inside the
    /// user's own media. A place that fails deletes the download it was handed.
    @concurrent
    static func placeDownloaded(_ downloaded: URL, at destination: URL, inside stagingRoot: URL) async throws {
        guard isInsideStaging(destination, inContainers: [stagingRoot]) else {
            OtosLog.fileAccess.errorOperation("source.staging", phase: "placeRefused", fields: [
                "reason": "outsideStagingRoot", "path": destination.path(percentEncoded: false),
            ])
            discardLeftover(downloaded)
            throw CocoaError(.fileWriteNoPermission)
        }
        let folder = destination.deletingLastPathComponent()
        let partial = folder.appending(path: ".\(UUID().uuidString).partial")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: downloaded, to: partial)
            if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: destination)
            }
        } catch {
            // Whichever of the two the bytes are in when a step fails goes: a failed place
            // leaves no file behind, in staging or in the temporary folder.
            for leftover in [downloaded, partial] {
                discardLeftover(leftover)
            }
            throw error
        }
    }

    private static func discardLeftover(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            OtosLog.fileAccess.errorOperation("source.staging", phase: "leftoverRemoveFailed", fields: [
                "path": url.path(percentEncoded: false), "error": String(describing: error),
            ])
        }
    }

    /// Whether `url` lies inside a staging container.
    ///
    /// The guard on releasing staged bytes. Checked against the containers rather than one
    /// source's tree, because a release can legitimately target any attached source; what it
    /// must never do is reach outside staging altogether.
    static func isInsideStaging(_ url: URL, inContainers containers: [URL]) -> Bool {
        let candidate = url.standardizedFileURL.path(percentEncoded: false)
        return containers.contains { container in
            let root = container.standardizedFileURL.path(percentEncoded: false)
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return candidate.hasPrefix(prefix)
        }
    }
}
