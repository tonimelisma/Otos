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
/// counts them in `factRevisions`. `reads` keeps the last answer of each held read — the
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
/// The duplicate groups and People have their own owners, `DuplicatesProjection` and
/// `PeopleAssignment`, each with its own loop. A pass publishes the window with what they
/// last built and, when it took up a catalog change of a kind an owner's answer is built from
/// (`DuplicatesProjection.inputs`, `PeopleAssignment.inputs`), asks that owner for a build
/// (`duplicatesRequested`, `peopleRequested`), or People for its unchecked tally alone when
/// rows were only added (`tallyRequested`); it never waits for one. Builds come back on `duplicatesTask` and
/// `peopleTask` and go out by republishing the last state with them. So detection and
/// grouping never hold back the sidebar or the grid, and a change of scope, filter or sort
/// never rebuilds them, since neither depends on it.
///
/// The filter's options never hold the window back. A pass that owes them publishes the
/// window with the last options read for its row (none for a row not read yet), then reads
/// them and republishes the window with them (`OwedFilterOptions`); it covers its request only
/// once they are read.
///
/// What the user asked for is never queued behind work for what they left (ADR 0032). A
/// pass's build, and its owed options read, run in a task the pass waits on (`inFlight`); an
/// intent that changes what is shown — another scope, filter, sort or search — cancels that
/// task when it is for the descriptor the user left. That work is not published and never can
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

    /// How often background Store changes may publish: at most once a second. A rate
    /// limit standing on a measurement: each publication that reorders the grid costs
    /// the MainActor an apply of ~25 ms for an enrichment trickle and ~200 ms for a
    /// reloadData-class apply at 23k items
    /// (`docs/research/grid-reorder-cadence-and-appkit-diffable-apply.md`). User intents
    /// ring the doorbell directly and never wait for it.
    private let cadence: Duration
    let stateBuilder: WindowStateBuilder?
    /// Tests replace the duplicates build to hold it at its suspension; production builds them.
    let duplicatesBuilder: DuplicatesProjection.Builder?
    /// Tests replace the People build to hold it at its suspension; production builds it.
    let peopleBuilder: PeopleAssignment.Builder?
    /// Which of the duplicates and People owners this projection starts: all of them, except
    /// in a tour that leaves some out (`BackgroundOwners`).
    let backgroundOwners: BackgroundOwners

    private var queryRequest: CatalogQueryRequest = .initial
    /// Distinguishes one projection's diagnostics from another's in a shared log.
    private let diagnosticID = String(UUID().uuidString.prefix(8))
    /// Bumped by every intent and store change. Nothing decrements or clears it.
    private var requested: UInt64 = 0
    /// The `requested` value the last *successful* pass started from.
    private var covered: UInt64 = 0
    /// How many times each kind of catalog fact changed, by the Store's own account.
    private var factRevisions = CatalogFactRevisions()
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
    private var lastBuiltState: CatalogWindowState?
    /// What each Move to Trash and each choice keeps off the window until a read of the
    /// Store's write (`hold(_:_:)`), by act.
    private var holds: [WindowHoldKey: WindowHold] = [:]
    /// The duplicate groups the last successful duplicates build produced; nil until one has.
    private var duplicates: CatalogDuplicatesState?
    private var duplicatesProjection: DuplicatesProjection?
    /// What the last successful People build produced; nil until one has.
    private var people: CatalogPeopleState?
    private var peopleAssignment: PeopleAssignment?
    private var peopleTask: Task<Void, Never>?
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
    /// Bumped by rows only added: they carry nothing the groups or the assignment are built
    /// from, but each new still is one People's tally counts as not yet checked.
    private var tallyRequested: UInt64 = 0
    /// The `tallyRequested` value last passed on to `peopleAssignment`.
    private var tallyForwarded: UInt64 = 0
    /// The last publication was the pre-load `.loadingCatalog` state. The next store
    /// change is the load itself (or something after it), so it publishes immediately
    /// rather than leaving the window blank for a cadence tick (APP-044).
    private var publishedBeforeCatalogLoad = false
    /// Count of ordered-asset reads executed by publications. A pass whose order still
    /// answers skips it; the count is the observable "full-catalog re-sort per enrichment
    /// batch" metric (ADR 0005) and drives the regression tests.
    var orderQueryCount: UInt64 = 0
    /// Count of filter-option reads executed by publications, likewise.
    var filterOptionsQueryCount: UInt64 = 0
    /// Count of order reads that read the stack candidates rather than reusing the stacks
    /// the last read built (`CatalogProjectionReads.Stacks`).
    var stackReadCount: UInt64 = 0
    /// Count of searches the index was asked to match rather than answered from the last
    /// answer (`CatalogProjectionReads.Search`).
    var searchMatchCount: UInt64 = 0
    /// Count of passes whose build or owed read an intent superseded (`supersede()`).
    private(set) var supersededCount: UInt64 = 0
    /// The build or owed options read the loop is waiting on: what it is for, and how to
    /// cancel it when an intent leaves that descriptor.
    private var inFlight: InFlightWork?
    /// The work an intent cancelled, so its pass knows the error it ends with is that.
    private var supersededWork: UInt64?
    private var nextWorkID: UInt64 = 0
    /// The pass waiting on supersedable work, resumed when it ends or is superseded.
    private var workWaiter: WorkWaiter?
    /// The intent generation whose first pass published what the projection held
    /// (`CatalogProjectionReuse.held`): the passes after it for that generation read.
    private var heldPublishedGeneration: UInt64?
    /// Window states published so far. Read with `isQuiescent`, it says whether a change
    /// published anything, without depending on when a subscriber receives it.
    private(set) var publicationCount: UInt64 = 0
    var detailRefreshGeneration: UInt64 = 0

    /// True when every request has been covered by a successful pass and no pass is
    /// running. Lets a test wait for settlement instead of guessing a sleep duration.
    var isQuiescent: Bool {
        requested == covered && runningPasses == 0
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
            await peopleAssignment?.isQuiescent ?? true
        }
    }

    /// Whether any consumer still holds a stream. Teardown happens when the last one ends.
    var hasSubscribers: Bool {
        !continuations.isEmpty
    }

    init(
        cadence: Duration = .seconds(1),
        stateBuilder: WindowStateBuilder? = nil,
        duplicatesBuilder: DuplicatesProjection.Builder? = nil,
        peopleBuilder: PeopleAssignment.Builder? = nil,
        backgroundOwners: BackgroundOwners = .all
    ) {
        self.cadence = cadence
        self.stateBuilder = stateBuilder
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
        let changes = changeTask == nil ? await store.changeNotifications() : nil
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
        let slot = CatalogProjectionReads.Slot(built.queryDescriptor.scope)
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
    /// Choices shown ahead of the Store's write (DES-120): an item a choice filter no longer
    /// matches leaves the window now. `request` is the window's number for them.
    case choose([MediaAssetID: MediaChoice], request: UInt64)
    /// The Store's write of the choices numbered `request` is written.
    case choicesLanded(request: UInt64)
    /// The choices numbered `request` were not written: what they took out comes back.
    case choicesWithdrawn(request: UInt64)
}

