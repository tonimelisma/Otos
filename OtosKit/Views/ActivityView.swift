import SwiftUI

// The sidebar's Activity line and its popover (ADR 0058, `docs/design/activity.md`,
// DES-124): the one place the window says the status of the background work — working,
// waiting on something, or up to date. The line sits at the sidebar's foot at one fixed height
// in every state (DES-053); a click, Space or Return opens a read-only popover (DES-041) listing
// the work that runs or waits, each with what stops it, and one line for everything else.
// Passive: every string comes from `ActivityPresentation`.

struct ActivityLine: View {
    let presentation: ActivityPresentation

    @State private var showsPopover = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            showsPopover.toggle()
        } label: {
            // A two-line template holds the line's one height in every state (DES-053); the
            // shown text is centred in it, so `Up to date` alone sits level with its glyph.
            ZStack(alignment: .leading) {
                content(title: " ", detail: " ").hidden()
                content(title: presentation.line ?? " ", detail: presentation.lineDetail)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            // The spinner inside would otherwise stand in for the button: VoiceOver and
            // Full Keyboard Access read the line as a button with its label, never a busy
            // indicator (DES-080).
            .accessibilityElement(children: .ignore)
        }
        .buttonStyle(.plain)
        .disabled(presentation.line == nil)
        .help("Show what Otos is doing in the background")
        .accessibilityLabel(presentation.accessibilityLabel)
        .background(DesignPalette.sidebar(for: colorScheme))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DesignPalette.hairline(for: colorScheme))
                .frame(height: 1)
        }
        .popover(isPresented: $showsPopover, arrowEdge: .trailing) {
            ActivityPopover(presentation: presentation)
        }
    }

    /// The glyph level with the L2 line's centre (`ActivityStatusGlyph.onBodyLine`), then L2
    /// over an optional L3.
    private func content(title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ActivityStatusGlyph(status: presentation.lineStatus)
                .onBodyLine()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(DesignPalette.label(for: colorScheme))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(DesignPalette.l3(for: colorScheme))
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A status's 16 pt glyph: a small spinner while working (DES-072), a pause while waiting, a
/// checkmark when up to date, nothing while unknown.
struct ActivityStatusGlyph: View {
    let status: ActivityPresentation.Status?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch status {
            case .working:
                ProgressView()
                    .controlSize(.small)
            case .waiting:
                Image(systemName: "pause.circle")
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
            case .upToDate:
                Image(systemName: "checkmark")
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
            case nil:
                Color.clear
            }
        }
        .frame(width: 16, height: 16)
    }

    /// Centres the glyph on an L2 (`body`) line: a hidden line of that font gives the row its
    /// first baseline and height, and the glyph sits at that line's middle.
    func onBodyLine() -> some View {
        Text(" ")
            .font(.body)
            .hidden()
            .frame(width: 16)
            .overlay { self }
    }
}

struct ActivityPopover: View {
    let presentation: ActivityPresentation

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(presentation.header)
                .font(.title3.weight(.semibold))
                .foregroundStyle(DesignPalette.label(for: colorScheme))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(presentation.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: row.systemImage)
                            .foregroundStyle(DesignPalette.l3(for: colorScheme))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(.body)
                                .foregroundStyle(DesignPalette.label(for: colorScheme))
                            ForEach(row.details, id: \.self) { detail in
                                Text(detail)
                                    .font(.subheadline)
                                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
                                    .monospacedDigit()
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 8)
                        ActivityStatusGlyph(status: row.status)
                            .onBodyLine()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let footer = presentation.footer {
                Text(footer)
                    .font(.subheadline)
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }
}
