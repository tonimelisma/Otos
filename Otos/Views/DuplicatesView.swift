import SwiftUI

// The detail pane for the `.duplicates` scope (ADR 0042, `docs/design/duplicates.md`): a
// list of groups — copies that look alike cannot be told apart by thumbnail, so each row
// leads with where the copy lives — then a fixed-height bar stating the duplicates fact
// and offering the one act. Passive: it renders the groups and the session it is given
// and calls the view model's intents; the marks and counts are `DuplicatesSession`'s.

/// What the duplicates bar draws (DES-018): the L1 fact, one L3 clause, and the act.
nonisolated struct DuplicatesBarPresentation: Equatable, Sendable {
    enum Secondary: Equatable, Sendable {
        case none
        case plain(String)
        /// A clause with a Show reveal beside it (DES-015).
        case reveal(String)
    }

    let primaryLine: String
    let secondary: Secondary
    let actionTitle: String
    let actionEnabled: Bool

    static func map(_ tally: DuplicatesTally) -> DuplicatesBarPresentation {
        let photos = tally.photosWithDuplicates
        let primary = photos == 0
            ? "No duplicates"
            : "\(photos) \(photos == 1 ? "photo" : "photos") with duplicates"
        let marked = tally.itemsToMove.count
        let secondary: Secondary = if marked > 0 {
            .plain([
                "\(marked) \(marked == 1 ? "item" : "items") marked",
                ImportBarByteFormat.phrase(tally.bytesToMove),
            ].compactMap(\.self).joined(separator: " · "))
        } else if tally.needingChoice > 0 {
            .reveal("\(tally.needingChoice) \(tally.needingChoice == 1 ? "needs" : "need") your choice")
        } else {
            .none
        }
        return DuplicatesBarPresentation(
            primaryLine: primary,
            secondary: secondary,
            // DES-036: the count is the new information the click commits to; disabled, the
            // title keeps its place and says what it would do (DES-053).
            actionTitle: marked > 0 ? "Move \(marked) \(marked == 1 ? "Item" : "Items") to Trash" : "Move Marked Items to Trash",
            actionEnabled: marked > 0
        )
    }
}

