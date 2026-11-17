import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// An act's publication costs in what the act changes, never in the scope it changes
/// (ADR 0005, "An act's publication is its edit"): a Move to Trash of one photo and its Put
/// Back, at the owner's library size, visit and index a few positions, the same few as in a
/// tenth of it. Counted work (`CatalogGridContent.Work`), never time.
@Suite(.testScope)
struct ActPublicationWorkTests {
    private static let photosPerDay = 32

    private static func id(_ index: Int) -> MediaAssetID {
        MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "w\(index).jpg")
        )
    }

    /// `photos` photos, 32 a day, newest day first, as All Media shows them.
    /// With `movingFirst`, a read that gave the newest photo the fourth day's date: it moves
    /// to the end of that day.
    private static func state(photos: Int, request: CatalogQueryRequest, movingFirst: Bool = false) -> CatalogWindowState {
        let days = photos / photosPerDay
        var ids: [MediaAssetID] = []
        var buckets: [Date?] = []
        ids.reserveCapacity(photos)
        buckets.reserveCapacity(photos)
        for day in 0 ..< days {
            let date = Date(timeIntervalSince1970: 86400 * Double(days - day))
            for photo in 0 ..< photosPerDay where !(movingFirst && day == 0 && photo == 0) {
                ids.append(id(day * photosPerDay + photo))
                buckets.append(date)
            }
            if movingFirst, day == 3 {
                ids.append(id(0))
                buckets.append(date)
            }
        }
        return CatalogWindowState(
            title: "All Media",
            libraries: [],
            removableSources: [],
            mediaGrid: CatalogMediaGridState(descriptor: request.descriptor, orderedAssetIDs: ids, dayBuckets: buckets),
            filterOptions: .empty,
            resolvedSidebarSelection: request.descriptor.scope,
            mediaEmptyState: nil,
            deviceConnectionBanner: nil,
            queryGeneration: request.generation
        )
    }

    /// What the publications of a Move to Trash of one photo mid-library and of its Put Back
    /// cost, through the projection's own act path, at a scope of `photos`.
    private static func actWork(photos: Int) async throws -> (hide: CatalogGridContent.Work, putBack: CatalogGridContent.Work) {
        let store = makeTestStore(location: .inMemory)
        try await store.start(scansSavedLibraries: false)
        let projection = CatalogProjection(
            volumeCapacity: ampleVolumeCapacity,
            cadence: .seconds(3600),
            stateBuilder: { _, _, request in Self.state(photos: photos, request: request) }
        )
        let stream = await projection.states(store: store, initialDescriptor: .default)
        let draining = Task {
            for await _ in stream {}
        }
        defer {
            draining.cancel()
        }
        try await waitUntil { await projection.isQuiescent }
        let shown = try #require(await projection.lastPublishedState)
        #expect(shown.mediaGrid.orderedAssetIDs.count == photos)
        let trashed = shown.mediaGrid.orderedAssetIDs[photos / 2 + 5]
        let batch = MediaTrashBatchID(unixMilliseconds: 1)

        await projection.hide([trashed], batch: batch)
        let hidden = try #require(await projection.lastPublishedState)
        #expect(hidden.mediaGrid.orderedAssetIDs.count == photos - 1)
        #expect(hidden.mediaGrid.content.edit(from: shown.mediaGrid.content) == CatalogGridContent.Edit(removed: [photos / 2 + 5], inserted: []))

        await projection.putBack(batch)
        let back = try #require(await projection.lastPublishedState)
        #expect(back.mediaGrid.orderedAssetIDs == shown.mediaGrid.orderedAssetIDs)
        #expect(back.mediaGrid.content.edit(from: hidden.mediaGrid.content) == CatalogGridContent.Edit(removed: [], inserted: [photos / 2 + 5]))
        #expect(back.mediaGrid.content.position(of: trashed) == photos / 2 + 5)
        #expect(back.mediaGrid.content.position(of: shown.mediaGrid.orderedAssetIDs[photos - 1]) == photos - 1)
        return (hidden.mediaGrid.content.work, back.mediaGrid.content.work)
    }

    /// At 160,000 photos a one-photo Move to Trash and its Put Back each visit and index a
    /// few positions, and the same few at 16,000: the work is the edit's, not the scope's.
    /// Copying the order's storage in runs is the one part in proportion to the scope.
    @Test func aOnePhotoActsPublicationCostsItsEditNotItsScope() async throws {
        let owner = try await Self.actWork(photos: 160_000)
        let tenth = try await Self.actWork(photos: 16000)
        #expect(owner.hide.visited <= 4 && owner.hide.indexed <= 4, "Move to Trash at 160,000: \(owner.hide)")
        #expect(owner.putBack.visited <= 8 && owner.putBack.indexed <= 4, "Put Back at 160,000: \(owner.putBack)")
        #expect(owner.hide.visited == tenth.hide.visited && owner.hide.indexed == tenth.hide.indexed)
        #expect(owner.putBack.visited == tenth.putBack.visited && owner.putBack.indexed == tenth.putBack.indexed)
    }

    /// A Move to Trash delivered while a background pass's publication of a read is being
    /// made off the actor is published at once, before that publication; when the read's
    /// publication follows, it keeps the trashed photo off, is an edit of the act's order of
    /// one photo moved, and costs the edit, not the 160,000 photos.
    @Test func anActWhileABuildIsPublishedIsNotQueuedBehindIt() async throws {
        let photos = 160_000
        let store = makeTestStore(location: .inMemory)
        try await store.start(scansSavedLibraries: false)
        let builds = Mutex(0)
        let gate = PublicationGate()
        let projection = CatalogProjection(
            volumeCapacity: ampleVolumeCapacity,
            cadence: .milliseconds(10),
            stateBuilder: { _, _, request in
                let call = builds.withLock { count in
                    count += 1
                    return count
                }
                return Self.state(photos: photos, request: request, movingFirst: call > 1)
            },
            preparingPublication: { await gate.pass() }
        )
        let stream = await projection.states(store: store, initialDescriptor: .default)
        let draining = Task {
            for await _ in stream {}
        }
        defer {
            draining.cancel()
        }
        try await waitUntil { await projection.isQuiescent }
        let shown = try #require(await projection.lastPublishedState)

        // A read that moved a photo: its publication is held where it is made.
        await gate.close()
        try await store.addLibrary(url: makeTestDirectory())
        await gate.waitUntilHeld()

        let trashed = shown.mediaGrid.orderedAssetIDs[photos / 2]
        await projection.hide([trashed], batch: MediaTrashBatchID(unixMilliseconds: 1))
        let acted = try #require(await projection.lastPublishedState)
        #expect(!acted.mediaGrid.content.contains(trashed), "the act is published while the read's publication is held")
        #expect(acted.mediaGrid.content.edit(from: shown.mediaGrid.content)?.size == 1)

        await gate.open()
        try await waitUntil { await projection.isQuiescent }
        let read = try #require(await projection.lastPublishedState)
        #expect(read.mediaGrid.orderedAssetIDs.count == photos - 1)
        #expect(!read.mediaGrid.content.contains(trashed), "the read keeps the held act")
        #expect(read.mediaGrid.content.position(of: Self.id(0)) == 4 * Self.photosPerDay - 1)
        let edit = try #require(read.mediaGrid.content.edit(from: acted.mediaGrid.content))
        #expect(edit.size == 2, "one photo moved: \(edit)")
        let work = read.mediaGrid.content.work
        #expect(work.visited <= 8 && work.indexed <= 4, "the read's publication after the act: \(work)")
    }
}

/// Holds a pass's publication where it is made off the actor while closed.
private actor PublicationGate {
    private var closed = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []

    func close() {
        closed = true
    }

    func open() {
        closed = false
        let resumed = held
        held = []
        for continuation in resumed {
            continuation.resume()
        }
    }

    func pass() async {
        guard closed else {
            return
        }
        await withCheckedContinuation { continuation in
            held.append(continuation)
            let waiters = heldWaiters
            heldWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitUntilHeld() async {
        guard held.isEmpty else {
            return
        }
        await withCheckedContinuation { heldWaiters.append($0) }
    }
}
