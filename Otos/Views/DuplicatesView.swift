import AppKit
import SwiftUI

// The detail pane for the `.duplicates` scope (ADR 0042, `docs/design/duplicates.md`): a
// list of groups, each a header — the facts the copies share and the decision in words —
// over a strip of tiles, one per copy, each its picture, what differs about it and its
// Keep mark; then a fixed-height bar stating the duplicates fact and offering the one act.
// Passive: every string comes from `DuplicatesPresentation`, every control calls a
// view-model intent, and a click on a tile goes to the grid's one selection model
// (`GridSelection`, through the view model); the marks and counts are `DuplicatesSession`'s.

struct DuplicatesView: View {
    let duplicates: CatalogDuplicatesState
    let session: DuplicatesSession
    let canUndoMove: Bool
    let selection: Set<MediaAssetID>
    let tileContentStore: TileContentStore?
    let thumbnailDirectory: URL?
    let detailReader: MediaTileDetailReader?
    let actions: DuplicatesActions

    /// The copy the arrow keys move from: the last one clicked or reached by a key. Local
    /// control state; the selection itself is the view model's.
    @State private var cursor: MediaAssetID?
    @FocusState private var listFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            if duplicates.groups.isEmpty {
                // The bar is the status surface and carries the L1 `No duplicates`; the
                // list area says why it is empty.
                ContentUnavailableView {
                    Image(systemName: "square.on.square")
                } description: {
                    Text("Nothing Otos has checked is stored twice.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DesignPalette.content(for: colorScheme))
            } else {
                list
            }
            Rectangle()
                .fill(DesignPalette.hairline(for: colorScheme))
                .frame(height: 1)
            DuplicatesStatusBar(
                presentation: .map(session.tally(in: duplicates), receipt: session.receipt, canUndoMove: canUndoMove),
                actions: actions
            )
        }
        // The seam's hairline composes over `content`, never over the window colour.
        .background(DesignPalette.content(for: colorScheme))
    }

    private var pairs: [(pair: DuplicateLibraryPair, groups: [DuplicateGroup])] {
        let grouped = Dictionary(grouping: duplicates.groups.filter { $0.libraryPair != nil }) { $0.libraryPair! }
        return grouped.map { ($0.key, $0.value) }.sorted { $0.pair.first.rawValue < $1.pair.first.rawValue }
    }

    private var standaloneGroups: [DuplicateGroup] {
        duplicates.groups.filter { $0.libraryPair == nil }
    }

    /// The groups on screen, in the list's order: each pair's groups while it is expanded,
    /// then the standalone groups.
    private var shownGroups: [DuplicateGroup] {
        pairs.flatMap { session.expandedPairs.contains($0.pair) ? $0.groups : [] } + standaloneGroups
    }

