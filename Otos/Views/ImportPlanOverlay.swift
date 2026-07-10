import SwiftUI

/// Read-only plan detail sheet for the selected removable source.
///
/// Loads dispositions for the ready plan through `ImportPlanDetailReader` /
/// coordinator `readyPlan` — never a published full plan map on window state.
struct ImportPlanOverlay: View {
    let presentation: MediaOperationSourcePresentation
    let plan: MediaOperationPlan?
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Import Plan")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done", action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }

            if let plan {
                Text(summaryLine(plan.totals))
                    .foregroundStyle(.secondary)
                List(plan.entries, id: \.source.id) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.source.relativePath.rawValue)
                            .lineLimit(1)
                        Spacer()
                        Text(dispositionLabel(entry.disposition))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else {
                Text("No ready plan is available for this source.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 360)
    }

    private func summaryLine(_ totals: MediaOperationPlanTotals) -> String {
        "\(totals.copyCount) copy · \(totals.skipCount) preexisting · \(totals.blockedCount) blocked · \(totals.companionCopyCount) companion"
    }

    private func dispositionLabel(_ disposition: MediaOperationDisposition) -> String {
        switch disposition {
        case let .copy(destination):
            "Copy → \(destination.rawValue)"
        case let .skipPreexisting(destination):
            "Skip → \(destination.rawValue)"
        case let .relocate(destination):
            "Relocate → \(destination.rawValue)"
        case .noOp:
            "No-op"
        case let .blocked(reason):
            "Blocked (\(blockReasonLabel(reason)))"
        }
    }

    private func blockReasonLabel(_ reason: MediaOperationBlockReason) -> String {
        switch reason {
        case .noUsableDate:
            "no usable date"
        case let .comparisonUnavailable(_, detail):
            "comparison unavailable: \(detail)"
        case .comparisonRequiresMaterialization:
            "needs materialization"
        }
    }
}
