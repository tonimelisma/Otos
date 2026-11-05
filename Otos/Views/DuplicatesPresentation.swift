import Foundation

// Duplicates presentation (ADR 0042, `docs/design/duplicates.md`)
//
// Pure mappings from the published groups and the session's picks and rules to what the
// list and the bar draw: a rule row for each folder that holds duplicates, then each group
// as its date and why it keeps what it keeps over its copies' photos, each tagged Keep or
// Trash. Every string on the surface is composed here, so the view is passive and the
// words are testable without a view.

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

    static let legend = "Click a photo to keep it, or set a rule for a whole folder above."

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

/// One rule row: a folder (or two) that holds duplicates, how many, and the rule for all of
/// them as a segmented choice.
nonisolated struct DuplicateFolderRulePresentation: Equatable, Sendable, Identifiable {
    struct Option: Equatable, Sendable {
        let rule: DuplicateFolderRule
        let title: String
    }

    let folderSet: DuplicateFolderSet
    /// `2026/08 and Imports/Aug 2026`, or `2026/10`.
    let title: String
    /// `412 photos in both`, `38 photos saved twice in this folder`.
    let detail: String
    /// `Keep the copies in`, `Keep the`.
    let prompt: String
    let options: [Option]
    let selected: DuplicateFolderRule
    var id: DuplicateFolderSet {
        folderSet
    }

    static func map(
        _ summary: DuplicateFolderSetSummary,
        rule: DuplicateFolderRule?,
        noun: DuplicateItemNoun,
        withLibrary: Bool
    ) -> DuplicateFolderRulePresentation {
        let folders = summary.folderSet.folders
        let names = folders.map { DuplicateFolderName.string($0, withLibrary: withLibrary) }
        let count = summary.groupCount
        let things = "\(count) \(noun.string(count: count))"
        if folders.count == 2 {
            let spansLibraries = folders[0].library != folders[1].library
            return DuplicateFolderRulePresentation(
                folderSet: summary.folderSet,
                title: "\(names[0]) and \(names[1])",
                detail: "\(things) in both",
                prompt: "Keep the copies in",
                options: [
                    Option(rule: .folder(folders[0]), title: names[0]),
                    Option(rule: .folder(folders[1]), title: names[1]),
                    // Across libraries the keeper rule keeps each library's copy.
                    Option(rule: .automatic, title: spansLibraries ? "Both" : "Otos decides"),
                ],
                selected: rule ?? .automatic
            )
        }
        return DuplicateFolderRulePresentation(
            folderSet: summary.folderSet,
            title: names.first ?? "",
            detail: "\(things) saved twice in this folder",
            prompt: "Keep the",
            options: [
                Option(rule: .automatic, title: "Best copy"),
                Option(rule: .originalName, title: "Original name"),
                Option(rule: .oldest, title: "Oldest"),
                Option(rule: .largest, title: "Largest"),
            ],
            selected: rule ?? .automatic
        )
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

/// One copy's photo: its fate, its size over the picture, and the rest in its tooltip.
nonisolated struct DuplicateCopyTilePresentation: Equatable, Sendable, Identifiable {
    let id: MediaAssetID
    let kind: MediaKind?
    let fate: DuplicateCopyFate
    /// The size, at the precision that tells this group's copies apart (DES-005A).
    let size: String?
    let choice: MediaChoice
    /// Where it is and what it is, for the tooltip.
    let help: String
    /// What VoiceOver reads: the file, its fate, then the facts (DES-082).
    let accessibilityLabel: String
}

/// One group as the list draws it: its date and why it keeps what it keeps, over its
/// photos; kept, `Kept all N copies` with Review Again.
nonisolated struct DuplicateGroupPresentation: Equatable, Sendable, Identifiable {
    let id: DuplicateGroupID
    /// The capture date: `October 4, 2026`.
    let title: String
    /// `2026/10 · Keeping the original name`, `You chose this one`, or what to choose.
    let reason: String
    let isKept: Bool
    let tiles: [DuplicateCopyTilePresentation]
    let accessibilityLabel: String

    static func map(
        _ group: DuplicateGroup,
        session: DuplicatesSession,
        withLibrary: Bool = false,
        calendar: Calendar = .current
    ) -> DuplicateGroupPresentation {
        let copies = group.copies
        let count = copies.count
        let title = group.captureDate.map {
            $0.formatted(Date.FormatStyle(date: .long, time: .omitted, calendar: calendar))
        } ?? "No Date"
        if group.isKept {
            let note = count == 2 ? "Kept both copies" : "Kept all \(count) copies"
            return DuplicateGroupPresentation(
                id: group.id, title: title, reason: note, isKept: true, tiles: [],
                accessibilityLabel: "\(title), \(note)"
            )
        }
        let resolution = session.resolution(of: group)
        let folders = DuplicateFolderSet(group).folders
        let place = folders.count == 1 ? DuplicateFolderName.string(folders[0], withLibrary: withLibrary) : nil
        let why: String = if let resolution {
            reasonText(resolution, in: group, withLibrary: withLibrary)
        } else if case let .waits(conflict) = group.default {
            waitingText(conflict)
        } else {
            ""
        }
        let reason = [place, why].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " · ")

        let dates = DuplicateDateFormat(calendar: calendar)
        let sizes = DuplicateTileFacts.distinguishingSizes(of: copies)
        let births = copies.compactMap(\.createdAt)
        let tiles = copies.map { copy -> DuplicateCopyTilePresentation in
            let fate: DuplicateCopyFate = if let resolution {
                resolution.keep.contains(copy.id) ? .keep : .trash
            } else {
                .undecided
            }
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
            if group.cameraOriginals.contains(copy.id), group.cameraOriginals.count < count {
                facts.append("Camera original")
            }
            switch copy.mediaChoice {
            case .liked: facts.append("Liked")
            case .disliked: facts.append("Disliked")
            case .notRated: break
            }
            if copy.isEdited {
                facts.append("Edited in Otos")
            }
            if copy.hasCompanions {
                facts.append("Has an .xmp or .srt file")
            }
            let location = "\(copy.libraryDisplayName) ▸ \(copy.id.relativePath.rawValue)"
            let fateWords = switch fate {
            case .keep: "keep"
            case .trash: "goes to the Trash"
            case .undecided: "not chosen yet"
            }
            return DuplicateCopyTilePresentation(
                id: copy.id,
                kind: copy.kind,
                fate: fate,
                size: sizes[copy.id],
                choice: copy.mediaChoice,
                help: ([location] + [facts.joined(separator: " · ")].filter { !$0.isEmpty }).joined(separator: "\n"),
                accessibilityLabel: ([copy.id.relativePath.fileName, fateWords] + facts).joined(separator: ", ")
            )
        }
        return DuplicateGroupPresentation(
            id: group.id,
            title: title,
            reason: reason,
            isKept: false,
            tiles: tiles,
            accessibilityLabel: [title, reason].filter { !$0.isEmpty }.joined(separator: ", ")
        )
    }

    /// Why the group keeps what it keeps, in words: the click, the folder's rule, or the
    /// keeper rule's deciding criterion.
    private static func reasonText(_ resolution: DuplicateResolution, in group: DuplicateGroup, withLibrary: Bool) -> String {
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

nonisolated enum DuplicateTileFacts {
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
/// keys walk. ← and → step through every copy across groups; ↑ and ↓ move to the copy at
/// the same place in the previous or next group, or that group's last copy when it is
/// shorter.
nonisolated struct DuplicatesTileOrder: Equatable, Sendable {
    enum Direction: Equatable, Sendable {
        case left, right, up, down
    }

    let groups: [[MediaAssetID]]

    var copies: [MediaAssetID] {
        groups.flatMap(\.self)
    }

    /// Where `direction` goes from `current`; the first copy when nothing is current or
    /// `current` has left the list, nil at an edge.
    func target(from current: MediaAssetID?, _ direction: Direction) -> MediaAssetID? {
        guard let current,
              let groupIndex = groups.firstIndex(where: { $0.contains(current) }),
              let index = groups[groupIndex].firstIndex(of: current)
        else {
            return copies.first
        }
        switch direction {
        case .left, .right:
            let flat = copies
            guard let position = flat.firstIndex(of: current) else { return nil }
            let next = direction == .right ? position + 1 : position - 1
            return flat.indices.contains(next) ? flat[next] : nil
        case .up, .down:
            let nextGroup = direction == .down ? groupIndex + 1 : groupIndex - 1
            guard groups.indices.contains(nextGroup), let last = groups[nextGroup].indices.last else {
                return nil
            }
            return groups[nextGroup][min(index, last)]
        }
    }
}
