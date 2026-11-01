import Foundation
import OSLog

/// Export intents guide
///
/// File ▸ Export… (⇧⌘E) writes the current targets into a folder the person chooses
/// (ADR 0038). The sheet edits `exportSettings`, which are remembered across launches;
/// Export submits one request to an ordered, lossless lane (`exportStream`) with one
/// consumer, which:
/// 1. checks the folder still exists and reads the targets' details;
/// 2. exports them one after another through `MediaExporter`, publishing
///    `exportProgress` (the status bar's "Exporting 3 photos", M of N, with Cancel);
/// 3. reports what did not go as asked (`exportReport`): photos that could not be
///    exported, the free-space floor, or a folder that went away.
///
/// A photo that fails does not stop the others: what was exported stays exported, and the
/// report says how many did not. The floor and a vanished folder stop the job, because
/// every later photo would meet the same wall. Cancel stops between photos; the photos
/// already written stay, as with any copy the person stopped.
nonisolated struct ExportRequest: Sendable {
    let ids: [MediaAssetID]
    let settings: ExportSettings
    let folder: URL
    let generation: UInt64
}

/// The export being written, as the status bar shows it.
nonisolated struct ExportProgress: Equatable, Sendable {
    let completed: Int
    let total: Int
    let generation: UInt64

    var title: String {
        "Exporting \(total == 1 ? "1 photo" : "\(total) photos")"
    }
}

/// An export that did not do everything it was asked: the alert's title and message, and
/// the files it did write, which Show in Finder reveals.
nonisolated struct ExportReport: Equatable, Sendable {
    let title: String
    let message: String
    let exported: [URL]
}

/// The sheet's subject: the targets it was opened for.
nonisolated struct ExportSheet: Equatable, Sendable {
    let ids: [MediaAssetID]

    var title: String {
        "Export \(ids.count == 1 ? "1 Photo" : "\(ids.count) Photos")"
    }
}

extension CatalogWindowViewModel {
    /// File ▸ Export…: opens the sheet for the current targets.
    func beginExport() {
        let ids = targetIDs(.current)
        guard !ids.isEmpty else { return }
        exportSheet = ExportSheet(ids: ids)
    }

    var canExport: Bool {
        exportSheet == nil && !currentTargetFileURLs.isEmpty
    }

    func setExportSettings(_ settings: ExportSettings) {
        let settings = settings.clamped
        guard settings != exportSettings else { return }
        exportSettings = settings
        ExportSettingsStore.save(settings, defaults: preferences)
    }

    func setExportDestination(_ folder: URL) {
        var settings = exportSettings
        settings.destination = folder
        setExportSettings(settings)
    }

    func cancelExportSheet() {
        exportSheet = nil
    }

    /// The sheet's Export: submits the sheet's targets with the settings as they stand.
    func confirmExport() {
        guard let sheet = exportSheet, let folder = exportSettings.destination else { return }
        exportSheet = nil
        exportRequested &+= 1
        submittedExportCount += 1
        exportContinuation.yield(ExportRequest(
            ids: sheet.ids, settings: exportSettings, folder: folder, generation: exportRequested
        ))
        OtosLog.ui.noticeOperation("export.submit", phase: "submitted", fields: [
            "count": "\(sheet.ids.count)",
            "format": exportSettings.format.rawValue,
            "longEdge": exportSettings.outputLongEdge.map(String.init) ?? "full",
            "removesLocation": "\(exportSettings.removesLocation)",
            "generation": "\(exportRequested)",
        ])
    }

    /// The status bar's Cancel: the export stops before its next photo.
    func cancelExport() {
        guard let progress = exportProgress else { return }
        exportCancelledThrough = max(exportCancelledThrough, progress.generation)
        exportProgress = nil
        OtosLog.ui.noticeOperation("export.cancel", phase: "requested", fields: [
            "generation": "\(progress.generation)",
        ])
    }

    /// True once every submitted export has finished, stopped or been cancelled.
    var hasSettledExports: Bool {
        handledExportCount == submittedExportCount
    }

    func dismissExportReport() {
        exportReport = nil
    }

    /// The report's Show in Finder: the files this export wrote.
    func revealExportedFiles() {
        guard let report = exportReport else { return }
        exportReport = nil
        workspace.revealInFinder(report.exported)
    }

