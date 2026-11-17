import Foundation
import GRDB
@testable import OtosKit
import Testing

/// ADR 0042, plan 0116 bet 3: a duplicates build costs what changed. It reads the identical
/// copies and the compared stills' column facts from indexes that hold only those, pairs the
/// stills again only when they, the identical copies or the reach moved, and reads a still's
/// evidence only when its stamp moved. What it publishes is, after every change, what a build
/// from nothing publishes.
@Suite(.testScope, .serialized)
struct DuplicatesBuildTests {
    /// The generated library the benchmarks build from, at the smallest size that holds what
    /// the build is about: versions of one photo, identical copies (one in forty) and
    /// unrelated stills.
    private static let stills = 120

    private func build(
        _ library: BenchmarkLibrary,
        memory: SamePhotoMemory = .empty
    ) async throws -> DuplicatesProjection.Built {
        try await DuplicatesProjection.build(store: library.store, libraries: library.libraries, memory: memory)
    }

    @Test func aBuildFromWhatTheLastOneHeldIsTheBuildFromNothing() async throws {
        let library = try await BenchmarkLibrary.make(in: makeTestDirectory(), stills: Self.stills)
        let store = library.store
        let first = try await build(library)
        #expect(first.paired)
        #expect(first.evidenceRead > 0)
        let group = try #require(first.state.groups.first { $0.id.isSamePhoto })
        #expect(first.state.groups.contains { !$0.id.isSamePhoto })

        // Nothing it is built from moved: nothing is paired again and no evidence is read.
        let again = try await build(library, memory: first.memory)
        #expect(!again.paired)
        #expect(again.evidenceRead == 0)
        #expect(again.state == first.state)

        // A choice changes a member's copy, not what grouped it: the copy is read again and
        // the pairing held.
        let member = try #require(group.copies.first?.id)
        _ = try await store.setMediaChoice(.liked, for: [member])
        let liked = try await build(library, memory: again.memory)
        #expect(!liked.paired)
        #expect(liked.evidenceRead == 0)
        #expect(liked.state != first.state)
        #expect(try await liked.state == build(library).state)

        // A redrawn thumbnail leaves the member's signature stale: it is no longer compared.
        let asset = try #require(try await store.windowReads.mediaAssets(for: [member])[member])
        let signature = try #require(first.memory.evidence[member]?.evidence.signature)
        _ = await store.applyEnrichmentBatch([EnrichmentResult(
            id: member,
            metadata: nil,
            rendering: EnrichedRendering(thumbnailPath: "redrawn.jpg", previewPath: "redrawn-preview.jpg"),
            sourceSize: asset.byteSize,
            sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
            contentHash: nil
        )])
        let redrawn = try await build(library, memory: liked.memory)
        #expect(redrawn.paired)
        #expect(!redrawn.state.groups.flatMap(\.copies).contains { $0.id == member })
        #expect(try await redrawn.state == build(library).state)

        // Signed again with the same pixels, it returns to its group; only the evidence that
        // moved is read, not every proposed still's.
        let owed = try await store.backgroundReads.renderSignatureCandidates(limit: 10).candidates
        #expect(owed.map(\.id) == [member])
        #expect(try await store.applyRenderSignatures(owed.map {
            RenderSignatureResult(id: $0.id, source: $0.source, signature: signature)
        }) == 1)
        let resigned = try await build(library, memory: redrawn.memory)
        #expect(resigned.paired)
        #expect(resigned.evidenceRead > 0 && resigned.evidenceRead <= 2, "read \(resigned.evidenceRead)")
        #expect(resigned.state.groups.flatMap(\.copies).contains { $0.id == member })
        #expect(try await resigned.state == build(library).state)
        #expect(resigned.state.groups.map(\.id) == liked.state.groups.map(\.id))

        // A record whose camera changed is another capture's: the still is compared by its
        // new facts.
        _ = await store.applyEnrichmentBatch([EnrichmentResult(
            id: member,
            metadata: AssetMetadata(cameraModel: "Another", pixelWidth: 4032, pixelHeight: 3024),
            enrichedKind: .image,
            thumbnailPath: "redrawn.jpg",
            sourceSize: asset.byteSize,
            sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
            contentHash: nil
        )])
        let recorded = try await build(library, memory: resigned.memory)
        #expect(recorded.paired)
        #expect(try await recorded.state == build(library).state)
        await store.shutdown()
    }

    /// The candidate read is answered from the two indexes that hold exactly the compared
    /// stills and their pairing columns, never from the wide asset or record rows.
    @Test func theComparedStillsAreReadFromTheirCoveringIndexesOnAnOwnerShapedCatalog() async throws {
        let catalog = try OwnerShapedCatalog.make(in: makeTestDirectory(), scale: 0.01)
        let store = makeTestStore(location: .databaseFile(catalog.databaseURL))
        try await store.start(scansSavedLibraries: false)
        await store.shutdown()
        let dbQueue = try makeTestDatabaseQueue(path: catalog.databaseURL.path(percentEncoded: false))
        let plan = try await dbQueue.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(SamePhotoSQL.candidatesSQL(rootCount: 3))", arguments: [6, 7, 15])
                .map { $0["detail"] as String }
        }
        #expect(plan == [
            "SEARCH media_asset USING COVERING INDEX \(SamePhotoSQL.candidateIndexName) (library_root_id=?)",
            "SEARCH m USING COVERING INDEX \(SamePhotoSQL.metadataIndexName) (library_root_id=? AND relative_path=?) LEFT-JOIN",
        ], "\(plan)")
    }
}
