import AppKit
import Darwin
import Foundation
@testable import OtosKit
import SwiftUI
import Testing

/// Generated People states at the owner's scale (738 people, about 100,000 faces) and
/// beyond, for the gallery's render cost. No catalog: the states are built as
/// `PeopleStateBuilder` would publish them, off the main actor (`states`), since a test that
/// held the main actor for the seconds this takes would starve every other test waiting on it.
nonisolated enum PeopleGalleryFixture {
    static let root = LibraryRootPath(rawValue: "/Pictures")

    /// One state per entry of `bumps` (`state(people:facesPerPerson:bump:)`), built off the
    /// main actor.
    @concurrent
    static func states(people: Int, facesPerPerson: Int, bumps: [Int?]) async -> [CatalogPeopleState] {
        bumps.map { state(people: people, facesPerPerson: facesPerPerson, bump: $0) }
    }

    static func asset(_ index: Int) -> MediaAssetID {
        MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "DCIM/IMG_\(index).HEIC"))
    }

    /// `people` people with `facesPerPerson` faces each, spread over two thirds as many
    /// photos as faces; every eighth person named, a few favourites and hidden ones. `bump`
    /// gives the person at that gallery position one more photo, as a face read does.
    static func state(people: Int, facesPerPerson: Int, bump: Int? = nil) -> CatalogPeopleState {
        let photoCount = max(1, people * facesPerPerson * 2 / 3)
        var photoFaces: [MediaAssetID: [PhotoFace]] = [:]
        var summaries: [PersonSummary] = []
        var faceIndex = 0
        for person in 0 ..< people {
            let id = PersonID(rawValue: Int64(person + 1))
            var tiles: [FaceTile] = []
            let count = facesPerPerson + (bump == person ? 1 : 0)
            for face in 0 ..< count {
                let photo = asset(faceIndex % photoCount)
                faceIndex += 1
                let tile = FaceTile(
                    id: FaceID(asset: photo, index: photoFaces[photo]?.count ?? 0),
                    box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                    preview: nil,
                    captureSeconds: Double(1_700_000_000 - face * 86400)
                )
                tiles.append(tile)
                photoFaces[photo, default: []].append(PhotoFace(tile: tile, person: id))
            }
            let user = Array(tiles.prefix(4))
            summaries.append(PersonSummary(
                id: id,
                name: person % 8 == 0 ? "Person \(person)" : nil,
                birthday: nil,
                isHidden: person % 50 == 49,
                isFavorite: person % 100 == 0,
                media: MediaCount(tiles: tiles),
                cover: tiles.first,
                userFaces: user,
                anchorMedia: Dictionary(user.map { ($0.id.asset, false) }, uniquingKeysWith: { first, _ in first })
            ))
        }
        return CatalogPeopleState(
            people: summaries.sorted(by: PeopleStateBuilder.galleryOrder),
            photoFaces: photoFaces,
            unchecked: MediaCount(photos: 1200),
            faceCount: faceIndex
        )
    }

    /// The window showing the People gallery with `people`.
    @MainActor
    static func show(_ people: CatalogPeopleState, in model: CatalogWindowViewModel, title: String = "People") {
        var descriptor = model.queryDescriptor
        descriptor.scope = .people
        var state = CatalogWindowState(
            title: title,
            libraries: [],
            removableSources: [],
            mediaGrid: CatalogMediaGridState(descriptor: descriptor, orderedAssetIDs: []),
            filterOptions: .empty,
            resolvedSidebarSelection: .people,
            mediaEmptyState: nil,
            deviceConnectionBanner: nil
        )
        state.people = people
        state.queryGeneration = model.queryGeneration
        model.applyState(state)
    }

    /// Appends `line` to `build/measurements/people-gallery.log` in the checkout: the test
    /// host's standard output reaches no log.
    static func record(_ line: String) {
        let file = SourceTree.root.appending(path: "build/measurements/people-gallery.log")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }

    /// CPU time the calling thread has used.
    static func threadCPUTime() -> Duration {
        var spec = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &spec)
        return .seconds(spec.tv_sec) + .nanoseconds(spec.tv_nsec)
    }
}

/// One measured step: the main thread's CPU time to apply a change and render it, the part
/// spent applying it, and the menus the cells built meanwhile.
struct GalleryRenderStep {
    let cpu: Duration
    let apply: Duration
    let menus: Int
}

/// Counts what the gallery asks its owner for while it renders.
@MainActor
final class PeopleGalleryCalls {
    var menus = 0
}

/// The gallery as `ContentView` hosts it: read from the model, so it observes what the
/// window's detail pane observes.
private struct PeopleGalleryHost: View {
    let model: CatalogWindowViewModel
    let calls: PeopleGalleryCalls

