import Foundation

// Duplicates presentation (ADR 0042, `docs/design/duplicates.md`)
//
// Pure mappings from the published layout and the session's picks and rules to what the
// list and the bar draw: three sections by the attention a group needs. Groups only a
// click decides and files of one photo are a date and why over their copies' photos, each
// tagged Keep or Trash; exact copies sit under their folder's header, which carries the
// folder's rule, each group one picture beside its copies' names. Every string on the
// surface is composed here, so the view is passive and the words are testable without a
// view.

/// What the duplicates bar draws (DES-018): *what* (L1 over one L3 clause) · *the middle
/// zone* (the receipt of the last move, the groups that wait, or the legend) · *the act*.
nonisolated struct DuplicatesBarPresentation: Equatable, Sendable {
    enum Middle: Equatable, Sendable {
        /// What the last move hid, with Undo while it is the window's last change, over
        /// what the user does next to get the space.
        case receipt(line: String, detail: String, canUndo: Bool)
        /// `6 photos need your choice`, beside Show.
        case choices(String)
        /// How to choose, while nothing waits and nothing was just moved.
        case legend(String)
    }

    static let legend = "Click a photo or a name to keep it, or set a rule for a whole folder."

    let primaryLine: String
    /// `221 copies go to the Trash · 53.9 GB`: what the act moves, the count the button
    /// repeats and the bytes it does not carry; nil, drawn as blank space at the same
    /// height, while nothing moves (DES-053).
    let secondaryLine: String?
    let middle: Middle
    let actionTitle: String
    let actionEnabled: Bool

    static func map(
        _ tally: DuplicatesTally,
        receipt: DuplicatesReceipt? = nil,
        canUndoMove: Bool = false
    ) -> DuplicatesBarPresentation {
        let groups = tally.itemsWithDuplicates
        let primary = groups == 0
            ? "No duplicates"
            : "\(groups) \(tally.noun.string(count: groups)) with duplicates"
        let moving = tally.itemsToMove.count
        let secondary: String? = if moving > 0 {
            [
                "\(moving) \(moving == 1 ? "copy goes" : "copies go") to the Trash",
                ImportBarByteFormat.phrase(tally.bytesToMove),
            ].compactMap(\.self).joined(separator: " · ")
        } else {
            nil
        }
        let waiting = tally.needingChoice
        let middle: Middle = if let receipt {
            .receipt(
                line: [
                    "\(receipt.movedCount) \(receipt.movedCount == 1 ? "copy" : "copies") moved to the Trash",
                    ImportBarByteFormat.phrase(receipt.bytes),
                ].compactMap(\.self).joined(separator: " · "),
                detail: "Empty the Trash in Finder to free the space",
                canUndo: canUndoMove
            )
        } else if waiting > 0 {
            .choices("\(waiting) \(tally.noun.string(count: waiting)) \(waiting == 1 ? "needs" : "need") your choice")
        } else {
            .legend(legend)
        }
        return DuplicatesBarPresentation(
            primaryLine: primary,
            secondaryLine: secondary,
            middle: middle,
            // DES-036: the count is the new information the click commits to; disabled, the
            // title keeps its place and says what it would do (DES-053).
            actionTitle: moving > 0 ? "Move \(moving) \(moving == 1 ? "Copy" : "Copies") to Trash" : "Move Copies to Trash",
            actionEnabled: moving > 0
        )
    }
}

/// A folder's name as the list shows it: the folder inside its library, and the library's
/// name too when the list spans libraries.
nonisolated enum DuplicateFolderName {
    static func string(_ folder: DuplicateFolder, withLibrary: Bool) -> String {
        let inside = folder.folder.isEmpty ? folder.libraryDisplayName : folder.folder
        guard withLibrary, !folder.folder.isEmpty else {
            return inside
        }
        return "\(folder.libraryDisplayName) ▸ \(inside)"
    }
}

