import Foundation

// Duplicates presentation (ADR 0042, `docs/design/duplicates.md`)
//
// Pure mappings from the published groups and the session's marks to what the list and
// the bar draw: every string on the surface is composed here, so the view is passive and
// the words are testable without a view. The one rule the spec states — the header says
// what the copies share, the tiles say what differs, and the fate and its reason are
// stated in words — is these mappings.

/// What the duplicates bar draws (DES-018): *what* (L1 over one L3 clause) · *the middle
/// zone* (the receipt of the last act, the groups that wait, or the legend) · *the act*.
nonisolated struct DuplicatesBarPresentation: Equatable, Sendable {
    enum Middle: Equatable, Sendable {
        /// What the last act moved, with Undo while it is the window's last change, over
        /// what the user does next to get the space.
        case receipt(line: String, detail: String, canUndo: Bool)
        /// `6 photos need your choice`, beside Show.
        case choices(String)
        /// What the marks mean, while nothing waits and nothing was just moved.
        case legend(String)
    }

    static let legend = "Checked copies stay. Dimmed copies go to the Trash; Undo brings them back."

    let primaryLine: String
    /// `178 extra copies to move · 53.2 GB`: what the act moves, the count the button
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
                "\(moving) extra \(moving == 1 ? "copy" : "copies") to move",
                ImportBarByteFormat.phrase(tally.bytesToMove),
            ].compactMap(\.self).joined(separator: " · ")
        } else {
            nil
        }
        let waiting = tally.needingChoice
        let middle: Middle = if let receipt {
            .receipt(
                line: [
                    "\(receipt.movedCount) extra \(receipt.movedCount == 1 ? "copy" : "copies") moved to the Trash",
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
            actionTitle: moving > 0 ? "Move \(moving) Extra \(moving == 1 ? "Copy" : "Copies") to Trash" : "Move Extra Copies to Trash",
            actionEnabled: moving > 0
        )
    }
}

/// A copy's fate as its tile states it: the checkbox, and a face drawn bright or dimmed
/// (DES-029: never colour alone).
nonisolated enum DuplicateCopyFate: Equatable, Sendable {
    /// Checked: the copy stays.
    case stays
    /// Unchecked: the copy moves with the act.
    case movesToTrash
    /// The group waits: the tile offers `Keep This Copy` instead of a checkbox, so the
    /// first click means keep, never un-keep.
    case choice
}

/// One tile of a group's strip: what differs about this copy, and its fate.
nonisolated struct DuplicateCopyTilePresentation: Equatable, Sendable, Identifiable {
    let id: MediaAssetID
    let kind: MediaKind?
    /// The part of the location the header did not state (L2).
    let primary: String
    /// The facts that differ within the group, then the copy's own marks (L3); nil when
    /// there is nothing to say, drawn as a blank line so every tile has one height.
    let secondary: String?
    let fate: DuplicateCopyFate
    /// Whether unchecking changes a mark: another copy stays kept, or the pair's other copy
    /// takes over. False only on the last kept copy of a group of three or more.
    let canUnkeep: Bool
    /// What VoiceOver reads: what differs, the fate, then the facts (DES-082).
    let accessibilityLabel: String
}