    /// The copies on screen in reading order, by group: the order ⇧-click ranges over and
    /// the arrow keys walk. A kept group shows no tiles, so it has none.
    private var tileOrder: DuplicatesTileOrder {
        DuplicatesTileOrder(groups: shownGroups.filter { !$0.isKept }.map { $0.copies.map(\.id) })
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(pairs.enumerated()), id: \.element.pair) { index, entry in
                        DuplicateLibraryPairRow(
                            presentation: .map(entry.pair, groups: entry.groups, session: session),
                            groups: entry.groups,
                            isExpanded: session.expandedPairs.contains(entry.pair),
                            isFirst: index == 0,
                            actions: actions
                        )
                        if session.expandedPairs.contains(entry.pair) {
                            ForEach(entry.groups) { group in
                                groupSection(group, isFirst: false)
                            }
                        }
                    }
                    ForEach(Array(standaloneGroups.enumerated()), id: \.element.id) { index, group in
                        groupSection(group, isFirst: index == 0 && pairs.isEmpty)
                    }
                }
                // DES-060's section inset: one left edge for every header and first tile.
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .background {
                    // A click on the list's empty space selects nothing, as in the grid.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            listFocused = true
                            select(nil)
                        }
                }
            }
            .background(DesignPalette.content(for: colorScheme))
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                guard let direction = DuplicatesTileOrder.Direction(press.key),
                      let target = tileOrder.target(from: cursor, direction)
                else {
                    return .ignored
                }
                select(target, modifiers: press.modifiers.contains(.shift) ? .shift : [])
                proxy.scrollTo(target)
                return .handled
            }
            .onKeyPress(.return) {
                actions.openGroup()
                return .handled
            }
            // Space opens the group as Return does: Lightroom's Loupe toggle.
            .onKeyPress(.space) {
                actions.openGroup()
                return .handled
            }
            .onChange(of: selection) { _, selected in
                // A selection made elsewhere — Show, Undo's reveal — is scrolled to and
                // becomes where the arrow keys start.
                if let cursor, selected.contains(cursor) {
                    return
                }
                if let first = tileOrder.copies.first(where: selected.contains) {
                    cursor = first
                    proxy.scrollTo(first)
                }
            }
        }
    }

    private func select(_ id: MediaAssetID?, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        cursor = id
        actions.select(id, modifiers, tileOrder.copies)
    }

    @ViewBuilder
    private func groupSection(_ group: DuplicateGroup, isFirst: Bool) -> some View {
        let presentation = DuplicateGroupPresentation.map(group, session: session)
        VStack(alignment: .leading, spacing: 10) {
            DuplicateGroupSeam(isFirst: isFirst)
            DuplicateGroupHeader(group: group, presentation: presentation, actions: actions)
            if !presentation.tiles.isEmpty {
                LazyVGrid(
                    columns: [GridItem(
                        .adaptive(minimum: DuplicateCopyTile.width, maximum: DuplicateCopyTile.width),
                        spacing: DuplicateCopyTile.gutter,
                        alignment: .topLeading
                    )],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(presentation.tiles) { tile in
                        DuplicateCopyTile(
                            tile: tile,
                            isSelected: selection.contains(tile.id),
                            tileContentStore: tileContentStore,
                            thumbnailDirectory: thumbnailDirectory,
                            detailReader: detailReader,
                            actions: actions,
                            select: {
                                listFocused = true
                                select(tile.id)
                            }
                        )
                        .id(tile.id)
                    }
                }
            }
        }
        .padding(.top, isFirst ? 0 : 4)
        .padding(.bottom, 16)
    }
}

/// The view model's duplicates intents, handed to the passive views.
struct DuplicatesActions {
    /// A click or arrow key on a tile (nil: the list's empty space), with its modifiers and
    /// the list's copies in order — the grid's click intent, so one selection model serves
    /// both (APP-011).
    let select: @MainActor (MediaAssetID?, NSEvent.ModifierFlags, [MediaAssetID]) -> Void
    let keep: @MainActor (MediaAssetID) -> Void
    let unkeep: @MainActor (MediaAssetID) -> Void
    let keepAll: @MainActor (DuplicateGroup) -> Void
    let keepOnly: @MainActor (MediaAssetID) -> Void
    let reviewAgain: @MainActor ([DuplicateGroup]) -> Void
    let keepBothLibraries: @MainActor (DuplicateLibraryPair) -> Void
    let keepOnlyLibrary: @MainActor (LibraryRootPath, DuplicateLibraryPair) -> Void
    let keepEachLibrary: @MainActor (DuplicateLibraryPair) -> Void
    let togglePair: @MainActor (DuplicateLibraryPair) -> Void
    let openGroup: @MainActor () -> Void
    let openGroupContaining: @MainActor (MediaAssetID) -> Void
    let compareGroup: @MainActor (DuplicateGroup) -> Void
    let moveToTrashNow: @MainActor (MediaAssetID) -> Void
    let moveMarked: @MainActor () -> Void
    let undoMove: @MainActor () -> Void
    let revealNeedingChoice: @MainActor () -> Void
}

/// A hairline between groups (DES-023): drawn above every card but the list's first.
private struct DuplicateGroupSeam: View {
    let isFirst: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if !isFirst {
            Rectangle()
                .fill(DesignPalette.hairline(for: colorScheme))
                .frame(height: 1)
                .padding(.bottom, 12)
        }
    }
}