/// A section's header: what its groups have in common, how many, and what to do with them.
nonisolated struct DuplicatesSectionPresentation: Equatable, Sendable, Identifiable {
    let id: DuplicatesSection
    /// `Only you can choose`, `Different files of one photo`, `Exact copies`.
    let title: String
    /// `6 photos`: the section's active groups, in the bar's noun.
    let count: String
    let detail: String

    /// Nil for a section with no group.
    static func map(_ section: DuplicatesSection, in layout: DuplicatesLayout) -> DuplicatesSectionPresentation? {
        let groups = layout.groups(in: section)
        guard !groups.isEmpty else {
            return nil
        }
        let active = groups.filter { !$0.isKept }
        let noun = DuplicateItemNoun.covering(groups.flatMap(\.copies).map(\.kind))
        let (title, detail) = switch section {
        case .choose:
            ("Only you can choose", "The copies hold different edits, ratings or .xmp files. Click the one to keep.")
        case .different:
            ("Different files of one photo", "Otos keeps the best file of each. Click another to keep it instead.")
        case .exact:
            ("Exact copies", "The same file stored more than once. Set a rule for a folder, or click a name to keep it.")
        }
        return DuplicatesSectionPresentation(
            id: section,
            title: title,
            count: "\(active.count) \(noun.string(count: active.count))",
            detail: detail
        )
    }
}

/// One folder header in Exact copies: the folder (or two) its groups sit in, how many and
/// how much, why they keep what they keep, and the folder's rule as a segmented choice.
nonisolated struct DuplicateFolderBucketPresentation: Equatable, Sendable, Identifiable {
    struct Option: Equatable, Sendable {
        let rule: DuplicateFolderRule
        let title: String
    }

    /// The folder's rule: nil where no rule could decide anything (three or more folders,
    /// an Immich account's copies alone, or every group kept).
    struct Rule: Equatable, Sendable {
        let folderSet: DuplicateFolderSet
        /// `Keep the copies in`, `Keep the`.
        let prompt: String
        let options: [Option]
        let selected: DuplicateFolderRule
    }

    let id: DuplicateFolderPlace
    /// `2026/08 and Imports/Aug 2026`, `2026/10`, or `In three or more folders`.
    let title: String
    /// `412 photos in both · 31 GB in extra copies`, `38 photos saved twice in this folder`.
    let detail: String
    /// Why the folder's groups keep what they keep, counted by reason, so the folder is
    /// audited as a whole: `Keeping the original name`, or `96 keeping the original name ·
    /// 14 keeping the older file`. Nil when nothing in it is decided.
    let summary: String?
    let rule: Rule?
    let isTwoFolders: Bool

    static func map(
        _ bucket: DuplicateFolderBucket,
        session: DuplicatesSession,
        withLibrary: Bool
    ) -> DuplicateFolderBucketPresentation {
        let active = bucket.activeGroups
        let resolutions = active.compactMap(session.resolution(of:))
        let noun = DuplicateItemNoun.covering(bucket.groups.flatMap(\.copies).map(\.kind))
        let count = active.count
        let things = "\(count) \(noun.string(count: count))"
        let bytes = PartialByteCount(
            knownBytes: resolutions.reduce(0) { $0 + $1.bytes.knownBytes },
            unknownCount: resolutions.reduce(0) { $0 + $1.bytes.unknownCount }
        )
        let moving = resolutions.reduce(0) { $0 + $1.moving.count }
        let extra = moving > 0 ? ImportBarByteFormat.phrase(bytes).map { "\($0) in extra copies" } : nil
        let summary = summary(of: active, session: session, withLibrary: withLibrary)
        guard case let .folders(set) = bucket.id else {
            return DuplicateFolderBucketPresentation(
                id: bucket.id,
                title: "In three or more folders",
                detail: ([count == 0 ? "Every copy kept" : things] + [extra].compactMap(\.self)).joined(separator: " · "),
                summary: summary, rule: nil, isTwoFolders: false
            )
        }
        let folders = set.folders
        let names = folders.map { DuplicateFolderName.string($0, withLibrary: withLibrary) }
        let selected = session.rules[set] ?? .automatic
        let offersRule = bucket.id.ruleFolderSet != nil && count > 0
        if folders.count == 2 {
            let spansLibraries = folders[0].library != folders[1].library
            // Keeping one folder's copies moves the other's to the Trash, which Otos never
            // does to an Immich account's copies (ADR 0046 §8): that choice is not offered,
            // and the header says why.
            let keepable = folders.indices.filter { folders[1 - $0].canMoveToTrash }
            let staying = folders.filter { !$0.canMoveToTrash }.map(\.libraryDisplayName)
            let refusal = staying.isEmpty ? nil : "Otos never removes copies in \(DuplicatesWords.quoted(staying))"
            return DuplicateFolderBucketPresentation(
                id: bucket.id,
                title: "\(names[0]) and \(names[1])",
                detail: ([count == 0 ? "Every copy kept" : "\(things) in both"] + [extra, refusal].compactMap(\.self))
                    .joined(separator: " · "),
                summary: summary,
                rule: offersRule ? Rule(
                    folderSet: set,
                    prompt: "Keep the copies in",
                    options: keepable.map { Option(rule: .folder(folders[$0]), title: names[$0]) } + [
                        // Across libraries the keeper rule keeps each library's copy.
                        Option(rule: .automatic, title: spansLibraries ? "Both" : "Otos decides"),
                    ],
                    selected: selected
                ) : nil,
                isTwoFolders: true
            )
        }
        let staying = folders.filter { !$0.canMoveToTrash }.map(\.libraryDisplayName)
        let refusal = staying.isEmpty ? nil : "Otos never removes copies in \(DuplicatesWords.quoted(staying))"
        return DuplicateFolderBucketPresentation(
            id: bucket.id,
            title: names.first ?? "",
            detail: ([count == 0 ? "Every copy kept" : "\(things) saved twice in this folder"] + [extra, refusal].compactMap(\.self))
                .joined(separator: " · "),
            summary: summary,
            rule: offersRule ? Rule(
                folderSet: set,
                prompt: "Keep the",
                options: [
                    Option(rule: .automatic, title: "Best copy"),
                    Option(rule: .originalName, title: "Original name"),
                    Option(rule: .oldest, title: "Oldest"),
                    Option(rule: .largest, title: "Largest"),
                ],
                selected: selected
            ) : nil,
            isTwoFolders: false
        )
    }

    /// The groups' reasons, counted: one reason reads as a group's own line does; several
    /// read `96 keeping the original name · 14 keeping the older file`, the two most
    /// common, then `5 more`, so the line fits beside the folder's rule.
    private static func summary(of groups: [DuplicateGroup], session: DuplicatesSession, withLibrary: Bool) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for group in groups {
            guard let resolution = session.resolution(of: group), !resolution.moving.isEmpty else {
                continue
            }
            let reason = resolution.reason == .picked
                ? "Chosen by you"
                : DuplicateGroupPresentation.reasonText(resolution, in: group, withLibrary: withLibrary)
            guard !reason.isEmpty else {
                continue
            }
            if counts[reason] == nil {
                order.append(reason)
            }
            counts[reason, default: 0] += 1
        }
        guard order.count > 1 else {
            return order.first
        }
        let ranked = order.enumerated().sorted { left, right in
            let (leftCount, rightCount) = (counts[left.element] ?? 0, counts[right.element] ?? 0)
            return leftCount != rightCount ? leftCount > rightCount : left.offset < right.offset
        }.map(\.element)
        var parts = ranked.prefix(2).map { "\(counts[$0] ?? 0) \($0.prefix(1).lowercased() + $0.dropFirst())" }
        let rest = ranked.dropFirst(2).reduce(0) { $0 + (counts[$1] ?? 0) }
        if rest > 0 {
            parts.append("\(rest) more")
        }
        return parts.joined(separator: " · ")
    }
}

