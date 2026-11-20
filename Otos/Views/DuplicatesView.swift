import AppKit
import SwiftUI

// The detail pane for the `.duplicates` scope (ADR 0042, `docs/design/duplicates.md`): the
// groups in three sections, by the attention each needs. Groups only a click decides and
// files of one photo are a date and why over their copies' photos side by side, each tagged
// Keep or Trash. Exact copies sit under a header for each folder that holds them, which
// carries that folder's rule and opens to its groups, each one picture beside its copies'
// names. A click on a photo or a name keeps that copy. Under the list, a fixed-height bar
// states what will move and offers the one act. Passive: every string comes from
// `DuplicatesPresentation`, and every control calls a view-model intent; the picks, rules
// and counts are `DuplicatesSession`'s. Which folder headers are open is local control
// state.

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
    /// The folder headers the user opened or closed, against where they start: closed, so
    /// the folders read as a list, or open when there is only one.
    @State private var toggled: Set<DuplicateFolderPlace> = []
    @FocusState private var listFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    /// Whether the window is the key one: a selected name is drawn emphasized only while
    /// the list has focus in the key window, as a macOS list draws its selected row.
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        let tally = session.tally(in: duplicates)
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
                presentation: .map(tally, receipt: session.receipt, canUndoMove: canUndoMove),
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

    private func isExpanded(_ place: DuplicateFolderPlace) -> Bool {
        (duplicates.layout.buckets.count == 1) != toggled.contains(place)
    }

    private func toggle(_ place: DuplicateFolderPlace) {
        toggled.formSymmetricDifference([place])
    }

    /// The list's rows, top to bottom: each section's header, then its groups; in Exact
    /// copies each folder's header, then its groups while it is open.
    private var rows: [DuplicatesRow] {
        let layout = duplicates.layout
        let withLibrary = withLibrary
        var rows: [DuplicatesRow] = []
        for section in DuplicatesSection.allCases {
            guard let header = DuplicatesSectionPresentation.map(section, in: layout) else {
                continue
            }
            rows.append(.section(header, isFirst: rows.isEmpty))
            switch section {
            case .choose, .different:
                rows += layout.groups(in: section).enumerated().map { DuplicatesRow.photos($1, isFirst: $0 == 0) }
            case .exact:
                for bucket in layout.buckets {
                    let open = isExpanded(bucket.id)
                    rows.append(.bucket(.map(bucket, session: session, withLibrary: withLibrary), isExpanded: open))
                    if open {
                        rows += bucket.groups.map(DuplicatesRow.names)
                    }
                }
            }
        }
        return rows
    }

    /// The copies on screen in reading order, by group: what the arrow keys walk. A kept
    /// group shows no copies, and a closed folder none of its groups.
    private static func tileOrder(of rows: [DuplicatesRow]) -> DuplicatesTileOrder {
        DuplicatesTileOrder(groups: rows.compactMap { row -> DuplicatesTileOrder.Group? in
            switch row {
            case let .photos(group, _) where !group.isKept:
                DuplicatesTileOrder.Group(copies: group.copies.map(\.id), stacked: false)
            case let .names(group) where !group.isKept:
                DuplicatesTileOrder.Group(copies: group.copies.map(\.id), stacked: true)
            default:
                nil
            }
        })
    }

    private func group(containing id: MediaAssetID) -> DuplicateGroup? {
        duplicates.groups.first { group in group.copies.contains { $0.id == id } }
    }

    private var list: some View {
        let rows = rows
        let tileOrder = Self.tileOrder(of: rows)
        let withLibrary = withLibrary
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        switch row {
                        case let .section(header, isFirst):
                            DuplicatesSectionHeader(header: header, isFirst: isFirst)
                        case let .photos(group, isFirst):
                            photosRow(group, isFirst: isFirst, order: tileOrder, withLibrary: withLibrary)
                        case let .bucket(bucket, isExpanded):
                            DuplicateFolderHeader(
                                bucket: bucket,
                                isExpanded: isExpanded,
                                tileContentStore: tileContentStore,
                                thumbnailDirectory: thumbnailDirectory,
                                detailReader: detailReader,
                                actions: actions
                            ) {
                                toggle(bucket.id)
                            }
                        case let .names(group):
                            namesRow(group, order: tileOrder, withLibrary: withLibrary)
                        }
                    }
                }
                // DES-060's section inset: one left edge for every header, row and photo.
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .background(DesignPalette.content(for: colorScheme))
            .focusable()
            // The arrows move the selection, which shows where the keys are: no ring around the
            // whole gallery (HIG, Focus and selection; DES-081).
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                guard let direction = DuplicatesTileOrder.Direction(press.key),
                      let target = tileOrder.target(from: cursor, direction)
                else {
                    return .ignored
                }
                cursor = target
                actions.select(target, press.modifiers.contains(.shift) ? .shift : [], tileOrder.copies)
                if let group = group(containing: target) {
                    proxy.scrollTo(DuplicatesRow.ID.group(group.id))
                }
                return .handled
            }
            // Space keeps the copy under the cursor, as a click does.
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
                // becomes where the arrow keys start; a closed folder holding it opens.
                if let cursor, selected.contains(cursor) {
                    return
                }
                guard let group = duplicates.groups.first(where: { group in
                    !group.isKept && group.copies.contains { selected.contains($0.id) }
                }) else {
                    return
                }
                cursor = group.copies.first { selected.contains($0.id) }?.id
                let place = DuplicateFolderPlace(group)
                if group.section == .exact, !isExpanded(place) {
                    // The group's row exists only once its folder is open: bring the
                    // folder's header into view, with the group under it.
                    toggle(place)
                    proxy.scrollTo(DuplicatesRow.ID.bucket(place), anchor: .top)
                } else {
                    proxy.scrollTo(DuplicatesRow.ID.group(group.id))
                }
            }
        }
    }

    /// A click on a copy, as a photo or as a name: it is selected and kept.
    private func keep(_ id: MediaAssetID, order: DuplicatesTileOrder) {
        listFocused = true
        cursor = id
        actions.select(id, [], order.copies)
        actions.keep(id)
    }

    @ViewBuilder
    private func photosRow(_ group: DuplicateGroup, isFirst: Bool, order: DuplicatesTileOrder, withLibrary: Bool) -> some View {
        let presentation = DuplicateGroupPresentation.map(group, session: session, withLibrary: withLibrary)
        VStack(alignment: .leading, spacing: 8) {
            DuplicateGroupSeam(isFirst: isFirst)
            DuplicateGroupHeader(group: group, presentation: presentation, actions: actions)
            if !presentation.tiles.isEmpty {
                // The group's cells take its own aspect, so a picture fills its cell.
                LazyVGrid(
                    columns: [GridItem(
                        .adaptive(minimum: presentation.cell.width, maximum: presentation.cell.width),
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
                            cell: presentation.cell,
                            isSelected: selection.contains(tile.id),
                            tileContentStore: tileContentStore,
                            thumbnailDirectory: thumbnailDirectory,
                            detailReader: detailReader,
                            actions: actions,
                            keep: { keep(tile.id, order: order) }
                        )
                    }
                }
            }
        }
        .padding(.bottom, 16)
    }

    /// An exact-copy group: one picture, since its copies are one picture, beside a line per
    /// copy, the first carrying the group's date, the size the copies share and why it keeps
    /// what it keeps at its trailing edge. Kept, its date and `Kept both copies`.
    @ViewBuilder
    private func namesRow(_ group: DuplicateGroup, order: DuplicatesTileOrder, withLibrary: Bool) -> some View {
        let presentation = DuplicateGroupPresentation.map(group, session: session, style: .names, withLibrary: withLibrary)
        HStack(alignment: .top, spacing: 8) {
            if let picture = presentation.picture {
                DuplicateThumbnail(
                    id: picture,
                    kind: presentation.pictureKind,
                    face: .cropped(DuplicateCopyLine.pictureEdge),
                    tileContentStore: tileContentStore,
                    thumbnailDirectory: thumbnailDirectory,
                    detailReader: detailReader
                )
                .onTapGesture(count: 2) {
                    actions.openGroupContaining(picture)
                }
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 0) {
                if presentation.isKept {
                    DuplicateGroupHeader(group: group, presentation: presentation, actions: actions)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                }
                ForEach(Array(presentation.tiles.enumerated()), id: \.element.id) { index, tile in
                    DuplicateCopyLine(
                        tile: tile,
                        group: group,
                        trailing: index == 0 ? presentation.dateAndReason : nil,
                        isSelected: selection.contains(tile.id),
                        isEmphasized: listFocused && appearsActive,
                        actions: actions,
                        keep: { keep(tile.id, order: order) }
                    )
                }
            }
            // VoiceOver reads the group's facts before its names (DES-082).
            .accessibilityElement(children: .contain)
        }
        .padding(.vertical, 4)
        // Under its folder's header, past the header's disclosure mark.
        .padding(.leading, DuplicateFolderHeader.indent)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignPalette.hairline(for: colorScheme))
                .frame(height: 1)
                .padding(.leading, DuplicateFolderHeader.indent)
        }
    }
}

