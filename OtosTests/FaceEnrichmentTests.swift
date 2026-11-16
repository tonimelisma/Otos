import CoreGraphics
import CoreServices
import Foundation
@testable import OtosKit
import Testing

/// Faces in the catalog (ADR 0047): enrichment never reads a still's, and the catalog stores,
/// replaces, moves and purges a still's faces read from its stored preview.
@Suite(.testScope)
struct FaceEnrichmentTests {
    // MARK: - Enrichment

    /// A still's faces are not an enrichment product: a library still whose metadata,
    /// rendering and digest are current is not claimed, whether or not its faces were read,
    /// so no original is downloaded for them.
    @Test func enrichmentNeverClaimsAStillForItsFaces() {
        for read in [false, true] {
            let asset = Self.asset(facesStamped: read)
            for claim in EnrichmentClaim.allCases {
                #expect(!asset.needsEnrichment(claim))
            }
            #expect(EnrichmentScope(claim: .products, asset: asset).isEmpty)
            #expect(EnrichmentScope(claim: .library, asset: asset).isEmpty)
        }
    }

    // MARK: - The catalog

    /// A reading's faces are stored with its stamp and read back as they were found; a
    /// later reading replaces every one of them.
    @Test func aReadingStoresItsFacesAndTheNextReplacesThem() async throws {
        let library = try await ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg"])
        let first = [Self.face(seed: 1), Self.face(seed: 2)]

        try await library.readFaces([library.result(for: "a.jpg", faces: first)])

        #expect(try await library.store.faces(of: library.id("a.jpg")) == first)
        #expect(try await library.store.previewFaceCandidates(limit: 10).candidates.isEmpty)

        let second = [Self.face(seed: 3)]
        try await library.readFaces([library.result(for: "a.jpg", faces: second)])
        #expect(try await library.store.faces(of: library.id("a.jpg")) == second)
        await library.store.shutdown()
    }

    /// A reading of a preview of bytes the row's preview was not made from is rejected
    /// whole: no faces are stored and the row still owes them.
    @Test func aReadingOfOtherBytesStoresNoFaces() async throws {
        let library = try await ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg"])

        try await library.readFaces([
            library.result(for: "a.jpg", faces: [Self.face(seed: 1)], sizeOffset: 1),
        ])

        #expect(try await library.store.faces(of: library.id("a.jpg")).isEmpty)
        #expect(try await library.store.previewFaceCandidates(limit: 10).candidates.map(\.id) == [library.id("a.jpg")])
        await library.store.shutdown()
    }

    /// What the user said about a face outlives a new reading of the same source that does not
    /// find it (an analysis revision, an edit hiding part of the photo): a named face and a
    /// face marked not a face stay as they were read, and a found face keeps its mark, so it
    /// stays out of the People snapshot. A changed file is read afresh: only what overlaps a
    /// new face carries.
    @Test func aReReadingKeepsWhatTheUserSaidAboutFacesItDoesNotFind() async throws {
        let library = try await ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg"])
        let named = Self.face(seed: 1), marked = Self.face(seed: 5)
        try await library.readFaces([library.result(for: "a.jpg", faces: [named, marked])])
        let a0 = FaceID(asset: library.id("a.jpg"), index: 0), a1 = FaceID(asset: library.id("a.jpg"), index: 1)
        let sam = try #require(try await library.store.perform(.moveToNewPerson([a0], name: "Sam")).person)
        _ = try await library.store.perform(.notAFace([a1]))

        try await library.readFaces([library.result(for: "a.jpg", faces: [marked])])
        var facts = try await library.store.peopleSnapshot().faces
        #expect(try await library.store.faces(of: library.id("a.jpg")) == [marked, named])
        #expect(facts.map(\.assignment) == [.user(sam)])

        try await library.readFaces([library.result(for: "a.jpg", faces: [])])
        facts = try await library.store.peopleSnapshot().faces
        #expect(try await library.store.faces(of: library.id("a.jpg")) == [marked, named])
        #expect(facts.map(\.assignment) == [.user(sam)])

        let file = library.root.appending(path: "a.jpg")
        try Data("a changed photo, longer than before".utf8).write(to: file)
        library.emit(FilesystemEvent(
            path: file.path,
            flags: UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
        ))
        _ = try await waitForCatalogStoreState(library.store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.first?.byteSize == 35
        }
        try await library.readFaces([library.result(for: "a.jpg", faces: [named])])
        facts = try await library.store.peopleSnapshot().faces
        #expect(try await library.store.faces(of: library.id("a.jpg")) == [named])
        #expect(facts.map(\.assignment) == [.user(sam)])
        await library.store.shutdown()
    }