/// One group as the list draws it: the header (title, shared facts, decision), its
/// controls, and the strip of its copies — or, kept, one quiet header with Review Again.
nonisolated struct DuplicateGroupPresentation: Equatable, Sendable, Identifiable {
    let id: DuplicateGroupID
    /// `2 identical videos`, `3 files of one photo`; kept, `Kept both copies`.
    let title: String
    /// The facts every copy shares, with the shared location last; nil when none is known.
    let sharedFacts: String?
    /// What Otos will do and why, or what the user must choose; nil for a kept group,
    /// whose title says it.
    let decision: String?
    let showsCompare: Bool
    /// `Keep Both Copies` / `Keep All Copies`; nil when kept, where `Review Again` stands.
    let keepAllTitle: String?
    let isKept: Bool
    let tiles: [DuplicateCopyTilePresentation]
    /// What VoiceOver reads for the header: the date first, since it is what tells one group
    /// from the next (DES-082), then the title, the facts and the decision, with words for
    /// the glyphs.
    let accessibilityLabel: String

    static func map(
        _ group: DuplicateGroup,
        session: DuplicatesSession,
        calendar: Calendar = .current
    ) -> DuplicateGroupPresentation {
        let copies = group.copies
        let isSamePhoto = group.id.isSamePhoto
        let count = copies.count
        let noun = DuplicateItemNoun.covering(copies.map(\.kind))
        let location = DuplicateLocationSplit(copies: copies)
        let dates = DuplicateDateFormat(calendar: calendar)
        let facts = DuplicateSharedFacts(copies: copies)
        let kind = isSamePhoto ? "\(count) files of one photo" : "\(count) identical \(noun.string(count: count))"
        let taken = group.captureDate.map { "Captured \(dates.string(for: $0))" }

        var shared: [String] = []
        if let taken {
            shared.append(taken)
        }
        if group.isKept {
            shared.append(kind)
        }
        // The size first: it is the fact a reader uses; the format and pixels qualify it.
        // Off the header when the shown size hides a difference the tiles must show.
        if let size = facts.sharedSize, !facts.bytesDifferBelowShownPrecision {
            shared.append(count > 1 ? "\(size) each" : size)
        }
        if let format = facts.sharedFormat {
            shared.append(format)
        }
        if let dimensions = facts.sharedDimensions {
            shared.append(dimensions)
        }
        if let header = location.header {
            shared.append(header)
        }
        let sharedFacts = shared.isEmpty ? nil : shared.joined(separator: " · ")
        let spokenFacts = shared.filter { $0 != taken }.map(spoken)

        if group.isKept {
            let title = count == 2 ? "Kept both copies" : "Kept all \(count) copies"
            return DuplicateGroupPresentation(
                id: group.id, title: title, sharedFacts: sharedFacts, decision: nil,
                showsCompare: false, keepAllTitle: nil, isKept: true, tiles: [],
                accessibilityLabel: ([taken, title].compactMap(\.self) + spokenFacts).joined(separator: ", ")
            )
        }

        let kept = copies.filter { session.keeps($0.id, in: group) }.map(\.id)
        let decision = decision(for: group, session: session, keptCount: kept.count, isSamePhoto: isSamePhoto)
        let carries = session.carries(in: group)
        let sizes = DuplicateSharedFacts.distinguishingSizes(of: copies)
        let tiles = copies.map { copy -> DuplicateCopyTilePresentation in
            let fate: DuplicateCopyFate = if session.needsChoice(group) {
                .choice
            } else {
                session.keeps(copy.id, in: group) ? .stays : .movesToTrash
            }
            let carried = Set(carries.filter { $0.from == copy.id }.map(\.work))
            let tileFacts = tileFacts(
                copy, in: group, fate: fate, carried: carried, shared: facts, sizes: sizes, dates: dates
            )
            let primary = location.remainder(for: copy)
            let fateWords = switch fate {
            case .stays: "stays"
            case .movesToTrash: "moves to Trash"
            case .choice: "waiting for your choice"
            }
            return DuplicateCopyTilePresentation(
                id: copy.id,
                kind: copy.kind,
                primary: primary,
                secondary: tileFacts.isEmpty ? nil : tileFacts.joined(separator: " · "),
                fate: fate,
                canUnkeep: session.canUnkeep(copy.id, in: group),
                accessibilityLabel: ([primary, fateWords] + tileFacts).joined(separator: ", ")
            )
        }

        return DuplicateGroupPresentation(
            id: group.id,
            title: kind,
            sharedFacts: sharedFacts,
            decision: decision,
            // Compare is for pictures that differ; identical copies have one picture, which
            // Return and double-click open.
            showsCompare: isSamePhoto,
            keepAllTitle: count == 2 ? "Keep Both Copies" : "Keep All Copies",
            isKept: false,
            tiles: tiles,
            accessibilityLabel: ([taken, kind].compactMap(\.self) + spokenFacts + [decision]).joined(separator: ", ")
        )
    }

    /// Words for the glyphs a fact line draws, so VoiceOver reads facts rather than symbols.
    private static func spoken(_ fact: String) -> String {
        fact.replacingOccurrences(of: " × ", with: " by ").replacingOccurrences(of: " ▸ ", with: ", folder ")
    }

    /// The decision line (`docs/design/duplicates.md`, "The decision line"): one clause,
    /// computed from the default and the marks.
    private static func decision(
        for group: DuplicateGroup,
        session: DuplicatesSession,
        keptCount: Int,
        isSamePhoto: Bool
    ) -> String {
        let copyNoun = isSamePhoto ? "file" : "copy"
        let plural = isSamePhoto ? "files" : "copies"
        let spansLibraries = Set(group.copies.map(\.id.libraryRootPath)).count > 1
        switch group.default {
        case .kept:
            // Unreachable: a kept group's card has no decision line (`map` returns first).
            return "Kept every \(copyNoun)"
        case let .waits(conflict):
            if session.hasChosen(in: group) {
                return keptCount == 1 ? "Keeping the \(copyNoun) you chose" : "Keeping the \(plural) you chose"
            }
            let library = group.copies.first { $0.id.libraryRootPath == conflict.library }?.libraryDisplayName
            let place = spansLibraries && library != nil ? " in \(library!)" : ""
            switch conflict.kind {
            case .edits: return "Choose which edited \(copyNoun)\(place) to keep"
            case .companions: return "Choose which \(copyNoun) with an .xmp or .srt file\(place) to keep"
            case .choices: return "Choose the liked or the disliked \(copyNoun)\(place) to keep"
            }
        case let .keep(ids, reason):
            if session.hasChosen(in: group) {
                return keptCount == 1 ? "Keeping the \(copyNoun) you chose" : "Keeping the \(plural) you chose"
            }
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
                    let keptCopy = group.copies.first { ids.contains($0.id) }
                    return keptCopy?.mediaChoice == .disliked
                        ? "Keeping the \(copyNoun) you disliked"
                        : "Keeping the \(copyNoun) you liked"
                case .originalName: return "Keeping the original file name"
                case .earliestBirth: return "Keeping the older file"
                case .pathOrder:
                    // A tie-break is not a merit: say why it does not matter which.
                    let sharesFolder = Set(group.copies.map(\.folder)).count == 1
                    let order = sharesFolder ? "the first by name" : "the first by folder and name"
                    return isSamePhoto
                        ? "Nothing told them apart, so keeping \(order)"
                        : "Alike in every way, so keeping \(order)"
                }
            }
        }
    }

    /// The tile's L3: the facts that differ within the group, then the copy's own marks and
    /// where its work goes — onto the kept copy when the act carries it (`carried`), else
    /// to the Trash with the file.
    private static func tileFacts(
        _ copy: DuplicateCopy,
        in group: DuplicateGroup,
        fate: DuplicateCopyFate,
        carried: Set<DuplicateCarry.Work>,
        shared: DuplicateSharedFacts,
        sizes: [MediaAssetID: String],
        dates: DuplicateDateFormat
    ) -> [String] {
        var facts: [String] = []
        let copies = group.copies
        if shared.sharedFormat == nil, let format = DuplicateSharedFacts.format(of: copy) {
            facts.append(format)
        }
        if shared.sharedDimensions == nil, let dimensions = DuplicateSharedFacts.dimensions(of: copy) {
            facts.append(dimensions)
        }
        if shared.sharedSize == nil || shared.bytesDifferBelowShownPrecision, let size = sizes[copy.id] {
            facts.append(size)
        }
        let births = copies.compactMap(\.createdAt)
        if Set(births).count > 1, let born = copy.createdAt {
            facts.append("File created \(dates.string(for: born, among: births))")
        }
        // A fact that differs: not when every copy is the camera's own file, and stated for
        // the other copy too, so no row is left blank beside a fact about its sibling.
        let everyCopyOriginal = copies.allSatisfy { group.cameraOriginals.contains($0.id) }
        if !everyCopyOriginal, !group.cameraOriginals.isEmpty {
            facts.append(group.cameraOriginals.contains(copy.id) ? "Camera original" : "Not the camera original")
        }
        let leaving = fate == .movesToTrash
        switch copy.mediaChoice {
        case .liked: facts.append(carried.contains(.choice) ? "Liked. Its Like moves to the kept copy" : "Liked")
        case .disliked:
            facts.append(carried.contains(.choice) ? "Disliked. Its Dislike moves to the kept copy" : "Disliked")
        case .notRated: break
        }
        if copy.isEdited {
            if carried.contains(.edit) {
                facts.append("Edited in Otos. Its edits move to the kept copy")
            } else if leaving {
                facts.append("Edited in Otos. Its edits move to the Trash with it")
            } else {
                facts.append("Edited in Otos")
            }
        }
        if copy.hasCompanions {
            facts.append(leaving ? "Its .xmp or .srt file moves to the Trash with it" : "Has an .xmp or .srt file")
        }
        return facts
    }
}