/// What one of the window's acts keeps off the window ahead of the Store's write, until a
/// pass that read the catalog after the write landed covers its request (`retiresAt`).
private nonisolated struct WindowHold {
    nonisolated enum Content {
        /// A Move to Trash's items, off every surface.
        case items(Set<MediaAssetID>)
        /// Choices: an item whose newest held choice the shown filter excludes is off it.
        case choices([MediaAssetID: MediaChoice])
    }

    let content: Content
    /// The request a pass must cover for this hold to retire; nil until the write lands.
    var retiresAt: UInt64?

    var count: Int {
        switch content {
        case let .items(ids): ids.count
        case let .choices(choices): choices.count
        }
    }
}

/// One hold per act: a Move to Trash by its batch, choices by the window's number for them.
private nonisolated enum WindowHoldKey: Hashable {
    case trash(MediaTrashBatchID)
    case choices(UInt64)

    var diagnosticDescription: String {
        switch self {
        case let .trash(batch): "trash:\(batch.unixMilliseconds)"
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
/// stream consumer after the write returns. It records the kind of fact the write is
/// (`CatalogChangedFacts.membership` for a mark, `.choices` for a choice), so no held read
/// answers from before it, and rings the loop; the hold retires once a pass started after that
/// report covers its request — that pass read the catalog with the write in it, so what it
/// builds already lacks the items and its publication shares the held one's grid content:
/// nothing is applied twice. A held answer covers nothing, so it never retires a hold.
/// `withdrawn(_:storeChanged:)` drops a hold: a failed write republishes what was built, and an
/// undo that put the items back in the Store records the change and rings the loop, as the
/// landing does.
extension CatalogProjection {
    func apply(_ intent: CatalogProjectionIntent) {
        switch intent {
        case let .query(request):
            updateQueryRequest(request)
        case let .hide(ids, batch):
            hide(ids, batch: batch)
        case let .hideLanded(batch):
            hideLanded(batch)
        case let .hideWithdrawn(batch, storeChanged):
            hideWithdrawn(batch, storeChanged: storeChanged)
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
        hold(.trash(batch), WindowHold(content: .items(Set(ids))))
    }

    /// The Store's mark for `batch` is written: the next pass reads it.
    func hideLanded(_ batch: MediaTrashBatchID) {
        landed(.trash(batch), fact: .membership)
    }

    /// `batch`'s items come back: its mark failed, or its undo put them back in the Store.
    func hideWithdrawn(_ batch: MediaTrashBatchID, storeChanged: Bool) {
        withdrawn(.trash(batch), storeChanged: storeChanged)
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
        factRevisions.record(fact)
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
        let withdrawn = holds.removeValue(forKey: key) != nil
        if storeChanged {
            factRevisions.record(.membership)
            requestPublication(ringNow: true)
        }
        guard withdrawn else {
            return
        }
        republish()
        OtosLog.catalog.noticeOperation("projection.hold", phase: "withdrawn", fields: [
            "projection": diagnosticID,
            "hold": key.diagnosticDescription,
            "storeChanged": "\(storeChanged)",
        ])
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
            case (.trash, .choices):
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
    /// (ADR 0047); none before People is first published.
    func faceCandidates(for photos: [MediaAssetID]) async -> [FaceID: [FaceCandidate]] {
        guard let peopleAssignment else {
            return [:]
        }
        return await peopleAssignment.candidates(for: photos)
    }

    /// Asks People for a build after a People write the window made has landed, and returns
    /// the request a build must cover to have read it (`CatalogPeopleState.covers`); 0 before
    /// People has an owner, which any state covers.
    func requestPeopleBuild() async -> UInt64 {
        guard let peopleAssignment else {
            return 0
        }
        return await peopleAssignment.request()
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
                await storeDidChange(change)
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
            ? DuplicatesProjection(store: store, builder: duplicatesBuilder) : nil
        self.duplicatesProjection = duplicatesProjection
        let peopleAssignment = backgroundOwners.starts(.people)
            ? PeopleAssignment(store: store, builder: peopleBuilder) : nil
        self.peopleAssignment = peopleAssignment
        duplicatesRequested &+= 1
        peopleRequested &+= 1
        if let duplicatesProjection {
            duplicatesTask = Task { [weak self, duplicatesProjection] in
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
            peopleTask = Task { [weak self, peopleAssignment] in
                await peopleAssignment.start()
                for await built in peopleAssignment.builds {
                    guard let self else {
                        return
                    }
                    await publishPeople(built)
                }
            }
        }

        // The cadence task is the one that notices the owner is gone, so it also ends the
        // doorbell and the derived owners on every exit: `loopTask`, `duplicatesTask` and
        // `peopleTask` wait indefinitely, and a wait nothing can end keeps `store` alive
        // through its closure.
        cadenceTask = Task { [weak self, continuation, duplicatesProjection, peopleAssignment] in
            defer {
                continuation.finish()
                duplicatesProjection?.stop()
                peopleAssignment?.stop()
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

    func storeDidChange(_ change: CatalogStoreChange) {
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
        factRevisions.record(change.facts)
        // Rows that were only added carry nothing the groups or the assignment are built
        // from; they change People's unchecked tally alone. Any other change asks each owner
        // whose answer is built from a kind of fact it touched.
        if change == .assetsAdded {
            tallyRequested &+= 1
        } else {
            if !change.facts.isDisjoint(with: DuplicatesProjection.inputs) {
                duplicatesRequested &+= 1
            }
            if !change.facts.isDisjoint(with: PeopleAssignment.inputs) {
                peopleRequested &+= 1
            }
        }
        requestPublication(ringNow: publishedBeforeCatalogLoad)
    }

    /// Cancels the build or owed read in flight when it is for a descriptor other than the one
    /// now asked for. Synchronous: it runs in the step that applies the intent, so no await
    /// separates the intent from the cancellation.
    private func supersede() {
        guard let inFlight, !inFlight.answers(queryRequest.descriptor) else {
            return
        }
        supersededWork = inFlight.id
        OtosLog.catalog.noticeOperation("projection.publish", phase: "superseded", fields: [
            "projection": diagnosticID,
            "work": inFlight.kindName,
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
        _ kind: InFlightWork.Kind,
        _ work: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        nextWorkID &+= 1
        let id = nextWorkID
        let task = Task { [weak self] in
            let result = await Result { try await work() }
            await self?.workEnded(id)
            return try result.get()
        }
        inFlight = InFlightWork(id: id, kind: kind, cancel: { task.cancel() })
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
        defer { runningPasses -= 1 }
        let startedFrom = requested
        let duplicatesStartedFrom = duplicatesRequested
        let peopleStartedFrom = peopleRequested
        let tallyStartedFrom = tallyRequested
        let startedReads = reads
        let startedRevisions = factRevisions
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
            let build = try await supersedable(.build(selectedRequest.descriptor)) {
                try await self.buildWindowState(
                    store: store,
                    libraries: libraries,
                    request: selectedRequest,
                    reads: startedReads,
                    revisions: startedRevisions,
                    answerFromHeld: answerFromHeld
                )
            }
            // A cancelled pass is a teardown: whatever it read is not the catalog.
            try Task.checkCancellation()
            guard case let .built(state, buildMetrics, builtReads, owed) = build else {
                // Owed, not failed: the window keeps what it shows and says it is searching,
                // and the reader's report that the reading ended rings the loop.
                OtosLog.catalog.noticeOperation("projection.publish", phase: "searchReading", fields: [
                    "projection": diagnosticID,
                    "generation": "\(selectedRequest.generation)",
                ])
                publishSearchReading()
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
        let collapseSlot = CatalogProjectionReads.Slot(window.queryDescriptor.scope)
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
        let diagnostics = publish(
            CatalogProjectionCompletedPublication(
                state: window,
                buildMetrics: completed.buildMetrics,
                selectedDescriptor: completed.selectedDescriptor,
                timing: completed.timing
            ),
            selectedRequest: selectedRequest
        )
        await diagnostics.emit()
        // A cancelled pass is a teardown: the counters and the derived owners it would touch
        // now belong to no subscription, or to the next one.
        guard !Task.isCancelled else {
            return
        }
        // The window is published, so the reads it was built from stand whatever the options
        // read does.
        reads = passReads
        // What the window shows was held, and a fact it depends on moved since: the next pass
        // reads it again, and takes up the options and the derived owners. This one covers
        // nothing.
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
        if let owedOptions {
            guard await readOwedFilterOptions(owedOptions, request: selectedRequest, store: store) else {
                return
            }
        }
        covered = startedFrom
        retireHolds(coveredFrom: startedFrom)
        ringIfBehind()
        // An injected test builder derives nothing. Otherwise a pass that took up a change
        // an owner's answer is built from asks that owner for a build, and one that took up
        // added rows asks People for its tally; it waits for neither.
        // An owner a tour left unstarted (`BackgroundOwners`) is nil and is asked nothing.
        guard stateBuilder == nil else {
            return
        }
        let asksDuplicates = duplicatesStartedFrom != duplicatesForwarded
        let asksPeople = peopleStartedFrom != peopleForwarded
        let asksTally = tallyStartedFrom != tallyForwarded
        duplicatesForwarded = duplicatesStartedFrom
        peopleForwarded = peopleStartedFrom
        tallyForwarded = tallyStartedFrom
        if asksDuplicates, let duplicatesProjection {
            await duplicatesProjection.request()
        }
        guard let peopleAssignment else {
            return
        }
        if asksPeople {
            // A full People pass reads the tally too.
            await peopleAssignment.request()
        } else if asksTally {
            await peopleAssignment.requestTally()
        }
    }

    /// Reads the options the published window owes and republishes it with them. False when
    /// the read was superseded, torn down or failed: the pass then covers nothing.
    private func readOwedFilterOptions(
        _ owed: OwedFilterOptions,
        request: CatalogQueryRequest,
        store: CatalogStore
    ) async -> Bool {
        let read: (options: CatalogFilterOptions, ms: Int)
        do {
            read = try await supersedable(.filterOptions(row: owed.row)) {
                try await self.readFilterOptions(owed, store: store)
            }
            try Task.checkCancellation()
        } catch {
            endUnpublishedPass(error, request: request)
            return false
        }
        reads.filterOptions = CatalogProjectionReads.FilterOptions(
            row: owed.row,
            availableLibraryPaths: owed.availableLibraryPaths,
            placeNameLanguages: owed.placeNameLanguages,
            revisions: owed.revisions,
            answer: read.options
        )
        let republished = publishFilterOptions(read.options, row: owed.row)
        OtosLog.catalog.noticeOperation("projection.filterOptions", phase: "read", fields: [
            "projection": diagnosticID,
            "generation": "\(request.generation)",
            "row": owed.row.diagnosticDescription,
            "ms": "\(read.ms)",
            "republished": "\(republished)",
        ])
        return true
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

    /// Normalizes the selection the build resolved, compares against the last published
    /// state, and yields it if it changed. Synchronous.
    func publish(
        _ publication: CatalogProjectionCompletedPublication,
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
        lastBuiltState = publication.state
        let state = publication.state.hidingItems(hiddenItems(for: publication.state.queryDescriptor))
            .sharingUnchanged(with: lastPublishedState)
        let changeSummary = CatalogProjectionChangeSummary.compare(
            previous: lastPublishedState,
            current: state
        )
        let stateChanged = changeSummary.stateChanged
        let equalityUs = DiagnosticsTiming.microseconds(since: equalityStart)
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
            orderQueryCount: orderQueryCount
        )
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
        OtosLog.catalog.notice("op=projection.publish phase=loadingCatalog")
        if loading != lastPublishedState {
            yield(loading)
        }
    }

    /// Republishes the last built state changed by `change`, with what the hides take off it,
    /// when the result differs from the last publication. Synchronous.
    private func republish(_ change: (inout CatalogWindowState) -> Void = { _ in }) {
        guard var built = lastBuiltState else {
            return
        }
        change(&built)
        lastBuiltState = built
        let state = built.hidingItems(hiddenItems(for: built.queryDescriptor)).sharingUnchanged(with: lastPublishedState)
        if state != lastPublishedState {
            yield(state)
        }
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
        peopleTask?.cancel()
        peopleTask = nil
        duplicatesRequested = 0
        duplicatesForwarded = 0
        peopleRequested = 0
        peopleForwarded = 0
        tallyRequested = 0
        tallyForwarded = 0
        changeTask?.cancel()
        changeTask = nil
        loopTask?.cancel()
        loopTask = nil
        cadenceTask?.cancel()
        cadenceTask = nil
        doorbell?.finish()
        doorbell = nil
        requested = 0
        covered = 0
        reads = .none
        lastPublishedState = nil
        lastBuiltState = nil
        holds = [:]
        duplicates = nil
        people = nil
        orderQueryCount = 0
        filterOptionsQueryCount = 0
        stackReadCount = 0
        inFlight = nil
        supersededWork = nil
        heldPublishedGeneration = nil
    }
}

/// The work a pass waits on, for `CatalogProjection.supersede()`.
private nonisolated struct InFlightWork {
    enum Kind {
        /// The window's build for this descriptor: it answers only this descriptor.
        case build(CatalogQueryDescriptor)
        /// The options of this sidebar row: they answer every descriptor shown under it, so a
        /// filter or sort change on the row leaves them standing.
        case filterOptions(row: SidebarSelection)
    }

    let id: UInt64
    let kind: Kind
    let cancel: @Sendable () -> Void

    /// Whether this work's answer is still asked for when the window asks for `descriptor`.
    func answers(_ descriptor: CatalogQueryDescriptor) -> Bool {
        switch kind {
        case let .build(built):
            built == descriptor
        case let .filterOptions(row):
            descriptor.scope.sidebarRow == row
        }
    }

    var scope: SidebarSelection {
        switch kind {
        case let .build(descriptor):
            descriptor.scope
        case let .filterOptions(row):
            row
        }
    }

    var kindName: String {
        switch kind {
        case .build: "build"
        case .filterOptions: "filterOptions"
        }
    }
}

/// The pass waiting on the supersedable work `id`.
private nonisolated struct WorkWaiter {
    let id: UInt64
    let continuation: CheckedContinuation<Void, Never>
}

/// A pass's work was cancelled by an intent that left the descriptor it was for.
nonisolated struct CatalogProjectionWorkSuperseded: Error {}