/// One row of the list. Rows are the lazy stack's own children, so the list can scroll to
/// one that has not been drawn yet.
private enum DuplicatesRow: Identifiable {
    enum ID: Hashable {
        case section(DuplicatesSection)
        case group(DuplicateGroupID)
        case bucket(DuplicateFolderPlace)
    }

    case section(DuplicatesSectionPresentation, isFirst: Bool)
    case photos(DuplicateGroup, isFirst: Bool)
    case bucket(DuplicateFolderBucketPresentation, isExpanded: Bool)
    case names(DuplicateGroup)

    var id: ID {
        switch self {
        case let .section(header, _): .section(header.id)
        case let .photos(group, _), let .names(group): .group(group.id)
        case let .bucket(bucket, _): .bucket(bucket.id)
        }
    }
}

/// The view model's duplicates intents, handed to the passive views.
struct DuplicatesActions {
    /// An arrow key or click on a photo, with its modifiers and the list's copies in order —
    /// the grid's click intent, so one selection model serves both (APP-011).
    let select: @MainActor (MediaAssetID?, NSEvent.ModifierFlags, [MediaAssetID]) -> Void
    /// A click on a photo, or Space: this copy stays and the rest of its group goes.
    let keep: @MainActor (MediaAssetID) -> Void
    /// A folder header's rule.
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

/// A section's header (DES-011: a group header inside content): its title with how many
/// it holds, over what its groups are; a hairline and space above every one but the first.
private struct DuplicatesSectionHeader: View {
    let header: DuplicatesSectionPresentation
    let isFirst: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !isFirst {
                Rectangle()
                    .fill(DesignPalette.hairline(for: colorScheme))
                    .frame(height: 1)
                    .padding(.top, 8)
                    .padding(.bottom, 14)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(header.title)
                    .font(.headline)
                    .foregroundStyle(DesignPalette.label(for: colorScheme))
                Text(header.count)
                    .font(.subheadline)
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
                    .monospacedDigit()
            }
            Text(header.detail)
                .font(.subheadline)
                .foregroundStyle(DesignPalette.l3(for: colorScheme))
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A folder's header in Exact copies: a disclosure mark, the folder (or two), how many and
/// how much, why its groups keep what they keep, closed a few of its pictures, and the
/// folder's rule as a small pop-up beside its prompt (DES-054) — one choice decides every
/// group under it.
private struct DuplicateFolderHeader: View {
    /// The disclosure mark's column: a folder's groups start past it.
    static let indent: CGFloat = 22
    /// A closed header's pictures.
    static let previewEdge: CGFloat = 28

