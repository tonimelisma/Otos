import Foundation
import OSLog

/// Catalog Projection guide
/// This actor is the read-model boundary between catalog truth and the main window:
/// fixed/removable source splitting, ordering, reachability filtering, sidebar scope,
/// title selection, camera guidance banner state, and empty-state meaning. Pure policy
/// lives in `CatalogWindowPolicy`; diagnostics values live in `CatalogProjectionDiagnostics`.
///
/// Publication is one loop. Every intent and every store change calls `requestPublication`, which
/// only ever adds to `requested`; a pass records the `requested` it started from and
/// advances `covered` to it when its build succeeds. Whether work is owed is
/// `requested != covered` — nothing a finishing pass does can erase a request made while
/// it ran, because a pass can only cover what it started from. One consumer task
/// (`loopTask`) runs every pass off a `bufferingNewest(1)` doorbell, so passes never
/// overlap; only a build an intent superseded can still be ending its cancelled read while
/// the next pass runs, and it publishes and keeps nothing. Intents and a store change that arrives before the first catalog load ring
/// the doorbell directly; other store changes wait for `cadenceTask`, which rings it
/// every `cadence` while the projection is behind.
///
/// A pass repeats a catalog read only when its answer can have changed (ADR 0005). Each Store
/// change says which kinds of fact it touched (`CatalogChangedFacts`), and `storeDidChange`
/// records it in `changeLog`, which counts them (`revisions`) beside the rows each named; a
/// write an act of the window's reports landed is recorded there the same way. `reads` keeps the last answer of each held read — the
/// order, the stack collapse, the whole-roots stacks, the filter's options, the import
/// batches, the place-name languages and the search (the list is `CatalogProjectionReads`'s)
/// — each with what it was read for and the revisions its pass started from; a pass reuses
/// one while those inputs are unchanged and no kind of fact it depends on moved
/// (`CatalogChangedFacts.orderInputs(of:)`, `stackInputs`, `filterOptionsInputs(of:)`,
/// `importBatchInputs`, `placeNameLanguageInputs`, `searchFactInputs`), reads it again
/// otherwise, and logs which it reused (`reused=`). The search
/// answer is also keyed by the index's own `revision`, which moves when what it answers from
/// does. An enrichment write that
/// touched only faces or a tile's detail therefore publishes its detail refresh without
/// reading the order or the options, while one that moved a capture date reads the order
/// again. A pass takes `reads` as a value and keeps the reads it built from only when it
/// publishes, so a failed or cancelled pass leaves the last answers standing.
///
/// A scope the user returns to paints from what it last showed. All Media's order and
/// collapse are held while the user is elsewhere, beside the last other scope's
/// (`CatalogProjectionReads.Slot`). The first pass of an intent answers every read it holds an
/// answer for from that answer, even when a fact it depends on moved since
/// (`answerFromHeld`); when one had moved, it publishes that window, covers nothing, and the
/// next pass reads again what moved and republishes — what the window would have shown had
/// the user stayed and waited for the cadence to bring it up to date. A scope with nothing
/// held is read.
///
/// The duplicate groups, People's assignment and People's gallery have their own owners,
/// `DuplicatesProjection`, `PeopleAssignment` and `PeopleGallery`, each with its own loop. A
/// pass publishes the window with the groups and the People state last built and, when it took
/// up a catalog change of a kind an owner reads (`DuplicatesProjection.inputs`,
/// `PeopleAssignment.inputs`, `PeopleGallery.inputs`; rows only added change the gallery's
/// unchecked tally), asks that owner for a build (`duplicatesRequested`, `peopleRequested`,
/// `galleryRequested`); it never waits for one. Builds come back on `duplicatesTask` and
/// `galleryTask` and go out by republishing the last state with them. So detection and
/// grouping never hold back the sidebar or the grid, and a change of scope, filter or sort
/// never rebuilds them, since neither depends on it.
///
/// The filter's options never hold the window back, nor the pass after it. A pass that owes
/// them publishes the window with the last options read for its row (none for a row not read
/// yet), asks for them (`askFilterOptions`) and covers its request; the read runs as its own
/// work (`optionsInFlight`), one at a time, with its own revision counter
/// (`optionsRequested`, `optionsCovered`), and its answer is kept and republished in the step
/// it ends in. An intent on the same row — a sort, a filter, a search — is built while the
/// options are read; one for another row cancels the read, whose answer is then never kept.
/// On the owner's catalog a search, a clear and a sort each waited 15–23 s for the options
/// read of the pass before them (`docs/research/2026-11-16-window-reads-owner-catalog.md`).
///
/// What the user asked for is never queued behind work for what they left (ADR 0032). A
/// pass's build runs in a task the pass waits on (`inFlight`); an intent that changes what is
/// shown — another scope, filter, sort or search — cancels that task when it is for the
/// descriptor the user left. That work is not published and never can
/// be, since what it answers is no longer asked; GRDB interrupts its statement. The pass does
/// not wait for the cancelled work to end: it publishes nothing, covers nothing and rings the
/// loop at once, which builds the new request next. A store change never supersedes anything: the build in
/// flight is for what is shown, and the next pass takes the change up. Teardown
/// (`removeContinuation`) cancels the loop itself, and a pass that is torn down or whose read
/// fails publishes nothing: it leaves `covered` where it was, so the request stays
/// outstanding and the next intent or cadence tick retries it.
actor CatalogProjection {
    typealias WindowStateBuilder = @Sendable ([CatalogLibraryState], [MediaAssetID], CatalogQueryRequest) async throws
        -> CatalogWindowState
    typealias FilterOptionsReader = @Sendable (OwedFilterOptions) async throws -> CatalogFilterOptions

    /// How often background Store changes may publish: at most once a second. A rate
    /// limit standing on a measurement: each publication that reorders the grid costs
    /// the MainActor an apply of ~25 ms for an enrichment trickle and ~200 ms for a
    /// reloadData-class apply at 23k items
    /// (`docs/research/grid-reorder-cadence-and-appkit-diffable-apply.md`). User intents
    /// ring the doorbell directly and never wait for it.
    private let cadence: Duration
    let stateBuilder: WindowStateBuilder?
    /// Tests replace the options read to hold it at its suspension; production reads the Store.
    let filterOptionsReader: FilterOptionsReader?
    /// Tests replace the duplicates build to hold it at its suspension; production builds them.
    let duplicatesBuilder: DuplicatesProjection.Builder?
    /// Tests replace the People gallery's read to hold it at its suspension; production reads it.
    let peopleBuilder: PeopleGallery.Builder?
    /// Which of the duplicates and People owners this projection starts: all of them, except
    /// in a tour that leaves some out (`BackgroundOwners`).
    let backgroundOwners: BackgroundOwners
    /// Told the IDs the projection holds as each pass ends, before the pass counts as ended,
    /// so a test that waits for quiescence has the census of what it waited for; the app's
    /// projection is made without one and builds no census.
    let heldIDsReport: (@Sendable (CatalogProjectionHeldIDs) -> Void)?
    /// Tests hold a pass's publication, made off the actor (`preparePublication`), at its
    /// suspension, to deliver an act there; production passes nothing.
    let preparingPublication: (@Sendable () async -> Void)?
    /// Runs the duplicates builds and People passes one heavy load at a time with the other
    /// owners' (`LoadAdmission`): the window's, which opens it at its first grid.
    let admission: LoadAdmission
    /// The free space of the volume People's vector file is made on (ADR 0027).
    private let volumeCapacity: VolumeCapacityReader

    /// The changes delivered against those acted on, the inputs and the passes, for the
    /// projection's quiescence (`QuiescentOwner`); its own counters say what it owes.
    let activity = OwnerActivity(owner: "projection")

    private var queryRequest: CatalogQueryRequest = .initial
    /// Distinguishes one projection's diagnostics from another's in a shared log.
    private let diagnosticID = String(UUID().uuidString.prefix(8))
    /// Bumped by every intent and store change. Nothing decrements or clears it.
    private var requested: UInt64 = 0
    /// The `requested` value the last *successful* pass started from.
    private var covered: UInt64 = 0
    /// The catalog's recent changes with the rows each named, for keyed re-reads, and how many
    /// times each kind of fact changed: the Store's changes, and the writes the window's own
    /// acts report landed before the Store's change for them arrives.
    private var changeLog = CatalogChangeLog()
    /// The last published pass's reads, which the next pass answers from while they hold.
    private var reads = CatalogProjectionReads.none
    /// Passes between their first and last line. Not request state: a count rather than
    /// a flag so a cancelled pass finishing after a re-subscribe cannot mask a live one.
    private var runningPasses = 0
    private var doorbell: AsyncStream<Void>.Continuation?
    private var continuations: [UUID: AsyncStream<CatalogWindowState>.Continuation] = [:]
    private var changeTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?
    private var cadenceTask: Task<Void, Never>?
    /// What every subscriber was last handed. Read with `isQuiescent`, it says what a
    /// subscriber holds once its stream has delivered everything published.
    private(set) var lastPublishedState: CatalogWindowState?
    /// The last state as built, before the hides take anything off it: what every
    /// republication starts from, a hide's and its withdrawal's included.
    private var lastBuiltState: CatalogWindowState? {
        didSet { builtRevision &+= 1 }
    }

    /// Counts the changes to `lastBuiltState`, so a publication can say which build it was
    /// made from (`publishedFrom`).
    private var builtRevision = 0
    /// The build the last publication was made from and the items it took off it. While the
    /// build is the same, a hold that takes more off is taken off the last publication
    /// itself (`republish`), so its order is an edit of the order the window shows.
    private var publishedFrom: (builtRevision: Int, hidden: Set<MediaAssetID>, putBacks: Set<MediaTrashBatchID>)?
    /// Where each Move to Trash took its items from, for its Put Back (`putBack(_:)`); taken
    /// by the Put Back. A few values per item taken.
    private var removals: [MediaTrashBatchID: TrashRemoval] = [:]
    /// What each Move to Trash and each choice keeps off the window until a read of the
    /// Store's write (`hold(_:_:)`), by act.
    private var holds: [WindowHoldKey: WindowHold] = [:]
    /// The duplicate groups the last successful duplicates build produced; nil until one has.
    private var duplicates: CatalogDuplicatesState?
    private var duplicatesProjection: DuplicatesProjection?
    /// What the last People gallery read gave; nil until one has.
    private var people: CatalogPeopleState?
    private var peopleAssignment: PeopleAssignment?
    private var peopleGallery: PeopleGallery?
    private var galleryTask: Task<Void, Never>?
    /// Answers a descriptor's search (ADR 0048); nil where nothing indexes (tests that do
    /// not search), and a search then publishes nothing.
    private(set) var searchIndex: PhotoSearchIndex?
    private var searchTask: Task<Void, Never>?
    private var searchQueryTask: Task<Void, Never>?
    private var duplicatesTask: Task<Void, Never>?
    /// Bumped by a new subscription and by every catalog change of a kind the groups are
    /// built from (`DuplicatesProjection.inputs`): the groups may differ.
    private var duplicatesRequested: UInt64 = 0
    /// The `duplicatesRequested` value last passed on to `duplicatesProjection`.
    private var duplicatesForwarded: UInt64 = 0
    /// Bumped by a new subscription and by every catalog change of a kind People reads
    /// (`PeopleAssignment.inputs`): who the faces are may differ.
    private var peopleRequested: UInt64 = 0
    /// The `peopleRequested` value last passed on to `peopleAssignment`.
    private var peopleForwarded: UInt64 = 0
    /// The photos the changes People reads named since the last request passed on, when each
    /// named its rows and touched only faces or tiles (`PeopleAssignment.incrementalInputs`);
    /// nil when one did not.
    private var peopleRows: Set<MediaAssetID>? = []
    /// Bumped by a new subscription, by every catalog change of a kind the People gallery
    /// reads (`PeopleGallery.inputs`) and by rows only added, each new still being one the
    /// gallery's tally counts as not yet checked.
    private var galleryRequested: UInt64 = 0
    /// The `galleryRequested` value last passed on to `peopleGallery`.
    private var galleryForwarded: UInt64 = 0
    /// The last publication was the pre-load `.loadingCatalog` state. The next store
    /// change is the load itself (or something after it), so it publishes immediately
    /// rather than leaving the window blank for a cadence tick (APP-044).
    private var publishedBeforeCatalogLoad = false
    /// Count of ordered-asset reads executed by publications. A pass whose order still
    /// answers skips it; the count is the observable "full-catalog re-sort per enrichment
    /// batch" metric (ADR 0005) and drives the regression tests.
    var orderQueryCount: UInt64 = 0
    /// Count of order reads answered by a keyed re-read of the held order's changed rows
    /// (`CatalogOrderPatch`) instead of a full read.
    var keyedOrderQueryCount: UInt64 = 0
    /// Count of filter-option reads executed by publications, likewise.
    var filterOptionsQueryCount: UInt64 = 0
    /// Options reads that patched a held tally with the rows changes named.
    var keyedFilterOptionsQueryCount: UInt64 = 0
    /// Count of order reads that read the stack candidates rather than reusing the stacks
    /// the last read built (`CatalogProjectionReads.Stacks`).
    var stackReadCount: UInt64 = 0
    /// Count of searches the index was asked to match rather than answered from the last
    /// answer (`CatalogProjectionReads.Search`).
    var searchMatchCount: UInt64 = 0
    /// Count of passes whose build an intent superseded (`supersede()`).
    private(set) var supersededCount: UInt64 = 0
    /// The build the loop is waiting on: what it is for, and how to
    /// cancel it when an intent leaves that descriptor.
    private var inFlight: InFlightWork?
    /// The work an intent cancelled, so its pass knows the error it ends with is that.
    private var supersededWork: UInt64?
    private var nextWorkID: UInt64 = 0
    /// The options the newest pass that owed them asked for (`askFilterOptions`).
    private var optionsAsked: OwedFilterOptions?
    /// Bumped by every ask; `optionsCovered` is the ask the last kept read started from.
    private var optionsRequested: UInt64 = 0
    private var optionsCovered: UInt64 = 0
    /// The options read running, which an intent for another row cancels.
    private var optionsInFlight: FilterOptionsInFlight?
    /// The pass waiting on supersedable work, resumed when it ends or is superseded.
    private var workWaiter: WorkWaiter?
    /// The intent generation whose first pass published what the projection held
    /// (`CatalogProjectionReuse.held`): the passes after it for that generation read.
    private var heldPublishedGeneration: UInt64?
    /// Window states published so far. Read with `isQuiescent`, it says whether a change
    /// published anything, without depending on when a subscriber receives it.
    private(set) var publicationCount: UInt64 = 0
    var detailRefreshGeneration: UInt64 = 0
    /// Store changes taken up, whatever they name (`storeDidChange`): what a test waits on for
    /// a change to have reached the projection. A root's own state moves no detail generation.
    private(set) var changesHeard: UInt64 = 0

    /// Whether the projection owes and runs nothing: its owner fact (`quiescence`) — every
    /// request covered by a successful pass, no pass or options read running, and every Store
    /// change delivered to it acted on. Lets a test wait for settlement instead of guessing a
    /// sleep duration; a change delivered and not yet acted on is work it owes.
    var isQuiescent: Bool {
        quiescence != nil
    }

    /// The asset IDs the projection holds now, by the structure that holds them: the window
    /// published last, each held order and collapse, the stacks' members and the IDs the
    /// change log's entries name. Each array is the held one itself, so its storage is the
    /// structure's own (two structures sharing one order show one storage): what the
    /// projection's memory is made of (ADR 0005, "One copy of an order"), handed to
    /// `heldIDsReport` as each pass ends.
    private var heldAssetIDs: CatalogProjectionHeldIDs {
        var held = CatalogProjectionHeldIDs()
        held.add("window", lastPublishedState.map { [$0.mediaGrid.orderedAssetIDs] } ?? [])
        for slot in [CatalogProjectionReads.Slot.allMedia, .other] {
            held.add("order.\(slot)", reads.orders[slot].map { [$0.answer.ids] } ?? [])
            for searched in [false, true] {
                let collapse = reads.collapses.first { $0.key.slot == slot && $0.key.searched == searched }?.value
                held.add("collapse.\(slot)\(searched ? ".searched" : "")", collapse.map { [$0.ids, $0.result.ids] } ?? [])
            }
        }
        held.add("stacks", reads.stacks.map { $0.built.stacks.stacks.values.map(\.members) } ?? [])
        held.add("changeLog", sets: changeLog.entries.compactMap { entry in
            if case let .named(named) = entry.rows {
                named.ids
            } else {
                nil
            }
        })
        return held
    }

    /// Whether the duplicates owner has built every request it was given. With `isQuiescent`,
    /// lets a test wait for the groups to settle.
    var duplicatesAreQuiescent: Bool {
        get async {
            await duplicatesProjection?.isQuiescent ?? true
        }
    }

    /// Whether the People owner has built every request it was given.
    var peopleAreQuiescent: Bool {
        get async {
            let assigned = await peopleAssignment?.isQuiescent ?? true
            let read = await peopleGallery?.isQuiescent ?? true
            return assigned && read
        }
    }

    /// Whether any consumer still holds a stream. Teardown happens when the last one ends.
    var hasSubscribers: Bool {
        !continuations.isEmpty
    }

    /// `volumeCapacity` reports the free space of the volume People's vector file is made on
    /// (`FaceVectorFile.Space`, ADR 0027); no default, so no caller depends on how full the
    /// real disk is by omitting it (ADR 0020).
    init(
        volumeCapacity: @escaping VolumeCapacityReader,
        cadence: Duration = .seconds(1),
        stateBuilder: WindowStateBuilder? = nil,
        filterOptionsReader: FilterOptionsReader? = nil,
        duplicatesBuilder: DuplicatesProjection.Builder? = nil,
        peopleBuilder: PeopleGallery.Builder? = nil,
        backgroundOwners: BackgroundOwners = .all,
        admission: LoadAdmission = LoadAdmission(isOpen: true),
        heldIDsReport: (@Sendable (CatalogProjectionHeldIDs) -> Void)? = nil,
        preparingPublication: (@Sendable () async -> Void)? = nil
    ) {
        self.heldIDsReport = heldIDsReport
        self.preparingPublication = preparingPublication
        self.admission = admission
        self.volumeCapacity = volumeCapacity
        self.cadence = cadence
        self.stateBuilder = stateBuilder
        self.filterOptionsReader = filterOptionsReader
        self.duplicatesBuilder = duplicatesBuilder
        self.peopleBuilder = peopleBuilder
        self.backgroundOwners = backgroundOwners
    }

    func states(
        store: CatalogStore,
        initialDescriptor: CatalogQueryDescriptor
    ) async -> AsyncStream<CatalogWindowState> {
        await states(
            store: store,
            initialRequest: CatalogQueryRequest(descriptor: initialDescriptor, generation: 0)
        )
    }

    func states(
        store: CatalogStore,
        initialRequest: CatalogQueryRequest
    ) async -> AsyncStream<CatalogWindowState> {
        queryRequest = initialRequest
        let changes = changeTask == nil ? await store.changeNotifications(deliveries: activity.deliveries) : nil
        ensurePublicationLoop(store: store, changes: changes)

        let (stream, continuation) = AsyncStream<CatalogWindowState>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        requestPublication(ringNow: true)
        return stream
    }

    /// Uses `index` for searches from now on. A change to what it holds asks for a
    /// publication while a search is shown, on the cadence; a query whose reading ended, read
    /// or failed, asks for one at once.
    func attachSearchIndex(_ index: PhotoSearchIndex) async {
        searchTask?.cancel()
        searchQueryTask?.cancel()
        searchIndex = index
        let changes = await index.changes()
        let readings = await index.queries.readings()
        searchTask = Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                await searchIndexDidChange()
            }
        }
        searchQueryTask = Task { [weak self] in
            for await _ in readings {
                guard let self else { return }
                await searchQueryDidRead()
            }
        }
    }

    func updateSidebarSelection(_ selection: SidebarSelection) {
        updateQueryDescriptor(CatalogQueryDescriptor(
            scope: selection,
            filter: queryRequest.descriptor.filter,
            sort: queryRequest.descriptor.sort,
            search: queryRequest.descriptor.search
        ))
    }

    func updateQueryDescriptor(_ descriptor: CatalogQueryDescriptor) {
        guard queryRequest.descriptor != descriptor else { return }
        queryRequest = CatalogQueryRequest(
            descriptor: descriptor,
            generation: queryRequest.generation &+ 1
        )
        supersede()
        requestPublication(ringNow: true)
    }

    func updateQueryRequest(_ request: CatalogQueryRequest) {
        OtosLog.catalog.noticeOperation("projection.intent", phase: "received", fields: [
            "projection": diagnosticID,
            "generation": "\(request.generation)",
            "scope": String(describing: request.descriptor.scope),
            "changed": "\(queryRequest != request)",
            "requested": "\(requested)",
            "covered": "\(covered)",
        ])
        guard queryRequest != request else { return }
        let expansionOnly = request.generation == queryRequest.generation
            && request.expandedStacks != queryRequest.expandedStacks
        queryRequest = request
        supersede()
        // The same query with other stacks expanded reuses the order: only the collapse
        // differs (ADR 0052), and it is shown now from the collapse held (DES-120).
        if expansionOnly {
            showExpansion()
        }
        requestPublication(ringNow: true)
    }

    /// Shows the expansion asked for now, from the order the last published pass collapsed,
    /// without waiting for the loop: a pass in flight for the same query would otherwise hold
    /// it back. The pass the request rings still runs, and finds this collapse made. Nothing
    /// when the window shows another query, or a scope whose grid is not its collapse.
    private func showExpansion() {
        guard let built = lastBuiltState, built.queryGeneration == queryRequest.generation else {
            return
        }
        let slot = CatalogProjectionReads.CollapseKey(built.queryDescriptor)
        guard let held = reads.collapses[slot],
              let expanded = Self.expanding(built, held: held, to: queryRequest.expandedStacks)
        else {
            return
        }
        let start = ContinuousClock.now
        reads.collapses[slot] = expanded.collapse
        lastBuiltState = expanded.state
        republish()
        OtosLog.catalog.noticeOperation("projection.stacks", phase: "expandedHeld", fields: [
            "projection": diagnosticID,
            "expanded": "\(queryRequest.expandedStacks.count)",
            "shown": "\(expanded.collapse.result.ids.count)",
            "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
    }

    /// `state` with its stacks collapsed as `expanded` asks, from `held`, the collapse its grid
    /// was made from; nil when the grid is not that collapse (On This Day's capped runs), when
    /// the new collapse would be capped, or when the collapse already has this expansion.
    ///
    /// Costs what the stacks that changed hold, plus one copy of the order: only their files
    /// are collapsed again (`PhotoStackCollapse.changingExpansion`), and the grid takes the
    /// new order as an edit of the one it shows (`CatalogGridContent.edited`), which it applies
    /// as that edit's inserts and removals. Of what else the collapse feeds, the map's located
    /// photos (Places) take the same edit and On This Day's anniversaries are counted again
    /// from its few photos; the empty state cannot change, since a collapse keeps one tile of
    /// every stack it shows, so an order is empty expanded exactly when it is collapsed.
    static func expanding(
        _ state: CatalogWindowState,
        held: CatalogProjectionReads.Collapse,
        to expanded: Set<PhotoStackID>
    ) -> (state: CatalogWindowState, collapse: CatalogProjectionReads.Collapse)? {
        guard held.expanded != expanded, state.mediaGrid.orderedAssetIDs == held.result.ids else {
            return nil
        }
        let (result, edit) = PhotoStackCollapse.changingExpansion(
            of: held.result,
            ids: held.ids,
            dayBuckets: held.dayBuckets,
            coordinates: held.coordinates,
            stacks: held.stacks,
            from: held.expanded,
            to: expanded
        )
        let descriptor = state.queryDescriptor
        if case .onThisDay = descriptor.scope, OnThisDayPicks.keptPositions(dayBuckets: result.dayBuckets) != nil {
            return nil
        }
        let collapse = CatalogProjectionReads.Collapse(
            ids: held.ids,
            dayBuckets: held.dayBuckets,
            coordinates: held.coordinates,
            stacks: held.stacks,
            expanded: expanded,
            result: result
        )
        let content = state.mediaGrid.content
        var shown = state
        shown.mediaGrid = state.mediaGrid.replacingContent(
            edit.isEmpty
                ? content.replacing(stacks: result.grid)
                : content.edited(by: edit, to: result.ids, dayBuckets: result.dayBuckets, stacks: result.grid)
        )
        if let map = state.map, !edit.isEmpty {
            shown.map = map.located.count == state.mediaGrid.orderedAssetIDs.count
                && result.coordinates.count == result.ids.count
                ? map.editing(edit, located: edit.inserted.map { LocatedAsset(id: result.ids[$0], coordinate: result.coordinates[$0]) })
                : CatalogWindowPolicy.mapState(for: descriptor, scopedAssetIDs: result.ids, scopedCoordinates: result.coordinates)
        }
        if state.onThisDay != nil, !edit.isEmpty {
            shown.onThisDay = CatalogWindowPolicy.onThisDayState(
                for: descriptor, scopedAssetIDs: result.ids, scopedDayBuckets: result.dayBuckets
            )
        }
        return (shown, collapse)
    }

    /// One-shot window-state build for tests. Production UI consumes the publication
    /// loop; this entry derives a state from supplied facts so projection math can be
    /// asserted without a store. It reads nothing, so it cannot fail.
    func windowState(
        libraries: [CatalogLibraryState],
        orderedAssetIDs: [MediaAssetID],
        sidebarSelection: SidebarSelection
    ) async -> CatalogWindowState {
        let request = CatalogQueryRequest(
            descriptor: CatalogQueryDescriptor(scope: sidebarSelection),
            generation: 0
        )
        let allRoots = CatalogWindowPolicy.sortLibraries(libraries)
        let facts = makeBuildFacts(
            allRoots: allRoots,
            request: request,
            resolvedDescriptor: Self.resolvedDescriptor(for: request, allRoots: allRoots, importBatches: [], placeNameLanguages: []),
            importBatches: [],
            ordered: (orderedAssetIDs, [], []),
            orderQueryMs: 0
        )
        return windowState(
            from: facts,
            allAssetCount: orderedAssetIDs.count,
            unfilteredVisibleAssetCount: facts.scopedAssetIDs.count,
            filterOptions: .empty
        ).0
    }
}

/// What the window asks of Projection, in the order the user acted (ADR 0032 rule 5): one
/// lossless stream with one consumer, so a hide reaches Projection before the report that the
/// Store's mark for it landed.
nonisolated enum CatalogProjectionIntent: Sendable {
    /// Show this query. Each is applied in turn; a pass builds the newest.
    case query(CatalogQueryRequest)
    /// A Move to Trash's items leave the window now, ahead of the Store's mark.
    case hide([MediaAssetID], batch: MediaTrashBatchID)
    /// The Store's mark for `batch` is written.
    case hideLanded(MediaTrashBatchID)
    /// `batch` is not hidden after all: its mark failed (`storeChanged` false), or its undo
    /// put the items back in the Store (true).
    case hideWithdrawn(MediaTrashBatchID, storeChanged: Bool)
    /// Undo of `batch`: its items return to the window now, where its hide took them from,
    /// ahead of the file work that puts them back (DES-119); `hideWithdrawn` follows it.
    case putBack(MediaTrashBatchID)
    /// Choices shown ahead of the Store's write (DES-120): an item a choice filter no longer
    /// matches leaves the window now. `request` is the window's number for them.
    case choose([MediaAssetID: MediaChoice], request: UInt64)
    /// The Store's write of the choices numbered `request` is written.
    case choicesLanded(request: UInt64)
    /// The choices numbered `request` were not written: what they took out comes back.
    case choicesWithdrawn(request: UInt64)

    /// The act's name in `op=projection.act` lines, for the intents whose result the window
    /// shows at once (DES-119, DES-120); nil for a query and for a write's report.
    var actName: String? {
        switch self {
        case .hide: "moveToTrash"
        case .putBack: "putBack"
        case .choose: "choose"
        case .query, .hideLanded, .hideWithdrawn, .choicesLanded, .choicesWithdrawn: nil
        }
    }
}

/// What one of the window's acts keeps off the window ahead of the Store's write, until a
/// pass that read the catalog after the write landed covers its request (`retiresAt`).
private nonisolated struct WindowHold {
    nonisolated enum Content {
        /// A Move to Trash's items, off every surface.
        case items(Set<MediaAssetID>)
        /// Choices: an item whose newest held choice the shown filter excludes is off it.
        case choices([MediaAssetID: MediaChoice])
        /// A Put Back's items, on the window again where their Move to Trash took them from.
        case putBack(TrashRemoval)
    }

    let content: Content
    /// The request a pass must cover for this hold to retire; nil until the write lands.
    var retiresAt: UInt64?

    var count: Int {
        switch content {
        case let .items(ids): ids.count
        case let .choices(choices): choices.count
        case let .putBack(removal): removal.ids.count
        }
    }
}

/// Where one Move to Trash took each of its items from in the grid: for each, the shown
/// items either side of it that the command did not take, its day and its stack. Its Put
/// Back puts each item back beside those neighbours (`puttingBack`). A few values per item,
/// never the order itself, so a session's removals cost what they took.
private nonisolated struct TrashRemoval {
    nonisolated struct Item {
        let id: MediaAssetID
        /// The nearest item before it in the grid that the command did not take.
        let predecessor: MediaAssetID?
        /// The nearest item after it that the command did not take.
        let successor: MediaAssetID?
        let dayBucket: Date?
        let tile: TileStacks?
        /// The hidden files that showed through it in a collapsed stack.
        let hiddenMembers: [MediaAssetID]
    }

    let descriptor: CatalogQueryDescriptor
    let items: [Item]

    var ids: Set<MediaAssetID> {
        Set(items.map(\.id))
    }

    /// What taking `ids` off `grid` removes, or nil when `grid` shows none of them.
    init?(taking ids: Set<MediaAssetID>, from grid: CatalogMediaGridState) {
        let content = grid.content
        let order = content.orderedAssetIDs
        let positions = ids.compactMap { content.position(of: $0) }.sorted()
        guard !positions.isEmpty else {
            return nil
        }
        let taken = Set(positions)
        let hiddenMembers = Dictionary(exactlyGrouping: content.stacks.shownForHiddenMember.filter { ids.contains($0.value) }, by: \.value)
        items = positions.map { position in
            let id = order[position]
            let predecessor = (0 ..< position).reversed().first { !taken.contains($0) }.map { order[$0] }
            let successor = (position + 1 ..< order.count).first { !taken.contains($0) }.map { order[$0] }
            return Item(
                id: id,
                predecessor: predecessor,
                successor: successor,
                dayBucket: content.dayBuckets.isEmpty ? nil : content.dayBuckets[position],
                tile: content.stacks.tiles[id],
                hiddenMembers: hiddenMembers[id]?.map(\.key) ?? []
            )
        }
        descriptor = grid.descriptor
    }
}

/// One hold per act: a Move to Trash by its batch, its Put Back by the same batch, choices by
/// the window's number for them.
private nonisolated enum WindowHoldKey: Hashable {
    case trash(MediaTrashBatchID)
    case putBack(MediaTrashBatchID)
    case choices(UInt64)

    var diagnosticDescription: String {
        switch self {
        case let .trash(batch): "trash:\(batch.unixMilliseconds)"
        case let .putBack(batch): "putBack:\(batch.unixMilliseconds)"
        case let .choices(request): "choices:\(request)"
        }
    }
}

/// Hold guide (DES-119, DES-120, APP-085, APP-086)
///
/// Move to Trash and a choice show their result before the Store has written anything. A Move
/// to Trash's items leave the published window from the order Projection already holds, with
/// no catalog read; a choice the shown choice filter excludes takes its item out the same way,
/// which is what the read of the write would do. `hold(_:_:)` keeps the act and republishes
/// `lastBuiltState` without what it takes off (`CatalogWindowState.hidingItems`, in proportion
/// to the change); every later publication — a pass, a held answer, the options, People, the
/// duplicate groups — leaves through the same `hidingItems`, so a pass that read the catalog
/// before the write cannot bring them back. A choice hold is judged against the filter of each
/// state it is laid over, so a filter changed meanwhile decides afresh, and the newest choice
/// held for an item is the one judged: an undo pressed before the act's write lands puts the
/// item back at once.
///
/// `landed(_:fact:)` is the Store's own report that the write is done, relayed by the act's
/// stream consumer after the write returns, often before the Store's own change for it reaches
/// `storeDidChange`. It records the write in `changeLog` as that change would — its kind
/// (`CatalogChangedFacts.membership` for a mark, `.choices` for a choice) and the rows it
/// wrote — so no held read answers from before it and no keyed re-read takes it for a change
/// of no rows, and rings the loop; the hold retires once a pass started after that
/// report covers its request — that pass read the catalog with the write in it, so what it
/// builds already lacks the items and its publication shares the held one's grid content:
/// nothing is applied twice. A held answer covers nothing, so it never retires a hold.
/// `withdrawn(_:storeChanged:)` drops a hold: a failed write republishes what was built, and an
/// undo that put the items back in the Store records the change and rings the loop, as the
/// landing does.
///
/// Put Back is a Move to Trash undone, and shows its result the same way: at once, ahead of
/// the file work (DES-119). Each hide records where it took each item from (`TrashRemoval`:
/// the neighbours either side that it did not take). `putBack(_:)` drops the hide's hold if
/// it has not retired and keeps a put-back hold, which every publication applies
/// (`puttingBack`): an item the window does not show goes back beside its neighbour, after
/// its predecessor or else before its successor, either one shown or itself being put back.
/// The first publication is the last one with the items put back, so its order is an edit of
/// the order the window shows and the grid commits it in the turn that delivers it. The hold
/// retires as a hide does, once a pass that read the undo's Store work covers it; items the
/// undo could not put back are absent from that read and leave again, and the window reports
/// them (DES-076). An item neither of whose neighbours is shown waits for the Store's read.
/// The map, On This Day and the duplicate groups follow that read.
extension CatalogProjection {
    /// Applies `intent` in the step it reaches the actor. `sentAt` is when its forwarder sent
    /// it: an act's line says how long it waited for the actor (`waitedUs`) and how long its
    /// own step took (`applyUs`), so an act's time on the projection reads as queueing or work.
    func apply(_ intent: CatalogProjectionIntent, sentAt: ContinuousClock.Instant? = nil) {
        let start = ContinuousClock.now
        let shown = lastPublishedState?.mediaGrid
        let publications = publicationCount
        defer {
            if let act = intent.actName {
                let published = publicationCount != publications
                OtosLog.catalog.noticeOperation("projection.act", phase: "applied", fields: [
                    "projection": diagnosticID,
                    "act": act,
                    "waitedUs": sentAt.map { "\(DiagnosticsTiming.microseconds(since: $0, now: start))" } ?? "unknown",
                    "applyUs": "\(DiagnosticsTiming.microseconds(since: start))",
                    "passRunning": "\(runningPasses > 0)",
                    "published": "\(published)",
                    "gridWork": published ? lastPublishedState.map { Self.gridWork($0.mediaGrid, after: shown) } ?? "none" : "none",
                ])
            }
        }
        switch intent {
        case let .query(request):
            updateQueryRequest(request)
        case let .hide(ids, batch):
            hide(ids, batch: batch)
        case let .hideLanded(batch):
            hideLanded(batch)
        case let .hideWithdrawn(batch, storeChanged):
            hideWithdrawn(batch, storeChanged: storeChanged)
        case let .putBack(batch):
            putBack(batch)
        case let .choose(choices, request):
            guard !choices.isEmpty else { return }
            hold(.choices(request), WindowHold(content: .choices(choices)))
        case let .choicesLanded(request):
            landed(.choices(request), fact: .choices)
        case let .choicesWithdrawn(request):
            withdrawn(.choices(request), storeChanged: false)
        }
    }

    /// Takes `ids` off the window now, from what was last built.
    func hide(_ ids: [MediaAssetID], batch: MediaTrashBatchID) {
        guard !ids.isEmpty else {
            return
        }
        if holds[.trash(batch)] == nil, let shown = lastPublishedState?.mediaGrid,
           let removal = TrashRemoval(taking: Set(ids), from: shown)
        {
            removals[batch] = removal
        }
        hold(.trash(batch), WindowHold(content: .items(Set(ids))))
    }

    /// The Store's mark for `batch` is written: the next pass reads it.
    func hideLanded(_ batch: MediaTrashBatchID) {
        landed(.trash(batch), fact: .membership)
    }

    /// `batch`'s items come back: its mark failed, or its undo put them back in the Store.
    /// After a Put Back this is the undo's Store work done: its hold retires once a pass has
    /// read it.
    func hideWithdrawn(_ batch: MediaTrashBatchID, storeChanged: Bool) {
        withdrawn(.trash(batch), storeChanged: storeChanged)
        if holds[.putBack(batch)] != nil {
            requestPublication(ringNow: true)
            holds[.putBack(batch)]?.retiresAt = requested
            OtosLog.catalog.noticeOperation("projection.hold", phase: "landed", fields: [
                "projection": diagnosticID,
                "hold": WindowHoldKey.putBack(batch).diagnosticDescription,
                "retiresAt": "\(requested)",
            ])
        }
    }

    /// Undo of `batch`: its items are on the window again now, where its hide took them from.
    /// A hide not yet landed takes nothing off any more; a hide whose removal is not known
    /// (it took nothing off what was published) leaves the Put Back to the Store's read.
    func putBack(_ batch: MediaTrashBatchID) {
        let start = ContinuousClock.now
        holds[.trash(batch)] = nil
        guard let removal = removals.removeValue(forKey: batch) else {
            republish()
            OtosLog.catalog.noticeOperation("projection.hold", phase: "putBackFollowsStore", fields: [
                "projection": diagnosticID,
                "hold": WindowHoldKey.putBack(batch).diagnosticDescription,
            ])
            return
        }
        holds[.putBack(batch)] = WindowHold(content: .putBack(removal))
        republish()
        let grid = lastPublishedState?.mediaGrid.content
        let shown = removal.items.filter { grid?.contains($0.id) == true }.count
        OtosLog.catalog.noticeOperation("projection.hold", phase: "held", fields: [
            "projection": diagnosticID,
            "hold": WindowHoldKey.putBack(batch).diagnosticDescription,
            "count": "\(removal.items.count)",
            "shown": "\(shown)",
            "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
    }

    /// `state` with every held Put Back's items that it does not show put back beside their
    /// neighbours: after the predecessor, or else before the successor, whichever is shown or
    /// is itself put back. The order is an edit of `state`'s (`CatalogGridContent.inserting`),
    /// so the grid follows it by the inserts alone. Items put back beside the same neighbour keep
    /// the order they were taken in. An item neither of whose neighbours is there is left to
    /// the Store's read, and one a newer Move to Trash holds (`hidden`) stays off.
    private func puttingBack(_ state: CatalogWindowState, hidden: Set<MediaAssetID>) -> CatalogWindowState {
        Self.puttingBack(state, hidden: hidden, removals: heldPutBackRemovals)
    }

    /// The removals whose Put Back is held.
    private var heldPutBackRemovals: [TrashRemoval] {
        holds.compactMap { key, hold in
            guard case .putBack = key, case let .putBack(removal) = hold.content else {
                return nil
            }
            return removal
        }
    }

    /// `puttingBack(_:hidden:)` for `removals`, a value: what the publication made off the
    /// actor puts back. Costs the items put back and their neighbours' look-ups, never the
    /// order: each neighbour's position is read from the index, and the order's runs between
    /// the insertions are copied whole.
    fileprivate nonisolated static func puttingBack(
        _ state: CatalogWindowState,
        hidden: Set<MediaAssetID>,
        removals: [TrashRemoval]
    ) -> CatalogWindowState {
        let content = state.mediaGrid.content
        var visited = 0
        var pending: [MediaAssetID: TrashRemoval.Item] = [:]
        for removal in removals where removal.descriptor == state.mediaGrid.descriptor {
            for item in removal.items where !hidden.contains(item.id) {
                visited += 1
                if !content.contains(item.id) {
                    pending[item.id] = item
                }
            }
        }
        guard !pending.isEmpty else {
            return state
        }
        var after: [MediaAssetID: [TrashRemoval.Item]] = [:]
        var before: [MediaAssetID: [TrashRemoval.Item]] = [:]
        var placed = Set<MediaAssetID>()
        func isThere(_ id: MediaAssetID?) -> Bool {
            guard let id else {
                return false
            }
            visited += 1
            return placed.contains(id) || content.contains(id)
        }
        var progressed = true
        while progressed {
            progressed = false
            for item in pending.values where !placed.contains(item.id) {
                if isThere(item.predecessor), let predecessor = item.predecessor {
                    after[predecessor, default: []].append(item)
                } else if isThere(item.successor), let successor = item.successor {
                    before[successor, default: []].append(item)
                } else {
                    continue
                }
                placed.insert(item.id)
                progressed = true
            }
        }
        guard !placed.isEmpty else {
            return state
        }
        /// Beside one neighbour, an item taken while the next was still shown goes before it.
        func ordered(_ items: [TrashRemoval.Item]) -> [TrashRemoval.Item] {
            items.sorted { lhs, rhs in
                lhs.successor == rhs.id || (rhs.successor != lhs.id && lhs.id.relativePathPrecedes(rhs.id))
            }
        }
        /// `item` with what is put back before and after it, in order.
        func chain(_ item: TrashRemoval.Item) -> [TrashRemoval.Item] {
            ordered(before[item.id] ?? []).flatMap(chain) + [item] + ordered(after[item.id] ?? []).flatMap(chain)
        }
        // The shown items something is put back beside, in the order's order.
        let anchors = Set(before.keys).union(after.keys)
            .compactMap { id -> (position: Int, id: MediaAssetID)? in
                visited += 1
                return content.position(of: id).map { ($0, id) }
            }
            .sorted { $0.position < $1.position }
        var inserted: [(position: Int, id: MediaAssetID, day: Date?)] = []
        inserted.reserveCapacity(placed.count)
        var shift = 0
        for anchor in anchors {
            for item in ordered(before[anchor.id] ?? []).flatMap(chain) {
                inserted.append((anchor.position + shift, item.id, item.dayBucket))
                shift += 1
            }
            for item in ordered(after[anchor.id] ?? []).flatMap(chain) {
                shift += 1
                inserted.append((anchor.position + shift, item.id, item.dayBucket))
            }
        }
        var stacks = content.stacks
        let placedItems = placed.compactMap { pending[$0] }
        if placedItems.contains(where: { $0.tile != nil || !$0.hiddenMembers.isEmpty }) {
            var tiles = stacks.tiles
            var shownFor = stacks.shownForHiddenMember
            for item in placedItems {
                tiles[item.id] = item.tile
                for member in item.hiddenMembers {
                    shownFor[member] = item.id
                }
            }
            stacks = CatalogGridStacks(tiles: tiles, shownForHiddenMember: shownFor)
        }
        var shown = state
        shown.mediaGrid = state.mediaGrid.replacingContent(content.inserting(
            inserted,
            stacks: stacks,
            work: CatalogGridContent.Work(visited: visited)
        ))
        return shown
    }

    /// Keeps `hold` and republishes without what it takes off.
    private func hold(_ key: WindowHoldKey, _ hold: WindowHold) {
        guard holds[key] == nil else {
            return
        }
        holds[key] = hold
        let start = ContinuousClock.now
        republish()
        OtosLog.catalog.noticeOperation("projection.hold", phase: "held", fields: [
            "projection": diagnosticID,
            "hold": key.diagnosticDescription,
            "count": "\(hold.count)",
            "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
    }

    /// The Store's write for `key` is done: the next pass reads it.
    private func landed(_ key: WindowHoldKey, fact: CatalogChangedFacts) {
        guard holds[key] != nil else {
            return
        }
        changeLog.record(fact, rows: Self.rows(of: holds[key]))
        requestPublication(ringNow: true)
        holds[key]?.retiresAt = requested
        OtosLog.catalog.noticeOperation("projection.hold", phase: "landed", fields: [
            "projection": diagnosticID,
            "hold": key.diagnosticDescription,
            "retiresAt": "\(requested)",
        ])
    }

    /// `key`'s act is not held after all: its write failed, or its undo put the items back in
    /// the Store (`storeChanged`).
    private func withdrawn(_ key: WindowHoldKey, storeChanged: Bool) {
        let removed = holds.removeValue(forKey: key)
        if storeChanged {
            // A Put Back dropped its Move to Trash's hold; its own hold names the rows.
            var undone = removed
            if undone == nil, case let .trash(batch) = key {
                undone = holds[.putBack(batch)]
            }
            changeLog.record(.membership, rows: Self.rows(of: undone))
            requestPublication(ringNow: true)
        }
        guard removed != nil else {
            return
        }
        republish()
        OtosLog.catalog.noticeOperation("projection.hold", phase: "withdrawn", fields: [
            "projection": diagnosticID,
            "hold": key.diagnosticDescription,
            "storeChanged": "\(storeChanged)",
        ])
    }

    /// The rows `hold`'s act wrote, as a change names them; unnamed when no hold says.
    private static func rows(of hold: WindowHold?) -> CatalogChangedRows {
        let ids: Set<MediaAssetID> = switch hold?.content {
        case let .items(ids): ids
        case let .choices(choices): Set(choices.keys)
        case let .putBack(removal): removal.ids
        case nil: []
        }
        return CatalogNamedRows(ids).map(CatalogChangedRows.named) ?? .unnamed
    }

    /// Every item the holds keep off a window showing `descriptor`: every held Move to Trash's
    /// items, and each item whose newest held choice the shown choice filter excludes. The
    /// duplicates list and People show no filter, so no choice takes anything off them.
    func hiddenItems(for descriptor: CatalogQueryDescriptor) -> Set<MediaAssetID> {
        var hidden = Set<MediaAssetID>()
        var newestChoice: [MediaAssetID: (request: UInt64, choice: MediaChoice)] = [:]
        for (key, hold) in holds {
            switch (key, hold.content) {
            case let (_, .items(ids)):
                hidden.formUnion(ids)
            case let (.choices(request), .choices(choices)):
                for (id, choice) in choices where (newestChoice[id]?.request ?? 0) < request {
                    newestChoice[id] = (request, choice)
                }
            case (_, .putBack), (.trash, .choices), (.putBack, .choices):
                break
            }
        }
        let shown = descriptor.filter.choices
        let showsFilter = descriptor.scope.detailSurface != .duplicates && descriptor.scope.detailSurface != .people
        if !shown.isEmpty, showsFilter {
            for (id, newest) in newestChoice where !shown.contains(newest.choice) {
                hidden.insert(id)
            }
        }
        return hidden
    }

    /// Whether no act is held, for tests and diagnostics.
    var holdsNothing: Bool {
        holds.isEmpty
    }

    /// Retires each hold whose write a pass that started from `startedFrom` has read, and
    /// republishes in case the Store kept one of its items shown.
    private func retireHolds(coveredFrom startedFrom: UInt64) {
        let retiring = holds.filter { $0.value.retiresAt.map { $0 <= startedFrom } ?? false }
        guard !retiring.isEmpty else {
            return
        }
        for key in retiring.keys {
            holds[key] = nil
        }
        republish()
        OtosLog.catalog.noticeOperation("projection.hold", phase: "retired", fields: [
            "projection": diagnosticID,
            "holds": "\(retiring.count)",
        ])
    }
}

extension CatalogProjection {
    /// The people each face of `photos` could be, from the last People published
    /// (ADR 0047); none before People is first published; nil when they could not be ranked.
    func faceCandidates(for photos: [MediaAssetID]) async -> [FaceID: [FaceCandidate]]? {
        guard let peopleAssignment else {
            return [:]
        }
        return await peopleAssignment.candidates(for: photos)
    }

    /// Asks the People gallery for a read after a People write the window made has landed,
    /// and returns the request a state must cover to have read it (`CatalogPeopleState.covers`);
    /// 0 before the gallery has an owner, which any state covers. Assignment is asked too, as a
    /// load the user waits on (`PeopleAssignment.requestForUser`): the write was the user's act,
    /// and they look for its twins and neighbours.
    func requestPeopleBuild() async -> UInt64 {
        await peopleAssignment?.requestForUser()
        guard let peopleGallery else {
            return 0
        }
        return await peopleGallery.request()
    }
}

private extension CatalogProjection {
    func ensurePublicationLoop(store: CatalogStore, changes: AsyncStream<CatalogStoreChange>?) {
        guard loopTask == nil else {
            return
        }

        let cadence = cadence
        let (bell, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        doorbell = continuation
        // Every loop here waits indefinitely, so it holds its owner weakly — and must
        // *end* when that upgrade fails, not merely skip a beat. A `while
        // !Task.isCancelled` loop whose body is `await self?.…` keeps running after
        // the projection is gone: it does nothing on each pass, but it never exits,
        // and its closure holds `store` strongly, so the whole `CatalogStore` (its
        // database, watchers and scan tasks) is kept alive by a loop with no owner.
        // `removeContinuation` cancels these, but only when the last stream consumer
        // tears down — which is not guaranteed to happen before the owner deallocates.
        // Hundreds of such orphans accumulating in one process is what deadlocked the
        // test suite mid-run.
        changeTask = Task { [weak self, changes] in
            guard let changes else {
                return
            }
            for await change in changes {
                guard let self else {
                    return
                }
                await actOnDelivered(change)
            }
        }

        loopTask = Task { [weak self] in
            for await _ in bell {
                guard let self else {
                    return
                }
                await pass(store: store)
            }
        }

        // A new subscription knows no groups or people yet, so its first loaded pass asks for
        // them.
        // A tour can leave either owner unstarted (`BackgroundOwners`): it is then never made.
        let duplicatesProjection = backgroundOwners.starts(.duplicates)
            ? DuplicatesProjection(store: store, builder: duplicatesBuilder, admission: admission) : nil
        self.duplicatesProjection = duplicatesProjection
        // A test that injects the gallery's read assigns nothing: its states are the test's.
        let peopleAssignment = backgroundOwners.starts(.people) && peopleBuilder == nil
            ? PeopleAssignment(store: store, vectorSpace: .temporary(availableBytes: volumeCapacity), admission: admission) : nil
        self.peopleAssignment = peopleAssignment
        // The gallery is the window's own read, not a background owner: it runs whatever the
        // tour leaves out, at the window's priority.
        let peopleGallery = PeopleGallery(store: store, builder: peopleBuilder)
        self.peopleGallery = peopleGallery
        galleryRequested &+= 1
        duplicatesRequested &+= 1
        peopleRequested &+= 1
        // Below the priority of the window, whose subscription runs this: the owners' loops
        // inherit it.
        if let duplicatesProjection {
            duplicatesTask = Task(priority: .backgroundOwner) { [weak self, duplicatesProjection] in
                await duplicatesProjection.start()
                for await built in duplicatesProjection.builds {
                    guard let self else {
                        return
                    }
                    await publishDuplicates(built)
                }
            }
        }
        if let peopleAssignment {
            Task(priority: .backgroundOwner) { [peopleAssignment] in
                await peopleAssignment.start()
            }
        }
        galleryTask = Task { [weak self, peopleGallery] in
            await peopleGallery.start()
            for await built in peopleGallery.builds {
                guard let self else {
                    return
                }
                await publishPeople(built)
            }
        }

        // The cadence task is the one that notices the owner is gone, so it also ends the
        // doorbell and the derived owners on every exit: `loopTask`, `duplicatesTask` and
        // `galleryTask` wait indefinitely, and a wait nothing can end keeps `store` alive
        // through its closure.
        // The cadence rings only when a publication is owed: the projection's one wake.
        activity.wake = OwnerWake(kind: .cadence, at: nil)
        cadenceTask = Task { [weak self, continuation, duplicatesProjection, peopleAssignment, peopleGallery] in
            defer {
                continuation.finish()
                duplicatesProjection?.stop()
                peopleAssignment?.stop()
                peopleGallery.stop()
            }
            while !Task.isCancelled {
                do {
                    // time: cadence docs/research/grid-reorder-cadence-and-appkit-diffable-apply.md
                    try await Task.sleep(for: cadence)
                } catch {
                    return
                }
                guard let self else {
                    return
                }
                await ringIfBehind()
            }
        }
    }

    /// The only way work becomes owed. `ringNow` wakes the loop immediately; without it
    /// the cadence tick picks the request up.
    private func requestPublication(ringNow: Bool) {
        requested &+= 1
        activity.noteInput()
        if ringNow {
            doorbell?.yield()
        }
    }

    func ringIfBehind() {
        if requested != covered {
            doorbell?.yield()
        }
    }

    func searchIndexDidChange() {
        guard queryRequest.descriptor.search != nil else { return }
        requestPublication(ringNow: false)
    }

    /// The answer to a user's query: published now, not on the cadence.
    func searchQueryDidRead() {
        guard queryRequest.descriptor.search != nil else { return }
        requestPublication(ringNow: true)
    }

    /// A change the Store delivered to this projection's subscription, counted as acted on in
    /// the step that takes it up.
    private func actOnDelivered(_ change: CatalogStoreChange) {
        storeDidChange(change)
        activity.actedOnChange()
        settleQuiescence()
    }

    func storeDidChange(_ change: CatalogStoreChange) {
        changesHeard &+= 1
        // A root's own order or activity (`CatalogChangedRows.none`: a scan or listing starting
        // or ending) moves no row and no root's reach. The next pass shows it, since the roots
        // are read every pass; no held read, tile detail or derived owner depends on it, so none
        // is read again or asked.
        if change.rows == .none {
            requestPublication(ringNow: publishesAtOnce(change))
            return
        }
        // A remove and same-path add can coalesce into a final snapshot where the
        // path exists again. Store's typed removal signal preserves that transient
        // deletion fact without durable library-instance identity.
        if case let .libraryRemoved(path) = change {
            if queryRequest.descriptor.scope == .library(path) {
                queryRequest.descriptor.scope = .allMedia
                supersede()
            }
        }
        detailRefreshGeneration &+= 1
        changeLog.record(change.facts, rows: change.rows)
        // Rows that were only added carry nothing the groups or the assignment are built
        // from; they change the People gallery's unchecked tally alone. Any other change asks
        // each owner whose answer is built from a kind of fact it touched.
        if change == .assetsAdded {
            galleryRequested &+= 1
        } else {
            if !change.facts.isDisjoint(with: DuplicatesProjection.inputs) {
                duplicatesRequested &+= 1
            }
            if !change.facts.isDisjoint(with: PeopleAssignment.inputs) {
                peopleRequested &+= 1
                let incremental = change.facts.intersection(PeopleAssignment.inputs).isSubset(of: PeopleAssignment.incrementalInputs)
                switch change.rows {
                case let .named(rows) where incremental: peopleRows?.formUnion(rows.ids)
                default: peopleRows = nil
                }
            }
            if !change.facts.isDisjoint(with: PeopleGallery.inputs) {
                galleryRequested &+= 1
            }
        }
        requestPublication(ringNow: publishesAtOnce(change))
    }

    /// Whether `change` is published now rather than on the cadence: the catalog's first load
    /// (APP-044), and a change of which rows exist (`.membership`: rows added, a root added
    /// or removed) while the window shows no item. The cadence spares the main actor the
    /// apply of a shown grid that a background change reorders; a window that shows no item
    /// has no grid to reorder, and what it waits for is its first rows — a newly added
    /// library's first scan batch, which waited for the next tick (0.9 s at the owner's
    /// library size, `docs/research/2026-11-17-a-new-library-at-the-owners-size.md`).
    private func publishesAtOnce(_ change: CatalogStoreChange) -> Bool {
        if publishedBeforeCatalogLoad {
            return true
        }
        guard change.facts.contains(.membership) else {
            return false
        }
        return lastPublishedState?.mediaGrid.orderedAssetIDs.isEmpty ?? true
    }

    /// Cancels the build in flight when it is for a descriptor other than the one now asked
    /// for, and the options read when it is for another row. Synchronous: it runs in the step that applies the intent, so no await
    /// separates the intent from the cancellation.
    private func supersede() {
        supersedeFilterOptions()
        guard let inFlight, !inFlight.answers(queryRequest.descriptor) else {
            return
        }
        supersededWork = inFlight.id
        OtosLog.catalog.noticeOperation("projection.publish", phase: "superseded", fields: [
            "projection": diagnosticID,
            "work": "build",
            "left": inFlight.scope.diagnosticDescription,
            "asked": queryRequest.descriptor.scope.diagnosticDescription,
        ])
        inFlight.cancel()
        workEnded(inFlight.id)
    }

    /// Runs `work` as the pass's in-flight work, which an intent whose descriptor it does not
    /// answer cancels (`supersede()`). Throws `CatalogProjectionWorkSuperseded` when it did; a
    /// teardown of the loop cancels the work with it and rethrows its error.
    ///
    /// The pass waits for the work to end or for an intent to supersede it, whichever comes
    /// first: superseded work is cancelled and left to end on its own, publishing nothing,
    /// because a cancelled read can only end when its statement or its wait for a connection
    /// does, and what the user asked for next must not wait on that.
    private func supersedable<Value: Sendable>(
        building descriptor: CatalogQueryDescriptor,
        _ work: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        nextWorkID &+= 1
        let id = nextWorkID
        let task = Task { [weak self] in
            let result = await Result { try await work() }
            await self?.workEnded(id)
            return try result.get()
        }
        inFlight = InFlightWork(id: id, descriptor: descriptor, cancel: { task.cancel() })
        defer {
            if inFlight?.id == id {
                inFlight = nil
            }
        }
        // Resumed by `workEnded` or by `supersede()`, both on this actor; the work cannot end
        // before this registers, since `workEnded` needs the actor this step holds.
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                workWaiter = WorkWaiter(id: id, continuation: continuation)
            }
        } onCancel: {
            task.cancel()
        }
        guard supersededWork != id else {
            // Work that finished in spite of its cancellation still answers what was left.
            supersededWork = nil
            throw CatalogProjectionWorkSuperseded()
        }
        return try await task.value
    }

    /// The supersedable work `id` has ended: the pass waiting on it, if it still is, goes on.
    private func workEnded(_ id: UInt64) {
        guard let waiter = workWaiter, waiter.id == id else {
            return
        }
        workWaiter = nil
        waiter.continuation.resume()
    }

    /// One publication pass. It only runs on `loopTask`, so passes never overlap. It
    /// takes up everything requested so far (`startedFrom`) and covers exactly that:
    /// a request made while it awaits leaves `requested != covered` and runs next.
    func pass(store: CatalogStore) async {
        guard requested != covered else {
            return
        }
        runningPasses += 1
        activity.work.passes += 1
        defer {
            heldIDsReport?(heldAssetIDs)
            runningPasses -= 1
            activity.work.reads = Int(orderQueryCount + keyedOrderQueryCount + filterOptionsQueryCount + stackReadCount)
            settleQuiescence()
        }
        let startedFrom = requested
        let duplicatesStartedFrom = duplicatesRequested
        let peopleStartedFrom = peopleRequested
        let galleryStartedFrom = galleryRequested
        let startedReads = reads
        let startedChanges = changeLog
        let selectedRequest = queryRequest
        OtosLog.catalog.noticeOperation("projection.publish", phase: "start", fields: [
            "projection": diagnosticID,
            "generation": "\(selectedRequest.generation)",
            "scope": String(describing: selectedRequest.descriptor.scope),
        ])

        let publicationStart = ContinuousClock.now
        let storeReadStart = ContinuousClock.now
        let completed: CatalogProjectionCompletedPublication
        var passReads: CatalogProjectionReads
        let owedOptions: OwedFilterOptions?
        do {
            // Before the catalog's first load there is nothing to query and nothing to
            // claim: publish the loading state instead of an empty catalog (APP-044).
            guard let libraries = await store.loadedLibraries() else {
                try Task.checkCancellation()
                publishLoadingState(for: selectedRequest)
                covered = startedFrom
                ringIfBehind()
                return
            }
            publishedBeforeCatalogLoad = false
            let storeReadMs = DiagnosticsTiming.milliseconds(since: storeReadStart)

            let projectionStart = ContinuousClock.now
            let signpost = OtosSignpost.performance.beginInterval("CatalogWindowPublication")
            defer {
                OtosSignpost.performance.endInterval("CatalogWindowPublication", signpost)
            }
            // The first pass of an intent shows what the projection holds for it at once; a
            // pass that did reads again, and nothing else answers from held reads.
            let answerFromHeld = lastPublishedState?.queryGeneration != selectedRequest.generation
                && heldPublishedGeneration != selectedRequest.generation
            let build = try await supersedable(building: selectedRequest.descriptor) {
                try await self.buildWindowState(
                    store: store,
                    libraries: libraries,
                    request: selectedRequest,
                    reads: startedReads,
                    changes: startedChanges,
                    answerFromHeld: answerFromHeld
                )
            }
            // A cancelled pass is a teardown: whatever it read is not the catalog.
            try Task.checkCancellation()
            guard case let .built(state, buildMetrics, builtReads, owed) = build else {
                // Not failed: the window keeps what it shows and says it is searching. The pass
                // covers what it took up, because the reader reports when the query's status
                // changes (`readings()`, a request of its own), so the cadence does not ask it
                // again every tick, nor match a words reading that matched nothing again.
                OtosLog.catalog.noticeOperation("projection.publish", phase: "searchReading", fields: [
                    "projection": diagnosticID,
                    "generation": "\(selectedRequest.generation)",
                ])
                publishSearchReading()
                covered = startedFrom
                ringIfBehind()
                return
            }
            passReads = builtReads
            owedOptions = owed
            completed = CatalogProjectionCompletedPublication(
                state: state,
                buildMetrics: buildMetrics,
                selectedDescriptor: selectedRequest.descriptor,
                timing: CatalogProjectionPublicationTiming(
                    storeReadMs: storeReadMs,
                    projectionMs: DiagnosticsTiming.milliseconds(since: projectionStart),
                    totalMs: DiagnosticsTiming.milliseconds(since: publicationStart)
                )
            )
        } catch {
            endUnpublishedPass(error, request: selectedRequest)
            return
        }

        // The window goes out now, with the groups last built, and with the stacks expanded as
        // the user asked meanwhile: an expansion was shown while this pass read, and a
        // publication of the collapse it started from would take it back for a pass.
        var window = completed.state
        let collapseSlot = CatalogProjectionReads.CollapseKey(window.queryDescriptor)
        if queryRequest.generation == selectedRequest.generation,
           queryRequest.expandedStacks != selectedRequest.expandedStacks,
           let held = passReads.collapses[collapseSlot],
           let expanded = Self.expanding(window, held: held, to: queryRequest.expandedStacks)
        {
            window = expanded.state
            passReads.collapses[collapseSlot] = expanded.collapse
        }
        window.duplicates = duplicates
        window.people = people
        // Telling a read's order from the one shown, the edit between them and the index cost
        // the order's size, so they are made off the actor, against the publication shown now
        // and the acts held now. An act that arrives meanwhile is applied and published at
        // once; `publish` then takes the acts held at its step on top (ADR 0005, "An act is
        // never queued behind a build"). An intent for another query supersedes this work as
        // it does the build.
        let prepared: PreparedPublication
        do {
            let base = lastPublishedState
            let hidden = hiddenItems(for: window.queryDescriptor)
            let putBacks = heldPutBacks
            let removals = heldPutBackRemovals
            prepared = try await supersedable(building: selectedRequest.descriptor) { [window, preparingPublication] in
                await preparingPublication?()
                return await Self.preparePublication(window, base: base, hidden: hidden, putBacks: putBacks, removals: removals)
            }
            try Task.checkCancellation()
        } catch {
            endUnpublishedPass(error, request: selectedRequest)
            return
        }
        let diagnostics = publish(
            CatalogProjectionCompletedPublication(
                state: window,
                buildMetrics: completed.buildMetrics,
                selectedDescriptor: completed.selectedDescriptor,
                timing: completed.timing
            ),
            prepared: prepared,
            selectedRequest: selectedRequest
        )
        await diagnostics.emit()
        // A cancelled pass is a teardown: the counters and the derived owners it would touch
        // now belong to no subscription, or to the next one.
        guard !Task.isCancelled else {
            return
        }
        // The window is published, so the reads it was built from stand. The options are not
        // among them: their own read keeps them (`filterOptionsReadEnded`), and one that ended
        // while this pass built is newer than the options this pass started from.
        passReads.filterOptions = reads.filterOptions
        reads = passReads
        if let owedOptions {
            askFilterOptions(owedOptions, store: store)
        }
        // What the window shows was held, and a fact it depends on moved since: the next pass
        // reads it again, and takes up the derived owners. This one covers nothing.
        if completed.buildMetrics.reuse.held {
            heldPublishedGeneration = selectedRequest.generation
            OtosLog.catalog.noticeOperation("projection.publish", phase: "held", fields: [
                "projection": diagnosticID,
                "generation": "\(selectedRequest.generation)",
                "scope": selectedRequest.descriptor.scope.diagnosticDescription,
            ])
            doorbell?.yield()
            return
        }
        covered = startedFrom
        retireHolds(coveredFrom: startedFrom)
        ringIfBehind()
        // An injected test builder derives nothing. Otherwise a pass that took up a change
        // an owner reads asks that owner for a build, and one that took up added rows asks the
        // People gallery for a read; it waits for none.
        // An owner a tour left unstarted (`BackgroundOwners`) is nil and is asked nothing.
        guard stateBuilder == nil else {
            return
        }
        let asksDuplicates = duplicatesStartedFrom != duplicatesForwarded
        let asksPeople = peopleStartedFrom != peopleForwarded
        let asksGallery = galleryStartedFrom != galleryForwarded
        duplicatesForwarded = duplicatesStartedFrom
        peopleForwarded = peopleStartedFrom
        galleryForwarded = galleryStartedFrom
        if asksDuplicates, let duplicatesProjection {
            await duplicatesProjection.request()
        }
        // The rows are taken in this step, so a change while the request is handed on adds to
        // the next one.
        let rows = peopleRows
        if asksPeople {
            peopleRows = []
        }
        if asksPeople, let peopleAssignment {
            await peopleAssignment.request(rows: rows.map(CatalogChangedRows.rows) ?? .unnamed)
        }
        if asksGallery, let peopleGallery {
            await peopleGallery.request()
        }
    }

    /// Asks for the options a published window owes. A read already running for exactly these
    /// is the answer; otherwise the ask is counted, and read once the read running ends, or now.
    private func askFilterOptions(_ owed: OwedFilterOptions, store: CatalogStore) {
        guard optionsInFlight?.owed != owed, !Self.answers(reads.filterOptions, owed) else {
            return
        }
        optionsAsked = owed
        optionsRequested &+= 1
        startAskedFilterOptionsRead(store: store)
    }

    /// Whether `held` was read for exactly what `owed` asks: a read that ended while the pass
    /// asking for it built.
    private static func answers(_ held: CatalogProjectionReads.FilterOptions?, _ owed: OwedFilterOptions) -> Bool {
        guard let held else {
            return false
        }
        return held.row == owed.row && held.availableLibraryPaths == owed.availableLibraryPaths
            && held.placeNameLanguages == owed.placeNameLanguages && held.revisions == owed.revisions
    }

    /// Starts the read of the newest options asked, when one is owed and none is running.
    /// Synchronous: the read is a task whose end is applied by `filterOptionsReadEnded`.
    private func startAskedFilterOptionsRead(store: CatalogStore) {
        guard optionsInFlight == nil, optionsRequested != optionsCovered, let owed = optionsAsked else {
            return
        }
        nextWorkID &+= 1
        let id = nextWorkID
        let startedFrom = optionsRequested
        let plan = plan(forOptions: owed, held: reads.filterOptions)
        let sequence = changeLog.sequence
        let task = Task { [weak self] in
            guard let self else { return }
            let result = await Result { try await self.readFilterOptions(owed, plan: plan, sequence: sequence, store: store) }
            await filterOptionsReadEnded(id: id, owed: owed, startedFrom: startedFrom, result: result, store: store)
        }
        optionsInFlight = FilterOptionsInFlight(id: id, owed: owed, cancel: { task.cancel() })
    }

    /// The plan for the next read of the options `owed` names, from what is held: a keyed
    /// re-read when the held tally is of the same row over the same roots and languages and
    /// every Store change since its read moved only named rows' locations or file types, or the
    /// cells' names (`CatalogChangeLog.keyedOptionRows`, ADR 0005 "Keyed re-reads"); otherwise
    /// a whole read. Synchronous, from the state the read starts from.
    private func plan(forOptions owed: OwedFilterOptions, held: CatalogProjectionReads.FilterOptions?) -> FilterOptionsPlan {
        guard let held, let tally = held.tally, held.row == owed.row,
              held.availableLibraryPaths == owed.availableLibraryPaths, held.placeNameLanguages == owed.placeNameLanguages
        else {
            return .whole
        }
        guard let keyed = changeLog.keyedOptionRows(since: held.sequence, for: owed.row) else {
            return .whole
        }
        // The re-read rows' cells are named in the tally's language; every cell it counts is
        // named again only when the cells' names moved.
        return .keyed(
            rows: keyed.rows, names: tally.language,
            renamed: keyed.names && tally.language != nil ? tally.cells : [], patching: held.sequence
        )
    }

    /// Keeps a read's options and republishes the window with them, then reads the newest
    /// asked if they were asked again meanwhile. A read an intent or a teardown cancelled is
    /// no longer the one in flight, and nothing of it is kept. A failed read keeps nothing
    /// and leaves its ask outstanding: the next pass that owes them asks again (ADR 0032).
    private func filterOptionsReadEnded(
        id: UInt64,
        owed: OwedFilterOptions,
        startedFrom: UInt64,
        result: Result<FilterOptionsRead, any Error>,
        store: CatalogStore
    ) {
        defer { settleQuiescence() }
        guard optionsInFlight?.id == id else {
            return
        }
        optionsInFlight = nil
        let read: FilterOptionsRead
        switch result {
        case let .success(value):
            read = value
        case let .failure(error):
            OtosLog.catalog.errorOperation("projection.filterOptions", phase: "failed", fields: [
                "projection": diagnosticID,
                "row": owed.row.diagnosticDescription,
                "error": String(describing: error),
            ])
            return
        }
        guard let options = keep(read, for: owed) else {
            // The keyed read patched a tally no longer held, or met a row it never counted: the
            // tally is dropped and the ask stays outstanding, so the next read is whole.
            reads.filterOptions?.tally = nil
            OtosLog.catalog.noticeOperation("projection.filterOptions", phase: "unpatched", fields: [
                "projection": diagnosticID,
                "row": owed.row.diagnosticDescription,
            ])
            startAskedFilterOptionsRead(store: store)
            return
        }
        optionsCovered = startedFrom
        let republished = publishFilterOptions(options, row: owed.row)
        OtosLog.catalog.noticeOperation("projection.filterOptions", phase: "read", fields: [
            "projection": diagnosticID,
            "row": owed.row.diagnosticDescription,
            "ms": "\(read.ms)",
            "keyed": "\(read.isKeyed)",
            "republished": "\(republished)",
        ])
        startAskedFilterOptionsRead(store: store)
    }

    /// Keeps what an options read gave as the options held for `owed`, and returns them: a
    /// whole read replaces what is held; a keyed read patches the held tally in place, when it
    /// is still the one the read was planned from and the patch counts only rows it counted
    /// (`CatalogFilterOptionTally.take`). Nil, keeping nothing, otherwise. Synchronous.
    private func keep(_ read: FilterOptionsRead, for owed: OwedFilterOptions) -> CatalogFilterOptions? {
        switch read.outcome {
        case let .answered(options):
            reads.filterOptions = CatalogProjectionReads.FilterOptions(
                row: owed.row, availableLibraryPaths: owed.availableLibraryPaths, placeNameLanguages: owed.placeNameLanguages,
                revisions: owed.revisions, answer: options, tally: nil, sequence: read.sequence
            )
            return options
        case let .whole(tally):
            let options = tally.options
            reads.filterOptions = CatalogProjectionReads.FilterOptions(
                row: owed.row, availableLibraryPaths: owed.availableLibraryPaths, placeNameLanguages: owed.placeNameLanguages,
                revisions: owed.revisions, answer: options, tally: tally, sequence: read.sequence
            )
            return options
        case let .keyed(rows, patching):
            // Each field is compared through the held value, never a copy of it: a copy alive
            // while the tally is patched would make the patch copy every row's arrays.
            guard reads.filterOptions?.sequence == patching, reads.filterOptions?.row == owed.row,
                  reads.filterOptions?.availableLibraryPaths == owed.availableLibraryPaths,
                  reads.filterOptions?.placeNameLanguages == owed.placeNameLanguages,
                  reads.filterOptions?.tally?.take(rows) == true,
                  let options = reads.filterOptions?.tally?.options
            else {
                return nil
            }
            reads.filterOptions?.answer = options
            reads.filterOptions?.revisions = owed.revisions
            reads.filterOptions?.sequence = read.sequence
            return options
        }
    }

    /// Cancels the options read and forgets the options asked when they are not for the row
    /// now asked for: nothing shows them. Synchronous, in the step that applies the intent.
    private func supersedeFilterOptions() {
        let row = queryRequest.descriptor.scope.sidebarRow
        if let optionsInFlight, optionsInFlight.owed.row != row {
            OtosLog.catalog.noticeOperation("projection.publish", phase: "superseded", fields: [
                "projection": diagnosticID,
                "work": "filterOptions",
                "left": optionsInFlight.owed.row.diagnosticDescription,
                "asked": queryRequest.descriptor.scope.diagnosticDescription,
            ])
            optionsInFlight.cancel()
            self.optionsInFlight = nil
        }
        if let optionsAsked, optionsAsked.row != row {
            self.optionsAsked = nil
            optionsCovered = optionsRequested
        }
    }

    /// How a pass that published nothing ends: torn down, superseded by an intent (the loop
    /// is rung for what was asked), or failed. The work stays owed in every case: `covered`
    /// stays put and the last reads stand. No doorbell for a failure — a persistent error
    /// must not retry in a tight loop; the next intent or cadence tick retries it.
    private func endUnpublishedPass(_ error: any Error, request: CatalogQueryRequest) {
        switch error {
        case is CatalogProjectionWorkSuperseded:
            supersededCount &+= 1
            doorbell?.yield()
        case is CancellationError:
            // Teardown (`removeContinuation`) already reset the counters; this pass
            // belongs to a subscription that no longer exists.
            break
        default:
            OtosLog.catalog.errorOperation("projection.publish", phase: "failed", fields: [
                "projection": diagnosticID,
                "generation": "\(request.generation)",
                "error": String(describing: error),
            ])
        }
    }

    /// Republishes the last state with freshly read options for `row`, when it still shows
    /// that row and the options differ. Synchronous.
    private func publishFilterOptions(_ options: CatalogFilterOptions, row: SidebarSelection) -> Bool {
        guard let state = lastBuiltState,
              state.queryDescriptor.scope.sidebarRow == row,
              state.filterOptions != options
        else {
            return false
        }
        republish { $0.filterOptions = options }
        return true
    }

    /// Republishes the last state, as it is, marked as searching: while a query is read the
    /// window keeps what it shows (ADR 0048). Nothing is covered, so the pass the reading's
    /// end rings builds the answer. Synchronous.
    func publishSearchReading() {
        guard let state = lastBuiltState, state.searchPhase != .reading else {
            return
        }
        republish { $0.searchPhase = .reading }
    }

    /// Takes in a fresh People build and republishes the last state with it when it differs
    /// from what it carries. Synchronous.
    func publishPeople(_ built: CatalogPeopleState) {
        people = built
        guard let state = lastBuiltState, state.people != built else {
            return
        }
        republish { $0.people = built }
    }

    /// Takes in freshly built groups and republishes the last state with them when they
    /// differ from what it carries. Synchronous.
    func publishDuplicates(_ built: CatalogDuplicatesState) {
        duplicates = built
        guard let state = lastBuiltState, state.duplicates != built else {
            return
        }
        republish { $0.duplicates = built }
    }

    /// What a pass's publication is made of off the actor (`preparePublication`): the build
    /// with every part equal to the base publication's handed on and its index built, and the
    /// publication of it with the acts held then, made from the base's order by an edit. The
    /// base is held until `publish`, so an act's publication made from it meanwhile and this
    /// one still share an order to find the edit between them through.
    struct PreparedPublication: Sendable {
        let built: CatalogWindowState
        let publication: CatalogWindowState
        let base: CatalogWindowState?
        let hidden: Set<MediaAssetID>
        let putBacks: Set<MediaTrashBatchID>
    }

    /// The pass's publication of `build` after `base`, off the actor (ADR 0032, rule 6): the
    /// comparison with the base's parts, the index of an order read whole and the edit from the
    /// base's order cost the scope, and an act must never wait behind them.
    @concurrent
    static func preparePublication(
        _ build: CatalogWindowState,
        base: CatalogWindowState?,
        hidden: Set<MediaAssetID>,
        putBacks: Set<MediaTrashBatchID>,
        removals: [TrashRemoval]
    ) async -> PreparedPublication {
        let built = build.sharingUnchanged(with: base)
        let publication = puttingBack(built.hidingItems(hidden), hidden: hidden, removals: removals)
            .sharingUnchanged(with: base)
        return PreparedPublication(built: built, publication: publication, base: base, hidden: hidden, putBacks: putBacks)
    }

    /// Normalizes the selection the build resolved, takes the acts held now on top of the
    /// publication prepared for it, and yields it if it changed. Synchronous, and in the
    /// edit's cost: when an act arrived while it was prepared, or the duplicates or People
    /// were built again, the build's own order, already indexed, is edited by the acts held
    /// now; either way the result is linked to the last publication by the edit between them,
    /// through the base both were made from.
    func publish(
        _ publication: CatalogProjectionCompletedPublication,
        prepared: PreparedPublication,
        selectedRequest: CatalogQueryRequest
    ) -> CatalogProjectionPublicationDiagnostics {
        // Normalize only the exact input this build used; a newer reentrant user
        // intent stays outstanding and wins on the next pass.
        let retainedResolvedSelection = retainResolvedSelection(
            publication.state.queryDescriptor,
            forInput: selectedRequest
        )
        let equalityStart = ContinuousClock.now
        // What a Move to Trash or a choice took off the window stays off it until a read of
        // the Store's write (`holds`). Parts equal to the last publication's are handed on as that
        // publication's own, so the window learns what changed by identity, never by walking
        // them — and a read that answers what a hide already showed applies nothing.
        var built = prepared.built
        let hidden = hiddenItems(for: built.queryDescriptor)
        let putBacks = heldPutBacks
        let ownersMoved = built.duplicates != duplicates || built.people != people
        if ownersMoved {
            built.duplicates = duplicates
            built.people = people
        }
        lastBuiltState = built
        let rebased = ownersMoved || hidden != prepared.hidden || putBacks != prepared.putBacks
        let state = (rebased ? puttingBack(built.hidingItems(hidden), hidden: hidden) : prepared.publication)
            .sharingUnchanged(with: lastPublishedState)
        publishedFrom = (builtRevision, hidden, putBacks)
        let changeSummary = CatalogProjectionChangeSummary.compare(
            previous: lastPublishedState,
            current: state
        )
        let stateChanged = changeSummary.stateChanged
        let equalityUs = DiagnosticsTiming.microseconds(since: equalityStart)
        let gridChange = Self.gridChange(state.mediaGrid, after: lastPublishedState?.mediaGrid)
        let gridWork = Self.gridWork(state.mediaGrid, after: lastPublishedState?.mediaGrid)
        if stateChanged {
            yield(state)
        }
        return CatalogProjectionPublicationDiagnostics(
            state: state,
            assetCount: state.mediaGrid.orderedAssetIDs.count,
            metrics: publication.buildMetrics,
            changeSummary: changeSummary,
            selectedSidebarRow: publication.selectedDescriptor.scope,
            retainedResolvedSelection: retainedResolvedSelection,
            equalityUs: equalityUs,
            storeReadMs: publication.timing.storeReadMs,
            projectionMs: publication.timing.projectionMs,
            totalMs: publication.timing.totalMs,
            dirtyAfter: requested != covered,
            stateChanged: stateChanged,
            orderQueryCount: orderQueryCount,
            gridChange: gridChange,
            gridWork: gridWork
        )
    }

    /// How a publication's grid order follows the one published before it, for its line: the
    /// same order, an edit of it with the positions it names, or a whole order the grid
    /// compares (a new query's).
    static func gridChange(_ grid: CatalogMediaGridState, after previous: CatalogMediaGridState?) -> String {
        guard let previous else {
            return "whole"
        }
        if grid.sharesOrder(with: previous) {
            return "same"
        }
        return grid.content.edit(from: previous.content).map { "edit:\($0.size)" } ?? "whole"
    }

    /// What making a publication's grid content cost (`CatalogGridContent.Work`), for its
    /// line; `none` when it hands the last publication's content on.
    static func gridWork(_ grid: CatalogMediaGridState, after previous: CatalogMediaGridState?) -> String {
        if let previous, grid.sharesContent(with: previous) {
            return "none"
        }
        return grid.content.work.description
    }

    private func retainResolvedSelection(
        _ resolvedDescriptor: CatalogQueryDescriptor,
        forInput inputRequest: CatalogQueryRequest
    ) -> Bool {
        guard queryRequest == inputRequest else {
            return false
        }
        queryRequest.descriptor = resolvedDescriptor
        return resolvedDescriptor != inputRequest.descriptor
    }

    func publishLoadingState(for request: CatalogQueryRequest) {
        publishedBeforeCatalogLoad = true
        var loading = CatalogWindowState.empty
        loading.mediaGrid = CatalogMediaGridState(descriptor: request.descriptor, orderedAssetIDs: [])
        loading.resolvedSidebarSelection = request.descriptor.scope
        loading.queryGeneration = request.generation
        lastBuiltState = loading
        publishedFrom = (builtRevision, [], heldPutBacks)
        OtosLog.catalog.notice("op=projection.publish phase=loadingCatalog")
        if loading != lastPublishedState {
            yield(loading)
        }
    }

    /// Republishes the last built state changed by `change`, with what the hides take off it,
    /// when the result differs from the last publication. Synchronous.
    ///
    /// When nothing was built since the last publication and the holds only take more off
    /// (a Move to Trash, or five in a row), the rest is taken off that publication rather
    /// than off the build: the same window by value, but its order an edit of the order the
    /// window shows (`CatalogGridContent.edit(from:)`), which the grid builds and commits in
    /// the turn that delivers it (ADR 0006). Taking items off composes: the build without A,
    /// then without B, is the build without both.
    private func republish(_ change: ((inout CatalogWindowState) -> Void)? = nil) {
        guard var built = lastBuiltState else {
            return
        }
        if let change {
            change(&built)
            lastBuiltState = built
        }
        let hidden = hiddenItems(for: built.queryDescriptor)
        let putBacks = heldPutBacks
        let state: CatalogWindowState
        let base: String
        if let last = lastPublishedState,
           let from = publishedFrom,
           from.builtRevision == builtRevision,
           from.putBacks.isSubset(of: putBacks),
           from.hidden.subtracting(hidden).isSubset(of: putBackItems)
        {
            // What is no longer hidden is being put back: put back beside its neighbours in the
            // last publication, as a new hide is taken off it.
            state = puttingBack(last.hidingItems(hidden.subtracting(from.hidden)), hidden: hidden)
            state.mediaGrid.content.prepareIndex()
            base = "publication"
        } else {
            state = puttingBack(built.hidingItems(hidden), hidden: hidden).sharingUnchanged(with: lastPublishedState)
            base = "build"
        }
        publishedFrom = (builtRevision, hidden, putBacks)
        let changed = state != lastPublishedState
        // Which base the window's next order was taken from: off the last publication it is
        // an edit of the order the grid shows; off the build it is one only when equal.
        OtosLog.catalog.debugOperation("projection.republish", phase: "finish", fields: [
            "projection": diagnosticID,
            "base": base,
            "hidden": "\(hidden.count)",
            "changed": "\(changed)",
            "gridChange": Self.gridChange(state.mediaGrid, after: lastPublishedState?.mediaGrid),
            "gridWork": Self.gridWork(state.mediaGrid, after: lastPublishedState?.mediaGrid),
        ])
        if changed {
            yield(state)
        }
    }

    /// Every item a held Put Back puts back.
    private var putBackItems: Set<MediaAssetID> {
        holds.values.reduce(into: Set<MediaAssetID>()) { items, hold in
            if case let .putBack(removal) = hold.content {
                items.formUnion(removal.ids)
            }
        }
    }

    /// The batches whose Put Back is held.
    private var heldPutBacks: Set<MediaTrashBatchID> {
        Set(holds.keys.compactMap { key in
            if case let .putBack(batch) = key {
                batch
            } else {
                nil
            }
        })
    }

    private func yield(_ state: CatalogWindowState) {
        lastPublishedState = state
        publicationCount += 1
        for continuation in continuations.values {
            continuation.yield(state)
        }
    }

    func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
        guard continuations.isEmpty else {
            return
        }
        duplicatesProjection?.stop()
        duplicatesProjection = nil
        duplicatesTask?.cancel()
        duplicatesTask = nil
        peopleAssignment?.stop()
        peopleAssignment = nil
        peopleGallery?.stop()
        peopleGallery = nil
        galleryTask?.cancel()
        galleryTask = nil
        duplicatesRequested = 0
        duplicatesForwarded = 0
        peopleRequested = 0
        peopleForwarded = 0
        peopleRows = []
        galleryRequested = 0
        galleryForwarded = 0
        changeTask?.cancel()
        changeTask = nil
        loopTask?.cancel()
        loopTask = nil
        cadenceTask?.cancel()
        cadenceTask = nil
        activity.wake = nil
        doorbell?.finish()
        doorbell = nil
        requested = 0
        covered = 0
        reads = .none
        changeLog = CatalogChangeLog()
        lastPublishedState = nil
        lastBuiltState = nil
        removals = [:]
        holds = [:]
        duplicates = nil
        people = nil
        orderQueryCount = 0
        keyedOrderQueryCount = 0
        filterOptionsQueryCount = 0
        keyedFilterOptionsQueryCount = 0
        stackReadCount = 0
        inFlight = nil
        supersededWork = nil
        heldPublishedGeneration = nil
        optionsInFlight?.cancel()
        optionsInFlight = nil
        optionsAsked = nil
        optionsRequested = 0
        optionsCovered = 0
    }
}

/// The build a pass waits on, for `CatalogProjection.supersede()`: it answers only the
/// descriptor it is for.
private nonisolated struct InFlightWork {
    let id: UInt64
    let descriptor: CatalogQueryDescriptor
    let cancel: @Sendable () -> Void

    /// Whether this build's answer is still asked for when the window asks for `descriptor`.
    func answers(_ asked: CatalogQueryDescriptor) -> Bool {
        descriptor == asked
    }

    var scope: SidebarSelection {
        descriptor.scope
    }
}

/// The options read running: the options it reads, and how to cancel it when an intent
/// leaves their row (`CatalogProjection.supersedeFilterOptions()`).
private nonisolated struct FilterOptionsInFlight {
    let id: UInt64
    let owed: OwedFilterOptions
    let cancel: @Sendable () -> Void
}

/// The pass waiting on the supersedable work `id`.
private nonisolated struct WorkWaiter {
    let id: UInt64
    let continuation: CheckedContinuation<Void, Never>
}

/// A pass's work was cancelled by an intent that left the descriptor it was for.
nonisolated struct CatalogProjectionWorkSuperseded: Error {}

extension CatalogProjection: QuiescentOwner {
    /// A publication or an options read owed or running: the projection's own counters.
    var holdsWork: Bool {
        requested != covered || runningPasses != 0 || optionsRequested != optionsCovered || optionsInFlight != nil
    }

    /// The publications and options reads asked for so far: the projection's own counters, the
    /// whole of what it holds (`holdsWork`), so covering them is its catch-up. A background
    /// change asks for a publication on the cadence, so while a backlog writes there is nearly
    /// always one owed: a later request never puts off covering an earlier mark.
    var owedMark: OwnerMark {
        OwnerMark([requested, optionsRequested])
    }

    func covers(_ mark: OwnerMark) -> Bool {
        guard mark.revisions.count == 2 else { return false }
        return covered >= mark.revisions[0] && optionsCovered >= mark.revisions[1]
    }

    /// Asks for a publication on the cadence, as a background change does.
    func ringIdle() {
        requestPublication(ringNow: false)
    }

    /// This projection and the owners it runs under it — the duplicate groups, People's
    /// assignment and its gallery — each of which reports its own quiescence.
    func quiescentOwners() -> [any QuiescentOwner] {
        let owners: [(any QuiescentOwner)?] = [self, duplicatesProjection, peopleAssignment, peopleGallery]
        return owners.compactMap(\.self)
    }

    /// The owners under this projection whose work the Activity surface names (ADR 0058): the
    /// duplicate groups and People's assignment. The gallery's tally is bookkeeping, and the
    /// projection's own publications are machinery.
    func activityOwners() -> [ActivityBoard.Watched] {
        var owners: [ActivityBoard.Watched] = []
        if let duplicatesProjection {
            owners.append(.init(kind: .findingDuplicates, owner: duplicatesProjection))
        }
        if let peopleAssignment {
            owners.append(.init(kind: .scanningFaces, owner: peopleAssignment))
        }
        return owners
    }

    /// Returns once the duplicates owner has built and published the groups this projection's
    /// first loaded pass asked for, at once when the owner does not run.
    func untilLaunchDuplicatesBuilt() async throws {
        try await duplicatesProjection?.untilLaunchBuildPublished()
    }
}

/// The asset IDs `CatalogProjection` holds at one moment, by the structure holding them
/// (`CatalogProjection.heldAssetIDs`). An array here is the structure's own, so comparing
/// storages says which structures share one copy.
nonisolated struct CatalogProjectionHeldIDs: Sendable {
    nonisolated struct Structure: Sendable {
        let name: String
        let arrays: [[MediaAssetID]]
        let sets: [Set<MediaAssetID>]
    }

    private(set) var structures: [Structure] = []

    mutating func add(_ name: String, _ arrays: [[MediaAssetID]] = [], sets: [Set<MediaAssetID>] = []) {
        structures.append(Structure(name: name, arrays: arrays, sets: sets))
    }
}
