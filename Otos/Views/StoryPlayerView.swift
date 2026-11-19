import AVFoundation
import SwiftUI

// Story player guide (ADR 0049, `docs/design/on-this-day.md`, DES-112)
//
// The detail pane while an On This Day story plays: a 52 pt bar — Close and the
// anniversary's distance leading; Play / Pause, one segment per item of the anniversary
// and the position in the
// center; Previous and Next trailing — over the item's picture, aspect-fit on the
// `content` surface, with its date on the picture's top-left. The view is passive: the
// picture, the video and the wait are the loupe's own pane state, the position and timing
// are `StoryPlayback`, and every key and button calls a ViewModel intent.

struct StoryPlayerView: View {
    let story: StoryPlayback
    /// The item on screen: the loupe's focus.
    let item: MediaAssetID
    let onThisDay: CatalogOnThisDayState
    let orderedIDs: [MediaAssetID]
    let today: CalendarDay
    let kind: MediaKind?
    let panePreview: PanePreview?
    let videoState: LoupeVideoState?
    let isDownloading: Bool
    var tileContentStore: TileContentStore?
    var thumbnailDirectory: URL?
    var detailReader: MediaTileDetailReader?
    /// Each anniversary's title, once one is written (ADR 0053).
    var titles: [CalendarDay: String] = [:]
    let actions: StoryPlayerActions
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var place: (anniversary: OnThisDayAnniversary, position: Int)? {
        StoryPlaybackPolicy.place(of: item, anniversaries: onThisDay.anniversaries, orderedIDs: orderedIDs)
    }

