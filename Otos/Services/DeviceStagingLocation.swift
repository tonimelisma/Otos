import Foundation

/// The one owner of where device staging lives on disk.
///
/// Two types built this path independently before — `DeviceStagingRegistry` for its sweeps
/// and `DeviceCameraSession` for its own root — so "where is staging?" had two answers, and
/// changing one would have silently diverged from the other. One owner; both ask it.
///
/// ## Why roots are per process instance
///
/// Staging is cleared at three points, and each covers a case the others cannot: per item
/// when a copy settles, wholesale at quit, and wholesale at launch as the crash backstop —
/// a process that died never ran its quit path, so its tree is still there.
///
/// The launch sweep is what forces the instance segment. Without it the sweep would delete
/// the whole shared directory, including a second running instance's in-flight staging.
/// Two instances ran on this machine on 2026-08-30, and the second would have destroyed the
/// first's card transfer. With it, a launch deletes every tree that is not its own and a
/// live instance is untouched — crash-safe and instance-safe by construction, with no
/// cross-process ownership state to keep correct.
///
/// The alternative considered and rejected was making one-main-window true at the process
/// level and refusing a second launch. That is a different invariant from ARC-014 (which is
/// about one *window*), and a user-visible product change, which is a large answer to a bug
/// whose actual cause is a shared directory name.
nonisolated enum DeviceStagingLocation {
    /// Names this process's staging tree for its whole lifetime.
    ///
    /// A `static let` rather than a stored property so every caller — the session building
    /// its root, the registry sweeping, the quit path — agrees without passing it around.
    static let instanceID = UUID().uuidString

    /// The directory holding every instance's staging tree.
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

    /// This process's staging tree.
    ///
    /// `container` is injectable, and that is not ceremony. Every destructive operation
    /// below is reached through it, and a test that ran them against the real container
    /// would delete the user's actual staged camera data — which has happened here before:
    /// an earlier sweep test called a no-argument overload and wiped live staging out of
    /// the cache when the suite ran. A required-looking default with an injectable
    /// parameter is what keeps the production path unambiguous and the test path harmless.
    static func instanceRootURL(inContainer container: URL = containerURL()) -> URL {
        container.appending(path: instanceID, directoryHint: .isDirectory)
    }

    /// Where one attached camera's bytes go.
    static func sessionRootURL(identity: String, inContainer container: URL = containerURL()) -> URL {
        let root = instanceRootURL(inContainer: container)
            .appending(path: CameraSourceMonitor.sanitize(identity), directoryHint: .isDirectory)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try? mutableRoot.setResourceValues(values)
        return root
    }

    /// Deletes this process's staging tree. Called at quit.
    static func discardInstanceStaging(inContainer container: URL = containerURL()) {
        let root = instanceRootURL(inContainer: container)
        try? FileManager.default.removeItem(at: root)
        OtosLog.fileAccess.noticeOperation("camera.staging", phase: "discardInstance", fields: [
            "instance": instanceID,
        ])
    }

    /// Whether this process has staged anything worth clearing.
    ///
    /// Quit shows a clearing window and defers termination; doing that when there is
    /// nothing to delete would add a pointless flash and delay to every quit, and the
    /// common case is a session that never attached a camera at all.
    static func hasStagedBytes(inContainer container: URL = containerURL()) -> Bool {
        let root = instanceRootURL(inContainer: container)
        // Looks for an actual file, not merely a directory entry. Attaching a camera
        // creates its session directory whether or not anything is ever staged into it —
        // and after ranged reads became the normal path, that is the common case: the tree
        // exists and is empty. Counting entries reported "there are bytes to clear" for
        // every session that had seen a camera, so quit deferred termination and flashed a
        // clearing window to delete nothing.
        //
        // Enumerating stops at the first file rather than walking the tree, so this stays
        // cheap even when there genuinely are tens of gigabytes below it.
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                return true
            }
        }
        return false
    }

    /// Deletes every staging tree that is not this process's.
    ///
    /// The crash backstop. Safe to run while another instance is live precisely because
    /// trees are per instance: whatever else is in the container belongs to a process that
    /// is either finished or is not this one, and the only tree this can remove from a live
    /// peer is one it does not own.
    static func sweepForeignInstanceStaging(inContainer container: URL = containerURL()) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        var swept = 0
        for url in contents where url.lastPathComponent != instanceID {
            try? FileManager.default.removeItem(at: url)
            swept += 1
        }
        OtosLog.fileAccess.noticeOperation("camera.staging", phase: "sweepForeign", fields: [
            "instance": instanceID,
            "removed": "\(swept)",
        ])
    }

    /// Frees one staged file once its copy is durably in the library.
    ///
    /// Synchronous and `nonisolated` on purpose. An earlier version routed this through
    /// `DeviceStagingRegistry`, which is `@MainActor`, so every settled entry hopped to the
    /// main actor to delete a file — MainActor gravity in the hot import path, and it
    /// measurably delayed `MediaImportExecutor.recoverJournal()`, which every
    /// `MediaOperationCoordinator.start()` awaits. Nothing about deleting an Otos-owned
    /// file needs the main actor, and the containment guard it needed is right here.
    ///
    /// Containment is proven before deleting, not assumed: this takes a path, and a path
    /// wrong by one component would be a delete inside the user's own media, which Otos
    /// never does.
    static func releaseStagedFile(at url: URL) {
        guard isInsideInstanceStaging(url) else {
            OtosLog.fileAccess.errorOperation("camera.staging", phase: "releaseRefused", fields: [
                "reason": "outsideStagingRoot",
                "path": url.path(percentEncoded: false),
            ])
            return
        }
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return
        }
        let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        do {
            try FileManager.default.removeItem(at: url)
            OtosLog.fileAccess.noticeOperation("camera.staging", phase: "released", fields: [
                "bytes": "\(bytes)",
            ])
        } catch {
            OtosLog.fileAccess.errorOperation("camera.staging", phase: "releaseFailed", fields: [
                "error": String(describing: error),
            ])
        }
    }

    /// Whether `url` lies inside this process's staging tree.
    ///
    /// The guard on releasing staged bytes. A release intent takes a path, and a path that
    /// is wrong by one component would be a delete inside the user's own media — which Otos
    /// never does. Proving containment first makes that unreachable rather than unlikely.
    static func isInsideInstanceStaging(_ url: URL, inContainer container: URL = containerURL()) -> Bool {
        let root = instanceRootURL(inContainer: container).standardizedFileURL.path(percentEncoded: false)
        let candidate = url.standardizedFileURL.path(percentEncoded: false)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return candidate.hasPrefix(prefix)
    }
}
