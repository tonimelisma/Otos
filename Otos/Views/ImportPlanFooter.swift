import SwiftUI

/// Bottom import plan footer for the selected removable source.
///
/// Renders coordinator presentation only: destination picker, status line
/// (§9), and Import/Cancel queue. The grid is the plan view; the footer
/// is the fixed status surface. Honest denominators only (§8).
struct ImportPlanFooter: View {
    let presentation: MediaOperationSourcePresentation
    let fixedLibraries: [CatalogLibraryState]
    let importPreferences: ImportPreferences
    let setDestination: (LibraryRootPath) -> Void
    let queueImport: () -> Void
    let cancelImport: () -> Void
    let retryPlanning: (() -> Void)?

    init(
        presentation: MediaOperationSourcePresentation,
        fixedLibraries: [CatalogLibraryState],
        importPreferences: ImportPreferences,
        setDestination: @escaping (LibraryRootPath) -> Void,
        queueImport: @escaping () -> Void,
        cancelImport: @escaping () -> Void = {},
        retryPlanning: (() -> Void)? = nil
    ) {
        self.presentation = presentation
        self.fixedLibraries = fixedLibraries
        self.importPreferences = importPreferences
        self.setDestination = setDestination
        self.queueImport = queueImport
        self.cancelImport = cancelImport
        self.retryPlanning = retryPlanning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                destinationPicker
                Spacer(minLength: 8)
                readinessLabel
                actionButtons
            }
            if let line = statusLine {
                HStack(spacing: 8) {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if showsRetry {
                        Button("Retry", action: { retryPlanning?() })
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }
            policySummary
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var destinationPicker: some View {
        HStack(spacing: 6) {
            Text("Destination")
                .foregroundStyle(.secondary)
            Picker(
                "Destination",
                selection: Binding(
                    get: { presentation.destinationPath },
                    set: { path in
                        if let path {
                            setDestination(path)
                        }
                    }
                )
            ) {
                Text("Choose…").tag(LibraryRootPath?.none)
                ForEach(fixedLibraries) { library in
                    Text(library.displayName).tag(Optional(library.path))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
        }
    }

    private var readinessLabel: some View {
        Text(readinessText)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var policySummary: some View {
        Text(policyText(importPreferences))
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch presentation.state {
        case .executing:
            Button("Cancel", action: cancelImport)
                .keyboardShortcut(.cancelAction)
        default:
            Button(importButtonTitle, action: queueImport)
                .disabled(!importEnabled)
                .keyboardShortcut(isDeleteOnly ? nil : .defaultAction)
        }
    }

    private var importButtonTitle: String {
        if isDeleteOnly {
            return "Delete from Card"
        }
        return "Import"
    }

    private var isDeleteOnly: Bool {
        guard importPreferences.deleteSourceAfterImport else {
            return false
        }
        switch presentation.state {
        case let .ready(summary, _, _):
            return summary.copyCount == 0 && summary.companionCopyCount == 0
        case let .executionUnavailable(summary, _):
            return summary.copyCount == 0 && summary.companionCopyCount == 0
        default:
            return false
        }
    }

    private var importEnabled: Bool {
        guard presentation.destinationPath != nil else {
            return false
        }
        switch presentation.state {
        case .waitingForMetadata, .queuedForReadiness:
            return true
        case let .ready(summary, _, _):
            if summary.copyCount > 0 || summary.companionCopyCount > 0 {
                return true
            }
            return importPreferences.deleteSourceAfterImport
        case let .executionUnavailable(summary, _):
            if summary.copyCount > 0 || summary.companionCopyCount > 0 {
                return true
            }
            return importPreferences.deleteSourceAfterImport
        case .executing:
            return false
        default:
            return false
        }
    }

    private var statusLine: String? {
        switch presentation.state {
        case let .ready(summary, _, _):
            return readyStatusLine(summary: summary)
        case let .executionUnavailable(summary, _):
            return readyStatusLine(summary: summary)
        case let .completed(summary, skippedForeign, failed):
            var text = completedStatusLine(summary: summary)
            if skippedForeign > 0 {
                text += " · \(skippedForeign) skipped (destination exists)"
            }
            if failed > 0 {
                text += " · \(failed) failed"
            }
            return text
        case let .executing(progress):
            return executingStatusLine(progress: progress)
        default:
            return nil
        }
    }

    private var showsRetry: Bool {
        switch presentation.state {
        case let .ready(summary, _, _):
            return summary.blockedCount > 0
        case let .executionUnavailable(summary, _):
            return summary.blockedCount > 0
        default:
            return false
        }
    }

    private var readinessText: String {
        switch presentation.state {
        case .inventory:
            return "Inventory…"
        case let .waitingForMetadata(done, total):
            return "Waiting for metadata (\(done)/\(total))"
        case .planning:
            return "Planning…"
        case .ready:
            return "Ready"
        case .queuedForReadiness:
            return "Import queued — finishing metadata…"
        case let .executing(progress):
            let bytesDone = ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)
            let bytesTotal = ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
            return "Importing \(progress.completedCount)/\(progress.totalCount) · \(bytesDone) of \(bytesTotal)"
        case .needsReplan:
            return "Source changed — replanning…"
        case .completed:
            return "Import complete"
        case let .failed(problem):
            return "Failed: \(problem)"
        case .executionUnavailable:
            return "Import queued (execution lands in a later update)"
        }
    }

    private func readyStatusLine(summary: MediaOperationPlanTotals) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: summary.copyBytes, countStyle: .file)
        if summary.copyCount == 0, summary.companionCopyCount == 0, summary.blockedCount == 0 {
            if summary.skipCount == 0 {
                return "This card is empty"
            }
            return "Nothing new — all \(summary.skipCount) items are already in your library"
        }
        if summary.copyCount == 0, summary.blockedCount > 0 {
            return "Nothing can be imported yet · \(summary.blockedCount) need attention"
        }
        var line = "\(summary.copyCount) new · \(bytes)"
        if summary.skipCount > 0 {
            line += " — \(summary.skipCount) already in your library"
        }
        if summary.blockedCount > 0 {
            line += " · \(summary.blockedCount) need attention"
        }
        return line
    }

    private func completedStatusLine(summary: MediaOperationPlanTotals) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: summary.copyBytes, countStyle: .file)
        if summary.copyCount == 0 {
            return "Import complete — nothing new"
        }
        return "\(summary.copyCount) new · \(bytes) — import complete"
    }

    private func executingStatusLine(progress: MediaOperationProgress) -> String {
        let bytesDone = ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)
        let bytesTotal = ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
        return "\(progress.completedCount) of \(progress.totalCount) · \(bytesDone) of \(bytesTotal)"
    }

    private func policyText(_ prefs: ImportPreferences) -> String {
        var parts: [String] = []
        parts.append(prefs.importSidecarFiles ? "Sidecars on" : "Sidecars off")
        parts.append(prefs.deleteSourceAfterImport ? "Delete source after import" : "Keep source files")
        parts.append(prefs.autoEjectAfterImport ? "Auto-eject on" : "Auto-eject off")
        return parts.joined(separator: " · ")
    }
}
