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
                // Plan 0067 Stage 3: bracket the availability-change path that runs on eject.
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

    func startDeviceStagingSweepThenCameraMonitoring() {
        deviceStagingSweepTask = Task { [weak self] in
            await DeviceStagingRegistry.sweepAbsentDeviceStaging()
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
                contentModifiedAt: item.captureDate
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
