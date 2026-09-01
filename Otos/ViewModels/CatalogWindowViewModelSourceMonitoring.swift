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
        let monitor = CameraSourceMonitor(
            onAttach: { [weak self] session in
                self?.attachCameraSession(session)
            },
            onDetach: { [weak self] identity in
                self?.detachCameraSession(identity)
            }
        )
        cameraSourceMonitor = monitor
        monitor.start()
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
        deviceStagingSweepTask = Task.detached(priority: .utility) { [weak self] in
            DeviceStagingLocation.sweepUnownedStaging()
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
        deviceCatalogTasks[session.identity] = Task { [weak self, session] in
            await self?.runCameraCatalogFlow(session)
        }
    }

    private func detachCameraSession(_ identity: String) {
        deviceCatalogTasks.removeValue(forKey: identity)?.cancel()
        deviceStagingRegistry.unregister(identity: identity)
        submitCatalogMutation(.detachRemovableSource(identity, .disconnected))
    }

    private func runCameraCatalogFlow(_ session: DeviceCameraSession) async {
        var activeScan: CatalogStore.ActiveScan?
        do {
            let rootPath = try await catalogStore.attachDeviceMTP(
                stagingRootURL: session.stagingRootURL,
                identity: session.identity,
                displayName: session.displayName
            )
            activeScan = try await catalogStore.beginDeviceCatalogEnumeration(rootPath: rootPath)
            let snapshot = try await session.catalogSnapshot()
            let items = snapshot.items
            try Task.checkCancellation()
            guard let scan = activeScan else {
                throw CancellationError()
            }
            try await catalogStore.recordDeviceCatalogBatch(
                scannedFiles(for: items),
                scan: scan
            )
            // Decide once per attach whether this device answers ranged reads, before any
            // seeding, because the answer decides whether seeding happens at all. One
            // 12-byte read against one item: cheap enough to always do, and the only honest
            // way to know — `GetPartialObject` is optional in MTP and devices that advertise
            // it are documented failing it.
            if let probe = items.first(where: { ($0.byteSize ?? 0) > 0 }),
               let size = probe.byteSize,
               await CameraMetadataReader.isRangeCapable(
                   session: session,
                   relativePath: probe.relativePath,
                   size: UInt64(size)
               )
            {
                await enrichmentCoordinator?.markRangeCapable(rootPath)
            }
            await enrichmentCoordinator?.stageDevice(stagingSeeds(for: items, rootPath: rootPath))
            if snapshot.isStable {
                try await catalogStore.completeDeviceCatalogEnumeration(
                    scan: scan,
                    observedPaths: Set(items.map(\.relativePath)),
                    companions: mediaCompanions(for: snapshot.companions)
                )
            } else {
                OtosLog.catalog.notice(
                    "op=catalog.device.scan phase=unstable identity=\(session.identity, privacy: .public) count=\(items.count, privacy: .public)"
                )
            }
            await applyProvisionalThumbnails(for: items, rootPath: rootPath, session: session)
        } catch is CancellationError {
            // The cleanup below ends the current enumeration lease if this task still
            // owns it; detach or reconnect may already have superseded it.
        } catch {
            OtosLog.fileAccess.error(
                "Camera catalog flow failed identity=\(session.identity, privacy: .public)"
            )
            OtosLog.catalog.error(
                "op=catalog.device.scan phase=error identity=\(session.identity, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
        if let activeScan {
            await catalogStore.endDeviceCatalogEnumeration(scan: activeScan)
        }
    }

    private func scannedFiles(for items: [DeviceCameraCatalogItem]) -> [ScannedMediaFile] {
        items.map { item in
            ScannedMediaFile(
                relativePath: item.relativePath,
                name: item.name,
                contentTypeIdentifier: item.contentTypeIdentifier,
                byteSize: item.byteSize,
                createdAt: item.captureDate,
                // Creation-first, not modification-first. `contentModifiedAt` is what
                // import naming falls back to, and `CameraFileDate.modificationDate`
                // prefers the modification dates — which for video is when recording
                // *stopped*, misnaming every clip by its own length. `captureDate`
                // answers the question naming actually asks; the modification date is
                // the fallback of last resort (ARC-057).
                contentModifiedAt: item.captureDate ?? item.modificationDate
            )
        }
    }

    private func mediaCompanions(for items: [DeviceCameraCompanionItem]) -> [MediaCompanion] {
        items.map { item in
            MediaCompanion(
                relativePath: item.relativePath,
                primaryRelativePath: item.primaryRelativePath,
                kind: item.kind,
                byteSize: item.byteSize,
                contentModifiedAt: item.contentModifiedAt
            )
        }
    }

    private func applyProvisionalThumbnails(
        for items: [DeviceCameraCatalogItem],
        rootPath: LibraryRootPath,
        session: DeviceCameraSession
    ) async {
        guard let thumbnailDirectory else {
            return
        }
        let batchSize = 24
        var thumbnailsByID: [MediaAssetID: String] = [:]
        for item in items {
            if Task.isCancelled {
                try? await catalogStore.applyProvisionalThumbnails(thumbnailsByID)
                return
            }
            await writeProvisionalThumbnail(
                item,
                rootPath: rootPath,
                session: session,
                thumbnailDirectory: thumbnailDirectory,
                thumbnailsByID: &thumbnailsByID
            )
            if thumbnailsByID.count >= batchSize {
                try? await catalogStore.applyProvisionalThumbnails(thumbnailsByID)
                thumbnailsByID.removeAll(keepingCapacity: true)
            }
        }
        try? await catalogStore.applyProvisionalThumbnails(thumbnailsByID)
    }

    private func writeProvisionalThumbnail(
        _ item: DeviceCameraCatalogItem,
        rootPath: LibraryRootPath,
        session: DeviceCameraSession,
        thumbnailDirectory: URL,
        thumbnailsByID: inout [MediaAssetID: String]
    ) async {
        let id = MediaAssetID(libraryRootPath: rootPath, relativePath: item.relativePath)
        let relativeName = ThumbnailStore.relativeName(for: id)
        do {
            guard let data = try await session.thumbnailData(
                for: item.relativePath,
                maxPixelSize: ThumbnailStore.maxPixelSize
            ) else {
                return
            }
            try ThumbnailStore.writeProvisionalJPEG(
                data,
                finalRelativeName: relativeName,
                in: thumbnailDirectory
            )
            thumbnailsByID[id] = relativeName
        } catch {
            OtosLog.thumbnails.debug(
                "Camera provisional thumbnail failed path=\(item.relativePath.rawValue, privacy: .public)"
            )
        }
    }

    private func stagingSeeds(
        for items: [DeviceCameraCatalogItem],
        rootPath: LibraryRootPath
    ) -> [EnrichmentCoordinator.DeviceStagingSeed] {
        items.map { item in
            EnrichmentCoordinator.DeviceStagingSeed(
                id: MediaAssetID(libraryRootPath: rootPath, relativePath: item.relativePath),
                sourceSize: item.byteSize,
                captureDate: item.captureDate,
                isVideo: MediaEligibility.isVideo(contentTypeIdentifier: item.contentTypeIdentifier)
            )
        }
    }
}
