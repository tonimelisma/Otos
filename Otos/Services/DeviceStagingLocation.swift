import Darwin
import Foundation
import Synchronization

/// The one owner of where device staging lives on disk.
///
/// Two types built this path independently before — `DeviceStagingRegistry` for its sweeps
/// and `DeviceCameraSession` for its own root — so "where is staging?" had two answers, and
/// changing one would have silently diverged from the other. One owner; both ask it.
///
/// ## The path is stable, and that is a correctness requirement
///
/// `DeviceStaging/<identity>/` is keyed by the camera, not by the process. It briefly was
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
/// of the kernel rather than encoded in a path: each attached session holds an exclusive
/// `flock` on `<identity>/.otos-owner` for as long as it is attached, and the sweep deletes a
/// tree only if it can take that lock.
///
/// Crash-safety falls out for free, which is why this is a lock and not a PID file or a
/// timestamp: the kernel releases an `flock` when the holder dies, however it dies. Verified
/// against SIGKILL — a killed holder's lock is immediately acquirable, so the next launch
/// collects exactly the trees whose owners are gone, with no stale state to reconcile and
/// nothing to time out.
///
/// The lock decides *deletion only*, never use. Two instances with the same camera attached
/// both stage normally; only one of them is responsible for cleaning up.
nonisolated enum DeviceStagingLocation {
    /// Locks held for cameras attached to this process, keyed by session root path.
    ///
    /// Held open for the life of each attachment; closing the descriptor is what releases
    /// the claim.
    private static let ownedDescriptors = Mutex<[String: Int32]>([:])

    private static let ownerMarkerName = ".otos-owner"

    /// The directory holding every camera's staging tree.
    ///
    /// Under Caches: staging is a rebuildable transfer cache, not overlay. Overlay lives in
    /// Application Support and is backed up; these bytes exist only until the item they
    /// belong to is imported or the app quits.
    static func containerURL() -> URL {
        let caches = (try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return caches
            .appending(path: "net.melisma.Otos", directoryHint: .isDirectory)
            .appending(path: "DeviceStaging", directoryHint: .isDirectory)
    }

    /// Where one camera's bytes go. Stable across launches for the same camera.
    static func sessionRootURL(identity: DeviceIdentity, inContainer container: URL = containerURL()) -> URL {
        let root = container
            .appending(path: CameraSourceMonitor.sanitize(identity.rawValue), directoryHint: .isDirectory)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        do {
            try mutableRoot.setResourceValues(values)
        } catch where ErrorDiagnostics.isMissingFile(error) {
            // Already gone: the outcome this removal wanted.
        } catch {
            // The folder may not exist yet; it is excluded again whenever it is resolved.
            OtosLog.fileAccess.errorOperation("camera.staging", phase: "excludeFromBackupFailed", fields: [
                "path": root.path(percentEncoded: false),
                "error": String(describing: error),
            ])
        }
        return root
    }

    /// Claims this camera's staging tree for as long as this process is attached to it.
    ///
    /// Best-effort by design: a failed claim means another instance will do the cleaning, not
    /// that staging cannot be used. Returning early rather than throwing keeps attach working
    /// in the pathological case of two instances sharing a camera.
    @discardableResult
    static func claimOwnership(identity: DeviceIdentity, inContainer container: URL = containerURL()) -> Bool {
        let root = sessionRootURL(identity: identity, inContainer: container)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            // Without the folder the marker cannot be opened, so the claim reports false.
            OtosLog.fileAccess.errorOperation("camera.staging", phase: "createFailed", fields: [
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

    /// Deletes every staging tree no live instance is holding.
    ///
    /// The crash backstop and the quit path, in one function. A tree whose lock can be taken
    /// has no live owner — either its process exited cleanly, or it died and the kernel
    /// released the lock for it — so its bytes belong to a session that is over.
    static func sweepUnownedStaging(inContainer container: URL = containerURL()) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return
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
                OtosLog.fileAccess.errorOperation("camera.staging", phase: "sweepRemoveFailed", fields: [
                    "path": tree.path(percentEncoded: false),
                    "error": String(describing: error),
                ])
            }
        }
        OtosLog.fileAccess.noticeOperation("camera.staging", phase: "sweepUnowned", fields: [
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
    static func hasStagedBytes(inContainer container: URL = containerURL()) -> Bool {
        let roots = ownedDescriptors.withLock { Array($0.keys) }
        for path in roots {
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
        _ = container
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
    static func releaseStagedFile(at url: URL) {
        guard isInsideStaging(url) else {
            OtosLog.fileAccess.errorOperation("camera.staging", phase: "releaseRefused", fields: [
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
            OtosLog.fileAccess.noticeOperation("camera.staging", phase: "released", fields: [
                "bytes": bytes.flatMap(\.self).map { "\($0)" } ?? "unknown",
            ])
        } catch {
            OtosLog.fileAccess.errorOperation("camera.staging", phase: "releaseFailed", fields: [
                "error": String(describing: error),
            ])
        }
    }

    /// Whether `url` lies inside the staging container.
    ///
    /// The guard on releasing staged bytes. Checked against the container rather than one
    /// camera's tree, because a release can legitimately target any attached camera; what it
    /// must never do is reach outside staging altogether.
    static func isInsideStaging(_ url: URL, inContainer container: URL = containerURL()) -> Bool {
        let root = container.standardizedFileURL.path(percentEncoded: false)
        let candidate = url.standardizedFileURL.path(percentEncoded: false)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return candidate.hasPrefix(prefix)
    }
}
