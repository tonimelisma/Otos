import AppKit
import SwiftUI

// The detail pane for the `.duplicates` scope (ADR 0042, `docs/design/duplicates.md`): a
// rule row for each folder that holds duplicates, so a whole folder is decided at once;
// then each group as its date and why it keeps what it keeps, over its copies' photos side
// by side, each tagged Keep or Trash — a click on a photo keeps that one; then a
// fixed-height bar stating what will move and offering the one act. Passive: every string
// comes from `DuplicatesPresentation`, and every control calls a view-model intent; the
// picks, rules and counts are `DuplicatesSession`'s.

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

    /// Whether names carry their library: only when the groups span more than one.
    private var withLibrary: Bool {
        Set(duplicates.groups.flatMap(\.copies).map(\.id.libraryRootPath)).count > 1
    }

    /// The copies on screen in reading order, by group: what the arrow keys walk. A kept
    /// group shows no photos, so it has none.
    private var tileOrder: DuplicatesTileOrder {
        DuplicatesTileOrder(groups: duplicates.groups.filter { !$0.isKept }.map { $0.copies.map(\.id) })
    }

    private var list: some View {
        let tally = session.tally(in: duplicates)
        let rules = DuplicateFolderSetSummary.summaries(of: duplicates).map {
            DuplicateFolderRulePresentation.map($0, rule: session.rules[$0.folderSet], noun: tally.noun, withLibrary: withLibrary)
        }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !rules.isEmpty {
                        DuplicateFolderRules(rules: rules, actions: actions)
                            .padding(.bottom, 20)
                    }
                    ForEach(Array(duplicates.groups.enumerated()), id: \.element.id) { index, group in
                        groupSection(group, isFirst: index == 0)
                    }
                }
                // DES-060's section inset: one left edge for every row, header and photo.
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .background(DesignPalette.content(for: colorScheme))
            .focusable()
            .focused($listFocused)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                guard let direction = DuplicatesTileOrder.Direction(press.key),
                      let target = tileOrder.target(from: cursor, direction)
                else {
                    return .ignored
                }
                cursor = target
                actions.select(target, press.modifiers.contains(.shift) ? .shift : [], tileOrder.copies)
                proxy.scrollTo(target)
                return .handled
            }
            // Space keeps the photo under the cursor, as a click does.
            .onKeyPress(.space) {
                guard let cursor else { return .ignored }
                actions.keep(cursor)
                return .handled
            }
            .onKeyPress(.return) {
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

    @ViewBuilder
    private func groupSection(_ group: DuplicateGroup, isFirst: Bool) -> some View {
        let presentation = DuplicateGroupPresentation.map(group, session: session, withLibrary: withLibrary)
        VStack(alignment: .leading, spacing: 8) {
            DuplicateGroupSeam(isFirst: isFirst)
            DuplicateGroupHeader(group: group, presentation: presentation, actions: actions)
            if !presentation.tiles.isEmpty {
                LazyVGrid(
                    columns: [GridItem(
                        .adaptive(minimum: DuplicateCopyTile.edge, maximum: DuplicateCopyTile.edge),
                        spacing: DuplicateCopyTile.gutter,
                        alignment: .topLeading
                    )],
                    alignment: .leading,
                    spacing: DuplicateCopyTile.gutter
                ) {
                    ForEach(presentation.tiles) { tile in
                        DuplicateCopyTile(
                            tile: tile,
                            group: group,
                            isSelected: selection.contains(tile.id),
                            tileContentStore: tileContentStore,
                            thumbnailDirectory: thumbnailDirectory,
                            detailReader: detailReader,
                            actions: actions,
                            keep: {
                                listFocused = true
                                cursor = tile.id
                                actions.select(tile.id, [], tileOrder.copies)
                                actions.keep(tile.id)
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
    /// An arrow key or click on a photo, with its modifiers and the list's copies in order —
    /// the grid's click intent, so one selection model serves both (APP-011).
    let select: @MainActor (MediaAssetID?, NSEvent.ModifierFlags, [MediaAssetID]) -> Void
    /// A click on a photo, or Space: this copy stays and the rest of its group goes.
    let keep: @MainActor (MediaAssetID) -> Void
    /// A folder rule row's choice.
    let setRule: @MainActor (DuplicateFolderRule, DuplicateFolderSet) -> Void
    let keepAll: @MainActor (DuplicateGroup) -> Void
    let reviewAgain: @MainActor ([DuplicateGroup]) -> Void
    let openGroup: @MainActor () -> Void
    let openGroupContaining: @MainActor (MediaAssetID) -> Void
    let moveToTrashNow: @MainActor (MediaAssetID) -> Void
    /// The bar's act: every group's extra copies to the Trash.
    let moveAll: @MainActor () -> Void
    let undoMove: @MainActor () -> Void
    let revealNeedingChoice: @MainActor () -> Void
}

/// The folders that hold duplicates, each with its rule as a segmented choice: one click
/// decides every group in that folder, or in that pair of folders.
private struct DuplicateFolderRules: View {
    let rules: [DuplicateFolderRulePresentation]
    let actions: DuplicatesActions

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Folders with duplicates")
                .font(.subheadline)
                .foregroundStyle(DesignPalette.l3(for: colorScheme))
                .padding(.bottom, 4)
            ForEach(rules) { rule in
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: rule.folderSet.folders.count == 2 ? "folder.badge.questionmark" : "folder")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rule.title)
                            .font(.body)
                            .foregroundStyle(DesignPalette.label(for: colorScheme))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(rule.detail)
                            .font(.subheadline)
                            .foregroundStyle(DesignPalette.l3(for: colorScheme))
                            .monospacedDigit()
                    }
                    Spacer(minLength: 12)
                    Text(rule.prompt)
                        .font(.subheadline)
                        .foregroundStyle(DesignPalette.l3(for: colorScheme))
                    Picker(rule.prompt, selection: Binding(
                        get: { rule.selected },
                        set: { actions.setRule($0, rule.folderSet) }
                    )) {
                        ForEach(rule.options, id: \.rule) { option in
                            Text(option.title).tag(option.rule)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(DesignPalette.hairline(for: colorScheme))
                        .frame(height: 1)
                }
            }
        }
    }
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

/// A group's header: its date, then why it keeps what it keeps — the click, the folder's
/// rule, or the keeper rule — or what to choose. Kept, `Kept both copies` with Review Again.
private struct DuplicateGroupHeader: View {
    let group: DuplicateGroup
    let presentation: DuplicateGroupPresentation
    let actions: DuplicatesActions

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(presentation.title)
                .font(.headline)
                .foregroundStyle(DesignPalette.label(for: colorScheme))
            Text(presentation.reason)
                .font(.subheadline)
                .foregroundStyle(DesignPalette.l3(for: colorScheme))
                .lineLimit(1)
                .truncationMode(.middle)
            if presentation.isKept {
                Button("Review Again") {
                    actions.reviewAgain([group])
                }
                .buttonStyle(.link)
                .focusable(false)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One copy's photo: a square cell with its picture, tagged Keep (and bright) or Trash (and
/// dimmed), its size and its Like or Dislike over the bottom of the picture. A click keeps
/// it; where it is and what else differs is its tooltip.
private struct DuplicateCopyTile: View {
    static let edge: CGFloat = 180
    /// DES-060's 8 pt gutter between tiles.
    static let gutter: CGFloat = 8

    let tile: DuplicateCopyTilePresentation
    let group: DuplicateGroup
    let isSelected: Bool
    let tileContentStore: TileContentStore?
    let thumbnailDirectory: URL?
    let detailReader: MediaTileDetailReader?
    let actions: DuplicatesActions
    let keep: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DuplicateThumbnail(
                id: tile.id,
                kind: tile.kind,
                edge: Self.edge,
                fate: tile.fate,
                size: tile.size,
                choice: tile.choice,
                isSelected: isSelected,
                tileContentStore: tileContentStore,
                thumbnailDirectory: thumbnailDirectory,
                detailReader: detailReader
            )
            // Which folder this copy is in, when the group spans folders: what a folder
            // rule chooses between, so the photos say it without a hover.
            if let folder = tile.folder {
                Label(folder, systemImage: "folder")
                    .font(.subheadline)
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: Self.edge, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: keep)
        // The first click keeps it at once; the second also opens the group (HIG Lists).
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            actions.openGroupContaining(tile.id)
        })
        .help(tile.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { keep() }
        .contextMenu {
            Button("Keep This Copy", action: keep)
                .disabled(!tile.canKeep)
            Button("Keep All Copies") { actions.keepAll(group) }
            Divider()
            Button("Move to Trash Now") { actions.moveToTrashNow(tile.id) }
                .disabled(!tile.canMoveToTrash)
        }
    }
}

/// A photo's face: the thumbnail aspect-fit and centred in its square cell (DES-060A),
/// following the grid's no-blank rule — the kind glyph (DES-063) only before this copy's
/// thumbnail has ever decoded, and its slash variant once a decode has failed. Its fate is
/// a tag at the top left — `Keep` with a checkmark on the accent, `Trash` with a trash can
/// on black — and a copy that goes is drawn at 40 % opacity, so a group's keeper reads at a
/// glance and in grayscale (DES-029). The size sits at the bottom centre and the Like or
/// Dislike at the bottom left, white over a shadow; tags and badges appear only once the
/// picture has painted (DES-062). Selection is DES-061's 3 pt accent border, never a fill.
private struct DuplicateThumbnail: View {
    let id: MediaAssetID
    let kind: MediaKind?
    let edge: CGFloat
    let fate: DuplicateCopyFate
    let size: String?
    let choice: MediaChoice
    let isSelected: Bool
    let tileContentStore: TileContentStore?
    let thumbnailDirectory: URL?
    let detailReader: MediaTileDetailReader?
    @State private var image: CGImage?
    @State private var unavailable = false
    @Environment(\.colorScheme) private var colorScheme

    /// The picture's drawn size, aspect-fit in the cell.
    private func fittedSize(of image: CGImage) -> CGSize {
        let scale = min(edge / CGFloat(max(image.width, 1)), edge / CGFloat(max(image.height, 1)))
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
                    .opacity(fate == .trash ? 0.4 : 1)
                    .overlay(alignment: .bottom) {
                        badges
                    }
                    .overlay(alignment: .topLeading) {
                        fateTag
                            .padding(6)
                    }
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
                .frame(width: edge, height: edge)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
            }
        }
        .frame(width: edge, height: edge)
        .task(id: id) {
            await load()
        }
    }

    /// The size centred along the bottom and the choice at the bottom left, as Photos
    /// draws its size and Favorite heart.
    private var badges: some View {
        ZStack(alignment: .bottomLeading) {
            if let size {
                Text(size)
                    .font(.callout)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
            }
            if let symbol = choiceSymbol {
                Image(systemName: symbol)
                    .font(.callout)
                    .padding(.leading, 6)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 2)
        .padding(.bottom, 5)
        .accessibilityHidden(true)
    }

    /// `Keep` or `Trash`, a word and a glyph on a capsule; nothing while the group waits.
    @ViewBuilder
    private var fateTag: some View {
        switch fate {
        case .keep:
            Label("Keep", systemImage: "checkmark")
                .font(.callout)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .foregroundStyle(.white)
                .background(Capsule().fill(Color.accentColor))
                .accessibilityHidden(true)
        case .trash:
            Label("Trash", systemImage: "trash")
                .font(.callout)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .foregroundStyle(.white)
                .background(Capsule().fill(.black.opacity(0.55)))
                .accessibilityHidden(true)
        case .undecided:
            EmptyView()
        }
    }

    private var choiceSymbol: String? {
        switch choice {
        case .liked: MediaChoiceToggle.like.symbol(isOn: true)
        case .disliked: MediaChoiceToggle.dislike.symbol(isOn: true)
        case .notRated: nil
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
            Button(presentation.actionTitle, action: actions.moveAll)
                .disabled(!presentation.actionEnabled)
                .help(presentation.actionEnabled
                    ? "Moves every copy tagged Trash to the Trash. Edit ▸ Undo puts them back."
                    : "Every group keeps all its copies, or waits for you to choose one.")
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