nonisolated enum DuplicatesWords {
    /// Library names as a list reads them: `“Family”`, `“Family” and “Work”`.
    static func quoted(_ names: [String]) -> String {
        let quoted = names.map { "“\($0)”" }
        guard quoted.count > 1, let last = quoted.last else {
            return quoted.first ?? ""
        }
        return quoted.dropLast().joined(separator: ", ") + " and " + last
    }
}

/// A copy's fate as its photo shows it: a tag, and a face drawn bright or dimmed (DES-029:
/// a word and a glyph, never colour alone).
nonisolated enum DuplicateCopyFate: Equatable, Sendable {
    case keep
    case trash
    /// The group waits for a click: its copies hold work no rule decides between.
    case undecided
}

/// One copy, as a photo or as a line of text: its fate, what tells it apart from the
/// group's other copies, and the rest in its tooltip.
nonisolated struct DuplicateCopyTilePresentation: Equatable, Sendable, Identifiable {
    let id: MediaAssetID
    let kind: MediaKind?
    let fate: DuplicateCopyFate
    /// What tells this copy from the others where their pictures cannot: its file name
    /// when the copies share a folder, its folder when they share a name, else both. An
    /// exact copy's line reads it.
    let label: String
    /// What else differs, or is the user's own, under a photo or after a name: the
    /// dimensions and format when the group's files differ in them, `Camera original` when
    /// not every file is one, then the work the copy holds (`Liked`, `Edited in Otos`, `Has
    /// an .xmp or .srt file`). Nil when there is nothing to say.
    let caption: String?
    /// The copy's folder, under its photo, when the group's copies sit in more than one
    /// folder: which folder a copy is in is then what tells the copies apart.
    let folder: String?
    /// The size, at the precision that tells this group's copies apart (DES-005A).
    let size: String?
    let choice: MediaChoice
    /// Whether Keep This Copy would change anything: not for the copy already chosen. A
    /// copy kept only because Otos may not move it can still be chosen over the others.
    let canKeep: Bool
    /// Whether its context menu offers Move to Trash Now: never for an Immich account's copy.
    let canMoveToTrash: Bool
    /// Where it is and what it is, for the tooltip.
    let help: String
    /// What VoiceOver reads: the file, its fate, then the facts (DES-082).
    let accessibilityLabel: String
}