/// A group's header: the title with Compare and Keep All Copies trailing, the shared
/// facts, and the decision. Kept, the title and facts with Review Again.
private struct DuplicateGroupHeader: View {
    let group: DuplicateGroup
    let presentation: DuplicateGroupPresentation
    let actions: DuplicatesActions

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(presentation.title)
                    .font(.headline)
                    .foregroundStyle(DesignPalette.label(for: colorScheme))
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityLabel(presentation.accessibilityLabel)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                // Not Tab stops: on a library of hundreds of groups they would stand between
                // the list and the bar (DES-080). Photo ▸ Keep All Copies / Review Again and
                // Return (Compare) act on the selected copies' groups.
                HStack(spacing: 8) {
                    if presentation.showsCompare {
                        Button("Compare") {
                            actions.compareGroup(group)
                        }
                        .focusable(false)
                        .help("See the first two side by side, at full size.")
                    }
                    if let title = presentation.keepAllTitle {
                        Button(title) {
                            actions.keepAll(group)
                        }
                        .focusable(false)
                    } else {
                        Button("Review Again") {
                            actions.reviewAgain([group])
                        }
                        .focusable(false)
                    }
                }
                .controlSize(.small)
            }
            Group {
                Text(presentation.sharedFacts ?? " ")
                    .font(.subheadline)
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
                    .monospacedDigit()
                if let decision = presentation.decision {
                    // The verdict, at L2: the one line that says what the act will do.
                    Text(decision)
                        .font(.body)
                        .foregroundStyle(DesignPalette.label(for: colorScheme))
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityHidden(true)
        }
    }
}

/// Two libraries' shared groups as one row: the fact, what the marks will do, and the
/// choice — each library keeps its own copy, or only one is kept — beside Keep Both
/// Libraries, which sets the pair aside (Review Again brings it back).
private struct DuplicateLibraryPairRow: View {
    let presentation: DuplicateLibraryPairPresentation
    let groups: [DuplicateGroup]
    let isExpanded: Bool
    let isFirst: Bool
    let actions: DuplicatesActions

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            DuplicateGroupSeam(isFirst: isFirst)
            HStack(alignment: .top, spacing: 8) {
                Button {
                    actions.togglePair(presentation.pair)
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .frame(width: 16, height: 20)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityLabel(isExpanded ? "Hide the shared items" : "Show the shared items")
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title)
                        .font(.headline)
                        .foregroundStyle(DesignPalette.label(for: colorScheme))
                        .monospacedDigit()
                        .lineLimit(1)
                    Text(presentation.state)
                        .font(.body)
                        .foregroundStyle(DesignPalette.label(for: colorScheme))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    if presentation.isKept {
                        Button("Review Again") {
                            actions.reviewAgain(groups)
                        }
                        .focusable(false)
                    } else {
                        // The marks: one pick can mark thousands of copies, so each item
                        // names the library it keeps and the state line says what moves.
                        Menu("Keep Only…") {
                            Button("Keep Only \(presentation.firstName)") {
                                actions.keepOnlyLibrary(presentation.pair.first, presentation.pair)
                            }
                            Button("Keep Only \(presentation.secondName)") {
                                actions.keepOnlyLibrary(presentation.pair.second, presentation.pair)
                            }
                            Divider()
                            Button("Keep One Copy in Each Library") {
                                actions.keepEachLibrary(presentation.pair)
                            }
                        }
                        .menuStyle(.button)
                        .fixedSize()
                        .focusable(false)
                        Button("Keep Both Libraries") {
                            actions.keepBothLibraries(presentation.pair)
                        }
                        .focusable(false)
                        .help("Sets aside everything these libraries share. Nothing moves.")
                    }
                }
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        }
        .padding(.top, isFirst ? 0 : 8)
    }
}

/// One copy: its picture, bright when it stays and dimmed when it moves; what differs
/// about it; and its Keep mark — one size for every tile, so a group reads as one row.
private struct DuplicateCopyTile: View {
    /// Wide enough for a camera's whole file name (`20261030_185200_001.arw`) in `.body`.
    static let width: CGFloat = 184
    static let faceHeight: CGFloat = 138
    /// DES-060's 8 pt gutter between tiles.
    static let gutter: CGFloat = 8
    /// The checkbox and `Keep This Copy` share one slot height, so a waiting group's tiles
    /// are as tall as the rest (DES-053).
    private static let markHeight: CGFloat = 22