    /// A rename seen as file events moves the row, and its faces go with it (ADR 0034).
    @Test func aRenamedPhotoKeepsItsFaces() async throws {
        let library = try await ScannedLibrary.make(in: makeTestDirectory(), files: ["before.jpg"])
        let faces = [Self.face(seed: 1)]
        try await library.readFaces([library.result(for: "before.jpg", faces: faces)])

        let original = library.root.appending(path: "before.jpg")
        let renamed = library.root.appending(path: "after.jpg")
        try FileManager.default.moveItem(at: original, to: renamed)
        let flags = UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile)
        library.emit(FilesystemEvent(path: original.path, flags: flags))
        library.emit(FilesystemEvent(path: renamed.path, flags: flags))
        _ = try await waitForCatalogStoreState(library.store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["after.jpg"]
        }

        #expect(try await library.store.faces(of: library.id("after.jpg")) == faces)
        #expect(try await library.store.faces(of: library.id("before.jpg")).isEmpty)
        await library.store.shutdown()
    }

    /// A photo proven deleted takes its faces with it.
    @Test func aRemovedPhotoTakesItsFacesWithIt() async throws {
        let library = try await ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg", "b.jpg"])
        try await library.readFaces([library.result(for: "a.jpg", faces: [Self.face(seed: 1)])])

        let file = library.root.appending(path: "a.jpg")
        try FileManager.default.removeItem(at: file)
        library.emit(FilesystemEvent(
            path: file.path,
            flags: UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)
        ))
        _ = try await waitForCatalogStoreState(library.store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["b.jpg"]
        }

        #expect(try await library.store.faces(of: library.id("a.jpg")).isEmpty)
        await library.store.shutdown()
    }

    // MARK: - Fixtures

    /// A library on disk, scanned, whose catalog hears file events from the test.
    struct ScannedLibrary {
        let store: CatalogStore
        let root: URL
        let rootPath: LibraryRootPath
        let emit: @Sendable (FilesystemEvent) -> Void
        /// The catalog's file, when the test asked for one to write rows the store never writes.
        var databaseURL: URL?

        /// `database` puts the catalog in a file, which a test can open beside the store.
        static func make(in directory: URL, files: [String], database: URL? = nil) async throws -> ScannedLibrary {
            let root = directory.appending(path: "Pictures", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for name in files {
                try writeCatalogStoreFile(root.appending(path: name), contents: "jpeg \(name)")
            }
            if let database {
                try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            let (watcher, emit) = CatalogFilesystemWatcher.testing()
            let store = makeTestStore(
                location: database.map { .databaseFile($0) } ?? .inMemory, filesystemWatcher: watcher, scanCadence: .milliseconds(10)
            )
            try await store.start(scansSavedLibraries: false)
            try await store.addLibrary(url: root)
            _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == files.count }
            return try ScannedLibrary(
                store: store, root: root, rootPath: CatalogPath.normalizedDirectoryPath(for: root), emit: emit,
                databaseURL: database
            )
        }

        func id(_ name: String) -> MediaAssetID {
            MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: name))
        }

        /// One still's faces, read from a stored preview of the file as scanned; `sizeOffset`
        /// makes it a reading of a preview of other bytes, and `captured` dates the photo.
        struct FaceReading {
            let name: String
            let faces: [DetectedFace]
            let sizeOffset: Int64
            var captured: Date?
        }

        func result(for name: String, faces: [DetectedFace], sizeOffset: Int64 = 0, captured: Date? = nil) -> FaceReading {
            FaceReading(name: name, faces: faces, sizeOffset: sizeOffset, captured: captured)
        }

        /// Writes a video's faces as enrichment reads them, with every other product current
        /// for the file as scanned; each face read in its own frame, with no frames file.
        @discardableResult
        func readVideoFaces(_ name: String, faces: [DetectedFace]) async throws -> EnrichmentApplyOutcome {
            let asset = try #require(try await store.mediaAssets(for: [id(name)])[id(name)])
            return await store.applyEnrichmentBatch([EnrichmentResult(
                id: id(name),
                metadata: AssetMetadata(),
                thumbnailPath: "thumb-\(name).jpg",
                sourceSize: asset.byteSize,
                sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
                contentHash: .empty,
                videoFaces: EnrichedVideoFaces(
                    faces: faces.enumerated().map { EnrichedVideoFaces.Face(face: $1, frameIndex: $0) },
                    analysisRevision: FaceAnalyzer.revision,
                    frames: nil
                )
            )])
        }

        /// Gives each still a stored preview with every product current for the file as
        /// scanned, then writes each reading's faces as `PreviewFaceReader` does. Returns the
        /// rows written.
        @discardableResult
        func readFaces(_ readings: [FaceReading]) async throws -> Int {
            var renderings: [EnrichmentResult] = []
            var candidates: [PreviewFaceCandidate] = []
            for reading in readings {
                let asset = try #require(try await store.mediaAssets(for: [id(reading.name)])[id(reading.name)])
                let size = try #require(asset.byteSize)
                let mtime = MediaAsset.mtimeSeconds(asset.contentModifiedAt)
                renderings.append(EnrichmentResult(
                    id: id(reading.name),
                    metadata: AssetMetadata(timestamps: reading.captured.map { [.absolute(instant: $0)] } ?? []),
                    thumbnailPath: "thumb-\(reading.name).jpg",
                    sourceSize: size,
                    sourceMTimeSeconds: mtime,
                    contentHash: .empty,
                    previewPath: "preview-\(reading.name).heic"
                ))
                candidates.append(PreviewFaceCandidate(
                    id: id(reading.name), previewPath: "preview-\(reading.name).heic",
                    sourceSize: size + reading.sizeOffset, sourceMTimeSeconds: mtime,
                    renderedRevision: 0, recipe: .neutral
                ))
            }
            _ = await store.applyEnrichmentBatch(renderings)
            return try await store.applyPreviewFaces(zip(readings, candidates).map { reading, candidate in
                PreviewFaceResult(candidate: candidate, faces: EnrichedFaces(faces: reading.faces, analysisRevision: FaceAnalyzer.revision))
            })
        }
    }

    static func id(_ name: String) -> MediaAssetID {
        MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/Lib"), relativePath: MediaRelativePath(rawValue: name))
    }

    /// A row of 100 bytes whose metadata, rendering and digest are current.
    static func asset(facesStamped: Bool) -> MediaAsset {
        MediaAsset(
            libraryRootPath: LibraryRootPath(rawValue: "/Lib"),
            relativePath: MediaRelativePath(rawValue: "a.jpg"),
            name: "a.jpg",
            contentTypeIdentifier: "public.jpeg",
            byteSize: 100,
            createdAt: nil,
            contentModifiedAt: Date(timeIntervalSince1970: 1000),
            metadataSourceSize: 100,
            metadataSourceMTimeSeconds: 1000,
            renderedSourceSize: 100,
            renderedSourceMTimeSeconds: 1000,
            contentHash: .empty,
            contentHashSourceSize: 100,
            contentHashSourceMTimeSeconds: 1000,
            facesSourceSize: facesStamped ? 100 : nil,
            facesSourceMTimeSeconds: facesStamped ? 1000 : nil
        )
    }

    /// A face with its own fixed position and embedding for each seed.
    static func face(seed: Int) -> DetectedFace {
        let quarter = Double(seed) / 16
        return DetectedFace(
            box: CGRect(x: quarter, y: 0.25, width: 0.125, height: 0.25),
            landmarks: FaceAlignment.Landmarks(
                leftEye: CGPoint(x: quarter, y: 0.375), rightEye: CGPoint(x: quarter + 1 / 64, y: 0.375),
                nose: CGPoint(x: quarter + 2 / 64, y: 0.375), leftMouth: CGPoint(x: quarter + 3 / 64, y: 0.375),
                rightMouth: CGPoint(x: quarter + 4 / 64, y: 0.375)
            ),
            quality: 0.5,
            embedding: FaceEmbedding(normalizing: (0 ..< FaceEmbeddingModel.dimensions).map { Float(($0 + seed) % 7) })!
        )
    }
}