    let bucket: DuplicateFolderBucketPresentation
    let isExpanded: Bool
    let tileContentStore: TileContentStore?
    let thumbnailDirectory: URL?
    let detailReader: MediaTileDetailReader?
    let actions: DuplicatesActions
    let toggle: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: toggle) {
                HStack(alignment: .center, spacing: 0) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: Self.indent, alignment: .leading)
                    Image(systemName: bucket.isTwoFolders ? "folder.badge.questionmark" : "folder")
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(bucket.title)
                            .font(.body)
                            .foregroundStyle(DesignPalette.label(for: colorScheme))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(bucket.detail)
                            .font(.subheadline)
                            .foregroundStyle(DesignPalette.l3(for: colorScheme))
                            .monospacedDigit()
                            .lineLimit(1)
                        if let summary = bucket.summary {
                            Text(summary)
                                .font(.subheadline)
                                .foregroundStyle(DesignPalette.l3(for: colorScheme))
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    // Closed, a glance at what is inside; open, the groups themselves show it.
                    if !isExpanded, !bucket.previews.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(bucket.previews) { preview in
                                DuplicateThumbnail(
                                    id: preview.id,
                                    kind: preview.kind,
                                    face: .cropped(Self.previewEdge),
                                    tileContentStore: tileContentStore,
                                    thumbnailDirectory: thumbnailDirectory,
                                    detailReader: detailReader
                                )
                            }
                        }
                        .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel([bucket.title, bucket.detail, bucket.summary].compactMap(\.self).joined(separator: ", "))
            .accessibilityValue(isExpanded ? "expanded" : "collapsed")
            if let rule = bucket.rule {
                // DES-017: the label left of its control, 7 pt apart.
                HStack(spacing: 7) {
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
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignPalette.hairline(for: colorScheme))
                .frame(height: 1)
        }
    }
}

