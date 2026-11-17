import AppKit
import Foundation
import Observation
import OSLog

/// A background owner the window starts at launch. A tour can leave any of them unstarted
/// for its session, to measure what the app does without it ("what if it were free").
nonisolated enum BackgroundOwner: String, CaseIterable, Sendable {
    /// `EnrichmentCoordinator`, with the `MaterializationCoordinator` it feeds.
    case enrichment
    case metadataRefresh
    case renderSignatures
    case previewFaces
    case placeNames
    /// Keyword search's index, its embeddings and its text (ADR 0048).
    case searchIndex
    case descriptions
    /// `DuplicatesProjection` (ADR 0042).
    case duplicates
    /// `PeopleAssignment` (ADR 0047).
    case people
    /// The Immich accounts: their sync and mirror probes (ADR 0046).
    case immich
}

/// Which background owners a session starts. Every one, always, except in a tour
/// (`SmokeTour`) that names some to leave out: a release build has no tour, and a debug build
/// honours the list only beside `OTOS_TOUR=1`. An owner left out is simply not started;
/// nothing is written to say so, so the catalog is exactly as it would be after a quit.
nonisolated struct BackgroundOwners: Equatable, Sendable {
    let off: Set<BackgroundOwner>

    static let all = BackgroundOwners(off: [])

    func starts(_ owner: BackgroundOwner) -> Bool {
        !off.contains(owner)
    }

    /// The owners this launch starts.
    static func configured(environment: [String: String] = ProcessInfo.processInfo.environment) -> BackgroundOwners {
        #if DEBUG
            guard let tour = SmokeTour.Configuration(environment: environment) else {
                return .all
            }
            return BackgroundOwners(off: tour.ablated)
        #else
            return .all
        #endif
    }

    /// `none`, `all`, or owners by name, comma-separated. The names it does not know are
    /// returned beside the set, so a typo is reported rather than measured as nothing.
    static func parse(_ raw: String) -> (owners: Set<BackgroundOwner>, unknown: [String]) {
        let names = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if names == ["none"] || names.isEmpty {
            return ([], [])
        }
        if names == ["all"] {
            return (Set(BackgroundOwner.allCases), [])
        }
        var owners = Set<BackgroundOwner>()
        var unknown: [String] = []
        for name in names {
            if let owner = BackgroundOwner(rawValue: name) {
                owners.insert(owner)
            } else {
                unknown.append(name)
            }
        }
        return (owners, unknown)
    }
}

extension PaneOriginalDownloads {
    /// The panes' downloads this launch allows: never in a tour, which is read-only (a
    /// release build has no tour), whenever needed otherwise.
    nonisolated static func configured(environment: [String: String] = ProcessInfo.processInfo.environment) -> PaneOriginalDownloads {
        #if DEBUG
            SmokeTour.Configuration(environment: environment) == nil ? .whenNeeded : .never
        #else
            .whenNeeded
        #endif
    }
}

extension PreferencesDomain {
    /// The preferences this launch reads and writes: the user's own (`.standard`), except in
    /// a tour, which is read-only (a release build has no tour) and so reads them and keeps
    /// every write in memory (`.sessionOnly(.standard)`). The tour's filter, sort, scope and
    /// zoom are then the visible session's alone, and a tour ended at any point — cut by the
    /// script, crashed, or quit before its restore step — leaves the user's saved place and
    /// settings exactly as they were.
    nonisolated static func configured(environment: [String: String] = ProcessInfo.processInfo.environment) -> PreferencesDomain {
        #if DEBUG
            SmokeTour.Configuration(environment: environment) == nil ? .standard : .sessionOnly(.standard)
        #else
            .standard
        #endif
    }
}

