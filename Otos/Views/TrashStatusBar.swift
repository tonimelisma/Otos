import SwiftUI

/// What the trash status bar draws for one queue state (DES-089). Pure: every string
/// is derived here from `MediaTrashCoordinator.QueueState`, and the view renders it.
/// Status vocabulary follows DES-030: the queue is Working, or Needs attention while
/// it waits on free space or a download.
nonisolated struct TrashStatusPresentation: Equatable, Sendable {
    enum Badge: Equatable, Sendable {
        case none
        case attention
    }

    let badge: Badge
    let primaryLine: String
    let secondaryLine: String?
    /// Items moved and the run's total, when the bar is Working. Never a percentage
    /// synthesized from bytes (DES-032).
    let progress: (completed: Int, total: Int)?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.badge == rhs.badge && lhs.primaryLine == rhs.primaryLine
            && lhs.secondaryLine == rhs.secondaryLine
            && lhs.progress?.completed == rhs.progress?.completed
            && lhs.progress?.total == rhs.progress?.total
    }

    /// `nil` when nothing is waiting: the bar is not drawn.
    static func map(_ state: MediaTrashCoordinator.QueueState) -> TrashStatusPresentation? {
        guard state.pendingCount > 0 else {
            return nil
        }
        let waiting = "\(items(state.pendingCount)) waiting to move to the Trash"
        switch state.attention {
        case .waitingForSpace:
            return TrashStatusPresentation(
                badge: .attention,
                primaryLine: "Waiting for free space",
                secondaryLine: waiting,
                progress: nil
            )
        case .waitingForDownload:
            return TrashStatusPresentation(
                badge: .attention,
                primaryLine: "Waiting to download",
                secondaryLine: waiting,
                progress: nil
            )
        case nil:
            return TrashStatusPresentation(
                badge: .none,
                primaryLine: "Moving \(items(state.runTotal)) to the Trash",
                secondaryLine: state.bytesToDownload == .zero
                    ? nil
                    : ImportBarByteFormat.phrase(state.bytesToDownload).map { "\($0) to download" },
                progress: (state.movedCount, state.runTotal)
            )
        }
    }

    private static func items(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }
}

/// Bottom status surface for the trash queue (DES-089). Shown in every scope while
/// any item is waiting to move to the Trash, below the selection's own status surface.
/// *What* (L1 over L3), *progress*, then *the act* — Cancel, which leaves every item still
/// waiting where it is (DES-032) — at one fixed height across states (DES-018, DES-053).
/// Passive: it renders a `TrashStatusPresentation` and calls `cancel`; the queue's
/// questions arrive as alerts.
struct TrashStatusBar: View {
    let presentation: TrashStatusPresentation
    let cancel: @MainActor () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The title3 line over the subheadline line; the bar never resizes between states.
    private static let contentHeight: CGFloat = 40

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if presentation.badge == .attention {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                    }
                    Text(presentation.primaryLine)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(DesignPalette.label(for: colorScheme))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                if let secondary = presentation.secondaryLine {
                    Text(secondary)
                        .font(.subheadline)
                        .foregroundStyle(DesignPalette.l3(for: colorScheme))
                        .monospacedDigit()
                        .lineLimit(1)
                } else {
                    Color.clear.frame(height: 14)
                }
            }
            Spacer(minLength: 0)
            if let progress = presentation.progress {
                HStack(spacing: 8) {
                    ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .frame(width: 160)
                        .animation(
                            reduceMotion ? .linear(duration: 0.1) : .linear(duration: 0.2),
                            value: progress.completed
                        )
                    Text("\(progress.completed) of \(progress.total)")
                        .font(.subheadline)
                        .foregroundStyle(DesignPalette.l3(for: colorScheme))
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
            Button("Cancel", action: cancel)
        }
        .frame(minHeight: Self.contentHeight, maxHeight: Self.contentHeight)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(DesignPalette.bar(for: colorScheme))
        .accessibilityElement(children: .contain)
    }
}
