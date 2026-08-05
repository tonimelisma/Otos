import SwiftUI

/// Bottom import plan footer for the selected removable source.
///
/// Renders coordinator presentation only: destination picker, readiness, totals
/// (including blocked/skipped-package counts), and Import queue. Filters and
/// grid selection never alter these totals.
struct ImportPlanFooter: View {
    let presentation: MediaOperationSourcePresentation
    let fixedLibraries: [CatalogLibraryState]
    let importPreferences: ImportPreferences
    let setDestination: (LibraryRootPath) -> Void
    let queueImport: () -> Void
    let showPlanDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                destinationPicker
                Spacer(minLength: 8)
                readinessLabel
                if canShowDetails {
                    Button("Details…", action: showPlanDetails)
                        .buttonStyle(.borderless)
                }
                importButton
            }
            if let totalsLine {
                Text(totalsLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private var importButton: some View {
        Button("Import", action: queueImport)
            .disabled(!importEnabled)
            .keyboardShortcut(.defaultAction)
    }

    private var canShowDetails: Bool {
        switch presentation.state {
        case .ready, .executionUnavailable, .completed:
            true
        default:
            false
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
            return summary.copyCount > 0 || summary.companionCopyCount > 0
        case .executionUnavailable:
            return false
        default:
            return false
        }
    }

    private var totalsLine: String? {
        switch presentation.state {
        case let .ready(summary, _, skipped):
            totalsText(summary: summary, skippedPackages: skipped)
        case let .executionUnavailable(summary, _):
            totalsText(summary: summary, skippedPackages: 0)
        case let .completed(summary):
            totalsText(summary: summary, skippedPackages: 0)
        default:
            nil
        }
    }

    private var readinessText: String {
        switch presentation.state {
        case .inventory:
            "Inventory…"
        case .waitingForDestination:
            "Choose a destination library"
        case let .waitingForMetadata(done, total):
            "Waiting for metadata (\(done)/\(total))"
        case .planning:
            "Planning…"
        case .ready:
            "Ready"
        case .queuedForReadiness:
            "Import queued — finishing metadata…"
        case let .executing(progress):
            "Importing \(progress.completedCount)/\(progress.totalCount)"
        case .needsReplan:
            "Source changed — replanning…"
        case .completed:
            "Import complete"
        case let .failed(problem):
            "Failed: \(problem)"
        case .executionUnavailable:
            "Import queued (execution lands in a later update)"
        }
    }

    private func totalsText(summary: MediaOperationPlanTotals, skippedPackages: Int) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: summary.copyBytes, countStyle: .file)
        var parts = [
            "\(summary.copyCount) copy",
            "\(summary.skipCount) preexisting",
            "\(summary.companionCopyCount) companion",
            "\(summary.blockedCount) blocked",
            bytes,
        ]
        if skippedPackages > 0 {
            parts.append("\(skippedPackages) skipped packages")
        }
        return parts.joined(separator: " · ")
    }

    private func policyText(_ prefs: ImportPreferences) -> String {
        var parts: [String] = []
        parts.append(prefs.importSidecarFiles ? "Sidecars on" : "Sidecars off")
        parts.append(prefs.deleteSourceAfterImport ? "Delete source after import" : "Keep source files")
        parts.append(prefs.autoEjectAfterImport ? "Auto-eject on" : "Auto-eject off")
        parts.append("Cleanup/eject withheld while blocked or skipped-package attention remains")
        return parts.joined(separator: " · ")
    }
}
