import Foundation

/// Small value carriers used while `CatalogProjection` builds a window state.
///
/// These are kept outside the actor file so the actor's source stays focused on
/// publication ownership rather than local tuple plumbing.
nonisolated struct CatalogProjectionWindowStateParts {
    let title: String
    let libraries: [CatalogLibraryState]
    let removableSources: [CatalogLibraryState]
    let importBatches: [ImportBatchSummary]
    let resolvedDescriptor: CatalogQueryDescriptor
    let queryGeneration: UInt64
    let scopedAssetIDs: [MediaAssetID]
    /// DES-069 day-grouping key, index-paired with `scopedAssetIDs`; empty
    /// under any sort but `.bestDate`. See `CatalogMediaGridState.dayBuckets`.
    let scopedDayBuckets: [Date?]
    let filterOptions: CatalogFilterOptions
    let mediaEmptyState: CatalogMediaEmptyState?
    /// The Places map's content; nil for every other scope (ADR 0040).
    let map: CatalogMapState?
    /// On This Day's years; nil for every other scope (ADR 0049).
    let onThisDay: CatalogOnThisDayState?
    /// How the scoped order shows its stacks (ADR 0052).
    var gridStacks: CatalogGridStacks = .empty
}

/// How many times the Store has said each kind of fact changed (`CatalogChangedFacts`),
/// counted by the projection as each change arrives. A read records the counts it started
/// from, and a later pass repeats it only when a count it depends on has moved since: a
/// revision per kind, never a flag a finished read clears (ADR 0032).
nonisolated struct CatalogFactRevisions: Equatable, Sendable {
    private var counts = [UInt64](repeating: 0, count: CatalogChangedFacts.bitCount)

    mutating func record(_ facts: CatalogChangedFacts) {
        for bit in 0 ..< CatalogChangedFacts.bitCount where facts.rawValue & (1 << bit) != 0 {
            counts[bit] &+= 1
        }
    }

    /// Whether any kind in `facts` changed between `earlier` and these counts.
    func moved(_ facts: CatalogChangedFacts, since earlier: CatalogFactRevisions) -> Bool {
        (0 ..< CatalogChangedFacts.bitCount).contains { bit in
            facts.rawValue & (1 << bit) != 0 && counts[bit] != earlier.counts[bit]
        }
    }
}

nonisolated extension CatalogChangedFacts {
    /// What the ordered-asset read for `descriptor` depends on: which rows are shown, their
    /// dates, kinds and formats, how they group and the user's choices, always; their places where the scope or
    /// the filter is by place; faces where it is by person or by likeness; copies in the
    /// Duplicates rows; and On This Day's labels, with the thumbnails they were read from, there. Search is applied after the read,
    /// from the index's own answer, so it is not among them.
    static func orderInputs(of descriptor: CatalogQueryDescriptor) -> CatalogChangedFacts {
        var facts: CatalogChangedFacts = [.membership, .captureDate, .kindAndFormat, .grouping, .choices]
        facts.formUnion(scopeInputs(of: descriptor.scope))
        if descriptor.filter.places != nil {
            facts.formUnion([.location, .placeNames])
        }
        if descriptor.filter.filtersPeople || descriptor.effectiveSort.field == .likeness {
            facts.insert(.faces)
        }
        return facts
    }

    /// What the stacks (ADR 0052) are built from: which rows exist, the user's choices and
    /// stack keys, and the facts of the stills that are or can become stack candidates
    /// (`stacks`). A capture date, kind or grouping moving on a row no stack can hold — an
    /// Immich still alone in its asset's folder — leaves them standing.
    static let stackInputs: CatalogChangedFacts = [.membership, .choices, .stacks]

    /// What the import batches' photo counts are built from: which rows exist and carry a
    /// batch, the Live Photo identifiers that hide a movie, and what decides the stacks that
    /// fold a batch's files (ADR 0052). Which file a stack shows changes no count.
    static let importBatchInputs: CatalogChangedFacts = [.membership, .grouping, .stacks]

    /// What the Store's answer to a query's facts (`CatalogStore.searchFactMatches`) reads:
    /// which rows exist on which reachable roots, their capture dates, their locations, and
    /// who their faces are.
    static let searchFactInputs: CatalogChangedFacts = [.membership, .captureDate, .location, .faces]

    /// What the filter's options for the sidebar row `row` depend on: which rows the row
    /// holds, their kinds and formats, and the places named for them. Not which file is a
    /// copy: the options are read with every copy (`CatalogStore.filterOptions`), and 227 of
    /// the 277 changes of the owner's tour named copies
    /// (`docs/research/2026-11-16-window-reads-owner-catalog.md`).
    static func filterOptionsInputs(of row: SidebarSelection) -> CatalogChangedFacts {
        var facts: CatalogChangedFacts = [.membership, .kindAndFormat, .grouping, .location, .placeNames]
        facts.formUnion(rowInputs(of: row))
        return facts
    }

    /// What decides which rows a scope holds, beyond the rows themselves. A scope that shows
    /// one copy of identical copies (ADR 0054) depends on which files are copies.
    private static func scopeInputs(of scope: SidebarSelection) -> CatalogChangedFacts {
        var facts = rowInputs(of: scope)
        if scope.showsOneCopy {
            facts.insert(.copies)
        }
        return facts
    }

    /// What decides which rows a scope holds before one copy is chosen of identical copies.
    private static func rowInputs(of scope: SidebarSelection) -> CatalogChangedFacts {
        switch scope {
        case .allMedia, .library, .importBatch, .allImports:
            []
        case .places, .mapArea, .mapStack:
            [.location, .placeNames]
        case .onThisDay:
            // Its labels count only while the thumbnail they were read from is the row's
            // (`OnThisDayPicks.leftOutSQL`), so a new thumbnail can bring a photo back.
            [.captureDate, .grouping, .choices, .searchReadings, .images]
        case .duplicates, .duplicateGroup:
            [.copies, .duplicateFacts]
        case .people, .person:
            .faces
        }
    }
}

