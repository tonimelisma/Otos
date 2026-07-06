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
            onDetach: { [weak self] identity, reason in
                self?.submitCatalogMutation(.detachRemovableSource(identity, reason))
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
        do {
            let rootPath = try await catalogStore.attachDeviceMTP(
                stagingRootURL: session.stagingRootURL,
                identity: session.identity,
                displayName: session.displayName
            )
            await catalogStore.beginDeviceCatalogEnumeration(rootPath: rootPath)
            let items = try await session.catalogItems()
            try Task.checkCancellation()
            try await catalogStore.recordDeviceCatalogBatch(
                scannedFiles(for: items),
                rootPath: rootPath
            )
            await catalogStore.completeDeviceCatalogEnumeration(
                rootPath: rootPath,
                observedPaths: Set(items.map(\.relativePath))
            )
            await applyProvisionalThumbnails(for: items, rootPath: rootPath, session: session)
            await enrichmentCoordinator?.stageDevice(stagingSeeds(for: items, rootPath: rootPath))
        } catch is CancellationError {
            return
        } catch {
            OtosLog.fileAccess.error(
                "Camera catalog flow failed identity=\(session.identity, privacy: .public)"
            )
            await diagnostics?.record(
                operation: "catalog.device.scan",
                phase: "error",
                fields: ["identity": session.identity, "error": String(describing: error)]
            )
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

    private func applyProvisionalThumbnails(
        for items: [DeviceCameraCatalogItem],
        rootPath: LibraryRootPath,
        session: DeviceCameraSession
    ) async {
        guard let thumbnailDirectory else {
            return
        }
        var thumbnailsByID: [MediaAssetID: String] = [:]
        for item in items {
            guard !Task.isCancelled else {
                return
            }
            await writeProvisionalThumbnail(
                item,
                rootPath: rootPath,
                session: session,
                thumbnailDirectory: thumbnailDirectory,
                thumbnailsByID: &thumbnailsByID
            )
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
