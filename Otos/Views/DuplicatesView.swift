import SwiftUI

// The detail pane for the `.duplicates` scope (ADR 0042, `docs/design/duplicates.md`): a
// list of groups, each a card — one picture when one stands for every copy, the facts the
// copies share, and the decision in words — over the rows that say what differs about
// each copy and its fate; then a fixed-height bar stating the duplicates fact and offering
// the one act. Passive: every string comes from `DuplicatesPresentation`, and every
// control calls a view-model intent; the marks and counts are `DuplicatesSession`'s.

struct DuplicatesView: View {
    let duplicates: CatalogDuplicatesState
    let session: DuplicatesSession
    let canUndoMove: Bool
    let selection: Binding<Set<MediaAssetID>>
    let tileContentStore: TileContentStore?
    let thumbnailDirectory: URL?
    let detailReader: MediaTileDetailReader?
    let actions: DuplicatesActions

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

    /// Cards and rows are all rows of one list: a card is a row that cannot be selected,
    /// never a section header, which the platform pins at the top edge and draws over the
    /// rows passing beneath it. Separators are the cards' own hairlines (DES-023), drawn
    /// between groups, never above the first.
    private var list: some View {
        List(selection: selection) {
            ForEach(Array(pairs.enumerated()), id: \.element.pair) { index, entry in
                DuplicateLibraryPairRow(
                    presentation: .map(entry.pair, groups: entry.groups, session: session),
                    groups: entry.groups,
                    isExpanded: session.expandedPairs.contains(entry.pair),
                    isFirst: index == 0,
                    actions: actions
                )
                .selectionDisabled()
                .listRowSeparator(.hidden)
                if session.expandedPairs.contains(entry.pair) {
                    ForEach(entry.groups) { group in
                        groupRows(group, isFirst: false)
                    }
                }
            }
            ForEach(Array(standaloneGroups.enumerated()), id: \.element.id) { index, group in
                groupRows(group, isFirst: index == 0 && pairs.isEmpty)
            }
        }
        .scrollContentBackground(.hidden)
        .background(DesignPalette.content(for: colorScheme))
        // The platform's list inset left a blank band before the first card.
        .contentMargins(.top, 8, for: .scrollContent)
        .onKeyPress(.return) {
            actions.openGroup()
            return .handled
        }
        // Space opens the group as Return does: Lightroom's Loupe toggle.
        .onKeyPress(.space) {
            actions.openGroup()
            return .handled
        }
    }

    @ViewBuilder
    private func groupRows(_ group: DuplicateGroup, isFirst: Bool) -> some View {
        let presentation = DuplicateGroupPresentation.map(group, session: session)
        DuplicateGroupCard(
            group: group,
            presentation: presentation,
            isFirst: isFirst,
            tileContentStore: tileContentStore,
            thumbnailDirectory: thumbnailDirectory,
            detailReader: detailReader,
            actions: actions
        )
        .selectionDisabled()
        .listRowSeparator(.hidden)
        ForEach(presentation.rows) { row in
            DuplicateCopyRow(
                row: row,
                tileContentStore: tileContentStore,
                thumbnailDirectory: thumbnailDirectory,
                detailReader: detailReader,
                actions: actions
            )
            .tag(row.id)
            .listRowSeparator(.hidden)
        }
    }
}