/// The last answer of each of the window's catalog reads, with what it was read for and the
/// fact revisions it started from (ADR 0005). A pass reuses an answer while its inputs are
/// what they were and no kind of fact it depends on has changed, and reads it again
/// otherwise; nothing else decides it. A pass takes these as a value and returns the ones it
/// built with its state, which the projection keeps only once that state is published.
///
/// The held set, each keyed by what it was read for and the facts it is read from:
/// - the ordered assets, one per `Slot` (All Media's, and the last other scope's);
/// - the stack collapse, one per `Slot`;
/// - the whole-roots stacks (`stackInputs`);
/// - the filter's options, for one sidebar row;
/// - the import batches, for one count scope (`importBatchInputs`);
/// - the place-name languages (`placeNameLanguageInputs`);
/// - the shown search's answer, keyed also by the index's revision.
/// `CatalogProjectionReuse` names which of them a pass answered from (`reused=`).
nonisolated struct CatalogProjectionReads: Sendable {
    struct Order: Sendable {
        let descriptor: CatalogQueryDescriptor
        let availableLibraryPaths: Set<LibraryRootPath>
        let revisions: CatalogFactRevisions
        /// The Store change the read started after (`CatalogChangeLog.sequence`): the changes
        /// after it are what a keyed re-read reads again (`keyedRows(since:in:for:)`).
        var sequence: UInt64 = 0
        let answer: CatalogOrderedAssets
    }

    struct FilterOptions: Sendable {
        let row: SidebarSelection
        let availableLibraryPaths: Set<LibraryRootPath>
        let placeNameLanguages: Set<PlaceNameLanguage>
        var revisions: CatalogFactRevisions
        var answer: CatalogFilterOptions
        /// What each row gave the answer, and the Store change the read it holds started after
        /// (`CatalogChangeLog.sequence`): what a keyed re-read patches in place
        /// (`CatalogChangeLog.keyedOptionRows`). Nil for options a test's reader gave.
        var tally: CatalogFilterOptionTally?
        var sequence: UInt64 = 0
    }

    /// The last stack collapse (ADR 0052), a pure step over the scoped order: the same
    /// order, stacks and expansions collapse the same way.
    struct Collapse: Sendable {
        let ids: [MediaAssetID]
        let dayBuckets: [Date?]
        let coordinates: [PlaceCoordinate]
        let stacks: CatalogStacks
        let expanded: Set<PhotoStackID>
        let result: PhotoStackCollapse.Result
    }

    /// The stacks the last order read built (ADR 0052), held for the next order read over
    /// the same roots while nothing they are built from moved (`CatalogChangedFacts.stackInputs`):
    /// reading every candidate of the fixed libraries is the larger half of an order read.
    struct Stacks: Sendable {
        let built: PhotoStackSQL.Built
        let revisions: CatalogFactRevisions
    }

    /// The import batches the last pass read, counted for the batches the selection counts
    /// (`ImportBatchListing.counting(for:)`), held for the same batches while nothing their counts
    /// are built from moved (`CatalogChangedFacts.importBatchInputs`).
    struct ImportBatches: Sendable {
        let counting: ImportBatchCounting
        let answer: [ImportBatchSummary]
        let revisions: CatalogFactRevisions
    }

    /// The last search answer (ADR 0048): what the index matched for one query over one scope.
    /// The index says when what it answers from moved (`PhotoSearchIndex.revision`, carried by
    /// the answer); the Store's fact matches move with the kinds of fact they read
    /// (`CatalogChangedFacts.searchFactInputs`), and only when the query names a fact; the date
    /// is in `facts`, resolved for the pass's now.
    struct Search: Sendable {
        let index: PhotoSearchIndex
        let facts: SearchFactFilter?
        let scope: [MediaAssetID]
        let revisions: CatalogFactRevisions
        let matches: SearchMatches
    }

    /// The languages the map's cells are named in, held with the revisions they were read at.
    struct PlaceNameLanguages: Sendable {
        let answer: Set<PlaceNameLanguage>
        let revisions: CatalogFactRevisions
    }

    /// Where a scope's order and collapse are held. All Media, the scope a return to the
    /// library lands on, keeps its own answers while the user is anywhere else; every other
    /// scope shares one slot, the last one read. So at most two orders and two unsearched
    /// collapses are held: All Media's (at owner scale about 165,000 IDs, some 20 MB with its
    /// collapse, most of it shared with the published window while All Media is shown) and one
    /// more; a slot also holds its last search's collapse, as large as the search's matches.
    enum Slot: Hashable, Sendable {
        case allMedia
        case other

        init(_ scope: SidebarSelection) {
            self = scope == .allMedia ? .allMedia : .other
        }
    }

    /// The last order read in each slot.
    var orders: [Slot: Order] = [:]
    var filterOptions: FilterOptions?
    /// The last collapse made in each slot, searched and not.
    var collapses: [CollapseKey: Collapse] = [:]

    /// Where a collapse is held: its scope's slot, and whether a search narrowed the order it
    /// collapsed. A search's collapse is held beside the unsearched one, so clearing the
    /// search shows the collapse the scope had (at owner scale 0.3–0.5 s to make again).
    struct CollapseKey: Hashable, Sendable {
        let slot: Slot
        let searched: Bool

        init(_ descriptor: CatalogQueryDescriptor) {
            slot = Slot(descriptor.scope)
            searched = descriptor.effectiveSearch != nil
        }
    }

    var stacks: Stacks?
    var importBatches: ImportBatches?
    var placeNameLanguages: PlaceNameLanguages?
    var search: Search?

    /// No answer yet: every read is made.
    static let none = CatalogProjectionReads()

    /// What the place-name languages are read from.
    static let placeNameLanguageInputs: CatalogChangedFacts = .placeNames

    /// The last order, when it answers `descriptor` over `paths` and nothing it depends on
    /// changed after `revisions`.
    func order(
        for descriptor: CatalogQueryDescriptor,
        availableLibraryPaths paths: Set<LibraryRootPath>,
        at revisions: CatalogFactRevisions
    ) -> CatalogOrderedAssets? {
        guard let order = heldOrder(for: descriptor, availableLibraryPaths: paths),
              !revisions.moved(.orderInputs(of: descriptor), since: order.revisions)
        else {
            return nil
        }
        return order.answer
    }

    /// The last order read for `descriptor` over `paths`, whether or not a fact it depends on
    /// moved since: what a scope the user returns to shows while it is read again. A search is
    /// applied after the order is read, from the index's answer, so the order read for the
    /// descriptor without its search answers it: typing a search, changing it and clearing it
    /// read no order (on the owner's catalog each read 164,762 rows again).
    func heldOrder(
        for descriptor: CatalogQueryDescriptor,
        availableLibraryPaths paths: Set<LibraryRootPath>
    ) -> Order? {
        guard let order = orders[Slot(descriptor.scope)], order.descriptor.unsearched == descriptor.unsearched,
              order.availableLibraryPaths == paths
        else {
            return nil
        }
        return order
    }

    /// The last place-name languages, when nothing they are read from moved after
    /// `revisions`, or, with `current` false, whatever they were.
    func placeNameLanguages(at revisions: CatalogFactRevisions, current: Bool) -> Set<PlaceNameLanguage>? {
        guard let placeNameLanguages,
              !current || !revisions.moved(Self.placeNameLanguageInputs, since: placeNameLanguages.revisions)
        else {
            return nil
        }
        return placeNameLanguages.answer
    }

    /// The last search answer, when it answers `encoding` with `facts` over `scope` from the
    /// index `index` at `indexRevision`, and, for a query naming facts, no kind of fact the
    /// Store's matches read changed after `revisions`.
    func search(
        _ encoding: SearchQueryEncoding,
        facts: SearchFactFilter?,
        among scope: [MediaAssetID],
        index: PhotoSearchIndex,
        indexRevision: UInt64,
        at revisions: CatalogFactRevisions
    ) -> Search? {
        guard let search, search.index === index, search.matches.indexRevision == indexRevision,
              search.matches.encoding == encoding, search.facts == facts,
              facts == nil || !revisions.moved(CatalogChangedFacts.searchFactInputs, since: search.revisions),
              search.scope == scope
        else {
            return nil
        }
        return search
    }

    /// The last import batches, when they were counted for `counting` and nothing their
    /// counts are built from moved after `revisions`, or, with `current` false, whatever they
    /// were.
    func importBatches(
        counting: ImportBatchCounting,
        at revisions: CatalogFactRevisions,
        current: Bool
    ) -> [ImportBatchSummary]? {
        guard let importBatches, importBatches.counting == counting,
              !current || !revisions.moved(CatalogChangedFacts.importBatchInputs, since: importBatches.revisions)
        else {
            return nil
        }
        return importBatches.answer
    }

    /// The last stacks, while nothing they are built from changed after `revisions`. The
    /// order read uses them only over the roots they were built for.
    func stacks(at revisions: CatalogFactRevisions) -> PhotoStackSQL.Built? {
        guard let stacks, !revisions.moved(CatalogChangedFacts.stackInputs, since: stacks.revisions) else {
            return nil
        }
        return stacks.built
    }

    /// The last options read for `row` over `paths` in `languages`, whether or not a fact they
    /// depend on moved since: what the window shows while the options are read again.
    func lastFilterOptions(
        for row: SidebarSelection,
        availableLibraryPaths paths: Set<LibraryRootPath>,
        placeNameLanguages languages: Set<PlaceNameLanguage>
    ) -> CatalogFilterOptions? {
        guard let filterOptions, filterOptions.row == row, filterOptions.availableLibraryPaths == paths,
              filterOptions.placeNameLanguages == languages
        else {
            return nil
        }
        return filterOptions.answer
    }

    /// The last options, when they answer `row` over `paths` in `languages` and nothing they
    /// depend on changed after `revisions`.
    func filterOptions(
        for row: SidebarSelection,
        availableLibraryPaths paths: Set<LibraryRootPath>,
        placeNameLanguages languages: Set<PlaceNameLanguage>,
        at revisions: CatalogFactRevisions
    ) -> CatalogFilterOptions? {
        guard let filterOptions, filterOptions.row == row, filterOptions.availableLibraryPaths == paths,
              filterOptions.placeNameLanguages == languages,
              !revisions.moved(.filterOptionsInputs(of: row), since: filterOptions.revisions)
        else {
            return nil
        }
        return filterOptions.answer
    }
}