    let tile: DuplicateCopyTilePresentation
    let isSelected: Bool
    let tileContentStore: TileContentStore?
    let thumbnailDirectory: URL?
    let detailReader: MediaTileDetailReader?
    let actions: DuplicatesActions
    let select: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DuplicateThumbnail(
                id: tile.id,
                kind: tile.kind,
                width: Self.width,
                height: Self.faceHeight,
                isDimmed: tile.fate == .movesToTrash,
                isSelected: isSelected,
                tileContentStore: tileContentStore,
                thumbnailDirectory: thumbnailDirectory,
                detailReader: detailReader
            )
            .padding(.bottom, 2)
            Text(tile.primary)
                .font(.body)
                .foregroundStyle(DesignPalette.label(for: colorScheme))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(tile.secondary ?? " ")
                .font(.subheadline)
                .foregroundStyle(DesignPalette.l3(for: colorScheme))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
            mark
                .frame(height: Self.markHeight, alignment: .leading)
        }
        .frame(width: Self.width, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        // The first click selects at once; the second also opens the group (HIG Lists).
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            actions.openGroupContaining(tile.id)
        })
        .help(([tile.primary] + (tile.secondary.map { [$0] } ?? [])).joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            Button("Keep This Copy") { actions.keep(tile.id) }
                .disabled(tile.fate == .stays)
            Button("Don't Keep This Copy") { actions.unkeep(tile.id) }
                .disabled(tile.fate == .movesToTrash || (tile.fate == .stays && !tile.canUnkeep))
            Button("Keep Only This Copy") { actions.keepOnly(tile.id) }
            Divider()
            Button("Move to Trash Now") { actions.moveToTrashNow(tile.id) }
        }
        .accessibilityAction(named: "Keep This Copy") { actions.keep(tile.id) }
        .accessibilityAction(named: "Keep Only This Copy") { actions.keepOnly(tile.id) }
        .accessibilityAction(named: "Don't Keep This Copy") { actions.unkeep(tile.id) }
    }

    /// The mark: a checkbox titled `Keep` — the setting, which never changes with its state
    /// (HIG Toggles) — whose consequence is the face, bright or dimmed. Not a Tab stop:
    /// tiles are the selection, and Photo ▸ Keep This Copy / Don't Keep This Copy act on
    /// them. A waiting group's tile offers the act that decides it.
    @ViewBuilder
    private var mark: some View {
        switch tile.fate {
        case .stays, .movesToTrash:
            Toggle("Keep", isOn: Binding(
                get: { tile.fate == .stays },
                set: { keep in keep ? actions.keep(tile.id) : actions.unkeep(tile.id) }
            ))
            .toggleStyle(.checkbox)
            .focusable(false)
            .disabled(tile.fate == .stays && !tile.canUnkeep)
            .modifier(DuplicateKeepHelp(shown: tile.fate == .stays && !tile.canUnkeep))
        case .choice:
            Button("Keep This Copy") {
                actions.keepOnly(tile.id)
            }
            .controlSize(.small)
            .focusable(false)
        }
    }
}

/// The tooltip of the one box that cannot be unchecked: the last kept copy of a group of
/// three or more.
private struct DuplicateKeepHelp: ViewModifier {
    let shown: Bool

    func body(content: Content) -> some View {
        if shown {
            content.help("A group always keeps one copy.")
        } else {
            content
        }
    }
}

/// A tile's face: the thumbnail aspect-fit and centred in its cell (DES-060A), following
/// the grid's no-blank rule — the kind glyph (DES-063) only before this copy's thumbnail
/// has ever decoded, and its slash variant once a decode has failed. A copy that moves is
/// drawn dimmed, the Lightroom idiom for a rejected photo; selection is DES-061's 3 pt
/// accent border on the picture, never a fill.
private struct DuplicateThumbnail: View {
    let id: MediaAssetID
    let kind: MediaKind?
    let width: CGFloat
    let height: CGFloat
    let isDimmed: Bool
    let isSelected: Bool
    let tileContentStore: TileContentStore?
    let thumbnailDirectory: URL?
    let detailReader: MediaTileDetailReader?
    @State private var image: CGImage?
    @State private var unavailable = false
    @Environment(\.colorScheme) private var colorScheme

    /// The picture's drawn size, aspect-fit in the well.
    private func fittedSize(of image: CGImage) -> CGSize {
        let scale = min(width / CGFloat(max(image.width, 1)), height / CGFloat(max(image.height, 1)))
        return CGSize(
            width: (CGFloat(image.width) * scale).rounded(),
            height: (CGFloat(image.height) * scale).rounded()
        )
    }

