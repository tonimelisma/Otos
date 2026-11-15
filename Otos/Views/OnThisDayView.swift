import SwiftUI

// On This Day guide (ADR 0049, `docs/design/on-this-day.md`)
//
// The detail pane for the `.onThisDay` scope: a bar naming the day, then one photo card
// per earlier anniversary that holds a match — earlier years, or earlier months when no
// year does — newest first. A click on a card, or Return or Space on the focused card,
// plays that anniversary's story. The view is passive: it renders `CatalogOnThisDayState`,
// holds only keyboard focus as control state, applies the ViewModel's focus request once
// per revision, and reports the anniversary to play.

struct OnThisDayView: View {
    let onThisDay: CatalogOnThisDayState?
    let today: CalendarDay
    let emptyState: CatalogMediaEmptyState?
    let focusRequest: OnThisDayFocusRequest?
    var tileContentStore: TileContentStore?
    var thumbnailDirectory: URL?
    var detailReader: MediaTileDetailReader?
    /// Each anniversary's title, once one is written (ADR 0053).
    var titles: [CalendarDay: String] = [:]
    let play: (CalendarDay) -> Void
    var clearFilters: () -> Void = {}
    @FocusState private var focused: CalendarDay?
    @State private var appliedFocusRevision: UInt64 = 0
    @State private var gridWidth: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    private static let minimumCardWidth: CGFloat = 260
    private static let maximumCardWidth: CGFloat = 420
    private static let gap: CGFloat = 16
    private static let margin: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            OnThisDayBar(
                day: onThisDay?.day ?? today,
                summary: OnThisDayPresentation.barSummary(onThisDay, emptyState: emptyState)
            )
            if let anniversaries = onThisDay?.anniversaries, !anniversaries.isEmpty {
                cards(anniversaries)
            } else if let emptyState {
                CatalogMediaEmptyStateView(emptyState: emptyState, clearFilters: clearFilters)
                    .background(DesignPalette.content(for: colorScheme))
            }
        }
    }

    private func cards(_ anniversaries: [OnThisDayAnniversary]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(
                    .adaptive(minimum: Self.minimumCardWidth, maximum: Self.maximumCardWidth),
                    spacing: Self.gap,
                    alignment: .topLeading
                )],
                alignment: .leading,
                spacing: Self.gap
            ) {
                ForEach(anniversaries) { anniversary in
                    OnThisDayCard(
                        anniversary: anniversary,
                        title: titles[anniversary.day],
                        today: today,
                        isFocused: focused == anniversary.day,
                        tileContentStore: tileContentStore,
                        thumbnailDirectory: thumbnailDirectory,
                        detailReader: detailReader
                    )
                    // The system focus ring shows the keyboard target (DES-081); the card's
                    // 3 pt accent border marks the focused card as DES-061 does a tile.
                    .focusable(interactions: .activate)
                    .focused($focused, equals: anniversary.day)
                    .onTapGesture { play(anniversary.day) }
                    .accessibilityAction { play(anniversary.day) }
                }
            }
            // On the grid, inside the scroll view, so the focused card's keys reach these
            // before the scroll view takes the arrows for scrolling.
            .onKeyPress(.return) { playFocused() }
            .onKeyPress(.space) { playFocused() }
            .onKeyPress(.leftArrow) { moveFocus(by: -1, in: anniversaries) }
            .onKeyPress(.rightArrow) { moveFocus(by: 1, in: anniversaries) }
            .onKeyPress(.upArrow) { moveFocus(by: -columnCount, in: anniversaries) }
            .onKeyPress(.downArrow) { moveFocus(by: columnCount, in: anniversaries) }
            .padding(Self.margin)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                gridWidth = width
            }
        }
        .background(DesignPalette.content(for: colorScheme))
        .onChange(of: focusRequest?.revision, initial: true) { _, _ in
            applyFocusRequest(anniversaries)
        }
    }

    /// The columns the adaptive grid lays out at its width: as many minimum-width cards
    /// as fit with their gaps, so ↑ and ↓ move by a row.
    private var columnCount: Int {
        let available = gridWidth - 2 * Self.margin
        return max(1, Int((available + Self.gap) / (Self.minimumCardWidth + Self.gap)))
    }

    private func playFocused() -> KeyPress.Result {
        guard let focused else {
            return .ignored
        }
        play(focused)
        return .handled
    }

    private func moveFocus(by delta: Int, in anniversaries: [OnThisDayAnniversary]) -> KeyPress.Result {
        guard !anniversaries.isEmpty else {
            return .ignored
        }
        let index = focused.flatMap { day in anniversaries.firstIndex { $0.day == day } }
        let next = index.map { min(max($0 + delta, 0), anniversaries.count - 1) } ?? 0
        focused = anniversaries[next].day
        return .handled
    }

    private func applyFocusRequest(_ anniversaries: [OnThisDayAnniversary]) {
        guard let focusRequest, focusRequest.revision != appliedFocusRevision else {
            return
        }
        appliedFocusRevision = focusRequest.revision
        let requested = focusRequest.anniversary
        focused = anniversaries.contains { $0.day == requested } ? requested : anniversaries.first?.day
    }
}