/// Which of its reads a pass answered from the last answer instead of reading again.
/// Logged with the pass (`reused=`).
nonisolated struct CatalogProjectionReuse: Equatable {
    var order = false
    var filterOptions = false
    var collapse = false
    /// The order was read again over the stacks the last read built.
    var stacks = false
    /// The index was not asked: the last search answer still held.
    var search = false
    /// The import batches the sidebar counts came from the last read.
    var importBatches = false
    /// The languages the map's cells are named in came from the last read.
    var placeNameLanguages = false
    /// The pass answered from what it held although a fact it depends on moved since: the
    /// first pass of a scope the user returned to, which the next pass reads again.
    var held = false
    /// The order was the held one with the rows the Store's changes named read again.
    var keyed = false

    var diagnosticDescription: String {
        let reused = [
            ("order", order), ("filterOptions", filterOptions), ("collapse", collapse), ("stacks", stacks), ("search", search),
            ("importBatches", importBatches), ("placeNameLanguages", placeNameLanguages), ("held", held),
            ("keyed", keyed),
        ]
        .filter(\.1).map(\.0)
        return reused.isEmpty ? "none" : reused.joined(separator: ",")
    }
}

/// Everything a window state is derived from once the Store has been read. Production
/// reads these facts from the Store; the one-shot test entry supplies them directly.
nonisolated struct CatalogProjectionBuildFacts {
    /// Display-ordered roots (`CatalogWindowPolicy.sortLibraries`).
    let allRoots: [CatalogLibraryState]
    let request: CatalogQueryRequest
    let resolvedDescriptor: CatalogQueryDescriptor
    let importBatches: [ImportBatchSummary]
    let orderedAssetIDs: [MediaAssetID]
    let availableLibraryPaths: Set<LibraryRootPath>
    var scopedAssetIDs: [MediaAssetID]
    var scopedDayBuckets: [Date?]
    /// Each scoped ID's location, index-paired; empty unless the scope requires one.
    var scopedCoordinates: [PlaceCoordinate]
    let orderQueryMs: Int
    /// Set when a search answered for the scope, or could not.
    var search: CatalogSearchOutcome?
    /// The stacks read with the order (ADR 0052), and how the scoped order shows them once
    /// collapsed.
    var stacks: CatalogStacks = .empty
    var gridStacks: CatalogGridStacks = .empty
}