    var body: some View {
        ZStack {
            if let image {
                let fitted = fittedSize(of: image)
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: fitted.width, height: fitted.height)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .opacity(isDimmed ? 0.4 : 1)
                    .overlay {
                        // A hairline edge (DES-023) so a dark picture reads on the dark
                        // backdrop; the selection border replaces it.
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(
                                isSelected ? Color.accentColor : DesignPalette.hairline(for: colorScheme),
                                lineWidth: isSelected ? 3 : 1
                            )
                    }
            } else {
                Image(systemName: MediaAssetTilePresentation.placeholderIconSystemName(
                    for: kind, thumbnailUnavailable: unavailable
                ))
                .font(.title2)
                .foregroundStyle(.tertiary)
                .frame(width: width, height: height)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
            }
        }
        .frame(width: width, height: height)
        .task(id: id) {
            await load()
        }
    }

    private func load() async {
        if let cached = tileContentStore?.image(for: id) {
            image = cached
            return
        }
        guard let detailReader else { return }
        let detail: MediaTileDetail?
        do {
            detail = try await detailReader.detail(for: id)
        } catch {
            OtosLog.ui.errorOperation("duplicates.thumbnail", phase: "detailFailed", fields: [
                "path": id.relativePath.rawValue, "error": String(describing: error),
            ])
            return
        }
        guard let detail, detail.thumbnailPath != nil else {
            // No thumbnail stored yet: the kind glyph stays until one is.
            return
        }
        guard !Task.isCancelled,
              let decoded = await DuplicateThumbnailDecode.decode(
                  detail: detail, thumbnailDirectory: thumbnailDirectory
              )
        else {
            if !Task.isCancelled {
                unavailable = true
            }
            return
        }
        guard !Task.isCancelled else { return }
        tileContentStore?.warm(id: id, image: decoded, detail: detail)
        image = decoded
    }
}

private nonisolated enum DuplicateThumbnailDecode {
    @concurrent
    static func decode(detail: MediaTileDetail, thumbnailDirectory: URL?) async -> CGImage? {
        MediaAssetTilePresentation.decodedThumbnailImage(detail: detail, thumbnailDirectory: thumbnailDirectory)
    }
}

/// The duplicates bar (DES-018): *what* (L1 over one L3 clause) · *the middle zone* (the
/// last act's receipt with Undo, the groups that wait with Show, or the legend) · *the
/// act*. The act is a plain bordered button with no Return equivalent — Return opens the
/// selected group, and a bulk move must not be one keystroke from a list (DES-052's
/// recorded deviation).
struct DuplicatesStatusBar: View {
    let presentation: DuplicatesBarPresentation
    let actions: DuplicatesActions

    @Environment(\.colorScheme) private var colorScheme

    private static let contentHeight: CGFloat = 40

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.primaryLine)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(DesignPalette.label(for: colorScheme))
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(presentation.secondaryLine ?? " ")
                    .font(.subheadline)
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            // The middle zone, behind a hairline (DES-018), as the import bar's.
            HStack(spacing: 20) {
                Rectangle()
                    .fill(DesignPalette.hairline(for: colorScheme))
                    .frame(width: 1, height: Self.contentHeight)
                middle
            }
            Spacer(minLength: 0)
            Button(presentation.actionTitle, action: actions.moveMarked)
                .disabled(!presentation.actionEnabled)
                .help(presentation.actionEnabled
                    ? "Moves the extra copies to the Trash. Edit ▸ Undo, or the Trash, puts them back."
                    : "Uncheck Keep on a copy, or choose a copy to keep in a group that waits.")
        }
        .frame(minHeight: Self.contentHeight, maxHeight: Self.contentHeight)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(DesignPalette.bar(for: colorScheme))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var middle: some View {
        switch presentation.middle {
        case let .receipt(line, detail, canUndo):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(DesignPalette.label(for: colorScheme))
                        .monospacedDigit()
                    if canUndo {
                        Button("Undo", action: actions.undoMove)
                            .buttonStyle(.link)
                            .font(.subheadline)
                    }
                }
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
            }
        case let .choices(text):
            HStack(spacing: 7) {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
                    .monospacedDigit()
                Button("Show", action: actions.revealNeedingChoice)
                    .buttonStyle(.link)
                    .font(.subheadline)
            }
        case let .legend(text):
            Text(text)
                .font(.subheadline)
                .foregroundStyle(DesignPalette.l3(for: colorScheme))
                .lineLimit(2)
        }
    }
}

private extension DuplicatesTileOrder.Direction {
    init?(_ key: KeyEquivalent) {
        switch key {
        case .leftArrow: self = .left
        case .rightArrow: self = .right
        case .upArrow: self = .up
        case .downArrow: self = .down
        default: return nil
        }
    }
}
