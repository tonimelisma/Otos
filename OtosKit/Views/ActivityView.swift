import SwiftUI

// The sidebar's Activity line and its popover (ADR 0058, `docs/design/activity.md`,
// DES-124): the one place the window says what background work runs and since when. The line
// sits at the sidebar's foot at one fixed height in every state (DES-053); a click, Space or
// Return opens a read-only popover (DES-041) listing what works now and what finished this
// session. Passive: every string comes from `ActivityPresentation`.

struct ActivityLine: View {
    let presentation: ActivityPresentation

    @State private var showsPopover = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            showsPopover.toggle()
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Group {
                    if presentation.isWorking {
                        // DES-072: it moves while work is in flight.
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "checkmark")
                            .foregroundStyle(DesignPalette.l3(for: colorScheme))
                            .opacity(presentation.line == nil ? 0 : 1)
                    }
                }
                .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.line ?? " ")
                        .font(.body)
                        .foregroundStyle(DesignPalette.label(for: colorScheme))
                        .lineLimit(1)
                    Text(presentation.lineDetail ?? " ")
                        .font(.subheadline)
                        .foregroundStyle(DesignPalette.l3(for: colorScheme))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
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
}

struct ActivityPopover: View {
    let presentation: ActivityPresentation

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(presentation.header)
                .font(.title3.weight(.semibold))
                .foregroundStyle(DesignPalette.label(for: colorScheme))
                .monospacedDigit()
                .accessibilityAddTraits(.isHeader)
            if !presentation.working.isEmpty {
                rows(presentation.working)
            }
            if !presentation.finished.isEmpty {
                if !presentation.working.isEmpty {
                    Rectangle()
                        .fill(DesignPalette.hairline(for: colorScheme))
                        .frame(height: 1)
                }
                rows(presentation.finished)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    private func rows(_ rows: [ActivityPresentation.Row]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: row.systemImage)
                        .foregroundStyle(DesignPalette.l3(for: colorScheme))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.body)
                            .foregroundStyle(DesignPalette.label(for: colorScheme))
                        if let detail = row.detail {
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(DesignPalette.l3(for: colorScheme))
                                .monospacedDigit()
                        }
                    }
                    Spacer(minLength: 8)
                    Text(row.time)
                        .font(.subheadline)
                        .foregroundStyle(DesignPalette.l3(for: colorScheme))
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