/// The view model's duplicates intents, handed to the passive views.
struct DuplicatesActions {
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

/// A group's card: the picture (when one stands for every copy), the title, the shared
/// facts and the decision, with Compare and Keep All Copies trailing. Kept, one quiet
/// line with Review Again.
private struct DuplicateGroupCard: View {
    let group: DuplicateGroup
    let presentation: DuplicateGroupPresentation
    let isFirst: Bool
    let tileContentStore: TileContentStore?
    let thumbnailDirectory: URL?
    let detailReader: MediaTileDetailReader?
    let actions: DuplicatesActions

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            DuplicateGroupSeam(isFirst: isFirst)
            card
        }
        .padding(.top, isFirst ? 0 : 8)
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 12) {
            // The well is reserved on every card, so every card's text shares one left
            // edge (DES-016); it is blank when the rows carry the pictures, and for a
            // kept group.
            ZStack {
                if let id = presentation.headerThumbnail {
                    DuplicateThumbnail(
                        id: id,
                        kind: presentation.headerKind,
                        width: DuplicateThumbnail.groupEdge,
                        height: DuplicateThumbnail.groupEdge,
                        tileContentStore: tileContentStore,
                        thumbnailDirectory: thumbnailDirectory,
                        detailReader: detailReader
                    )
                }
            }
            .frame(width: DuplicateThumbnail.groupEdge, height: presentation.isKept ? 0 : DuplicateThumbnail.groupEdge)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.headline)
                    .foregroundStyle(DesignPalette.label(for: colorScheme))
                    .monospacedDigit()
                    .lineLimit(1)
                Text(presentation.sharedFacts ?? " ")
                    .font(.subheadline)
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let decision = presentation.decision {
                    // The verdict, at L2: the one line that says what the act will do.
                    Text(decision)
                        .font(.body)
                        .foregroundStyle(DesignPalette.label(for: colorScheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            // Not Tab stops: on a library of hundreds of groups they would stand between the
            // list and the bar (DES-080). Photo ▸ Keep All Copies / Review Again and Return
            // (Compare) act on the selected group.
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
        .padding(.top, 4)
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

/// One copy: its picture when the pictures are what differ, what differs about it, and at
/// its trailing edge the Keep checkbox beside its fate in words — control and consequence
/// together, at one width in every state.
private struct DuplicateCopyRow: View {
    let row: DuplicateCopyRowPresentation
    let tileContentStore: TileContentStore?
    let thumbnailDirectory: URL?
    let detailReader: MediaTileDetailReader?
    let actions: DuplicatesActions

    @Environment(\.colorScheme) private var colorScheme

    private static let fateWidth: CGFloat = 212

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let aspect = row.thumbnailAspect {
                DuplicateThumbnail(
                    id: row.id,
                    kind: row.kind,
                    width: DuplicateThumbnail.versionEdge,
                    height: (DuplicateThumbnail.versionEdge * min(1, aspect)).rounded(),
                    tileContentStore: tileContentStore,
                    thumbnailDirectory: thumbnailDirectory,
                    detailReader: detailReader
                )
            } else {
                // The card's well, left blank, so the row's L2 shares the card text's left
                // edge (DES-016).
                Color.clear.frame(width: DuplicateThumbnail.groupEdge, height: 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.primary)
                    .font(.body)
                    .foregroundStyle(DesignPalette.label(for: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.showsSecondaryLine {
                    Text(row.secondary ?? " ")
                        .font(.subheadline)
                        .foregroundStyle(DesignPalette.l3(for: colorScheme))
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                actions.openGroupContaining(row.id)
            }
            Spacer(minLength: 8)
                .contentShape(Rectangle())
                // Double-click on the row's picture, name or space opens the group of the
                // row clicked, as Return opens the selection's (HIG Lists) — not on its
                // controls, where a second click would toggle twice.
                .onTapGesture(count: 2) {
                    actions.openGroupContaining(row.id)
                }
            fate
                .frame(width: Self.fateWidth, alignment: .leading)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .contextMenu {
            Button("Keep This Copy") { actions.keep(row.id) }
                .disabled(row.fate == .stays)
            Button("Don't Keep This Copy") { actions.unkeep(row.id) }
                .disabled(row.fate == .movesToTrash || (row.fate == .stays && !row.canUnkeep))
            Button("Keep Only This Copy") { actions.keepOnly(row.id) }
            Divider()
            Button("Move to Trash Now") { actions.moveToTrashNow(row.id) }
        }
        .accessibilityAction(named: "Keep This Copy") { actions.keep(row.id) }
        .accessibilityAction(named: "Keep Only This Copy") { actions.keepOnly(row.id) }
        .accessibilityAction(named: "Don't Keep This Copy") { actions.unkeep(row.id) }
    }

    /// The mark and its meaning (DES-029): a checkbox, not a Tab stop (rows are the
    /// selection; Photo ▸ Keep This Copy / Don't Keep This Copy act on them), beside
    /// `Stays` or `Moves to Trash`. A waiting row offers the act that decides it.
    @ViewBuilder
    private var fate: some View {
        switch row.fate {
        case .stays, .movesToTrash:
            // The box names the setting, `Keep`, which never changes with its state (HIG
            // Toggles); the words after it name the consequence.
            HStack(spacing: 12) {
                Toggle("Keep", isOn: Binding(
                    get: { row.fate == .stays },
                    set: { keep in keep ? actions.keep(row.id) : actions.unkeep(row.id) }
                ))
                .toggleStyle(.checkbox)
                .focusable(false)
                .disabled(row.fate == .stays && !row.canUnkeep)
                .modifier(DuplicateKeepHelp(shown: row.fate == .stays && !row.canUnkeep))
                if row.fate == .stays {
                    Label("Stays", systemImage: "checkmark.circle")
                } else {
                    Label("Moves to Trash", systemImage: "trash")
                }
            }
            .font(.body)
            .foregroundStyle(DesignPalette.label(for: colorScheme))
        case .choice:
            Button("Keep This Copy") {
                actions.keepOnly(row.id)
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

/// An aspect-fit thumbnail (DES-060A) in a leading-aligned well, following the grid's
/// no-blank rule: the kind glyph (DES-063) only before this copy's thumbnail has ever
/// decoded, and its slash variant once a decode has failed.
private struct DuplicateThumbnail: View {
    /// A group's one picture, at the head of the card.
    static let groupEdge: CGFloat = 64
    /// A row's picture when the pictures are what differ: the stored 256 px thumbnail at 2×.
    static let versionEdge: CGFloat = 128

    let id: MediaAssetID
    let kind: MediaKind?
    let width: CGFloat
    let height: CGFloat
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
        ZStack(alignment: .leading) {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: width, maxHeight: height, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: MediaAssetTilePresentation.placeholderIconSystemName(
                    for: kind, thumbnailUnavailable: unavailable
                ))
                .font(.title2)
                .foregroundStyle(.tertiary)
                .frame(width: width, height: height)
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .overlay(alignment: .leading) {
            // A hairline edge (DES-023) so a dark picture reads on the dark backdrop.
            if let image {
                let fitted = fittedSize(of: image)
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(DesignPalette.hairline(for: colorScheme))
                    .frame(width: fitted.width, height: fitted.height)
            }
        }
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
