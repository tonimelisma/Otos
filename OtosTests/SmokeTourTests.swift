import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// The tour measures the app the owner uses, so it must start every background owner unless
/// a tour asks otherwise, take each step through the window's own intents, wait on what the
/// window reports, and leave the window as it found it.
@Suite(.testScope)
struct SmokeTourTests {
    private func libraryState(path: String) -> CatalogLibraryState {
        CatalogLibraryState(
            root: LibraryRoot(
                path: LibraryRootPath(rawValue: path),
                kind: .library,
                deviceIdentity: nil,
                displayName: (path as NSString).lastPathComponent
            ),
            availability: .available,
            activity: .idle,
            isEjectable: false
        )
    }

    /// Without the tour flag every owner starts, whatever else the environment says: a
    /// switch that leaves an owner off can never reach an ordinary session.
    @Test func withoutTheTourFlagEveryOwnerStarts() {
        for environment in [
            [:],
            [SmokeTour.ablateVariable: "all"],
            [SmokeTour.ablateVariable: "enrichment,people", SmokeTour.tourVariable: "0"],
        ] {
            let owners = BackgroundOwners.configured(environment: environment)
            #expect(owners == .all)
            for owner in BackgroundOwner.allCases {
                #expect(owners.starts(owner))
            }
        }
    }