    var body: some View {
        VStack(spacing: 0) {
            StoryPlayerBar(
                story: story,
                item: item,
                place: place,
                today: today,
                title: place.flatMap { titles[$0.anniversary.day] },
                videoState: videoState,
                actions: actions
            )
            picture
        }
        // The player is the keyboard target while it plays, and its focus ring shows it
        // (DES-081); its buttons take focus with their own rings on Tab.
        .focusable()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.space) { handled(actions.togglePause) }
        .onKeyPress(.leftArrow) { handled(actions.previous) }
        .onKeyPress(.rightArrow) { handled(actions.next) }
        .onKeyPress(.escape) { handled(actions.close) }
    }

    private func handled(_ action: () -> Void) -> KeyPress.Result {
        action()
        return .handled
    }

    private var picture: some View {
        ZStack {
            DesignPalette.content(for: colorScheme)
            pictureContent
                .id(item)
                // An item change cross-fades: content appearing (DES-070), 0.15 s under
                // Reduce Motion (DES-075).
                .transition(.opacity)
            // Centered, where a play glyph would sit (DES-086).
            if isDownloading {
                ProgressView()
                    .controlSize(.large)
                    .shadow(radius: 8)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.25), value: item)
        .clipped()
    }

    @ViewBuilder
    private var pictureContent: some View {
        let display = PanePresentation.display(paneID: item, preview: panePreview, videoState: videoState)
        Group {
            switch display {
            case let .video(state):
                LoupeVideoPlayerView(state: state, showsControls: false)
                    .aspectRatio(state.displaySize ?? CGSize(width: 16, height: 9), contentMode: .fit)
                    .overlay(alignment: .topLeading) { dateLabel }
            case let .full(image):
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay(alignment: .topLeading) { dateLabel }
                    .accessibilityElement()
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityAddTraits(.isImage)
            case let .thumbnail(id):
                if story.pane == .none, videoState == nil {
                    // The item can have no picture (DES-063's failure glyph).
                    Image(systemName: kind == .video ? "video.slash" : "photo.slash")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("No picture")
                } else {
                    PaneThumbnailView(
                        id: id,
                        tileContentStore: tileContentStore,
                        thumbnailDirectory: thumbnailDirectory,
                        detailReader: detailReader
                    )
                    .overlay(alignment: .topLeading) { dateLabel }
                }
            case .empty:
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The item's date in white on the picture's top-left, over a top scrim (DES-112).
    @ViewBuilder
    private var dateLabel: some View {
        if let place {
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [DesignPalette.photoScrim, .clear], startPoint: .top, endPoint: .center)
                Text(OnThisDayPresentation.fullDate(place.anniversary.day))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(DesignPalette.photoLabel)
                    .padding(12)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var accessibilityLabel: String {
        let date = place.map { OnThisDayPresentation.fullDate($0.anniversary.day) } ?? ""
        return kind == .video ? "Video, \(date)" : "Photo, \(date)"
    }
}

/// The intents the player's keys and buttons call.
struct StoryPlayerActions {
    let canTogglePause: Bool
    let canPrevious: Bool
    let canNext: Bool
    let togglePause: () -> Void
    let previous: () -> Void
    let next: () -> Void
    let close: () -> Void
}

/// The player's bar (DES-112): 52 pt in every state, in the Places bar's place.
private struct StoryPlayerBar: View {
    let story: StoryPlayback
    let item: MediaAssetID
    let place: (anniversary: OnThisDayAnniversary, position: Int)?
    let today: CalendarDay
    /// The anniversary's title; nothing shows until one is written.
    let title: String?
    let videoState: LoupeVideoState?
    let actions: StoryPlayerActions
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            barButton("Close", systemImage: "xmark", isEnabled: true, action: actions.close)
            Text(ago)
                .font(.title3.weight(.semibold))
                .foregroundStyle(DesignPalette.label(for: colorScheme))
                .monospacedDigit()
                .lineLimit(1)
                .layoutPriority(1)
            Text(title ?? "")
                .font(.subheadline)
                .foregroundStyle(DesignPalette.l3(for: colorScheme))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            barButton(
                story.isPaused ? "Play" : "Pause",
                systemImage: story.isPaused ? "play.fill" : "pause.fill",
                isEnabled: actions.canTogglePause,
                action: actions.togglePause
            )
            StorySegments(story: story, item: item, place: place, videoState: videoState)
                .frame(maxWidth: 360)
            Text(place.map { OnThisDayPresentation.position($0.position, of: $0.anniversary.count) } ?? "")
                .font(.subheadline)
                .foregroundStyle(DesignPalette.l3(for: colorScheme))
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 8)
            barButton("Previous", systemImage: "chevron.left", isEnabled: actions.canPrevious, action: actions.previous)
            barButton("Next", systemImage: "chevron.right", isEnabled: actions.canNext, action: actions.next)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(DesignPalette.bar(for: colorScheme))
        .overlay(alignment: .bottom) {
            DesignPalette.hairline(for: colorScheme).frame(height: 1)
        }
    }

    private var ago: String {
        place.map { OnThisDayPresentation.ago($0.anniversary, today: today) } ?? ""
    }

    private func barButton(
        _ title: String,
        systemImage: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// One 4 pt segment per item of the anniversary, 4 pt apart: behind filled, ahead empty, the
/// current one filling as it plays — determinate progress, so the accent on a tertiary
/// track (DES-024).
private struct StorySegments: View {
    let story: StoryPlayback
    let item: MediaAssetID
    let place: (anniversary: OnThisDayAnniversary, position: Int)?
    let videoState: LoupeVideoState?

    var body: some View {
        HStack(spacing: 4) {
            if let place {
                ForEach(1 ... place.anniversary.count, id: \.self) { position in
                    segment(position: position, current: place.position)
                }
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(place.map { "Item \($0.position) of \($0.anniversary.count)" } ?? "")
    }

    @ViewBuilder
    private func segment(position: Int, current: Int) -> some View {
        if position == current {
            TimelineView(.animation(paused: !isCounting)) { context in
                bar(fill: currentFraction(at: context.date))
            }
        } else {
            bar(fill: position < current ? 1 : 0)
        }
    }

    private func bar(fill: Double) -> some View {
        Capsule()
            .fill(.tertiary)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * fill)
                }
            }
    }

    private var isCounting: Bool {
        !story.isPaused && (story.hold != nil || story.video == .playing)
    }

    /// How far the current item has played: the hold's share for a still, the player's
    /// time for a video.
    private func currentFraction(at _: Date) -> Double {
        if story.hasEnded {
            return 1
        }
        if let hold = story.hold {
            return hold.fraction(at: .now)
        }
        guard let videoState, videoState.id == item, let playerItem = videoState.player.currentItem else {
            return 0
        }
        // The range the player plays: a trim's (ADR 0036), else the whole file, so a
        // trimmed video's segment is full when it ends.
        let trimStart = playerItem.reversePlaybackEndTime
        let trimEnd = playerItem.forwardPlaybackEndTime
        let start = trimStart.isNumeric ? trimStart.seconds : 0
        let end = trimEnd.isNumeric ? trimEnd.seconds : playerItem.duration.seconds
        guard start.isFinite, end.isFinite, end > start else {
            return 0
        }
        return min(1, max(0, (videoState.player.currentTime().seconds - start) / (end - start)))
    }
}