/// One group as the list draws it: its date and why it keeps what it keeps, over its
/// photos or beside its copies' names; kept, `Kept all N copies` with Review Again.
nonisolated struct DuplicateGroupPresentation: Equatable, Sendable, Identifiable {
    /// How the group is drawn, which decides what its line of facts must carry.
    enum Style: Equatable, Sendable {
        /// Photos side by side: the line names the folder every copy shares.
        case photos
        /// One picture beside the copies' names, under a folder header that already names
        /// the folder: the line gives the size the copies share instead.
        case names
    }

    let id: DuplicateGroupID
    /// The capture date: `October 4, 2026`.
    let title: String
    /// `2026/10 · Keeping the original name`, `4.1 MB each · You chose this one`, or what
    /// to choose.
    let reason: String
    let isKept: Bool
    /// The copy whose picture stands for an exact-copy group: its first, the kept one.
    let picture: MediaAssetID?
    let pictureKind: MediaKind?
    let tiles: [DuplicateCopyTilePresentation]
    let accessibilityLabel: String

    static func map(
        _ group: DuplicateGroup,
        session: DuplicatesSession,
        style: Style = .photos,
        withLibrary: Bool = false,
        calendar: Calendar = .current
    ) -> DuplicateGroupPresentation {
        let copies = group.copies
        let count = copies.count
        let title = group.captureLocalTime.map {
            $0.formatted(Date.FormatStyle(date: .long, time: .omitted, calendar: calendar))
        } ?? "No Date"
        if group.isKept {
            let note = count == 2 ? "Kept both copies" : "Kept all \(count) copies"
            return DuplicateGroupPresentation(
                id: group.id, title: title, reason: note, isKept: true,
                picture: copies.first?.id, pictureKind: copies.first?.kind, tiles: [],
                accessibilityLabel: "\(title), \(note)"
            )
        }
        let resolution = session.resolution(of: group)
        let words = DuplicateCopyWords(group: group, withLibrary: withLibrary, calendar: calendar)
        let reason = reasonLine(group, resolution: resolution, shared: words.shared(style), withLibrary: withLibrary)
        let tiles = copies.map { copy -> DuplicateCopyTilePresentation in
            let fate: DuplicateCopyFate = if let resolution {
                resolution.keep.contains(copy.id) ? .keep : .trash
            } else {
                .undecided
            }
            let facts = words.facts(of: copy)
            let caption = words.caption(of: copy)
            return DuplicateCopyTilePresentation(
                id: copy.id,
                kind: copy.kind,
                fate: fate,
                label: words.label(of: copy),
                caption: caption.isEmpty ? nil : caption.joined(separator: " · "),
                folder: words.folders.count > 1 ? DuplicateFolderName.string(DuplicateFolder(copy), withLibrary: withLibrary) : nil,
                size: words.sizes[copy.id],
                choice: copy.mediaChoice,
                canKeep: !(resolution.map { $0.keep.contains(copy.id) && !$0.stays.contains(copy.id) } ?? false),
                canMoveToTrash: copy.canMoveToTrash,
                help: ([words.location(of: copy)] + [facts.joined(separator: " · ")].filter { !$0.isEmpty }).joined(separator: "\n"),
                accessibilityLabel: ([copy.name, fate.spoken] + facts).joined(separator: ", ")
            )
        }
        return DuplicateGroupPresentation(
            id: group.id,
            title: title,
            reason: reason,
            isKept: false,
            picture: copies.first?.id,
            pictureKind: copies.first?.kind,
            tiles: tiles,
            accessibilityLabel: [title, reason].filter { !$0.isEmpty }.joined(separator: ", ")
        )
    }

    /// The group's line: what its copies share, why it keeps what it keeps, and the copies
    /// Otos may not move.
    private static func reasonLine(
        _ group: DuplicateGroup,
        resolution: DuplicateResolution?,
        shared: String?,
        withLibrary: Bool
    ) -> String {
        let why: String = if let resolution {
            reasonText(resolution, in: group, withLibrary: withLibrary)
        } else if case let .waits(conflict) = group.default {
            waitingText(conflict)
        } else {
            ""
        }
        // A copy Otos may not move stays whatever was chosen (ADR 0046 §8), and the line
        // says so; when nothing moves, that is the whole of why.
        var staying: [String] = []
        for copy in group.copies where resolution?.stays.contains(copy.id) == true && !staying.contains(copy.libraryDisplayName) {
            staying.append(copy.libraryDisplayName)
        }
        let stay: String? = staying.isEmpty
            ? nil
            : "Otos never removes copies in \(DuplicatesWords.quoted(staying))"
        // When nothing moves because of it, the refusal is the whole line: it names the
        // library already, so the folder is not repeated before it.
        let decided: [String?] = resolution?.moving.isEmpty == true && stay != nil ? [stay] : [shared, why, stay]
        return decided.compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Why the group keeps what it keeps, in words: the click, the folder's rule, or the
    /// keeper rule's deciding criterion.
    static func reasonText(_ resolution: DuplicateResolution, in group: DuplicateGroup, withLibrary: Bool) -> String {
        let copyNoun = group.id.isSamePhoto ? "file" : "copy"
        switch resolution.reason {
        case .picked:
            return "You chose this one"
        case let .rule(rule):
            switch rule {
            case .automatic: return ""
            case let .folder(folder):
                return "Keeping the \(copyNoun) in \(DuplicateFolderName.string(folder, withLibrary: withLibrary)), as the folder rule says"
            case .originalName: return "Keeping the original name, as the folder rule says"
            case .oldest: return "Keeping the oldest, as the folder rule says"
            case .largest: return "Keeping the largest, as the folder rule says"
            }
        case let .automatic(reason):
            switch reason {
            case .eachLibrary:
                return "Keeping one \(copyNoun) in each library"
            case let .criterion(criterion):
                switch criterion {
                case .companions: return "Keeping the \(copyNoun) with its .xmp or .srt file"
                case .cameraOriginal: return "Keeping the camera original"
                case .mostPixels: return "Keeping the file with the most pixels"
                case .largestFile: return "Keeping the largest file"
                case .edited: return "Keeping the \(copyNoun) edited in Otos"
                case .rated:
                    let kept = group.copies.first { resolution.keep.contains($0.id) }
                    return kept?.mediaChoice == .disliked
                        ? "Keeping the \(copyNoun) you disliked"
                        : "Keeping the \(copyNoun) you liked"
                case .originalName: return "Keeping the original name"
                case .earliestBirth: return "Keeping the older file"
                case .pathOrder: return "Alike in every way, so keeping the first by name"
                }
            }
        }
    }

    /// What a group whose copies hold work that cannot be combined asks for.
    private static func waitingText(_ conflict: DuplicateWorkConflict) -> String {
        switch conflict.kind {
        case .edits: "The copies have different edits: click the one to keep"
        case .companions: "More than one copy has an .xmp or .srt file: click the one to keep"
        case .choices: "The copies are liked and disliked: click the one to keep"
        }
    }
}

private nonisolated extension DuplicateCopyFate {
    /// What VoiceOver reads for the fate.
    var spoken: String {
        switch self {
        case .keep: "keep"
        case .trash: "goes to the Trash"
        case .undecided: "not chosen yet"
        }
    }
}

/// What one group's copies read as: derived once per group, then asked per copy. What the
/// copies share is said once on the group's line; what differs goes on each copy.
private nonisolated struct DuplicateCopyWords {
    let group: DuplicateGroup
    let withLibrary: Bool
    let folders: [DuplicateFolder]
    let sizes: [MediaAssetID: String]
    private let dates: DuplicateDateFormat
    private let births: [Date]
    private let sameName: Bool
    private let dimensionsDiffer: Bool
    private let formatsDiffer: Bool

    init(group: DuplicateGroup, withLibrary: Bool, calendar: Calendar) {
        self.group = group
        self.withLibrary = withLibrary
        let copies = group.copies
        folders = DuplicateFolderSet(group).folders
        sizes = DuplicateTileFacts.distinguishingSizes(of: copies)
        dates = DuplicateDateFormat(calendar: calendar)
        births = copies.compactMap(\.createdAt)
        sameName = Set(copies.map(\.name)).count == 1
        dimensionsDiffer = Set(copies.map(DuplicateTileFacts.dimensions(of:))).count > 1
        formatsDiffer = Set(copies.map(DuplicateTileFacts.format(of:))).count > 1
    }

    /// What the copies share, said once: under photos the folder; beside names, where the
    /// folder's header already names it, the size.
    func shared(_ style: DuplicateGroupPresentation.Style) -> String? {
        switch style {
        case .photos:
            return folders.count == 1 ? DuplicateFolderName.string(folders[0], withLibrary: withLibrary) : nil
        case .names:
            guard Set(group.copies.map(\.byteSize)).count == 1, let bytes = group.copies.first?.byteSize else {
                return nil
            }
            return "\(ImportBarByteFormat.string(bytes: bytes)) each"
        }
    }

    /// What tells this copy from the others in text: its file name when the copies share a
    /// folder, its folder when they share a name, else both.
    func label(of copy: DuplicateCopy) -> String {
        if folders.count == 1 {
            return copy.name
        }
        let folder = DuplicateFolderName.string(DuplicateFolder(copy), withLibrary: withLibrary)
        return sameName ? folder : "\(folder) ▸ \(copy.name)"
    }

    func location(of copy: DuplicateCopy) -> String {
        let inside = [copy.folder, copy.name].filter { !$0.isEmpty }.joined(separator: "/")
        return "\(copy.libraryDisplayName) ▸ \(inside)"
    }

    private func isOriginalAmongOthers(_ copy: DuplicateCopy) -> Bool {
        group.cameraOriginals.contains(copy.id) && group.cameraOriginals.count < group.copies.count
    }

    /// Every fact, for the tooltip and VoiceOver.
    func facts(of copy: DuplicateCopy) -> [String] {
        var facts: [String] = []
        if let dimensions = DuplicateTileFacts.dimensions(of: copy) {
            facts.append(dimensions)
        }
        if let size = sizes[copy.id] {
            facts.append(size)
        }
        if let born = copy.createdAt, Set(births).count > 1 {
            facts.append("File created \(dates.string(for: born, among: births))")
        }
        if isOriginalAmongOthers(copy) {
            facts.append("Camera original")
        }
        return facts + DuplicateTileFacts.work(of: copy)
    }

    /// What differs besides the picture and the size, then the work the copy holds.
    func caption(of copy: DuplicateCopy) -> [String] {
        var caption: [String] = []
        if dimensionsDiffer, let dimensions = DuplicateTileFacts.dimensions(of: copy) {
            caption.append(dimensions)
        }
        if formatsDiffer, let format = DuplicateTileFacts.format(of: copy) {
            caption.append(format)
        }
        if isOriginalAmongOthers(copy) {
            caption.append("Camera original")
        }
        return caption + DuplicateTileFacts.work(of: copy)
    }
}

nonisolated enum DuplicateTileFacts {
    /// The work the copy holds: what the user would not want to lose with it.
    static func work(of copy: DuplicateCopy) -> [String] {
        var work: [String] = []
        switch copy.mediaChoice {
        case .liked: work.append("Liked")
        case .disliked: work.append("Disliked")
        case .notRated: break
        }
        if copy.isEdited {
            work.append("Edited in Otos")
        }
        if copy.hasCompanions {
            work.append("Has an .xmp or .srt file")
        }
        if !copy.canMoveToTrash {
            work.append("Removed only in Immich")
        }
        return work
    }

    /// The file's format as its name gives it: `HEIC`, `JPG`.
    static func format(of copy: DuplicateCopy) -> String? {
        let name = copy.name
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...]
        return ext.isEmpty ? nil : ext.uppercased()
    }

    static func dimensions(of copy: DuplicateCopy) -> String? {
        guard let width = copy.pixelWidth, let height = copy.pixelHeight else { return nil }
        return "\(width) × \(height)"
    }

    /// Each copy's size at the list's precision, or — when that ties two copies whose bytes
    /// differ — in the shown unit with the fewest decimals (up to three) that tell every
    /// copy of a different size apart (`39.13 MB`, `39.10 MB`; DES-005A), and the bytes when
    /// three decimals still tie. The keeper rule compares bytes, so the tiles never show a
    /// tie the rule broke.
    static func distinguishingSizes(of copies: [DuplicateCopy]) -> [MediaAssetID: String] {
        let sized = copies.compactMap { copy in copy.byteSize.map { (copy.id, $0) } }
        let distinctBytes = Set(sized.map(\.1)).count
        func tellsApart(_ strings: [String]) -> Bool {
            Set(strings).count == distinctBytes
        }
        let plain = sized.map { ImportBarByteFormat.string(bytes: $0.1) }
        if tellsApart(plain) {
            return Dictionary(uniqueKeysWithValues: zip(sized.map(\.0), plain))
        }
        let largest = sized.map(\.1).max() ?? 0
        let (divisor, unit): (Double, String) = largest < 1_000_000 ? (1000, "KB")
            : largest < 100_000_000 ? (1_000_000, "MB") : (1_000_000_000, "GB")
        for decimals in 1 ... 3 {
            let strings = sized.map { String(format: "%.\(decimals)f \(unit)", Double($0.1) / divisor) }
            if tellsApart(strings) {
                return Dictionary(uniqueKeysWithValues: zip(sized.map(\.0), strings))
            }
        }
        return Dictionary(uniqueKeysWithValues: sized.map { ($0.0, "\($0.1.formatted(.number.grouping(.automatic))) bytes") })
    }
}