/// The surface's one fact (DES-010): the day, with what it holds as L3. 52 pt in every
/// state, where the day bar sits (DES-112, after DES-105).
private struct OnThisDayBar: View {
    let day: CalendarDay
    let summary: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(OnThisDayPresentation.dayTitle(day))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(DesignPalette.label(for: colorScheme))
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(DesignPalette.bar(for: colorScheme))
        .overlay(alignment: .bottom) {
            DesignPalette.hairline(for: colorScheme).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One anniversary: its key photo on a 16:9 card, aspect-filled **[deviation DES-060A]** —
/// a cover stands for the anniversary, it is not the photograph under review — with its
/// distance on the photo, and under it its title and its date and count (DES-112).
private struct OnThisDayCard: View {
    let anniversary: OnThisDayAnniversary
    /// The title written for the anniversary; its line is kept, empty, until one is.
    let title: String?
    let today: CalendarDay
    let isFocused: Bool
    let tileContentStore: TileContentStore?
    let thumbnailDirectory: URL?
    let detailReader: MediaTileDetailReader?
    @State private var cover: (id: MediaAssetID, image: CGImage)?
    @Environment(\.colorScheme) private var colorScheme

    private static let radius: CGFloat = 9

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            face
            VStack(alignment: .leading, spacing: 2) {
                // The line holds its height before a title arrives (DES-053).
                Text(title ?? " ")
                    .font(.body)
                    .foregroundStyle(DesignPalette.label(for: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(OnThisDayPresentation.cardCaption(anniversary))
                    .font(.subheadline)
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OnThisDayPresentation.cardAccessibilityLabel(anniversary, title: title, today: today))
        .accessibilityAddTraits(.isButton)
        .task(id: anniversary.keyItem) {
            await loadCover()
        }
    }

    /// The cover to draw for the key item: the one this card painted, else the decode the
    /// shared store already holds — read while rendering, so a card made again (after a
    /// story closes, or when the grid recycles it) paints its cover in its first frame
    /// instead of the placeholder.
    private var displayedCover: CGImage? {
        OnThisDayCover.displayed(painted: cover, keyItem: anniversary.keyItem, stored: tileContentStore?.image(for: anniversary.keyItem))
    }

    private var face: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            // The well is content, not chrome (DES-022).
            .background(DesignPalette.content(for: colorScheme))
            .overlay {
                // A cover painted for this key item stays until a newer one replaces it;
                // before the first decode, DES-063's glyph on the well.
                if let image = displayedCover {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            .overlay(alignment: .bottomLeading) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [DesignPalette.photoScrim, .clear], startPoint: .bottom, endPoint: .top)
                    Text(OnThisDayPresentation.ago(anniversary, today: today))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(DesignPalette.photoLabel)
                        .padding(12)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.radius))
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: Self.radius)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
    }

    /// Keeps the cover the store holds, and decodes one only on a miss.
    private func loadCover() async {
        if let cached = tileContentStore?.image(for: anniversary.keyItem) {
            cover = (anniversary.keyItem, cached)
            return
        }
        guard let image = await ThumbnailLoad.image(
            for: anniversary.keyItem,
            tileContentStore: tileContentStore,
            thumbnailDirectory: thumbnailDirectory,
            detailReader: detailReader,
            operation: "onThisDay.cover"
        ), !Task.isCancelled else {
            return
        }
        cover = (anniversary.keyItem, image)
    }
}

/// Which cover a card draws (DES-112): the one it painted for its key item, else the decode
/// the shared store holds for it, else none — so the placeholder shows only before the key
/// item's first decode, never over a cover already painted for it.
nonisolated enum OnThisDayCover {
    static func displayed(
        painted: (id: MediaAssetID, image: CGImage)?,
        keyItem: MediaAssetID,
        stored: CGImage?
    ) -> CGImage? {
        if let painted, painted.id == keyItem {
            return painted.image
        }
        return stored
    }
}
