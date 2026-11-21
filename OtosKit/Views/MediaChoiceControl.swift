import SwiftUI

/// Shared content-choice control for the large Loupe and Compare surfaces. The
/// hover region owns visibility and placement; the row itself owns only the two
/// toggle acts, resolving each through `MediaChoiceToggle` so pressing the active
/// one clears to Not Rated.
///
/// The *region* stays full-pane, so hover is detected anywhere over the pane and
/// nothing reserves resting space. The *group* is placed on the media, not on the
/// pane: a pane wider than its photo paints black beside it, and a group anchored
/// to the pane corner sits in that letterbox instead of on the picture (DES-066).
/// `mediaPixelSize` is nil where the pane cannot know the size (a poster or a
/// video), and `contentRect` answers the full bounds for nil — the honest
/// fallback, since a guessed frame would put the group somewhere the media may
/// not be.
struct MediaChoiceHoverRegion<Content: View>: View {
    let currentChoice: MediaChoice?
    let mediaPixelSize: CGSize?
    let onChoice: (MediaChoice) -> Void
    @ViewBuilder let content: () -> Content
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            content()
            GeometryReader { proxy in
                let face = MediaAssetTilePresentation.contentRect(
                    imagePixelSize: mediaPixelSize,
                    bounds: CGRect(origin: .zero, size: proxy.size)
                )
                MediaChoiceControl(
                    currentChoice: currentChoice,
                    isVisible: isHovering,
                    onChoice: onChoice
                )
                .padding(12)
                .offset(x: face.minX, y: face.minY)
            }
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
                    // Two independent carriers of the selected state, because
                    // neither may be colour alone (DES-068): the glyph switches
                    // outline -> filled, and an accent disc sits behind it. The
                    // glyph itself stays at full contrast — tinting it accent
                    // made the *selected* act read dimmer than the unselected
                    // one in grayscale, since accent desaturates to a mid grey
                    // below both white and black.
                    Image(systemName: toggle.symbol(isOn: isOn))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                        .background(isOn ? Color.accentColor : Color.clear, in: Circle())
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