/// The facts a group's copies share, at the precision the list shows (DES-005A), so a
/// fact goes in the header once or on every tile, never both.
nonisolated struct DuplicateSharedFacts: Equatable, Sendable {
    let sharedFormat: String?
    let sharedDimensions: String?
    let sharedSize: String?
    /// Every copy shows the same size, yet their bytes differ: the tiles show the sizes at
    /// the precision that tells them apart.
    let bytesDifferBelowShownPrecision: Bool

    init(copies: [DuplicateCopy]) {
        sharedFormat = Self.shared(copies.map(Self.format(of:)))
        sharedDimensions = Self.shared(copies.map(Self.dimensions(of:)))
        sharedSize = Self.shared(copies.map(Self.size(of:)))
        bytesDifferBelowShownPrecision = sharedSize != nil && Set(copies.map(\.byteSize)).count > 1
    }

    /// The one value every copy has; nil when any copy lacks it or they differ.
    private static func shared(_ values: [String?]) -> String? {
        let present = values.compactMap(\.self)
        guard present.count == values.count, let first = present.first, present.allSatisfy({ $0 == first }) else {
            return nil
        }
        return first
    }

    static func format(of copy: DuplicateCopy) -> String? {
        let format = copy.id.relativePath.fileExtension.uppercased()
        return format.isEmpty ? nil : format
    }

    static func dimensions(of copy: DuplicateCopy) -> String? {
        guard let width = copy.pixelWidth, let height = copy.pixelHeight else { return nil }
        return "\(width) × \(height)"
    }

    static func size(of copy: DuplicateCopy) -> String? {
        copy.byteSize.map(ImportBarByteFormat.string(bytes:))
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

/// Where a group's copies live, split into what they share (the header) and what each
/// tile must say. Within one library the header names the deepest folder every copy is in
/// or under, and each tile the rest of its path — the bare file name when the copy is in
/// that folder. Across libraries the header names nothing and each tile names its library,
/// folder and file.
nonisolated struct DuplicateLocationSplit: Equatable, Sendable {
    enum Shared: Equatable, Sendable {
        /// Every copy is in or under this folder of this library ("" for its top).
        case folder(library: String, folder: String)
        case nothing
    }

    let shared: Shared

    init(copies: [DuplicateCopy]) {
        let libraries = Set(copies.map(\.id.libraryRootPath))
        guard libraries.count == 1, let first = copies.first else {
            shared = .nothing
            return
        }
        var common = first.folder.split(separator: "/").map(String.init)
        for copy in copies.dropFirst() {
            let parts = copy.folder.split(separator: "/").map(String.init)
            let kept = zip(common, parts).prefix { $0 == $1 }.count
            common = Array(common.prefix(kept))
        }
        shared = .folder(library: first.libraryDisplayName, folder: common.joined(separator: "/"))
    }

    /// The header's location line; nil when the copies share no library.
    var header: String? {
        switch shared {
        case let .folder(library, folder): folder.isEmpty ? library : "\(library) ▸ \(folder)"
        case .nothing: nil
        }
    }

    /// What the tile says about this copy's location.
    func remainder(for copy: DuplicateCopy) -> String {
        switch shared {
        case let .folder(_, folder):
            let path = copy.id.relativePath.rawValue
            return folder.isEmpty ? path : String(path.dropFirst(folder.count + 1))
        case .nothing:
            return "\(copy.libraryDisplayName) ▸ \(copy.id.relativePath.rawValue)"
        }
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

/// A library pair's summary row.
nonisolated struct DuplicateLibraryPairPresentation: Equatable, Sendable {
    let pair: DuplicateLibraryPair
    let firstName: String
    let secondName: String
    let title: String
    /// What the pair's marks will do: nothing, or one library's copies moving; or that the
    /// user kept both libraries' copies.
    let state: String
    let isKept: Bool

    static func map(
        _ pair: DuplicateLibraryPair,
        groups: [DuplicateGroup],
        session: DuplicatesSession
    ) -> DuplicateLibraryPairPresentation {
        let copies = groups.flatMap(\.copies)
        func name(of library: LibraryRootPath) -> String {
            copies.first { $0.id.libraryRootPath == library }?.libraryDisplayName ?? library.displayName
        }
        let firstName = name(of: pair.first)
        let secondName = name(of: pair.second)
        let noun = DuplicateItemNoun.covering(copies.map(\.kind)).string(count: groups.count)
        let title = "\(firstName) and \(secondName) share \(groups.count) \(noun)"
        let isKept = groups.allSatisfy(\.isKept)
        var movingByLibrary: [LibraryRootPath: Int] = [:]
        for group in groups {
            for id in session.copiesToMove(in: group) {
                movingByLibrary[id.libraryRootPath, default: 0] += 1
            }
        }
        let state: String = if isKept {
            "You kept both libraries' copies"
        } else if movingByLibrary.isEmpty {
            "Each library keeps its own copy. Nothing moves."
        } else {
            movingByLibrary
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { library, count in
                    let name = library == pair.first ? firstName : secondName
                    return "\(count) \(count == 1 ? "copy" : "copies") in \(name) \(count == 1 ? "moves" : "move") to the Trash"
                }
                .joined(separator: ". ")
        }
        return DuplicateLibraryPairPresentation(
            pair: pair, firstName: firstName, secondName: secondName, title: title, state: state, isKept: isKept
        )
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