    func startExport() {
        let reader = tileDetailReader
        let materialization = materializationCoordinator
        exportTask = Task { [weak self, exportStream, reader, materialization] in
            for await request in exportStream {
                defer { self?.handledExportCount += 1 }
                guard !Task.isCancelled else { break }
                self?.beginExportProgress(request)
                guard await MediaExporter.isAvailableFolder(request.folder) else {
                    self?.finishExport(request, exported: [], failed: 0, stop: .folderUnavailable)
                    continue
                }
                let details: [MediaAssetID: MediaTileDetail]
                do {
                    details = try await reader.details(for: request.ids)
                } catch {
                    // The reader logged it; an unread target cannot be exported as edited.
                    self?.finishExport(request, exported: [], failed: request.ids.count, stop: nil)
                    continue
                }
                var exported: [URL] = []
                var failed = 0
                var stop: ExportStop?
                items: for id in request.ids {
                    if let through = self?.exportCancelledThrough, through >= request.generation {
                        stop = .cancelled
                        break
                    }
                    let outcome = await MediaExporter.export(
                        EditedMediaItem(id: id, detail: details[id]),
                        settings: request.settings,
                        to: request.folder,
                        materialization: materialization
                    )
                    switch outcome {
                    case let .exported(url):
                        exported.append(url)
                    case .failed:
                        failed += 1
                    case .belowFloor:
                        stop = .belowFloor
                        break items
                    case .folderUnavailable:
                        stop = .folderUnavailable
                        break items
                    case .outOfSpace:
                        stop = .outOfSpace
                        break items
                    }
                    self?.advanceExportProgress(request)
                }
                guard let self else { break }
                if stop == nil, exportCancelledThrough >= request.generation {
                    stop = .cancelled
                }
                finishExport(request, exported: exported, failed: failed, stop: stop)
            }
        }
    }

    private func beginExportProgress(_ request: ExportRequest) {
        exportProgress = ExportProgress(completed: 0, total: request.ids.count, generation: request.generation)
    }

    private func advanceExportProgress(_ request: ExportRequest) {
        guard let progress = exportProgress, progress.generation == request.generation else { return }
        exportProgress = ExportProgress(
            completed: min(progress.completed + 1, progress.total),
            total: progress.total,
            generation: progress.generation
        )
    }

    private func finishExport(_ request: ExportRequest, exported: [URL], failed: Int, stop: ExportStop?) {
        if exportProgress?.generation == request.generation {
            exportProgress = nil
        }
        exportReport = Self.exportReport(
            requested: request.ids.count, exported: exported, failed: failed, stop: stop, folder: request.folder
        )
        OtosLog.ui.noticeOperation("export.complete", phase: stop.map { "\($0)" } ?? "finished", fields: [
            "requested": "\(request.ids.count)",
            "exported": "\(exported.count)",
            "failed": "\(failed)",
            "generation": "\(request.generation)",
        ])
    }

    /// What the person is told when an export did not do everything asked; nil when it did,
    /// or when they cancelled it.
    nonisolated static func exportReport(
        requested: Int,
        exported: [URL],
        failed: Int,
        stop: ExportStop?,
        folder: URL
    ) -> ExportReport? {
        let title = "Exported \(exported.count) of \(requested) \(requested == 1 ? "Photo" : "Photos")"
        switch stop {
        case .cancelled:
            return nil
        case .folderUnavailable:
            return ExportReport(
                title: exported.isEmpty ? "Couldn’t Export" : title,
                message: "The folder “\(folder.lastPathComponent)” isn’t available. Choose another folder and export again.",
                exported: exported
            )
        case .belowFloor:
            return ExportReport(
                title: title,
                message: "Export stopped to keep 5 GB free on the disk.",
                exported: exported
            )
        case .outOfSpace:
            return ExportReport(
                title: exported.isEmpty ? "Couldn’t Export" : title,
                message: "Export stopped because the disk is full. Free up space and export again.",
                exported: exported
            )
        case nil:
            guard failed > 0 else { return nil }
            let photos = failed == 1 ? "One photo couldn’t be exported. Its original" : "\(failed) photos couldn’t be exported. Their originals"
            return ExportReport(title: title, message: "\(photos) may be unavailable.", exported: exported)
        }
    }
}

/// Why an export ended before its last photo.
nonisolated enum ExportStop: Equatable, Sendable {
    case cancelled
    case belowFloor
    case folderUnavailable
    /// A write was refused for space (the disk filled faster than the floor check saw).
    case outOfSpace
}