/// The Info pane's date format (`PhotoInfo`): abbreviated date, shortened time. Two birth
/// times in one minute get their seconds, so the tiles that differ are seen to differ.
nonisolated struct DuplicateDateFormat {
    let calendar: Calendar

    func string(for date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, calendar: calendar))
    }

    func string(for date: Date, among others: [Date]) -> String {
        let short = string(for: date)
        let collides = others.contains { $0 != date && string(for: $0) == short }
        guard collides else { return short }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .standard, calendar: calendar))
    }
}

/// The list's copies in reading order, by group: what ⇧-click ranges over and the arrow
/// keys walk. ← and → step through every copy across groups. Among photos, ↑ and ↓ move to
/// the copy at the same place in the previous or next group, or that group's last copy when
/// it is shorter; among an exact-copy group's names, which stack, they move a line.
nonisolated struct DuplicatesTileOrder: Equatable, Sendable {
    enum Direction: Equatable, Sendable {
        case left, right, up, down
    }

    struct Group: Equatable, Sendable {
        let copies: [MediaAssetID]
        /// The copies are lines under one another, not photos side by side.
        let stacked: Bool
    }

    let groups: [Group]

    init(groups: [Group]) {
        self.groups = groups
    }

    /// Groups of photos side by side.
    init(groups: [[MediaAssetID]]) {
        self.groups = groups.map { Group(copies: $0, stacked: false) }
    }

    var copies: [MediaAssetID] {
        groups.flatMap(\.copies)
    }

    /// Where `direction` goes from `current`; the first copy when nothing is current or
    /// `current` has left the list, nil at an edge.
    func target(from current: MediaAssetID?, _ direction: Direction) -> MediaAssetID? {
        guard let current,
              let groupIndex = groups.firstIndex(where: { $0.copies.contains(current) }),
              let index = groups[groupIndex].copies.firstIndex(of: current)
        else {
            return copies.first
        }
        let forward = direction == .right || direction == .down
        let alongTheCopies = direction == .left || direction == .right || groups[groupIndex].stacked
        if alongTheCopies {
            let flat = copies
            guard let position = flat.firstIndex(of: current) else { return nil }
            let next = forward ? position + 1 : position - 1
            return flat.indices.contains(next) ? flat[next] : nil
        }
        let nextGroup = forward ? groupIndex + 1 : groupIndex - 1
        guard groups.indices.contains(nextGroup), let last = groups[nextGroup].copies.indices.last else {
            return nil
        }
        // Into stacked names: the line nearest the photos it came from.
        if groups[nextGroup].stacked {
            return groups[nextGroup].copies[forward ? 0 : last]
        }
        return groups[nextGroup].copies[min(index, last)]
    }
}