/// A hairline between groups of photos (DES-023): drawn above every one but its section's
/// first.
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

/// A group's header: its date, then what its copies share and why it keeps what it keeps —
/// the click, the folder's rule, or the keeper rule — or what to choose. Kept, `Kept both
/// copies` with Review Again.
private struct DuplicateGroupHeader: View {
    let group: DuplicateGroup
    let presentation: DuplicateGroupPresentation
    let actions: DuplicatesActions

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(presentation.title)
                .font(.body)
                .foregroundStyle(DesignPalette.label(for: colorScheme))
            Text(presentation.reason)
                .font(.subheadline)
                .foregroundStyle(DesignPalette.l3(for: colorScheme))
                .monospacedDigit()
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

/// What a copy offers under the pointer, as a photo or as a name: the pointing hand and a
/// highlight while the pointer is over it, so a click's effect is seen without a sentence; a
/// click keeps it, a double-click opens its group, and its context menu carries the per-copy
/// commands.
private struct DuplicateCopyPointer: ViewModifier {
    let tile: DuplicateCopyTilePresentation
    let group: DuplicateGroup
    @Binding var isHovered: Bool
    let actions: DuplicatesActions
    let keep: () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .pointerStyle(.link)
            .onTapGesture(perform: keep)
            // The first click keeps it at once; the second also opens the group (HIG Lists).
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                actions.openGroupContaining(tile.id)
            })
            .help(tile.help)
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

/// A copy as VoiceOver reads it: one button naming the file, its fate and its facts
/// (DES-082), whose action keeps it.
private struct DuplicateCopyAccessibility: ViewModifier {
    let tile: DuplicateCopyTilePresentation
    let isSelected: Bool
    let keep: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tile.accessibilityLabel)
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            .accessibilityAction { keep() }
    }
}

/// `Keep` or `Trash` on a photo, a word and a glyph on a capsule (DES-029); nothing while
/// the group waits. Trash's dark capsule carries a hairline edge so it reads on a dimmed
/// picture over the dark backdrop.
private struct DuplicateFateTag: View {
    let fate: DuplicateCopyFate

    var body: some View {
        switch fate {
        case .keep:
            Label("Keep", systemImage: "checkmark")
                .font(.callout)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .foregroundStyle(DesignPalette.badgeLabel)
                .background(Capsule().fill(Color.accentColor))
                .accessibilityHidden(true)
        case .trash:
            Label("Trash", systemImage: "trash")
                .font(.callout)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .foregroundStyle(DesignPalette.badgeLabel)
                .background(Capsule().fill(DesignPalette.badge))
                .overlay(Capsule().strokeBorder(DesignPalette.badgeEdge, lineWidth: 1))
                .accessibilityHidden(true)
        case .undecided:
            EmptyView()
        }
    }
}

/// One exact copy as a line, drawn as a macOS list row: a glyph column — the accent
/// checkmark for the copy kept, a secondary trash can for one that goes, blank while the
/// group waits — then what tells it from the group's other copies (its name, or its folder)
/// and the work it holds; on the group's first line, the group's date and why at the
/// trailing edge. The names of a group sit at one left edge, so they compare down a column.
/// A click keeps it; selected, the line takes the system's selected-row highlight.
private struct DuplicateCopyLine: View {
    /// The group's one picture.
    static let pictureEdge: CGFloat = 40
    /// The fate glyphs' column, so every name starts at one edge.
    private static let glyphWidth: CGFloat = 20

    let tile: DuplicateCopyTilePresentation
    let group: DuplicateGroup
    let trailing: String?
    let isSelected: Bool
    /// Whether the selection is drawn in the accent, as the key list's selected row is,
    /// or in the unemphasized gray of a list without focus.
    let isEmphasized: Bool
    let actions: DuplicatesActions
    let keep: () -> Void

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    /// On the accent, every glyph and word turns to the selected text colour, as a macOS
    /// list row's do.
    private var onAccent: Bool {
        isSelected && isEmphasized
    }