    /// With the flag, the list names who stays off; `all` is every owner, `none` is none,
    /// and a name it does not know is kept to be reported, not dropped.
    @Test func theTourFlagReadsTheOwnersToLeaveOff() {
        let tour = [SmokeTour.tourVariable: "1"]
        #expect(BackgroundOwners.configured(environment: tour) == .all)
        #expect(BackgroundOwners.configured(environment: tour.merging([SmokeTour.ablateVariable: "all"]) { $1 })
            .off == Set(BackgroundOwner.allCases))
        let some = BackgroundOwners.configured(environment: tour.merging([SmokeTour.ablateVariable: "searchIndex, people"]) { $1 })
        #expect(some.off == [.searchIndex, .people])
        #expect(!some.starts(.people))
        #expect(some.starts(.enrichment))
        let typo = SmokeTour.Configuration(environment: tour.merging([SmokeTour.ablateVariable: "peeple"]) { $1 })
        #expect(typo?.unknownOwners == ["peeple"])
        #expect(SmokeTour.Configuration(environment: [:]) == nil)
    }

    /// A tour starts at the first grid unless it is asked to start settled, with a settle
    /// deadline of its own.
    @Test func aTourStartsAtLaunchUnlessAskedToStartSettled() throws {
        let tour = [SmokeTour.tourVariable: "1"]
        let launch = try #require(SmokeTour.Configuration(environment: tour))
        #expect(launch.start == .launch)
        let settled = try #require(SmokeTour.Configuration(environment: tour.merging([
            SmokeTour.startVariable: "settled", SmokeTour.settleDeadlineVariable: "300",
        ]) { $1 }))
        #expect(settled.start == .settled)
        #expect(settled.settleDeadline == .seconds(300))
        #expect(SmokeTour.Configuration(environment: tour.merging([SmokeTour.startVariable: "later"]) { $1 })?.start == .launch)
    }

    /// An owner's status says what keeps it from quiescence: a pass running a long walk, a
    /// request owed, a change not acted on, work in flight; with none of them it is quiescent.
    @Test func anOwnersStatusNamesWhatKeepsItBusy() {
        let activity = OwnerActivity(owner: "descriptions")
        #expect(activity.status(holdsWork: false).isQuiescent)
        let request = activity.request()
        activity.beginPass()
        activity.wrote(3)
        let walking = activity.status(holdsWork: false)
        #expect(!walking.isQuiescent)
        #expect((walking.owedRequests, walking.runningPasses, walking.work.written) == (1, 1, 3))
        #expect(walking.fields["runningPasses"] == "1" && walking.fields["owner"] == "descriptions")
        activity.endPass(covering: request)
        #expect(activity.status(holdsWork: false).isQuiescent)
        #expect(!activity.status(holdsWork: true).isQuiescent)
        activity.deliveries.recordDelivery()
        #expect(activity.status(holdsWork: false).unactedChanges == 1)
        activity.actedOnChange()
        #expect(activity.status(holdsWork: false).isQuiescent)
    }

    /// The launch settles in stages, each holding the one before, and never goes back. The
    /// Duplicates step's fact is the window showing the groups built when the launch reached
    /// `duplicatesBuilt`: a stage reached before the window applies that build waits for the
    /// apply, and a later build changes nothing.
    @MainActor
    @Test func theDuplicatesStepWaitsForTheWindowToShowTheLaunchsGroups() throws {
        #expect(LaunchSettlement.duplicatesBuilt < .launchWork && LaunchSettlement.launchWork < .ownersQuiescent)
        let viewModel = CatalogWindowViewModel(
            catalogStore: makeTestStore(location: .inMemory),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: .suite(UUID().uuidString),
            volumeCapacity: ampleVolumeCapacity,
            trashFiles: .refusing
        )
        let root = LibraryRootPath(rawValue: "/Pictures")
        let ids = (0 ..< 2).map { MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "\($0).jpg")) }
        let copies = ids.enumerated().map { index, id in
            DuplicateCopy(
                id: id, libraryDisplayName: "Pictures", libraryKind: .library, kind: .image, captureLocalTime: nil, byteSize: 1,
                createdAt: Date(timeIntervalSince1970: Double(index)), pixelWidth: 4, pixelHeight: 3,
                mediaChoice: .notRated, isEdited: false, hasCompanions: false
            )
        }
        let digest = try #require(ContentDigest(data: Data(repeating: 7, count: ContentDigest.byteCount)))
        let group = DuplicateGroupPolicy.group(id: .identical(digest, library: nil), copies: copies, keptPairs: [])
        let built = CatalogDuplicatesState(groups: [group])
        var state = CatalogWindowState.empty
        state.libraries = [libraryState(path: root.rawValue)]
        state.duplicates = .empty
        viewModel.applyState(state)

        // Reached while the window still shows the build before it (no group yet).
        viewModel.settleLaunch(.duplicatesBuilt, duplicates: built)
        #expect(viewModel.launchSettlement == .duplicatesBuilt)
        #expect(!viewModel.showsLaunchDuplicates)
        state.duplicates = built
        viewModel.applyState(state)
        #expect(viewModel.showsLaunchDuplicates)
        // A later build, and a stage that goes back, change nothing.
        state.duplicates = .empty
        viewModel.applyState(state)
        #expect(viewModel.showsLaunchDuplicates)
        viewModel.settleLaunch(.launchWork)
        viewModel.settleLaunch(.duplicatesBuilt, duplicates: nil)
        #expect(viewModel.launchSettlement == .launchWork)
    }

    /// A tour reads the user's preferences and writes none: its domain is session-only over
    /// the user's own, and every other launch uses the user's own.
    @Test func aTourSessionsPreferencesAreSessionOnly() {
        #expect(PreferencesDomain.configured(environment: [SmokeTour.tourVariable: "1"]) == .sessionOnly(.standard))
        #expect(PreferencesDomain.configured(environment: [:]) == .standard)
        #expect(PreferencesDomain.configured(environment: [SmokeTour.tourVariable: "0"]) == .standard)
    }

    /// A session-only store reads through to its base until it writes or removes a key, and
    /// never writes the base.
    @Test func aSessionOnlyStoreReadsTheBaseAndWritesOnlyMemory() throws {
        let base = PreferencesDomain.suite(UUID().uuidString)
        let stored = try #require(base.makeDefaults() as? InMemorySuitePreferenceStore)
        stored.set("owner", forKey: "kept")
        stored.set(true, forKey: "removed")
        stored.set(["en", "fi"], forKey: "languages")
        let before = stored.serialized()
        let session = PreferencesDomain.sessionOnly(base).makeDefaults()

        #expect(session.string(forKey: "kept") == "owner")
        #expect(session.object(forKey: "languages") as? [String] == ["en", "fi"])
        session.set("tour", forKey: "kept")
        session.removeObject(forKey: "removed")
        session.set(["et"], forKey: "languages")
        session.set(7, forKey: "new")

        #expect(session.string(forKey: "kept") == "tour")
        #expect(session.object(forKey: "removed") == nil)
        #expect(!session.bool(forKey: "removed"))
        #expect(session.object(forKey: "languages") as? [String] == ["et"])
        #expect(session.integer(forKey: "new") == 7)
        #expect(PreferencesDomain.sessionOnly(base).makeDefaults() === session, "one store per base for the process")
        #expect(stored.serialized() == before)
    }

    /// A plan visits the scopes the sidebar shows, returns to All Media, and leaves out the
    /// scopes of owners left off; a short tour stops after the sidebar.
    @Test func thePlanFollowsTheSidebarAndTheOwnersStarted() throws {
        var state = CatalogWindowState.empty
        state.libraries = [libraryState(path: "/Pictures"), libraryState(path: "/Archive")]
        state.mediaEmptyState = .noMedia
        let day = CalendarDay.today()
        let full = try #require(SmokeTour.Configuration(environment: [SmokeTour.tourVariable: "1"]))
        let plan = SmokeTour.plan(for: state, configuration: full, today: day)
        #expect(plan.first == .scope(label: "allMedia", selection: .allMedia))
        #expect(plan.contains(.scope(label: "people", selection: .people)))
        #expect(plan.contains(.duplicates))
        #expect(plan.contains(.openPhoto))
        #expect(plan.last == .idle)

        let short = try #require(SmokeTour.Configuration(environment: [
            SmokeTour.tourVariable: "1", SmokeTour.stepsVariable: "scopes", SmokeTour.ablateVariable: "people,duplicates",
        ]))
        #expect(SmokeTour.plan(for: state, configuration: short, today: day) == [
            .scope(label: "allMedia", selection: .allMedia),
            .scope(label: "library", selection: .library(LibraryRootPath(rawValue: "/Pictures"))),
            .scope(label: "places", selection: .places),
            .scope(label: "onThisDay", selection: .onThisDay(day)),
            .scope(label: "allMedia", selection: .allMedia),
            .idle,
        ])
        #expect(short.idle == .zero)

        // With one library All Media is no row: the library is the scope the tour browses.
        state.libraries = [libraryState(path: "/Pictures")]
        let single = SmokeTour.plan(for: state, configuration: short, today: day)
        #expect(single.first == .scope(label: "library", selection: .library(LibraryRootPath(rawValue: "/Pictures"))))
        #expect(!single.contains(.scope(label: "allMedia", selection: .allMedia)))
    }

    /// The act steps run only in a sandbox home: `CFFIXED_USER_HOME` set, the process's own
    /// home, and neither the account's home nor a folder holding it.
    @Test func actsRunOnlyInASandboxHome() {
        let user = "/Users/someone"
        let sandbox = "/private/tmp/otos-sandbox-home"
        let fixed = ["CFFIXED_USER_HOME": sandbox]
        #expect(SmokeTour.sandboxHome(environment: fixed, processHome: sandbox, userHome: user) == sandbox)
        #expect(SmokeTour.sandboxHome(environment: [:], processHome: sandbox, userHome: user) == nil)
        #expect(SmokeTour.sandboxHome(environment: ["CFFIXED_USER_HOME": user], processHome: user, userHome: user) == nil)
        #expect(SmokeTour.sandboxHome(environment: ["CFFIXED_USER_HOME": "/Users"], processHome: "/Users", userHome: user) == nil)
        #expect(SmokeTour.sandboxHome(environment: ["CFFIXED_USER_HOME": "/"], processHome: "/", userHome: user) == nil)
        // Set, but not the home this process runs in.
        #expect(SmokeTour.sandboxHome(environment: fixed, processHome: user, userHome: user) == nil)

        var state = CatalogWindowState.empty
        state.libraries = [libraryState(path: sandbox + "/Pictures")]
        #expect(SmokeTour.sourcesLie(state, inside: sandbox))
        state.libraries.append(libraryState(path: user + "/Pictures"))
        #expect(!SmokeTour.sourcesLie(state, inside: sandbox))
        #expect(!SmokeTour.sourcesLie(.empty, inside: sandbox))
    }

    /// Move to Trash keeps an item on its volume, so the acts run only when every source's
    /// volume is mounted inside the sandbox home: a source inside the home but on the boot
    /// volume would trash into the account's Trash.
    @Test func actsTrashOnlyOnAVolumeMountedInsideTheSandbox() {
        let sandbox = "/private/tmp/otos-sandbox-home"
        let mounted = sandbox + "/TourLibrary"
        var state = CatalogWindowState.empty
        state.libraries = [libraryState(path: mounted + "/Photos")]
        #expect(SmokeTour.trashStays(state, inside: sandbox) { _ in mounted })
        // The boot volume, the sandbox home itself, a volume elsewhere, an unnamed volume.
        for volume in ["/", sandbox, "/Volumes/Card", nil] as [String?] {
            #expect(!SmokeTour.trashStays(state, inside: sandbox) { _ in volume })
        }
        // Every source must pass, and a window with none never does.
        state.libraries.append(libraryState(path: sandbox + "/Pictures"))
        #expect(!SmokeTour.trashStays(state, inside: sandbox) { $0.hasPrefix(mounted) ? mounted : "/" })
        #expect(!SmokeTour.trashStays(.empty, inside: sandbox) { _ in mounted })
    }

    /// A tour session in a sandbox home on the account's own volume: the Trash the system names
    /// for a file there is the account's, not the sandbox's, so its acts are refused. The
    /// volume is read from the filesystem, the way the tour reads it; nothing is trashed.
    @Test func aSandboxHomeOnTheAccountsVolumeKeepsTheActsFromItsTrash() throws {
        let sandbox = try makeTestDirectory()
        let library = sandbox.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
        let file = library.appending(path: "photo.jpg")
        try Data([0xFF, 0xD8]).write(to: file)
        let sandboxPath = sandbox.path(percentEncoded: false)
        var state = CatalogWindowState.empty
        state.libraries = [libraryState(path: library.path(percentEncoded: false))]

        #expect(SmokeTour.sourcesLie(state, inside: sandboxPath))
        let volume = try #require(SmokeTour.volumeRoot(of: library.path(percentEncoded: false)))
        #expect(!SmokeTour.lies(volume, inside: sandboxPath))
        #expect(!SmokeTour.trashStays(state, inside: sandboxPath))
        // The system's Trash for this file is the account's own, outside the sandbox.
        let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: file, create: false)
        let account = try #require(SmokeTour.accountHome())
        #expect(SmokeTour.lies(trash.path(percentEncoded: false), inside: account))
        #expect(!SmokeTour.lies(trash.path(percentEncoded: false), inside: sandboxPath))
    }

    /// The sandbox library seam registers a folder only in a sandbox home whose catalog and
    /// folder both lie inside it; anywhere else it is refused with the reason.
    @Test func aSandboxLibraryIsRegisteredOnlyInsideASandboxHome() throws {
        let sandbox = try makeTestDirectory()
        let home = sandbox.path(percentEncoded: false)
        let folder = sandbox.appending(path: "TourLibrary", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let user = "/Users/someone"
        let catalog = home + "/Library/Application Support"
        let asked = ["CFFIXED_USER_HOME": home, SandboxLibrary.variable: folder.path(percentEncoded: false)]
        func request(_ environment: [String: String], catalog: String? = catalog, processHome: String = home) -> SandboxLibrary.Request? {
            SandboxLibrary.request(environment: environment, catalogFolder: catalog, processHome: processHome, userHome: user)
        }

        #expect(try request(asked) == .add(CatalogPath.normalizedDirectoryPath(for: folder)))
        #expect(request(["CFFIXED_USER_HOME": home]) == nil)
        #expect(request([SandboxLibrary.variable: folder.path(percentEncoded: false)], processHome: user) == .refused("notSandboxHome"))
        #expect(request(asked, catalog: user + "/Library/Application Support") == .refused("catalogOutsideSandbox"))
        #expect(request(asked, catalog: nil) == .refused("catalogOutsideSandbox"))
        let outside = try makeTestDirectory()
        #expect(request(asked.merging([SandboxLibrary.variable: outside.path(percentEncoded: false)]) { $1 }) == .refused("folderOutsideSandbox"))
    }

    /// The three choices each change what the tile shows, and the last puts the photo's own
    /// choice back.
    @Test func theChoiceStepsEndOnThePhotosOwnChoice() {
        for original in MediaChoice.allCases {
            let cycle = SmokeTour.choiceCycle(after: original)
            #expect(cycle.count == 3)
            #expect(Set(cycle) == Set(MediaChoice.allCases))
            #expect(cycle.first != original)
            #expect(cycle.last == original)
        }
    }

    /// The photo steps open four neighbours the loupe can show without a download, the first
    /// such run in the order, or none.
    @Test func thePhotoStepsChooseTheFirstRunOfOpenableNeighbours() {
        let ids = (0 ..< 8).map {
            MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/Pictures"), relativePath: MediaRelativePath(rawValue: "\($0).jpg"))
        }
        // 2 is a video (not openable), so the first run of four starts at 3.
        let openable = Set(ids.enumerated().filter { $0.offset != 2 }.map(\.element))
        #expect(SmokeTour.firstOpenableRun(in: ids, openable: openable) == Array(ids[3 ..< 7]))
        #expect(SmokeTour.firstOpenableRun(in: ids, openable: [ids[0], ids[1], ids[2]]) == nil)
        #expect(SmokeTour.firstOpenableRun(in: Array(ids.prefix(3)), openable: Set(ids)) == nil)
    }

    /// A full tour plans the act steps (each refused outside a sandbox home when it runs) and
    /// a filter chosen from the options the scope publishes.
    @Test func aFullTourPlansTheActsAndAnOfferedFilter() throws {
        var state = CatalogWindowState.empty
        state.libraries = [libraryState(path: "/Pictures"), libraryState(path: "/Archive")]
        let full = try #require(SmokeTour.Configuration(environment: [SmokeTour.tourVariable: "1"]))
        let plan = SmokeTour.plan(for: state, configuration: full, today: CalendarDay.today())
        #expect(plan.contains(.choiceAct(0)) && plan.contains(.choiceAct(2)) && plan.contains(.trashAct) && plan.contains(.trashRun))
        #expect(plan.contains(.filterByOfferedKind))
    }

    /// A scroll lands on a position the order has, and is skipped for an order too short to
    /// move the viewport.
    @Test func scrollPositionsLandInsideTheOrder() {
        #expect(SmokeTour.index(of: .end, count: 100) == nil)
        #expect(SmokeTour.index(of: .end, count: 5000) == 4999)
        #expect(SmokeTour.index(of: .middle, count: 5000) == 2500)
        #expect(SmokeTour.index(of: .index(300), count: 5000) == 300)
    }

    /// The tour selects each scope with the sidebar's intent, moves on only when that scope
    /// paints, puts the scope back and quits; it writes nothing to the catalog.
    @MainActor
    @Test func theTourSelectsEachScopeWaitsForItsPaintAndPutsTheWindowBack() async throws {
        let viewModel = CatalogWindowViewModel(
            catalogStore: makeTestStore(location: .inMemory, scanCadence: .milliseconds(10)),
            catalogProjection: CatalogProjection(volumeCapacity: ampleVolumeCapacity, cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: .suite(UUID().uuidString),
            volumeCapacity: ampleVolumeCapacity,
            trashFiles: .refusing
        )
        let library = LibraryRootPath(rawValue: "/Pictures")
        let start = SidebarSelection.library(library)
        var loaded = CatalogWindowState.empty
        loaded.libraries = [libraryState(path: library.rawValue), libraryState(path: "/Archive")]
        loaded.mediaEmptyState = .noMedia
        viewModel.applyState(loaded)
        viewModel.selectSidebar(start)
        viewModel.uiStallMonitor.completeIntentToPaint(appliedScope: start)

        let quits = Mutex(0)
        SmokeTour.applyIfPresent(to: viewModel, environment: [
            SmokeTour.tourVariable: "1",
            SmokeTour.stepsVariable: "scopes",
            SmokeTour.ablateVariable: "people,duplicates",
        ], quit: { quits.withLock { $0 += 1 } })

        // Paints each scope the tour selects, as the window does when its surface draws, until
        // the tour has put the starting scope back. The tour selects the next scope only
        // after this paint, so no selection is missed between two observations.
        var painted: [SidebarSelection] = []
        let selections = Observations { @MainActor in viewModel.sidebarSelection }
        for await selection in selections where selection != painted.last {
            if selection == start, painted.isEmpty {
                continue
            }
            painted.append(selection)
            viewModel.uiStallMonitor.completeIntentToPaint(appliedScope: selection)
            if painted.count == 6 {
                break
            }
        }
        try await waitUntil { quits.withLock { $0 } == 1 }
        // The plan's scopes, then the starting scope put back.
        #expect(painted == [.allMedia, start, .places, .onThisDay(viewModel.today), .allMedia, start])
        #expect(viewModel.sidebarSelection == start)
    }
}