/// What a search made of a scope, for the empty state (ADR 0048). `unsearchedScopeCount` is
/// the scope's items before the search: a scope that holds none keeps its own empty state.
nonisolated enum CatalogSearchOutcome: Equatable {
    /// The query was read and narrowed the scope to its matches. `stillReadingCount`: items
    /// whose thumbnails search has not read yet, counted only when nothing matched.
    case read(unsearchedScopeCount: Int, stillReadingCount: Int)
    /// The query's first reading narrowed the scope to its matches while the full reading is
    /// read (`SearchQueryStatus.refining`): shown, and still searching.
    case refining(unsearchedScopeCount: Int)
    /// The query could not be read: the scope shows none of its items rather than all of
    /// them unsearched.
    case failed(unsearchedScopeCount: Int)

    var unsearchedScopeCount: Int {
        switch self {
        case let .read(count, _), let .refining(count), let .failed(count):
            count
        }
    }

    var phase: CatalogSearchPhase {
        switch self {
        case .read: .read
        case .refining: .refining
        case .failed: .failed
        }
    }
}

/// What a build made: the window state, or nothing yet because the shown search's query is
/// still being read (`SearchQueryReader`), whose report rings the loop when it ends.
nonisolated enum CatalogProjectionBuild {
    /// The state, what the build cost, the reads it was built from, for the next pass, and the
    /// filter's options when they are owed: the state carries the last options read for its
    /// row, or none, and the pass reads these after it publishes (`OwedFilterOptions`).
    case built(CatalogWindowState, CatalogProjectionBuildMetrics, CatalogProjectionReads, OwedFilterOptions?)
    case queryBeingRead
}