struct DuplicatesView: View {
    let duplicates: CatalogDuplicatesState
    let session: DuplicatesSession
    let selection: Binding<Set<MediaAssetID>>
    let tileContentStore: TileContentStore?
    let thumbnailDirectory: URL?
    let detailReader: MediaTileDetailReader?
    let actions: DuplicatesActions

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            if duplicates.groups.isEmpty {
                ContentUnavailableView("No duplicates", systemImage: "square.on.square")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
            Divider()
            DuplicatesStatusBar(
                presentation: .map(session.tally(in: duplicates)),
                actions: actions
            )
        }
    }

    private var pairs: [(pair: DuplicateLibraryPair, groups: [DuplicateGroup])] {
        let grouped = Dictionary(grouping: duplicates.activeGroups.filter { $0.libraryPair != nil }) { $0.libraryPair! }
        return grouped.map { ($0.key, $0.value) }.sorted { $0.pair.first.rawValue < $1.pair.first.rawValue }
    }

    private var list: some View {
        List(selection: selection) {
            ForEach(pairs, id: \.pair) { entry in
                Section {
                    DuplicateLibraryPairRow(
                        pair: entry.pair,
                        groups: entry.groups,
                        isExpanded: session.expandedPairs.contains(entry.pair),
                        actions: actions
                    )
                }
                if session.expandedPairs.contains(entry.pair) {
                    ForEach(entry.groups) { group in
                        groupSection(group)
                    }
                }
            }
            ForEach(duplicates.activeGroups.filter { $0.libraryPair == nil }) { group in
                groupSection(group)
            }
            if !duplicates.keptGroups.isEmpty {
                Section {
                    if session.showsKept {
                        ForEach(duplicates.keptGroups) { group in
                            ForEach(group.copies) { copy in
                                row(copy, in: group)
                            }
                        }
                    }
                } header: {
                    Button {
                        actions.toggleKept()
                    } label: {
                        Label(
                            "Kept · \(duplicates.keptGroups.count)",
                            systemImage: session.showsKept ? "chevron.down" : "chevron.right"
                        )
                        .font(.headline)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .onKeyPress(.return) {
            actions.openGroup()
            return .handled
        }
    }

    private func groupSection(_ group: DuplicateGroup) -> some View {
        Section {
            ForEach(group.copies) { copy in
                row(copy, in: group)
            }
        } header: {
            DuplicateGroupHeader(group: group, actions: actions)
        }
    }

    private func row(_ copy: DuplicateCopy, in group: DuplicateGroup) -> some View {
        DuplicateCopyRow(
            copy: copy,
            keeps: session.keeps(copy.id, in: group),
            canMoveToTrash: session.canMoveToTrash(copy.id, in: group),
            // Versions of one photo are told apart by their pixels: a thumbnail at the stored
            // thumbnail's own size. Identical copies are told apart by where they live.
            thumbnailEdge: group.id.isSamePhoto ? DuplicateThumbnail.versionEdge : DuplicateThumbnail.copyEdge,
            tileContentStore: tileContentStore,
            thumbnailDirectory: thumbnailDirectory,
            detailReader: detailReader,
            actions: actions
        )
        .tag(copy.id)
    }
}

/// The view model's duplicates intents, handed to the passive views.
struct DuplicatesActions {
    let keep: @MainActor (MediaAssetID) -> Void
    let moveToTrash: @MainActor (MediaAssetID) -> Void
    let keepAll: @MainActor (DuplicateGroup) -> Void
    let keepOnly: @MainActor (MediaAssetID) -> Void
    let keepBothLibraries: @MainActor (DuplicateLibraryPair) -> Void
    let keepOnlyLibrary: @MainActor (LibraryRootPath, DuplicateLibraryPair) -> Void
    let togglePair: @MainActor (DuplicateLibraryPair) -> Void
    let toggleKept: @MainActor () -> Void
    let openGroup: @MainActor () -> Void
    let compareGroup: @MainActor (DuplicateGroup) -> Void
    let moveMarked: @MainActor () -> Void
    let revealNeedingChoice: @MainActor () -> Void
}

private struct DuplicateGroupHeader: View {
    let group: DuplicateGroup
    let actions: DuplicatesActions

    private var title: String {
        isSamePhoto ? "Same photo · \(group.copies.count) versions" : "Identical · \(group.copies.count) copies"
    }

    private var isSamePhoto: Bool {
        group.id.isSamePhoto
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                // Only copies whose work cannot be combined wait for a choice.
                if group.defaultKeep == nil {
                    Text(isSamePhoto ? "Choose the version to keep" : "Choose a copy to keep")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if isSamePhoto, !group.isKept {
                Button("Compare") {
                    actions.compareGroup(group)
                }
                .controlSize(.small)
            }
            if !group.isKept {
                Button("Keep All") {
                    actions.keepAll(group)
                }
                .controlSize(.small)
            }
        }
    }
}

private struct DuplicateLibraryPairRow: View {
    let pair: DuplicateLibraryPair
    let groups: [DuplicateGroup]
    let isExpanded: Bool
    let actions: DuplicatesActions

    private var names: (String, String) {
        let copies = groups.flatMap(\.copies)
        let first = copies.first { $0.id.libraryRootPath == pair.first }?.libraryDisplayName ?? pair.first.displayName
        let second = copies.first { $0.id.libraryRootPath == pair.second }?.libraryDisplayName ?? pair.second.displayName
        return (first, second)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                actions.togglePair(pair)
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide photos" : "Show photos")
            Text("\(names.0) and \(names.1) share \(groups.count) \(groups.count == 1 ? "photo" : "photos")")
                .font(.body)
            Spacer(minLength: 0)
            // Each library keeps its own copies by default; one library's copies go only
            // when the user names the library to keep.
            Menu("Keep Only") {
                Button(names.0) {
                    actions.keepOnlyLibrary(pair.first, pair)
                }
                Button(names.1) {
                    actions.keepOnlyLibrary(pair.second, pair)
                }
            }
            .menuStyle(.button)
            .fixedSize()
            .controlSize(.small)
            Button("Keep Both Libraries") {
                actions.keepBothLibraries(pair)
            }
            .controlSize(.small)
        }
    }
}

private struct DuplicateCopyRow: View {
    let copy: DuplicateCopy
    let keeps: Bool
    let canMoveToTrash: Bool
    let thumbnailEdge: CGFloat
    let tileContentStore: TileContentStore?
    let thumbnailDirectory: URL?
    let detailReader: MediaTileDetailReader?
    let actions: DuplicatesActions

    @Environment(\.colorScheme) private var colorScheme

    private var location: String {
        copy.folder.isEmpty ? copy.libraryDisplayName : "\(copy.libraryDisplayName) ▸ \(copy.folder)"
    }

    private var facts: String {
        var parts = [copy.name]
        if let width = copy.pixelWidth, let height = copy.pixelHeight {
            parts.append("\(width) × \(height)")
        }
        if let size = copy.byteSize, let phrase = ImportBarByteFormat.phrase(PartialByteCount(knownBytes: size, unknownCount: 0)) {
            parts.append(phrase)
        }
        return parts.joined(separator: " · ")
    }

    private var marks: [String] {
        var marks: [String] = []
        switch copy.mediaChoice {
        case .liked: marks.append("liked")
        case .disliked: marks.append("disliked")
        case .notRated: break
        }
        if copy.isEdited {
            marks.append("edited")
        }
        if copy.hasCompanions {
            marks.append("has sidecar")
        }
        return marks
    }

    var body: some View {
        HStack(spacing: 12) {
            DuplicateThumbnail(
                id: copy.id,
                edge: thumbnailEdge,
                tileContentStore: tileContentStore,
                thumbnailDirectory: thumbnailDirectory,
                detailReader: detailReader
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(location)
                    .font(.body)
                    .foregroundStyle(DesignPalette.label(for: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(facts)
                    .font(.subheadline)
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if copy.mediaChoice == .liked {
                    Image(systemName: "hand.thumbsup.fill").accessibilityHidden(true)
                }
                if copy.mediaChoice == .disliked {
                    Image(systemName: "hand.thumbsdown.fill").accessibilityHidden(true)
                }
                if copy.isEdited {
                    Image(systemName: "slider.horizontal.3").accessibilityHidden(true)
                }
                if copy.hasCompanions {
                    Image(systemName: "doc.badge.gearshape").accessibilityHidden(true)
                }
            }
            .foregroundStyle(.secondary)
            // The state, as a symbol and text (DES-029). Not a Tab stop: rows are the
            // selection, and Photo ▸ Keep This Copy / Move This Copy to Trash act on them.
            Button {
                if keeps {
                    actions.moveToTrash(copy.id)
                } else {
                    actions.keep(copy.id)
                }
            } label: {
                Label(keeps ? "Keep" : "Move to Trash", systemImage: keeps ? "checkmark.circle" : "trash")
                    .frame(minWidth: 120, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .disabled(keeps && !canMoveToTrash)
            .help(keeps && !canMoveToTrash ? "A group always keeps one copy." : "")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([location, copy.name, keeps ? "kept" : "moves to Trash"] + marks).joined(separator: ", "))
        .contextMenu {
            Button("Keep Only This Copy") { actions.keepOnly(copy.id) }
        }
        .accessibilityAction(named: "Keep This Copy") { actions.keep(copy.id) }
        .accessibilityAction(named: "Keep Only This Copy") { actions.keepOnly(copy.id) }
        .accessibilityAction(named: "Move This Copy to Trash") { actions.moveToTrash(copy.id) }
    }
}

/// An aspect-fit thumbnail (DES-060A), following the grid's no-blank rule: a placeholder
/// only before this copy's thumbnail has ever decoded.
private struct DuplicateThumbnail: View {
    /// An identical copy's: the row leads with where it lives, not with the picture.
    static let copyEdge: CGFloat = 48
    /// A version of the same photo's: the stored 256 px thumbnail at 2×.
    static let versionEdge: CGFloat = 128

    let id: MediaAssetID
    let edge: CGFloat
    let tileContentStore: TileContentStore?
    let thumbnailDirectory: URL?
    let detailReader: MediaTileDetailReader?
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: edge, height: edge)
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
        guard let detail, detail.thumbnailPath != nil, !Task.isCancelled,
              let decoded = await DuplicateThumbnailDecode.decode(detail: detail, thumbnailDirectory: thumbnailDirectory),
              !Task.isCancelled
        else {
            return
        }
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

/// The duplicates bar (DES-018): *what* (L1 over one L3 clause) · *the act*. The act is a
/// plain bordered button with no Return equivalent — Return opens the selected group, and
/// a bulk move must not be one keystroke from a list (DES-052's recorded deviation).
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
                switch presentation.secondary {
                case .none:
                    Color.clear.frame(height: 14)
                case let .plain(text):
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(DesignPalette.l3(for: colorScheme))
                        .monospacedDigit()
                        .lineLimit(1)
                case let .reveal(text):
                    HStack(spacing: 6) {
                        Text(text)
                            .font(.subheadline)
                            .foregroundStyle(DesignPalette.l3(for: colorScheme))
                            .monospacedDigit()
                        Button("Show", action: actions.revealNeedingChoice)
                            .buttonStyle(.link)
                            .font(.subheadline)
                    }
                }
            }
            Spacer(minLength: 0)
            Button(presentation.actionTitle, action: actions.moveMarked)
                .disabled(!presentation.actionEnabled)
                .help(presentation.actionEnabled ? "" : "Mark copies to move, or choose a copy to keep in a group.")
        }
        .frame(minHeight: Self.contentHeight, maxHeight: Self.contentHeight)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(DesignPalette.bar(for: colorScheme))
        .accessibilityElement(children: .contain)
    }
}
