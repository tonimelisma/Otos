import Foundation
import OSLog

/// Source monitoring guide
///
/// The ViewModel owns platform monitor lifetimes because they are app/window
/// integration, not catalog truth. This extension converts macOS removable-volume
/// events and ImageCapture camera sessions into Store-owned mutations and
/// per-camera catalog tasks. The Store remains the only owner of source persistence,
/// path remapping, availability, enumeration state, and overlay lifecycle.
extension CatalogWindowViewModel {
    func startRemovableVolumeMonitoring() {
        let monitor = RemovableVolumeMonitor(
            onAttach: { [weak self] attachment in
                self?.submitCatalogMutation(.attachRemovableVolume(attachment))
            },
            onQuiesce: { [weak self] identity in
                self?.submitCatalogMutation(.quiesceRemovableSource(identity))
            },
            onResume: { [weak self] identity in
                self?.submitCatalogMutation(.resumeRemovableSource(identity))
            },
            onDetach: { [weak self] identity, reason in
                // Bracket the availability-change path that runs on eject.
                // The stall monitor flags; Instruments names the code.
                let op = self?.uiStallMonitor.beginOperation("RemovableVolumeMonitor.detach")
                self?.submitCatalogMutation(.detachRemovableSource(identity, reason))
                if let op {
                    self?.uiStallMonitor.endOperation(op)
                }
            }
        )
        removableVolumeMonitor = monitor
        monitor.start()
    }

    func startCameraSourceMonitoring() {
        let monitor = makeCameraSourceMonitor()
        cameraSourceMonitor = monitor
        monitor.start()
    }

    /// The camera monitor the window runs, not yet started: it stages each camera under the
    /// catalog's own containers (`CatalogStore.stagingContainers`), so a camera's session and
    /// the root the Store loads for it are one path.
    func makeCameraSourceMonitor() -> CameraSourceMonitor {
        CameraSourceMonitor(
            stagingContainers: catalogStore.stagingContainers,
            onAttach: { [weak self] session in
                self?.attachCameraSession(session)
            },
            onDetach: { [weak self] identity in
                self?.detachCameraSession(identity)
            }
        )
    }

    /// Staging survives a camera eject, so anything on disk at launch belongs to a session
    /// that has ended — a clean quit should already have cleared its own tree, and a crash
    /// will not have. Sweeping every *other* instance's tree here is the backstop that keeps
    /// the cache from growing across crashes, and it must happen before monitoring starts so
    /// a camera attaching immediately cannot race it (APP-018, owner decision 2026-08-30).
    ///
    /// `Task.detached` rather than `Task`: this type is `@MainActor`, so a plain `Task`
    /// inherits that isolation and would run a recursive delete of potentially tens of
    /// gigabytes on the main thread. The `await MainActor.run` that followed it was a no-op
    /// hop, and evidence the author believed the work was already off-main.
    ///
    /// The sweep asks the kernel, not a filename: a tree is deleted only if its `flock` can
    /// be taken, which is true exactly when no live instance holds it. A crashed owner's lock
    /// is released by the kernel, so its tree is collected on the next launch with no stale
    /// state to reconcile; a live peer's tree is skipped. It runs before monitoring starts so
    /// a camera attaching right now cannot race it.
    func startDeviceStagingSweepThenCameraMonitoring() {
        let stagingContainers = catalogStore.stagingContainers
        deviceStagingSweepTask = Task.detached(priority: .utility) { [weak self] in
            stagingContainers.sweepUnowned()
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                self?.startCameraSourceMonitoring()
            }
        }
    }

    private func attachCameraSession(_ session: DeviceCameraSession) {
        deviceStagingRegistry.register(session)
        deviceCatalogTasks[session.identity]?.cancel()
        let coordinator = enrichmentCoordinator
        let sync = CameraCatalogSync(
            source: session,
            store: catalogStore,
            enrichment: CameraCatalogSync.Enrichment(
                markRangeCapable: { rootPath in await coordinator?.markRangeCapable(rootPath) },
                stage: { seeds in await coordinator?.stageDevice(seeds) }
            ),
            thumbnailDirectory: thumbnailDirectory
        )
        deviceCatalogTasks[session.identity] = Task {
            await sync.run()
        }
    }

    private func detachCameraSession(_ identity: DeviceIdentity) {
        deviceCatalogTasks.removeValue(forKey: identity)?.cancel()
        deviceStagingRegistry.unregister(identity: identity)
        submitCatalogMutation(.detachRemovableSource(identity, .disconnected))
    }
}