/// The filter's options a published window still owes: the row they are read for and what
/// the read is keyed by (ADR 0005). Neither the window nor the next pass waits for them: the
/// pass asks for them after it publishes, and their own read republishes the window with them.
nonisolated struct OwedFilterOptions: Equatable, Sendable {
    let row: SidebarSelection
    let availableLibraryPaths: Set<LibraryRootPath>
    let placeNameLanguages: Set<PlaceNameLanguage>
    let revisions: CatalogFactRevisions
}

/// The catalog changes the projection knows of, numbered, with the rows each named (ADR 0005,
/// "Keyed re-reads"): what tells a pass which rows of a held order a change can have moved.
/// Bounded: a held order read before the oldest change kept is read again whole.
///
/// It also counts every change by kind (`revisions`), which says whether a held read still
/// answers. One `record` keeps both, so a kind that moved is always a kept change that names
/// the rows it moved. A write the window learns of from its own act (a Move to Trash's mark,
/// a Put Back, a choice) before the Store's change for it arrives is recorded here too: a
/// revision no entry explained would read as a change of no rows, and a keyed re-read would
/// answer with the held order, the write missing from it.
nonisolated struct CatalogChangeLog: Sendable {
    struct Entry: Sendable {
        let sequence: UInt64
        let facts: CatalogChangedFacts
        let rows: CatalogChangedRows
    }

    /// The changes kept, oldest first.
    private(set) var entries: [Entry] = []
    /// The number of the newest change heard.
    private(set) var sequence: UInt64 = 0
    /// Every change after this one is kept.
    private(set) var keptAfter: UInt64 = 0

    /// How many changes are kept: a sync's metadata arrives in batches of a few dozen rows,
    /// a pass at most a second apart, so a held order is behind by a handful of changes.
    static let capacity = 256
    /// The most rows a keyed re-read reads: past it, a full read costs no more.
    static let rowCapacity = 5000

    /// How many times each kind of fact changed, by every change recorded.
    private(set) var revisions = CatalogFactRevisions()

    mutating func record(_ facts: CatalogChangedFacts, rows: CatalogChangedRows) {
        revisions.record(facts)
        sequence &+= 1
        entries.append(Entry(sequence: sequence, facts: facts, rows: rows))
        if entries.count > Self.capacity {
            let dropped = entries.count - Self.capacity
            keptAfter = entries[dropped - 1].sequence
            entries.removeFirst(dropped)
        }
    }

    /// What a keyed re-read of the options of `row`, tallied after change `since`, reads again
    /// (`CatalogFilterOptionTally`): the named rows of every later change that moved only rows'
    /// locations or file types, and whether a change moved the cells' names. A change that
    /// names no row (`.none`) moved none. Nil when a whole read is owed: a change that moved
    /// which rows the row holds or how they group, one whose rows are unnamed, more rows than
    /// `rowCapacity`, or changes no longer kept.
    func keyedOptionRows(since: UInt64, for row: SidebarSelection) -> (rows: Set<MediaAssetID>, names: Bool)? {
        guard since >= keptAfter else {
            return nil
        }
        let inputs = CatalogChangedFacts.filterOptionsInputs(of: row)
        var rows = Set<MediaAssetID>()
        var names = false
        for entry in entries where entry.sequence > since {
            var moved = entry.facts.intersection(inputs)
            if moved.contains(.placeNames) {
                names = true
                moved.remove(.placeNames)
            }
            guard !moved.isEmpty else {
                continue
            }
            guard moved.isSubset(of: [.location, .kindAndFormat]) else {
                return nil
            }
            switch entry.rows {
            case let .named(named):
                rows.formUnion(named.ids)
            case .none:
                continue
            case .unnamed:
                return nil
            }
            if rows.count > Self.rowCapacity {
                return nil
            }
        }
        return (rows, names)
    }

    /// The rows a keyed re-read of an order for `descriptor`, read after change `since`, reads
    /// again: the named rows of every later change that moved a fact the order depends on,
    /// when every such change moved only capture dates and named its rows. Nil when a full
    /// read is owed: a change that moved another fact the order depends on (which rows are
    /// shown, kinds, grouping, choices, a stack), one that named no rows, more rows than
    /// `rowCapacity`, or changes no longer kept.
    func keyedRows(since: UInt64, for descriptor: CatalogQueryDescriptor) -> Set<MediaAssetID>? {
        guard since >= keptAfter else {
            return nil
        }
        let inputs = CatalogChangedFacts.orderInputs(of: descriptor).union(CatalogChangedFacts.stackInputs)
        var rows = Set<MediaAssetID>()
        for entry in entries where entry.sequence > since {
            let moved = entry.facts.intersection(inputs)
            guard !moved.isEmpty else {
                continue
            }
            guard moved.isSubset(of: .captureDate), case let .named(named) = entry.rows else {
                return nil
            }
            rows.formUnion(named.ids)
            if rows.count > Self.rowCapacity {
                return nil
            }
        }
        return rows
    }
}