#if DEBUG
    /// Read-only performance tour guide
    ///
    /// `OTOS_TOUR=1` makes a session tour itself once its first grid is in, so what the owner
    /// feels can be measured the same way every time (ADR 0015, the scorecard). Every step is
    /// a gesture's own intent on the window's view model — the sidebar's `selectSidebar`, the
    /// gallery's `openPerson`, the grid's focus, Return's `openLoupe`, the arrow keys'
    /// `focusNext`, the search field's `setSearchText`, the filter's and sort menu's setters —
    /// so the tour measures the path a click takes, not a parallel one. Each step waits on the
    /// fact the app reports when it is done (a paint, the visible thumbnails, the loupe's
    /// image, a query's published state); its only clock is a deadline, so a step that never
    /// reports is logged as one and cannot hang the tour.
    ///
    /// The tour changes nothing: no choice, Trash, edit, import, naming or download. A photo
    /// is opened only when the loupe can show it without a download — its original is on
    /// this Mac (`OriginalLocality.local`) or its preview is stored (ADR 0035) — and the
    /// panes' requester refuses every download for the session (`PaneOriginalDownloads.never`),
    /// so a full-resolution decode of a cloud-only photo is never asked of its provider. A
    /// tour session writes no preference of Otos's: its domain is `.sessionOnly(.standard)`
    /// (`PreferencesDomain.configured`), so the place saved at quit, the grid's zoom and every
    /// other setting stay in memory and the owner's stored ones are untouched however the
    /// session ends (AppKit's own frame autosave writes only when the window or the sidebar's
    /// divider moves, which no step does; ADR 0020). The window is still put back as it was — scope, filter, sort, search,
    /// mode, focus, selection, inspector — before the app quits, for the visible session and
    /// so the tour's last steps time a return to where it started.
    ///
    /// The one exception is the act steps (Like, Dislike, Not Rated, Move to Trash), which
    /// time an act to its result on the grid. They run only in a sandbox home
    /// (`CFFIXED_USER_HOME`, not the user's own) whose every source lies inside it on a volume
    /// mounted inside it, so Move to Trash moves into that volume's own Trash and never into
    /// the account's (`SmokeTour.trashStays`). They put each photo back as it was (the last
    /// choice is its own, Undo puts the trashed photo back), and are skipped with the reason
    /// (`notSandboxHome`, `sourceOutsideSandbox`, `trashOutsideSandbox`) everywhere else.
    ///
    /// Each step logs `op=tour phase=step`; the session opens with `op=tour phase=config`
    /// and ends with `op=tour phase=finish`, after which the app quits itself.
    nonisolated enum SmokeTour {
        static let tourVariable = "OTOS_TOUR"
        /// Owners to leave unstarted: `none`, `all`, or names (`BackgroundOwner`).
        static let ablateVariable = "OTOS_TOUR_ABLATE"
        /// `full` (default), or `scopes`: the sidebar steps alone, for a short session.
        static let stepsVariable = "OTOS_TOUR_STEPS"
        static let idleVariable = "OTOS_TOUR_IDLE_SECONDS"
        static let deadlineVariable = "OTOS_TOUR_STEP_DEADLINE_SECONDS"
        /// `launch` (default): the first step as soon as the first grid is in, under the
        /// launch's own load. `settled`: once the launch's background work has settled
        /// (`CatalogWindowViewModel.launchSettlement`), as a person's session meets it; for a
        /// tour that registers its library, once the work that library's first walk raised has
        /// (`CatalogWindowViewModel.untilOwnersCaughtUp`).
        static let startVariable = "OTOS_TOUR_START"
        /// The longest a settled tour waits for the settlement before it starts anyway.
        static let settleDeadlineVariable = "OTOS_TOUR_SETTLE_DEADLINE_SECONDS"
        /// The longest a tour waits for the sandbox library it registers to finish its first
        /// walk before it fails (`sandboxLibraryNeverScanned`): a walk of the owner's library
        /// size takes minutes, more than a step's deadline, on a loaded Mac.
        static let libraryDeadlineVariable = "OTOS_TOUR_LIBRARY_DEADLINE_SECONDS"
        /// Fixed queries: a common word with many matches, a rarer one with few.
        static let manyResultsQuery = "sky"
        static let fewResultsQuery = "lighthouse"
        /// How far apart the scroll steps land, in items, so each moves the viewport.
        static let scrollStride = 300
        /// How many of a scope's first items are looked at for photos the loupe can open.
        static let openablePhotoSearchLimit = 400
        /// The photos the photo steps open, in order: the first, three next, three back.
        static let openablePhotoRun = 4

        struct Configuration: Equatable, Sendable {
            enum Steps: String, Sendable {
                case full
                case scopes
            }

            let steps: Steps
            let ablated: Set<BackgroundOwner>
            let unknownOwners: [String]
            let idle: Duration
            let stepDeadline: Duration
            /// When the first step runs (`SmokeTour.startVariable`).
            let start: Start
            let settleDeadline: Duration
            let libraryDeadline: Duration

            enum Start: String, Sendable {
                case launch
                case settled
            }

            /// Nil unless `OTOS_TOUR=1`: without it nothing here, the owner list included, is read.
            init?(environment: [String: String]) {
                guard environment[SmokeTour.tourVariable] == "1" else {
                    return nil
                }
                let parsed = BackgroundOwners.parse(environment[SmokeTour.ablateVariable] ?? "none")
                ablated = parsed.owners
                unknownOwners = parsed.unknown
                steps = Steps(rawValue: environment[SmokeTour.stepsVariable] ?? "full") ?? .full
                idle = .seconds(Int(environment[SmokeTour.idleVariable] ?? "") ?? (steps == .full ? 60 : 0))
                stepDeadline = .seconds(Int(environment[SmokeTour.deadlineVariable] ?? "") ?? 120)
                start = Start(rawValue: environment[SmokeTour.startVariable] ?? "launch") ?? .launch
                settleDeadline = .seconds(Int(environment[SmokeTour.settleDeadlineVariable] ?? "") ?? 900)
                libraryDeadline = .seconds(Int(environment[SmokeTour.libraryDeadlineVariable] ?? "") ?? 900)
            }
        }

        /// One step of the tour.
        enum Step: Equatable, Sendable {
            /// A sidebar row: `label` names its kind for the scorecard.
            case scope(label: String, selection: SidebarSelection)
            /// The gallery's most photographed person, chosen when the step is reached.
            case mostPhotographedPerson
            /// Duplicates, once the groups the launch owes are built: its row is clicked when a
            /// group is active, the only time the sidebar shows it.
            case duplicates
            /// The grid's focus moved to this position in the scope's order.
            case scroll(label: String, position: Position)
            case openPhoto
            case nextPhoto
            case previousPhoto
            case compare
            case info
            /// The `n`th choice (0, 1, 2) on the first photo, timed to its result: the three
            /// choices in turn, starting after the photo's own and ending on it. Only in a
            /// sandbox home.
            case choiceAct(Int)
            /// Move to Trash on the first photo, timed to its result, then undone. Only in a
            /// sandbox home.
            case trashAct
            /// Five Move to Trash acts in a row, each issued once the one before shows its
            /// result, as Delete pressed quickly is, then five Undos the same way; each act is
            /// timed to its result. Only in a sandbox home.
            case trashRun
            case search(label: String, text: String)
            /// A kind the scope's published filter options offer, chosen when the step runs.
            case filterByOfferedKind
            case sortByName
            case idle
        }

        enum Position: Equatable, Sendable {
            case index(Int)
            case middle
            case end
        }

        /// The steps for a window whose catalog has loaded. Rows the sidebar does not show are
        /// left out, and so are the owners' scopes a tour left unstarted.
        static func plan(
            for state: CatalogWindowState,
            configuration: Configuration,
            today: CalendarDay
        ) -> [Step] {
            let owners = BackgroundOwners(off: configuration.ablated)
            let hasFixedLibrary = SidebarSelectionPolicy.showsPlaces(libraries: state.libraries)
            // All Media is a sidebar row only with two or more fixed libraries; with one, its
            // library is the scope the tour browses, first and on its return.
            let library = state.libraries.first.map { Step.scope(label: "library", selection: .library($0.path)) }
            let browse: Step = if let library, !SidebarSelectionPolicy.showsAllMedia(libraries: state.libraries) {
                library
            } else {
                .scope(label: "allMedia", selection: .allMedia)
            }
            var steps: [Step] = [browse]
            if let newest = state.importBatches.first {
                steps.append(.scope(label: "import", selection: .importBatch(newest.batchID)))
            }
            if let library, library != browse {
                steps.append(library)
            }
            if hasFixedLibrary {
                if owners.starts(.people) {
                    steps.append(.scope(label: "people", selection: .people))
                    steps.append(.mostPhotographedPerson)
                }
                steps.append(.scope(label: "places", selection: .places))
                steps.append(.scope(label: "onThisDay", selection: .onThisDay(today)))
            }
            if owners.starts(.duplicates) {
                steps.append(.duplicates)
            }
            steps.append(browse)
            guard configuration.steps == .full else {
                steps.append(.idle)
                return steps
            }
            steps += [
                .scroll(label: "down", position: .index(scrollStride)),
                .scroll(label: "down", position: .index(2 * scrollStride)),
                .scroll(label: "down", position: .index(3 * scrollStride)),
                .scroll(label: "middle", position: .middle),
                .scroll(label: "end", position: .end),
                .scroll(label: "top", position: .index(0)),
                .openPhoto,
                .nextPhoto, .nextPhoto, .nextPhoto,
                .previousPhoto, .previousPhoto, .previousPhoto,
                .compare,
                .info,
                .choiceAct(0), .choiceAct(1), .choiceAct(2), .trashAct, .trashRun,
                .search(label: "searchMany", text: manyResultsQuery),
                .search(label: "searchFew", text: fewResultsQuery),
                .search(label: "searchClear", text: ""),
                .filterByOfferedKind,
                .sortByName,
                .idle,
            ]
            return steps
        }

        /// The index a scroll position names in an order of `count` items; nil when it names
        /// none, or the order is too short for the steps to move the viewport.
        static func index(of position: Position, count: Int) -> Int? {
            guard count > 3 * scrollStride else {
                return nil
            }
            return switch position {
            case let .index(index): min(index, count - 1)
            case .middle: count / 2
            case .end: count - 1
            }
        }

        /// The sandbox home this session runs in: `CFFIXED_USER_HOME`, resolved, when it is the
        /// process's home and neither the user's own home nor a folder holding it. Nil
        /// otherwise, and then the act steps are refused.
        static func sandboxHome(
            environment: [String: String],
            processHome: String = NSHomeDirectory(),
            userHome: String? = SmokeTour.accountHome()
        ) -> String? {
            guard let fixed = environment["CFFIXED_USER_HOME"], !fixed.isEmpty, let userHome else {
                return nil
            }
            let sandbox = resolved(fixed)
            let user = resolved(userHome)
            guard sandbox != "/", sandbox == resolved(processHome), sandbox != user,
                  !user.hasPrefix(sandbox + "/")
            else {
                return nil
            }
            return sandbox
        }

        /// Whether every source the window lists lies inside `sandbox`, so an act there
        /// touches only files the sandbox holds.
        static func sourcesLie(_ state: CatalogWindowState, inside sandbox: String) -> Bool {
            let roots = sources(of: state)
            return !roots.isEmpty && roots.allSatisfy { lies($0.rawValue, inside: sandbox) }
        }

        /// Whether the Trash that Move to Trash uses for every source lies inside `sandbox`.
        ///
        /// `FileManager.trashItem` keeps an item on its own volume: on the volume that holds the
        /// account's home it moves it into that account's `~/.Trash`, found from the user
        /// database and not from `HOME` or `CFFIXED_USER_HOME`, and on any other volume into
        /// that volume's `.Trashes/<uid>` (measured on macOS 27:
        /// `docs/research/2026-11-16-trash-destination-by-volume.md`). So a sandbox home on the
        /// boot volume still trashes into the account's own Trash, and only a source whose
        /// volume is mounted inside the sandbox (`script/sandbox-library.sh`) trashes into a
        /// Trash the sandbox holds. `volumeRoot` names a folder's volume mount point; a volume
        /// it cannot name never passes.
        static func trashStays(
            _ state: CatalogWindowState,
            inside sandbox: String,
            volumeRoot: (String) -> String? = SmokeTour.volumeRoot(of:)
        ) -> Bool {
            let roots = sources(of: state)
            return !roots.isEmpty && roots.allSatisfy { root in
                volumeRoot(root.rawValue).map { lies($0, inside: sandbox) } ?? false
            }
        }

        /// The mount point of the volume holding `path`, resolved; nil when the system does
        /// not say.
        static func volumeRoot(of path: String) -> String? {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            return (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume.map { resolved($0.path(percentEncoded: false)) }
        }

        /// Whether `path`, resolved, lies strictly inside `folder`.
        static func lies(_ path: String, inside folder: String) -> Bool {
            resolved(path).hasPrefix(resolved(folder) + "/")
        }

        private static func sources(of state: CatalogWindowState) -> [LibraryRootPath] {
            state.libraries.map(\.path) + state.removableSources.map(\.path)
        }

        /// The account's own home from the user database, which `CFFIXED_USER_HOME` does not
        /// change.
        static func accountHome() -> String? {
            guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
                return nil
            }
            return String(cString: directory)
        }

        /// A folder's path with its symlinks resolved and no trailing slash.
        private static func resolved(_ path: String) -> String {
            let url = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            let text = url.path(percentEncoded: false)
            return text.count > 1 && text.hasSuffix("/") ? String(text.dropLast()) : text
        }

        /// The three choices in turn, starting after `original` and ending on it, so every act
        /// changes what the tile shows and the last puts it back.
        static func choiceCycle(after original: MediaChoice) -> [MediaChoice] {
            let all = MediaChoice.allCases
            let start = (all.firstIndex(of: original) ?? 0) + 1
            return (0 ..< all.count).map { all[(start + $0) % all.count] }
        }

        /// The first run of `openablePhotoRun` neighbours in `order` that all satisfy
        /// `openable`, as their ids; nil when the order has none.
        static func firstOpenableRun(in order: [MediaAssetID], openable: Set<MediaAssetID>) -> [MediaAssetID]? {
            guard order.count >= openablePhotoRun else {
                return nil
            }
            for start in 0 ... (order.count - openablePhotoRun) {
                let run = Array(order[start ..< start + openablePhotoRun])
                if run.allSatisfy(openable.contains) {
                    return run
                }
            }
            return nil
        }

        /// Starts the tour when the environment asks for one. The tour holds the view model
        /// weakly and ends with it; `quit` ends the app once the window is put back.
        @MainActor
        static func applyIfPresent(
            to viewModel: CatalogWindowViewModel,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            quit: @escaping @MainActor () -> Void = { NSApp?.terminate(nil) }
        ) {
            guard let configuration = Configuration(environment: environment) else {
                return
            }
            let runner = SmokeTourRunner(viewModel: viewModel, configuration: configuration, environment: environment, quit: quit)
            Task { await runner.run() }
        }
    }

    /// Runs one tour: plans it from the first loaded window, takes each step through the
    /// window's own intents, puts the window back and quits.
    @MainActor
    final class SmokeTourRunner {
        private weak var viewModel: CatalogWindowViewModel?
        private let configuration: SmokeTour.Configuration
        private let quit: @MainActor () -> Void
        private let environment: [String: String]
        private var visited: Set<SidebarSelection> = []
        /// The photos the photo steps open: neighbours the loupe shows without a download.
        private var openablePhotos: [MediaAssetID] = []
        /// The tile the choice acts act on and its choice before them, which the last one
        /// puts back; chosen by the first choice act.
        private var choiceTarget: (id: MediaAssetID, original: MediaChoice)?

        init(
            viewModel: CatalogWindowViewModel,
            configuration: SmokeTour.Configuration,
            environment: [String: String],
            quit: @escaping @MainActor () -> Void
        ) {
            self.viewModel = viewModel
            self.configuration = configuration
            self.environment = environment
            self.quit = quit
        }

        /// What the window showed before the tour, put back after it.
        private struct WindowPlace {
            let descriptor: CatalogQueryDescriptor
            let searchText: String
            let viewMode: BrowserViewMode
            let focus: MediaAssetID?
            let selection: GridSelection
            let inspector: InspectorPane?
        }

        func run() async {
            let fields: [String: String] = [
                "steps": configuration.steps.rawValue,
                "ablated": configuration.ablated.isEmpty ? "none" : configuration.ablated.map(\.rawValue).sorted().joined(separator: ","),
                "idleSeconds": "\(configuration.idle.components.seconds)",
                "deadlineSeconds": "\(configuration.stepDeadline.components.seconds)",
                "start": configuration.start.rawValue,
            ]
            guard configuration.unknownOwners.isEmpty else {
                OtosLog.performance.errorOperation("tour", phase: "failed", fields: fields.merging([
                    "reason": "unknownOwner", "unknown": configuration.unknownOwners.joined(separator: ","),
                ]) { $1 })
                await finish(outcome: "failed")
                return
            }
            if configuration.ablated.isEmpty {
                OtosLog.performance.noticeOperation("tour", phase: "config", fields: fields)
            } else {
                // Loud: a session with owners off must never pass for an ordinary one.
                OtosLog.performance.errorOperation("tour", phase: "config", fields: fields.merging(["ownersOff": "true"]) { $1 })
            }
            // The first grid is the first state applied after the catalog's load.
            guard await until({ $0.state.isCatalogLoaded }), viewModel != nil else {
                OtosLog.performance.errorOperation("tour", phase: "failed", fields: ["reason": "catalogNeverLoaded"])
                await finish(outcome: "failed")
                return
            }
            // A sandbox library this launch registers (`SandboxLibrary`) is toured once its
            // first scan has delivered, so the plan sees it: up to the library deadline, since a
            // walk of the owner's library size outlasts a step's.
            let library = SandboxLibrary.requestedPath(environment: environment)
            if let library {
                guard await until(deadline: configuration.libraryDeadline, { SandboxLibrary.isScanned(library, in: $0.state) }) else {
                    OtosLog.performance.errorOperation("tour", phase: "failed", fields: [
                        "reason": "sandboxLibraryNeverScanned", "rootPath": library.rawValue,
                    ])
                    await finish(outcome: "failed")
                    return
                }
                OtosLog.performance.noticeOperation("tour", phase: "library", fields: ["rootPath": library.rawValue])
            }
            if configuration.start == .settled {
                if library != nil {
                    await waitForSettlementAfterLibrary()
                } else {
                    await waitForSettlement()
                }
            }
            guard let viewModel else {
                await finish(outcome: "failed")
                return
            }
            let place = WindowPlace(
                descriptor: viewModel.queryDescriptor,
                searchText: viewModel.searchText,
                viewMode: viewModel.viewMode,
                focus: viewModel.focusedAssetID,
                selection: viewModel.gridSelection,
                inspector: viewModel.inspectorPane
            )
            visited.insert(viewModel.sidebarSelection)
            let steps = SmokeTour.plan(for: viewModel.state, configuration: configuration, today: viewModel.today)
            OtosLog.performance.noticeOperation("tour", phase: "plan", fields: [
                "steps": "\(steps.count)",
                "startScope": viewModel.sidebarSelection.diagnosticDescription,
            ])
            if viewModel.viewMode != .grid {
                viewModel.setViewMode(.grid)
            }
            for (index, step) in steps.enumerated() {
                await take(step, index: index + 1)
            }
            await restore(place)
            await finish(outcome: "finished")
        }

        /// A settled tour on the libraries the launch restored waits for the launch's work to settle
        /// (`LaunchSettlement.launchWork`: every owner covered what it owed once all had started,
        /// or works only its own backlog, as enrichment's hashing of a cloud library does for
        /// hours), up to the settle deadline; either way it says what it met
        /// (`op=tour phase=settled by=launchWork|ownersQuiescent|deadline`), and the scorecard
        /// labels the session by it.
        private func waitForSettlement() async {
            let started = ContinuousClock.now
            let settled = await until(deadline: configuration.settleDeadline) { model in
                model.launchSettlement.map { $0 >= .launchWork } ?? false
            }
            OtosLog.performance.noticeOperation("tour", phase: "settled", fields: [
                "by": settled ? (viewModel?.launchSettlement?.rawValue ?? "windowGone") : "deadline",
                "waitMs": "\(DiagnosticsTiming.milliseconds(since: started))",
            ])
        }

        /// A settled tour that added its library waits for the work that library raised, not
        /// for the launch's: the launch's stages were judged on the catalog before the library
        /// (empty, for a sandbox home), so they could be met before its walk began. From the
        /// moment its first walk is complete it waits, up to the settle deadline, for every
        /// owner caught up to that moment (`CatalogWindowViewModel.untilOwnersCaughtUp`): the
        /// requests the walk's rows raised covered, the backlogs still walking
        /// (`by=libraryWork`, with them named).
        private func waitForSettlementAfterLibrary() async {
            let started = ContinuousClock.now
            let settled: [OwnerCaughtUp]?? = await first(deadline: configuration.settleDeadline) { viewModel in
                // Thrown only when the deadline cancelled the wait, whose answer is then unread.
                try await viewModel.untilOwnersCaughtUp()
            }
            var fields = ["waitMs": "\(DiagnosticsTiming.milliseconds(since: started))"]
            switch settled {
            case let .some(.some(facts)):
                fields["by"] = "libraryWork"
                let backlog = facts.filter(\.backlog).map(\.owner)
                fields["backlog"] = backlog.isEmpty ? "none" : backlog.joined(separator: ",")
            case .some(.none):
                fields["by"] = "noOwners"
            case .none:
                fields["by"] = "deadline"
            }
            OtosLog.performance.noticeOperation("tour", phase: "settled", fields: fields)
        }

        /// The answer of `work` on the window, or nil once `deadline` passes, the window is
        /// gone or the work threw first. `until`'s race, for a fact an owner reports by
        /// returning rather than one the window shows.
        private func first<Answer: Sendable>(
            deadline: Duration,
            _ work: @escaping @MainActor (CatalogWindowViewModel) async throws -> Answer
        ) async -> Answer? {
            guard let viewModel else {
                return nil
            }
            let (answers, answer) = AsyncStream<Answer?>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let worker = Task { @MainActor [weak viewModel] in
                guard let viewModel else {
                    answer.yield(nil)
                    return
                }
                do {
                    let result = try await work(viewModel)
                    answer.yield(result)
                } catch {
                    answer.yield(nil)
                }
            }
            let timer = Task {
                // time: deadline — a settlement that never comes must not hang the tour
                try? await Task.sleep(for: deadline)
                answer.yield(nil)
            }
            var met: Answer?
            for await first in answers {
                met = first
                break
            }
            worker.cancel()
            timer.cancel()
            answer.finish()
            return met
        }

        /// Ends the tour: what every background owner still owed or ran at its end
        /// (`op=owners.status phase=sessionEnd`), then the finish line, and the app quits.
        private func finish(outcome: String) async {
            if let viewModel {
                await BackgroundOwnerQuiescence.logStatus(viewModel.ownerStatuses(), moment: "sessionEnd")
            }
            OtosLog.performance.noticeOperation("tour", phase: "finish", fields: ["outcome": outcome])
            ResourceCheckpoint.record("tourFinish", storeUse: storeUse)
            ResourceCheckpoint.flush()
            quit()
        }

        private var storeUse: (@Sendable () -> CatalogStoreUse)? {
            guard let store = viewModel?.catalogStore else {
                return nil
            }
            return { store.use() }
        }

        /// One step's result, logged and checkpointed.
        struct Outcome {
            var result: String
            var fields: [String: String] = [:]

            static func reported(_ fields: [String: String] = [:]) -> Outcome {
                Outcome(result: "reported", fields: fields)
            }

            static func skipped(_ reason: String) -> Outcome {
                Outcome(result: "skipped", fields: ["reason": reason])
            }

            static let deadline = Outcome(result: "deadline")
        }

        private func take(_ step: SmokeTour.Step, index: Int) async {
            let started = ContinuousClock.now
            let (kind, label, outcome) = await perform(step)
            var fields = outcome.fields
            fields["index"] = "\(index)"
            fields["kind"] = kind
            fields["label"] = label
            fields["outcome"] = outcome.result
            fields["ms"] = "\(DiagnosticsTiming.milliseconds(since: started))"
            if outcome.result == "deadline" {
                OtosLog.performance.errorOperation("tour", phase: "step", fields: fields)
            } else {
                OtosLog.performance.noticeOperation("tour", phase: "step", fields: fields)
            }
            ResourceCheckpoint.record("tourStep", fields: ["step": "\(index)", "label": label], storeUse: storeUse)
        }

        private func perform(_ step: SmokeTour.Step) async -> (String, String, Outcome) {
            switch step {
            case let .scope(label, selection):
                return await ("scope", label, select(selection))
            case .mostPhotographedPerson:
                let people = viewModel?.peopleState.visiblePeople ?? []
                guard let person = people.max(by: { $0.media.photos + $0.media.videos < $1.media.photos + $1.media.videos }) else {
                    return ("scope", "person", .skipped("noPeople"))
                }
                return await ("scope", "person", select(.person(person.id)) { $0.openPerson(person.id) })
            case .duplicates:
                return await ("scope", "duplicates", duplicates())
            case let .scroll(label, position):
                return await ("scroll", label, scroll(to: position))
            case .openPhoto:
                return await ("photo", "open", openPhoto())
            case .nextPhoto:
                return await ("photo", "next", stepPhoto(by: 1))
            case .previousPhoto:
                return await ("photo", "previous", stepPhoto(by: -1))
            case .compare:
                return await ("compare", "compare", compare())
            case .info:
                return await ("info", "info", info())
            case let .choiceAct(index):
                if let refusal = actsRefusal() {
                    return ("act", "choice\(index)", .skipped(refusal))
                }
                return await choiceAct(index)
            case .trashAct:
                return await ("act", WindowAct.moveToTrash.name, trashAct())
            case .trashRun:
                return await ("act", "trashRun", trashRun())
            case let .search(label, text):
                // The field takes focus and the query is typed at once: the least time the
                // focus's preparation can have before the first query (`searchFieldFocused`).
                return await ("search", label, query {
                    $0.searchFieldFocused()
                    $0.setSearchText(text)
                })
            case .filterByOfferedKind:
                return await filterByOfferedKind()
            case .sortByName:
                return await ("sort", "name", query { $0.setSortOrder(.filenameAscending) })
            case .idle:
                return await ("idle", "idle", idle())
            }
        }

        /// Selects a scope and waits for its paint. `act` is the gesture's own intent, the
        /// sidebar's by default.
        private func select(
            _ selection: SidebarSelection,
            act: ((CatalogWindowViewModel) -> Void)? = nil
        ) async -> Outcome {
            guard let viewModel else {
                return .skipped("windowGone")
            }
            guard viewModel.sidebarSelection != selection else {
                return .skipped("alreadyShown")
            }
            let first = !visited.contains(selection)
            visited.insert(selection)
            let before = viewModel.lastSidebarPaint?.revision ?? 0
            if let act {
                act(viewModel)
            } else {
                viewModel.selectSidebar(selection)
            }
            let painted = await until { model in
                guard let paint = model.lastSidebarPaint else {
                    return false
                }
                return paint.revision > before && paint.scope == selection
            }
            var fields = ["scope": selection.diagnosticDescription, "first": "\(first)"]
            guard painted, let paint = self.viewModel?.lastSidebarPaint else {
                return Outcome(result: "deadline", fields: fields)
            }
            fields["paintMs"] = "\(paint.milliseconds)"
            fields["surface"] = paint.surface
            fields["items"] = "\(self.viewModel?.state.mediaGrid.orderedAssetIDs.count ?? 0)"
            return .reported(fields)
        }

        /// Duplicates once the groups the launch owed are built and shown
        /// (`LaunchSettlement.duplicatesBuilt`, then `showsLaunchDuplicates`) — not once
        /// enrichment's digests stop asking for more builds, which a backlog puts off for the
        /// whole session — timed from
        /// the click to its paint like any scope. With no active group the sidebar has no row
        /// to click, and the step reports `groups=0` rather than a click.
        private func duplicates() async -> Outcome {
            let waitStart = ContinuousClock.now
            let built = await until { $0.showsLaunchDuplicates }
            guard built, let viewModel else {
                return Outcome(result: "deadline", fields: ["reason": "duplicatesNeverBuilt"])
            }
            let fields = [
                "groups": "\(viewModel.duplicatesCount ?? 0)",
                "buildWaitMs": "\(DiagnosticsTiming.milliseconds(since: waitStart))",
            ]
            guard viewModel.showsDuplicatesRow else {
                return .reported(fields.merging(["row": "absent"]) { $1 })
            }
            var outcome = await select(.duplicates)
            outcome.fields.merge(fields) { $1 }
            return outcome
        }

        private func scroll(to position: SmokeTour.Position) async -> Outcome {
            guard let viewModel, viewModel.viewMode == .grid else {
                return .skipped("notGrid")
            }
            let order = viewModel.parts.mediaGrid.orderedAssetIDs
            guard let index = SmokeTour.index(of: position, count: order.count) else {
                return .skipped("scopeTooSmall")
            }
            let target = order[index]
            let before = viewModel.lastVisibleThumbnails?.revision ?? 0
            viewModel.setFocus(target)
            // The step ends on a report that settles a visible set holding the target: a newer
            // one, or — when the target was already on screen and nothing moved — the one that
            // still settles the set shown now.
            let settled = await until { model in
                guard let report = model.lastVisibleThumbnails, report.ids.contains(target) else {
                    return false
                }
                return report.revision > before || model.tileContentStore.settledVisible == report
            }
            guard settled, let report = self.viewModel?.lastVisibleThumbnails else {
                return Outcome(result: "deadline", fields: ["position": "\(index)"])
            }
            return .reported([
                "position": "\(index)",
                "visible": "\(report.visible)",
                "withoutThumbnail": "\(report.withoutThumbnail)",
                "thumbnailsMs": "\(report.milliseconds)",
            ])
        }

        /// Which of `ids` the loupe can show without a download: stills whose original is on
        /// this Mac (`local`, also in `openable`) or whose preview is stored. Throws when their
        /// details cannot be read.
        private func openability(of ids: [MediaAssetID], in viewModel: CatalogWindowViewModel) async throws -> (
            openable: Set<MediaAssetID>, local: Set<MediaAssetID>, details: [MediaAssetID: MediaTileDetail]
        ) {
            let reader = viewModel.tileDetailReader
            let materialization = viewModel.materializationCoordinator
            let details = try await reader.details(for: ids)
            var openable = Set<MediaAssetID>()
            var local = Set<MediaAssetID>()
            for id in ids {
                guard let detail = details[id], detail.bestKind != .video else {
                    continue
                }
                // Locality is the file's `SF_DATALESS` flag, read without its bytes.
                if await materialization.locality(of: id) == .local {
                    local.insert(id)
                    openable.insert(id)
                } else if detail.previewPath != nil {
                    openable.insert(id)
                }
            }
            return (openable, local, details)
        }

        /// Opens the loupe on the first of four neighbours near the top that it can show
        /// without a download.
        private func openPhoto() async -> Outcome {
            guard let viewModel else {
                return .skipped("windowGone")
            }
            let candidates = Array(viewModel.parts.mediaGrid.orderedAssetIDs.prefix(SmokeTour.openablePhotoSearchLimit))
            let found: (openable: Set<MediaAssetID>, local: Set<MediaAssetID>, details: [MediaAssetID: MediaTileDetail])
            do {
                found = try await openability(of: candidates, in: viewModel)
            } catch {
                return Outcome(result: "skipped", fields: ["reason": "detailReadFailed", "error": String(describing: error)])
            }
            guard let run = SmokeTour.firstOpenableRun(in: candidates, openable: found.openable),
                  let photo = run.first, let viewModel = self.viewModel
            else {
                openablePhotos = []
                return .skipped("noOpenablePhotos")
            }
            openablePhotos = run
            viewModel.openLoupe(id: photo)
            var outcome = await loupeShows(photo)
            outcome.fields["local"] = "\(run.count(where: found.local.contains))"
            outcome.fields["storedPreview"] = "\(run.count(where: { !found.local.contains($0) }))"
            return outcome
        }

        /// The arrow key's own intent, which resolves the neighbour against the order on screen
        /// at the press and names the photo it moved to; the step waits on the pane showing
        /// that photo. The tour computes no neighbour of its own, so an order enrichment moves
        /// before or after the press changes which photo is next, never whether the step ends.
        /// A photo the loupe cannot show without a download is recorded and not waited on: the
        /// session refuses every download (`PaneOriginalDownloads.never`), so its pane stays
        /// empty and nothing is fetched.
        private func stepPhoto(by delta: Int) async -> Outcome {
            guard let viewModel, viewModel.viewMode == .loupe else {
                return .skipped("noLoupe")
            }
            guard let next = delta > 0 ? viewModel.focusNext() : viewModel.focusPrevious() else {
                return .skipped("noNeighbour")
            }
            let openable: Bool
            do {
                openable = try await openability(of: [next], in: viewModel).openable.contains(next)
            } catch {
                return Outcome(result: "skipped", fields: ["reason": "detailReadFailed", "error": String(describing: error)])
            }
            guard openable else {
                return .skipped("notOpenable")
            }
            return await loupeShows(next)
        }

        /// Waits for the loupe's pane to show `id`, or for its focus to leave it (a change of
        /// the order that removed the photo moves the focus to a survivor, reported as such).
        private func loupeShows(_ id: MediaAssetID) async -> Outcome {
            let ended = await until { $0.panePreviews[.loupe]?.id == id || $0.focusedAssetID != id }
            guard ended, let viewModel else {
                return .deadline
            }
            return viewModel.panePreviews[.loupe]?.id == id ? .reported() : .skipped("focusMoved")
        }

        /// Compares the first two photos the loupe opened, then returns to the grid.
        private func compare() async -> Outcome {
            guard let viewModel, openablePhotos.count >= 2 else {
                return .skipped("noOpenablePhotos")
            }
            let pair = Array(openablePhotos.prefix(2))
            viewModel.exitToGrid()
            viewModel.selectAssets(pair)
            viewModel.enterCompare()
            let shown = await until { model in
                Set(model.panePreviews.values.map(\.id)).isSuperset(of: pair)
            }
            self.viewModel?.exitToGrid()
            return shown ? .reported() : .deadline
        }

        private func info() async -> Outcome {
            guard let viewModel, let photo = openablePhotos.first else {
                return .skipped("noOpenablePhotos")
            }
            viewModel.selectAssets([photo])
            viewModel.setInspectorPane(.info)
            let shown = await until { $0.photoInfo?.id == photo }
            return shown ? .reported() : .deadline
        }

        /// Why the act steps may not run here, or nil when they may: a sandbox home whose
        /// every source lies inside it, on a volume mounted inside it, so the Trash the acts
        /// use is the sandbox's own.
        private func actsRefusal() -> String? {
            guard let viewModel else {
                return "windowGone"
            }
            guard let sandbox = SmokeTour.sandboxHome(environment: environment) else {
                return "notSandboxHome"
            }
            guard SmokeTour.sourcesLie(viewModel.state, inside: sandbox) else {
                return "sourceOutsideSandbox"
            }
            // A source inside the sandbox home but on the account's own volume trashes into
            // the account's Trash: the acts would put the tour's files among the user's.
            guard SmokeTour.trashStays(viewModel.state, inside: sandbox) else {
                return "trashOutsideSandbox"
            }
            guard !openablePhotos.isEmpty else {
                return "noOpenablePhotos"
            }
            return nil
        }

        /// The `index`th of the three choices on one tile the grid holds, timed from the
        /// menu's and the shortcut's own intent (`submitMediaChoice` on the selection) to the
        /// main-actor render of that tile with the choice. The third puts back the photo's own
        /// choice.
        ///
        /// The tile is one the collection view holds when the first act runs (the newest
        /// visible-thumbnails report that still settles the visible set), never one scrolled
        /// to: an occluded window's layout runs only about once a second, so a scroll there
        /// clamps to a stale document height and the photo it aims at is not laid out for the
        /// step's whole deadline (`docs/research/2026-11-17-act-result-in-an-occluded-window.md`).
        /// A tile the collection view holds is rendered in the same main-actor pass that
        /// receives the choice, occluded or not, as a Move to Trash's order is committed. The
        /// later acts bring the tile back on screen only when it has left the visible set.
        /// `perform` runs it only where the acts may run (`actsRefusal`).
        func choiceAct(_ index: Int) async -> (String, String, Outcome) {
            guard let viewModel else {
                return ("act", "choice\(index)", .skipped("windowGone"))
            }
            if viewModel.viewMode != .grid {
                viewModel.exitToGrid()
            }
            if choiceTarget == nil {
                guard let held = await heldTile() else {
                    return ("act", "choice\(index)", Outcome(result: "deadline", fields: ["reason": "noVisibleTile"]))
                }
                let original: MediaChoice
                do {
                    guard let read = try await viewModel.tileDetailReader.details(for: [held])[held]?.mediaChoice else {
                        return ("act", "choice\(index)", .skipped("noDetail"))
                    }
                    original = read
                } catch {
                    return ("act", "choice\(index)", Outcome(result: "skipped", fields: [
                        "reason": "detailReadFailed", "error": String(describing: error),
                    ]))
                }
                choiceTarget = (held, original)
            }
            guard let (photo, original) = choiceTarget, let viewModel = self.viewModel else {
                return ("act", "choice\(index)", .skipped("windowGone"))
            }
            let choice = SmokeTour.choiceCycle(after: original)[index]
            let name = WindowAct.choice(choice).name
            if viewModel.tileContentStore.settledVisible?.ids.contains(photo) != true {
                guard await onScreen(photo) else {
                    return ("act", name, Outcome(result: "deadline", fields: ["reason": "notOnScreen"]))
                }
            }
            viewModel.selectAssets([photo])
            // Each act is timed on its own: the one before has written its choice, so this
            // one does not queue behind that write's publication.
            guard await settled() else {
                return ("act", name, Outcome(result: "deadline", fields: ["reason": "notSettled"]))
            }
            let before = viewModel.lastActResult?.revision ?? 0
            viewModel.submitMediaChoice(choice)
            return await ("act", name, actResult(after: before))
        }

        /// The first tile, in the grid's order, of the visible set the collection view holds
        /// now: the newest visible-thumbnails report, once it settles the set still shown.
        /// Nil at the deadline.
        private func heldTile() async -> MediaAssetID? {
            let settled = await until { model in
                guard let report = model.lastVisibleThumbnails else {
                    return false
                }
                return model.tileContentStore.settledVisible == report
            }
            guard settled, let viewModel, let report = viewModel.lastVisibleThumbnails else {
                return nil
            }
            return viewModel.parts.mediaGrid.content.inDisplayOrder(report.ids).first
        }

        /// Move to Trash on the first photo, timed from the intent to the grid without it, then
        /// undone; the step ends once the photo is back in the window.
        private func trashAct() async -> Outcome {
            if let refusal = actsRefusal() {
                return .skipped(refusal)
            }
            guard let viewModel, let photo = openablePhotos.first else {
                return .skipped("windowGone")
            }
            if viewModel.viewMode != .grid {
                viewModel.exitToGrid()
            }
            viewModel.selectAssets([photo])
            guard viewModel.canMoveTargetedMediaToTrash else {
                return .skipped("cannotTrash")
            }
            guard await settled() else {
                return Outcome(result: "deadline", fields: ["reason": "notSettled"])
            }
            let before = viewModel.lastActResult?.revision ?? 0
            viewModel.moveTargetedMediaToTrash()
            var outcome = await actResult(after: before)
            // Put Back, timed the same way: from Undo to the grid showing the photo again.
            let beforeUndo = self.viewModel?.lastActResult?.revision ?? 0
            self.viewModel?.undoLastChange()
            let putBack = await actResult(after: beforeUndo)
            let back = await until { $0.state.mediaGrid.content.contains(photo) }
            outcome.fields["putBack"] = "\(back)"
            outcome.fields["putBackMs"] = putBack.fields["resultMs"] ?? putBack.result
            return outcome
        }

        /// Five Move to Trash acts on the first photo and the survivors the selection moves to,
        /// each issued as soon as the one before shows its result (its file work still
        /// running), then five Undos the same way; the step ends once all five are back.
        private func trashRun() async -> Outcome {
            if let refusal = actsRefusal() {
                return .skipped(refusal)
            }
            guard let viewModel, let photo = openablePhotos.first else {
                return .skipped("windowGone")
            }
            if viewModel.viewMode != .grid {
                viewModel.exitToGrid()
            }
            guard await settled() else {
                return Outcome(result: "deadline", fields: ["reason": "notSettled"])
            }
            viewModel.selectAssets([photo])
            var trashed: [MediaAssetID] = []
            var trashMs: [String] = []
            for _ in 0 ..< 5 {
                guard let viewModel = self.viewModel, viewModel.canMoveTargetedMediaToTrash else {
                    return Outcome(result: "skipped", fields: ["reason": "cannotTrash", "trashed": "\(trashed.count)"])
                }
                trashed.append(contentsOf: viewModel.targetIDs(.current))
                let before = viewModel.lastActResult?.revision ?? 0
                viewModel.moveTargetedMediaToTrash()
                let shown = await actResult(after: before)
                trashMs.append(shown.fields["resultMs"] ?? shown.result)
            }
            var putBackMs: [String] = []
            for _ in 0 ..< 5 {
                let before = self.viewModel?.lastActResult?.revision ?? 0
                self.viewModel?.undoLastChange()
                let shown = await actResult(after: before)
                putBackMs.append(shown.fields["resultMs"] ?? shown.result)
            }
            let back = await until { state in trashed.allSatisfy { state.state.mediaGrid.content.contains($0) } }
            return .reported([
                "trashMs": trashMs.joined(separator: ","),
                "putBackMs": putBackMs.joined(separator: ","),
                "allBack": "\(back)",
            ])
        }

        /// Moves the grid's focus to `photo` and waits for a visible-thumbnails report whose
        /// set holds it: a newer one, or the one that still settles the set shown now when it
        /// was already on screen. False at the deadline.
        private func onScreen(_ photo: MediaAssetID) async -> Bool {
            guard let viewModel else {
                return false
            }
            let before = viewModel.lastVisibleThumbnails?.revision ?? 0
            viewModel.setFocus(photo)
            return await until { model in
                guard let report = model.lastVisibleThumbnails, report.ids.contains(photo) else {
                    return false
                }
                return report.revision > before || model.tileContentStore.settledVisible == report
            }
        }

        /// True once every choice the window submitted has been written or refused and applied.
        private func settled() async -> Bool {
            await until { $0.hasSettledMediaChoices }
        }

        private func actResult(after revision: UInt64) async -> Outcome {
            let shown = await until { ($0.lastActResult?.revision ?? 0) > revision }
            guard shown, let report = viewModel?.lastActResult else {
                return .deadline
            }
            return .reported(["resultMs": "\(report.milliseconds)", "surface": report.surface, "window": report.window.rawValue])
        }

        /// Filters by a kind the scope's published options offer — videos when offered, else
        /// the first kind offered — once the options are in, timed from the intent alone.
        private func filterByOfferedKind() async -> (String, String, Outcome) {
            let waitStart = ContinuousClock.now
            guard await until({ !$0.state.filterOptions.formatsByKind.isEmpty }), let viewModel else {
                return ("filter", "kind", Outcome(result: "deadline", fields: ["reason": "noFilterOptions"]))
            }
            let optionsWaitMs = DiagnosticsTiming.milliseconds(since: waitStart)
            let offered = Set(viewModel.parts.filterOptions.formatsByKind.keys)
            let kinds = ([MediaKind.video] + MediaKind.displayOrder).filter(offered.contains)
            for kind in kinds {
                var outcome = await query { $0.setMediaKind(kind, included: true) }
                guard outcome.fields["reason"] != "queryUnchanged" else {
                    continue
                }
                outcome.fields["optionsWaitMs"] = "\(optionsWaitMs)"
                return ("filter", kind.rawValue, outcome)
            }
            return ("filter", "kind", .skipped("queryUnchanged"))
        }

        /// A query intent (search, filter, sort) and the published states that answer it, timed
        /// from the intent: the first results on screen (`firstMs`, a search's first matches
        /// while it is still searching, else the answer) and the complete answer (`resultMs`).
        private func query(_ act: (CatalogWindowViewModel) -> Void) async -> Outcome {
            guard let viewModel else {
                return .skipped("windowGone")
            }
            let before = viewModel.queryGeneration
            let started = ContinuousClock.now
            act(viewModel)
            let generation = viewModel.queryGeneration
            guard generation != before else {
                // The intent left the query as it was (a filter the descriptor already holds).
                return .skipped("queryUnchanged")
            }
            // The first results on screen: a search's first matches (`refining`, still searching),
            // or its answer; a query that is not a search has only its answer.
            let shown = await until { model in
                model.parts.queryGeneration >= generation && model.parts.searchPhase != .reading
            }
            let firstMs = DiagnosticsTiming.milliseconds(since: started)
            let firstItems = self.viewModel?.parts.mediaGrid.orderedAssetIDs.count ?? 0
            let answered = if shown {
                await until { model in
                    model.parts.queryGeneration >= generation && model.parts.searchPhase?.isSearching != true
                }
            } else {
                false
            }
            guard answered, let viewModel = self.viewModel else {
                return .deadline
            }
            return .reported([
                "items": "\(viewModel.parts.mediaGrid.orderedAssetIDs.count)",
                "firstItems": "\(firstItems)",
                "firstMs": "\(firstMs)",
                "resultMs": "\(DiagnosticsTiming.milliseconds(since: started))",
            ])
        }

        /// The app left alone. time: measurement — the idle window is what is measured; the
        /// checkpoints at its ends carry what the app did in it.
        private func idle() async -> Outcome {
            guard configuration.idle > .zero else {
                return .skipped("noIdleWindow")
            }
            ResourceCheckpoint.record("idleStart", storeUse: storeUse)
            // time: measurement
            try? await Task.sleep(for: configuration.idle)
            ResourceCheckpoint.record("idleEnd", storeUse: storeUse)
            return .reported(["seconds": "\(configuration.idle.components.seconds)"])
        }

        /// Puts the window back as the tour found it, waiting for its scope's paint.
        private func restore(_ place: WindowPlace) async {
            guard let viewModel else {
                return
            }
            viewModel.setInspectorPane(place.inspector)
            viewModel.exitToGrid()
            let before = viewModel.lastSidebarPaint?.revision ?? 0
            let scopeChanges = viewModel.sidebarSelection != place.descriptor.scope
            let queryChanges = viewModel.queryDescriptor != place.descriptor || viewModel.searchText != place.searchText
            viewModel.setQueryDescriptor(place.descriptor)
            viewModel.setSearchText(place.searchText)
            let generation = viewModel.queryGeneration
            if scopeChanges {
                _ = await until { ($0.lastSidebarPaint?.revision ?? 0) > before }
            } else if queryChanges {
                _ = await until { $0.state.queryGeneration >= generation && $0.state.searchPhase?.isSearching != true }
            }
            guard let viewModel = self.viewModel else {
                return
            }
            viewModel.gridSelection = place.selection
            switch place.viewMode {
            case .grid:
                viewModel.setFocus(place.focus)
            case .loupe:
                viewModel.openLoupe(id: place.focus)
            case .compare:
                viewModel.enterCompare()
            }
            OtosLog.performance.noticeOperation("tour", phase: "restored", fields: [
                "scope": viewModel.sidebarSelection.diagnosticDescription,
                "mode": viewModel.viewMode.rawValue,
                "matches": "\(viewModel.queryDescriptor == place.descriptor)",
            ])
        }

        /// Waits until `condition` holds for the window, or `deadline` (a step's, unless named)
        /// passes; false at the deadline or once the window is gone.
        private func until(
            deadline: Duration? = nil,
            _ condition: @escaping @MainActor (CatalogWindowViewModel) -> Bool
        ) async -> Bool {
            guard let viewModel else {
                return false
            }
            if condition(viewModel) {
                return true
            }
            let observed = Observations { @MainActor [weak viewModel] in
                viewModel.map(condition)
            }
            let deadline = deadline ?? configuration.stepDeadline
            // The first answer wins: the condition holding, or the deadline. Not a task group:
            // a group returns only once every child has, and a parked `Observations` iteration
            // does not end on cancellation until the window next changes, so a step whose fact
            // never came would hang its group past the deadline. The watcher left parked ends
            // at that next change (it checks cancellation) or with the window.
            let (answers, answer) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let watcher = Task {
                await answer.yield(Self.firstMet(observed))
            }
            let timer = Task {
                // time: deadline — a step whose fact never arrives must not hang the tour
                try? await Task.sleep(for: deadline)
                answer.yield(false)
            }
            var met = false
            for await first in answers {
                met = first
                break
            }
            watcher.cancel()
            timer.cancel()
            answer.finish()
            return met
        }

        /// True once the observed condition holds; false when the window is gone or the wait
        /// was cancelled before it held.
        private nonisolated static func firstMet(_ observed: Observations<Bool?, Never>) async -> Bool {
            for await met in observed {
                guard let met, !Task.isCancelled else {
                    return false
                }
                if met {
                    return true
                }
            }
            return false
        }
    }
#endif