    private var nameColor: Color {
        if onAccent {
            return Color(nsColor: .alternateSelectedControlTextColor)
        }
        return tile.fate == .trash ? DesignPalette.l3(for: colorScheme) : DesignPalette.label(for: colorScheme)
    }

    private var detailColor: Color {
        onAccent ? Color(nsColor: .alternateSelectedControlTextColor) : DesignPalette.l3(for: colorScheme)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                glyph
                    .frame(width: Self.glyphWidth, alignment: .center)
                Text(tile.label)
                    .font(.body)
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let caption = tile.caption {
                    Text(caption)
                        .font(.subheadline)
                        .foregroundStyle(detailColor)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            .modifier(DuplicateCopyAccessibility(tile: tile, isSelected: isSelected, keep: keep))
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.subheadline)
                    .foregroundStyle(detailColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilitySortPriority(1)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: isEmphasized
                            ? .selectedContentBackgroundColor
                            : .unemphasizedSelectedContentBackgroundColor))
            } else if isHovered {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.fill.tertiary)
            }
        }
        .modifier(DuplicateCopyPointer(tile: tile, group: group, isHovered: $isHovered, actions: actions, keep: keep))
    }

    @ViewBuilder
    private var glyph: some View {
        switch tile.fate {
        case .keep:
            Image(systemName: "checkmark")
                .font(.callout.weight(.semibold))
                .foregroundStyle(onAccent ? Color(nsColor: .alternateSelectedControlTextColor) : Color.accentColor)
        case .trash:
            Image(systemName: "trash")
                .font(.callout)
                .foregroundStyle(detailColor)
        case .undecided:
            Color.clear
                .frame(height: 1)
        }
    }
}

/// One copy's photo: a cell of its group's aspect with its picture, tagged Keep (and
/// bright) or Trash (and dimmed), its size and its Like or Dislike on badges over the bottom
/// of the picture; under it what else differs, and its folder when the group spans folders.
/// A click keeps it; where it is goes in its tooltip.
private struct DuplicateCopyTile: View {
    /// DES-060's 8 pt gutter between tiles.
    static let gutter: CGFloat = 8

    let tile: DuplicateCopyTilePresentation
    let group: DuplicateGroup
    let cell: CGSize
    let isSelected: Bool
    let tileContentStore: TileContentStore?
    let thumbnailDirectory: URL?
    let detailReader: MediaTileDetailReader?
    let actions: DuplicatesActions
    let keep: () -> Void

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DuplicateThumbnail(
                id: tile.id,
                kind: tile.kind,
                face: .photo(cell: cell, fate: tile.fate, size: tile.size, choice: tile.choice),
                isSelected: isSelected,
                isHovered: isHovered,
                tileContentStore: tileContentStore,
                thumbnailDirectory: thumbnailDirectory,
                detailReader: detailReader
            )
            // What differs besides the picture and the size, so the choice needs no hover.
            if let caption = tile.caption {
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(width: cell.width, alignment: .leading)
            }
            // Which folder this copy is in, when the group spans folders.
            if let folder = tile.folder {
                Label(folder, systemImage: "folder")
                    .font(.subheadline)
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: cell.width, alignment: .leading)
            }
        }
        .modifier(DuplicateCopyAccessibility(tile: tile, isSelected: isSelected, keep: keep))
        .modifier(DuplicateCopyPointer(tile: tile, group: group, isHovered: $isHovered, actions: actions, keep: keep))
    }
}

/// A copy's picture, following the grid's no-blank rule — the kind glyph (DES-063) only
/// before this copy's thumbnail has ever decoded, and its slash variant once a decode has
/// failed — in one of two faces:
///
/// - **A photo**: aspect-fit in a cell of its group's aspect (DES-060A), so it fills the
///   cell. Its fate is a tag at the top left — `Keep` with a checkmark on the accent, `Trash`
///   with a trash can on black — and a copy that goes is drawn at 40 % opacity, so a group's
///   keeper reads at a glance and in grayscale (DES-029). The size sits at the bottom centre
///   and the Like or Dislike at the bottom left, each on DES-062's badge; tags and badges
///   appear only once the picture has painted (DES-062). Selection is DES-061's 3 pt accent
///   border, never a fill; under the pointer, a 2 pt secondary border.
/// - **Cropped**: a small square, aspect-filled, standing for a group whose copies are one
///   picture (DES-107's recorded deviation from DES-060A, as DES-103's map stack).
private struct DuplicateThumbnail: View {
    enum Face {
        case photo(cell: CGSize, fate: DuplicateCopyFate, size: String?, choice: MediaChoice)
        case cropped(CGFloat)