    var body: some View {
        if let people = model.state.people {
            let actions = model.peopleActions
            PeopleView(
                people: people,
                session: model.peopleSession,
                librariesState: model.state.mediaEmptyState,
                images: model.faceTileImages,
                derivedImageDirectory: nil,
                actions: PeopleActions(
                    select: actions.select,
                    moveCursor: actions.moveCursor,
                    open: actions.open,
                    edit: actions.edit,
                    askMerge: actions.askMerge,
                    mergeRefusal: actions.mergeRefusal,
                    answerMerge: actions.answerMerge,
                    menu: { [calls] person in
                        calls.menus += 1
                        return actions.menu(person)
                    },
                    perform: actions.perform
                )
            )
            .equatable()
        }
    }
}

extension AppKitWindowTests {
    /// The People gallery's main-thread cost at the owner's scale and beyond: opening it,
    /// and applying the People update a face read publishes every few seconds.
    @MainActor
    @Suite(.testScope)
    struct PeopleGalleryRenderTests {
        @Test(arguments: [738, 5000])
        func openingAndUpdatingTheGallery(people count: Int) async throws {
            let faces = max(4, 102_753 / count)
            // The state shown first, then five in which a face read gives one person one more
            // photo, all built before the window opens and off the main actor.
            let built = await PeopleGalleryFixture.states(
                people: count, facesPerPerson: faces, bumps: [nil] + (0 ..< 5).map { $0 * 7 }
            )
            let first = built[0]
            let directory = try makeTestDirectory()
            let model = CatalogWindowViewModel(
                catalogStore: makeTestStore(
                    location: .databaseFile(directory.appending(path: "Catalog.sqlite")),
                    stagingContainers: StagingContainers(base: directory)
                ),
                catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
                startsStallMonitor: false,
                startsEnrichment: false,
                startsSourceMonitoring: false,
                preferencesDomain: PreferencesDomain.suite(UUID().uuidString),
                volumeCapacity: ampleVolumeCapacity,
                trashFiles: .refusing
            )
            let calls = PeopleGalleryCalls()

            let openStart = PeopleGalleryFixture.threadCPUTime()
            PeopleGalleryFixture.show(first, in: model)
            let host = NSHostingView(rootView: PeopleGalleryHost(model: model, calls: calls))
            let window = orderedInTestWindow(width: 1200, height: 800, contentView: host)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let open = PeopleGalleryFixture.threadCPUTime() - openStart
            let openMenus = calls.menus

            /// Each step first lets the main actor's other work run.
            func rendering(_ change: () -> Void) async -> GalleryRenderStep {
                await Task.yield()
                return measuring(change)
            }

            /// Applies `change` and lets the host render what it changed; the main thread's CPU
            /// time and the menus the cells built meanwhile.
            func measuring(_ change: () -> Void) -> GalleryRenderStep {
                calls.menus = 0
                let start = PeopleGalleryFixture.threadCPUTime()
                change()
                let apply = PeopleGalleryFixture.threadCPUTime() - start
                // Observation hands the change to the host on the run loop's next pass; no
                // pass waits (`before: .distantPast`).
                for _ in 0 ..< 3 {
                    RunLoop.main.run(mode: .default, before: .distantPast)
                }
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                return GalleryRenderStep(cpu: PeopleGalleryFixture.threadCPUTime() - start, apply: apply, menus: calls.menus)
            }

            var updates: [GalleryRenderStep] = []
            for next in built.dropFirst() {
                await updates.append(rendering { PeopleGalleryFixture.show(next, in: model) })
            }
            // A click, a ⌘-click and a ⇧-click.
            let people = model.peopleState.visiblePeople.map(\.id)
            var selections: [GalleryRenderStep] = []
            for (person, modifiers) in [(people[0], NSEvent.ModifierFlags()), (people[3], .command), (people[9], .shift)] {
                await selections.append(rendering { model.selectPeople(person, modifiers: modifiers) })
            }
            // A window state that changes something other than People, as the grid's and the
            // sidebar's publications do throughout enrichment.
            let shown = model.peopleState
            var unrelated: [GalleryRenderStep] = []
            for index in 0 ..< 3 {
                await unrelated.append(rendering { PeopleGalleryFixture.show(shown, in: model, title: "People \(index)") })
            }
            PeopleGalleryFixture.record(
                "op=people.galleryRender people=\(count) faces=\(first.faceCount) openCPUms=\(open.milliseconds) "
                    + "openMenus=\(openMenus) updateCPUms=\(updates.map(\.cpu.milliseconds)) "
                    + "updateApplyCPUms=\(updates.map(\.apply.milliseconds)) "
                    + "updateMenus=\(updates.map(\.menus)) selectCPUms=\(selections.map(\.cpu.milliseconds)) "
                    + "selectMenus=\(selections.map(\.menus)) unrelatedCPUms=\(unrelated.map(\.cpu.milliseconds))"
            )
            #expect(model.state.people?.people.count == count)
            #expect(model.peopleSession.selectedPeople.count == 8)
            // No cell builds a menu nobody opened, however many people there are.
            #expect(openMenus == 0)
            #expect(updates.allSatisfy { $0.menus == 0 })
            #expect(selections.allSatisfy { $0.menus == 0 })
            #expect(unrelated.allSatisfy { $0.menus == 0 })
        }
    }
}

private extension Duration {
    var milliseconds: Int {
        Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
