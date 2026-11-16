import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// The tour measures the app the owner uses, so it must start every background owner unless
/// a tour asks otherwise, take each step through the window's own intents, wait on what the
/// window reports, and leave the window as it found it.
@Suite(.testDirectory)
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
        #expect(plan.contains(.duplicatesIfShown))
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
        #expect(plan.contains(.choiceAct(0)) && plan.contains(.choiceAct(2)) && plan.contains(.trashAct))
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
            catalogStore: CatalogStore(location: .inMemory, scanCadence: .milliseconds(10)),
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
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