        var cell: CGSize {
            switch self {
            case let .photo(cell, _, _, _): cell
            case let .cropped(edge): CGSize(width: edge, height: edge)
            }
        }
    }

    let id: MediaAssetID
    let kind: MediaKind?
    let face: Face
    var isSelected = false
    var isHovered = false
    let tileContentStore: TileContentStore?
    let thumbnailDirectory: URL?
    let detailReader: MediaTileDetailReader?
    @State private var image: DisplayImage?
    @State private var unavailable = false
    @Environment(\.colorScheme) private var colorScheme

    /// The picture's drawn size, aspect-fit in the cell.
    private func fittedSize(of image: DisplayImage, in cell: CGSize) -> CGSize {
        let scale = min(cell.width / CGFloat(max(image.width, 1)), cell.height / CGFloat(max(image.height, 1)))
        return CGSize(
            width: (CGFloat(image.width) * scale).rounded(),
            height: (CGFloat(image.height) * scale).rounded()
        )
    }

    /// The edge: the selection's accent, the pointer's secondary border, or a DES-023
    /// hairline so a dark picture reads on the dark backdrop.
    private var edge: some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(
                isSelected ? AnyShapeStyle(Color.accentColor)
                    : isHovered ? AnyShapeStyle(.secondary) : AnyShapeStyle(DesignPalette.hairline(for: colorScheme)),
                lineWidth: isSelected ? 3 : isHovered ? 2 : 1
            )
    }

    var body: some View {
        let cell = face.cell
        ZStack {
            if let image {
                switch face {
                case let .photo(_, fate, size, choice):
                    let fitted = fittedSize(of: image, in: cell)
                    Image(decorative: image.cgImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: fitted.width, height: fitted.height)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .opacity(fate == .trash ? 0.4 : 1)
                        .overlay(alignment: .bottom) {
                            DuplicateThumbnailBadges(size: size, choice: choice)
                        }
                        .overlay(alignment: .topLeading) {
                            DuplicateFateTag(fate: fate)
                                .padding(4)
                        }
                        .overlay { edge }
                case .cropped:
                    Image(decorative: image.cgImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: cell.width, height: cell.height)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay { edge }
                }
            } else {
                Image(systemName: MediaAssetTilePresentation.placeholderIconSystemName(
                    for: kind, thumbnailUnavailable: unavailable
                ))
                .font(.title2)
                .foregroundStyle(.tertiary)
                .frame(width: cell.width, height: cell.height)
                .overlay {
                    if isSelected || isHovered {
                        edge
                    }
                }
            }
        }
        .frame(width: cell.width, height: cell.height)
        .task(id: id) {
            await load()
        }
    }

    private func load() async {
        if let cached = tileContentStore?.currentImage(for: id) {
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

/// A photo's size centred along the bottom and its Like or Dislike at the bottom left, as
/// Photos places its size and Favorite heart, each on DES-062's badge well so it stays
/// legible on a dimmed light picture.
private struct DuplicateThumbnailBadges: View {
    let size: String?
    let choice: MediaChoice

    private var choiceSymbol: String? {
        switch choice {
        case .liked: MediaChoiceToggle.like.symbol(isOn: true)
        case .disliked: MediaChoiceToggle.dislike.symbol(isOn: true)
        case .notRated: nil
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let size {
                badge(Text(size).monospacedDigit())
                    .frame(maxWidth: .infinity)
            }
            if let symbol = choiceSymbol {
                badge(Text(Image(systemName: symbol)))
                    .padding(.leading, 4)
            }
        }
        .padding(.bottom, 4)
        .accessibilityHidden(true)
    }

    private func badge(_ text: Text) -> some View {
        text
            .font(.footnote)
            .foregroundStyle(DesignPalette.badgeLabel)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(DesignPalette.badge, in: RoundedRectangle(cornerRadius: 3))
    }
}

private nonisolated enum DuplicateThumbnailDecode {
    @concurrent
    static func decode(detail: MediaTileDetail, thumbnailDirectory: URL?) async -> DisplayImage? {
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
