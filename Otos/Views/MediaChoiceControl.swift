import SwiftUI

/// Shared content-choice control for the large Loupe and Compare surfaces. The
/// hover region owns visibility; the row itself owns only the two toggle acts,
/// resolving each through `MediaChoiceToggle` so pressing the active one clears
/// to Not Rated. The region is full-pane so the controls appear without
/// reserving resting space or moving with an aspect-fit image.
struct MediaChoiceHoverRegion<Content: View>: View {
    let currentChoice: MediaChoice?
    let onChoice: (MediaChoice) -> Void
    @ViewBuilder let content: () -> Content
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            content()
            MediaChoiceControl(
                currentChoice: currentChoice,
                isVisible: isHovering,
                onChoice: onChoice
            )
            .padding(12)
        }
        .onHover { isHovering = $0 }
        // DES-068: the item carries the curation value once — not each of the
        // three hover buttons, which would announce "Selected"/"Not selected"
        // redundantly per button.
        .accessibilityValue((currentChoice ?? .default).accessibilityValue)
        .accessibilityAction(named: Text(MediaChoice.liked.accessibilityActionLabel)) {
            onChoice(.liked)
        }
        .accessibilityAction(named: Text(MediaChoice.notRated.accessibilityActionLabel)) {
            onChoice(.notRated)
        }
        .accessibilityAction(named: Text(MediaChoice.disliked.accessibilityActionLabel)) {
            onChoice(.disliked)
        }
    }
}

struct MediaChoiceControl: View {
    let currentChoice: MediaChoice?
    let isVisible: Bool
    let onChoice: (MediaChoice) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(MediaChoiceToggle.allCases, id: \.self) { toggle in
                let isOn = currentChoice == toggle.choice
                Button {
                    onChoice(toggle.resolved(from: currentChoice ?? .default))
                } label: {
                    // The filled variant is the selected state (DES-068); the
                    // accent tint only reinforces it, so grayscale still reads.
                    Image(systemName: toggle.symbol(isOn: isOn))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.borderless)
                .help(toggle.actionLabel)
                .accessibilityLabel(toggle.actionLabel)
            }
        }
        .padding(.horizontal, 2)
        .background(.ultraThinMaterial, in: Capsule())
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(.easeInOut(duration: 0.15), value: isVisible)
        .accessibilityHidden(!isVisible)
    }
}
