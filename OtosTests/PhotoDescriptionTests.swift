import CoreGraphics
import Foundation
import GRDB
@testable import OtosKit
import Synchronization
import Testing

/// Stills' descriptions (ADR 0053): when a still is owed one, what the model is told, how a
/// change to any fact it was written from makes it owed again, how a declined or stale answer
/// is stored, the writer end to end, and On This Day's titles written from them.
@Suite(.testScope)
struct PhotoDescriptionTests {
    /// Every prompt the stand-in model was handed.
    private final class Prompts: Sendable {
        private let seen = Mutex<[PhotoDescriptionPrompt]>([])

        func record(_ prompt: PhotoDescriptionPrompt) {
            seen.withLock { $0.append(prompt) }
        }

        var value: [PhotoDescriptionPrompt] {
            seen.withLock { $0 }
        }
    }

    /// A still is described only once its faces, text and labels are read for its preview;
    /// a description names the facts it was written from, so naming a face's person or giving
    /// them a birthday owes a new one, and an answer for facts since changed is not written.
    @Test func aStillIsOwedADescriptionForEachVersionOfItsFacts() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg"])
        let still = library.id("a.jpg")
        let store = library.store
        try await library.readFaces([library.result(for: "a.jpg", faces: [FaceEnrichmentTests.face(seed: 1)])])
        #expect(try await store.backgroundReads.photoDescriptionCandidates(limit: 10).candidates.isEmpty)

        try await Self.readText(["SAUNA"], in: store)
        #expect(try await store.backgroundReads.photoDescriptionCandidates(limit: 10).candidates.isEmpty)
        try await Self.readLabels(["lake"], in: store)

        let first = try await store.backgroundReads.photoDescriptionCandidates(limit: 10).candidates
        #expect(first.map(\.id) == [still])
        #expect(first.first?.facts.faces.map(\.name) == [nil])
        #expect(first.first?.facts.textLines == ["SAUNA"])
        #expect(first.first?.facts.labels == ["lake"])
        let written = try #require(first.first)
        #expect(try await store.applyPhotoDescriptions([Self.result(written, "A lake.")]).count == 1)
        #expect(try await store.backgroundReads.photoDescriptionCandidates(limit: 10).candidates.isEmpty)
        #expect(try await store.windowReads.photoInfoOverlay(for: still)?.photoDescription == .written("A lake."))

        let sam = try #require(try await store.perform(.moveToNewPerson([FaceID(asset: still, index: 0)], name: "Sam")).person)
        #expect(try await store.windowReads.photoInfoOverlay(for: still)?.photoDescription == nil)
        let named = try await store.backgroundReads.photoDescriptionCandidates(limit: 10).candidates
        #expect(named.first?.facts.faces.map(\.name) == ["Sam"])
        #expect(try await store.applyPhotoDescriptions([Self.result(written, "Stale.")]).isEmpty)

        _ = try await store.perform(.edit(sam, name: "Sam", birthday: PersonBirthday("2020-05-01")))
        let dated = try await store.backgroundReads.photoDescriptionCandidates(limit: 10).candidates
        #expect(dated.first?.facts.faces.first?.birthday == PersonBirthday("2020-05-01"))
        #expect(try await store.applyPhotoDescriptions(named.map { Self.result($0, "Sam.") }).isEmpty)
        #expect(try await store.applyPhotoDescriptions(dated.map { Self.result($0, nil) }).count == 1)
        #expect(try await store.windowReads.photoInfoOverlay(for: still)?.photoDescription == .declined)
        #expect(try await store.backgroundReads.currentPhotoDescriptions(for: [still]).isEmpty)

        _ = try await store.perform(.setHidden(sam, true))
        #expect(try await store.backgroundReads.photoDescriptionCandidates(limit: 10).candidates.first?.facts.faces.map(\.name) == [nil])
        await store.shutdown()
    }

    /// What the model is told of a still's text and scene labels is only what was read from
    /// the preview and thumbnail it has now: rows read from earlier ones tell it nothing.
    @Test func theModelIsToldOnlyTheReadingsOfTheStillsCurrentPictures() async throws {
        let directory = try makeTestDirectory()
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(
            in: directory, files: ["a.jpg"], database: directory.appending(path: "db/catalog.sqlite")
        )
        try await library.readFaces([library.result(for: "a.jpg", faces: [FaceEnrichmentTests.face(seed: 1)])])
        try await Self.readText(["SAUNA"], in: library.store)
        try await Self.readLabels(["lake"], in: library.store)
        let database = try makeTestDatabaseQueue(path: #require(library.databaseURL).path(percentEncoded: false))
        let rootID = try await database.read { db in
            try #require(try Int64.fetchOne(db, sql: "SELECT library_root_id FROM media_asset WHERE relative_path = 'a.jpg'"))
        }
        let current = try await database.read { db in try CatalogStore.photoDescriptionFacts(db, key: [rootID, "a.jpg"]) }
        #expect(current.textLines == ["SAUNA"])
        #expect(current.labels == ["lake"])

        // New pictures of the still; the rows were read from the old ones.
        try await database.write { db in
            try db.execute(sql: """
            UPDATE media_asset SET thumbnail_path = 'other-thumb.jpg', preview_path = 'other-preview.jpg'
            WHERE relative_path = 'a.jpg'
            """)
        }
        let stale = try await database.read { db in try CatalogStore.photoDescriptionFacts(db, key: [rootID, "a.jpg"]) }
        #expect(stale.textLines.isEmpty)
        #expect(stale.labels.isEmpty)
        await library.store.shutdown()
    }

    /// The writer reads the stored preview, tells the model who is where, and stores its
    /// answer; a renamed person is described again.
    @Test func theWriterDescribesAndDescribesAgainOnARename() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg"])
        let still = library.id("a.jpg")
        let store = library.store
        let directory = try makeTestDirectory().appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeSubjectJPEG(to: directory.appending(path: "preview-a.jpg.heic"), center: CGPoint(x: 0.5, y: 0.5))
        try await library.readFaces([library.result(for: "a.jpg", faces: [FaceEnrichmentTests.face(seed: 1)])])
        let sam = try #require(try await store.perform(.moveToNewPerson([FaceID(asset: still, index: 0)], name: "Sam")).person)
        try await Self.readText([], in: store)
        try await Self.readLabels(["lake"], in: store)
        let prompts = Prompts()
        let writer = PhotoDescriptionWriter(store: store, thumbnailDirectory: directory) { image, prompt in
            #expect(image.width <= PhotoDescriptionWriter.modelPixelSize)
            prompts.record(prompt)
            return .written(prompt.facts.contains("Max") ? "Max by a lake." : "Sam by a lake.")
        }

        await writer.start()
        try await waitUntil { try await store.windowReads.photoInfoOverlay(for: still)?.photoDescription == .written("Sam by a lake.") }
        _ = try await store.perform(.edit(sam, name: "Max", birthday: nil))
        try await waitUntil { try await store.windowReads.photoInfoOverlay(for: still)?.photoDescription == .written("Max by a lake.") }
        await writer.shutdown()

        #expect(prompts.value.first?.facts.contains("- Sam: face on the left.") == true)
        #expect(prompts.value.first?.facts.contains("Recognized in the scene: lake.") == true)
        await store.shutdown()
    }

    /// ADR 0057: while the person is in the app no request is made, and the writer's status
    /// names the hold; once the app is left the still is described, with one request.
    @Test func noRequestIsMadeWhileThePersonIsInTheApp() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg"])
        let still = library.id("a.jpg")
        let store = library.store
        let directory = try makeTestDirectory().appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeSubjectJPEG(to: directory.appending(path: "preview-a.jpg.heic"), center: CGPoint(x: 0.5, y: 0.5))
        try await library.readFaces([library.result(for: "a.jpg", faces: [])])
        try await Self.readText([], in: store)
        try await Self.readLabels([], in: store)
        var inApp = MachineConditions.roomy
        inApp.userInApp = true
        let room = BackgroundRoom(conditions: inApp)
        let requests = Mutex(0)
        let writer = PhotoDescriptionWriter(store: store, thumbnailDirectory: directory, describe: { _, _ in
            requests.withLock { $0 += 1 }
            return .written("A lake.")
        }, room: room)

        await writer.start()
        try await waitUntil { await writer.status.heldBy == BackgroundHold.userInApp.rawValue }
        #expect(requests.withLock { $0 } == 0)

        room.deliver(.roomy)
        try await waitUntil { try await store.windowReads.photoInfoOverlay(for: still)?.photoDescription == .written("A lake.") }
        #expect(requests.withLock { $0 } == 1)
        #expect(room.counts.admitted[.description] == 1)
        #expect(await writer.status.heldBy == nil)
        await writer.shutdown()
        await store.shutdown()
    }

    /// One drain is one newest-first walk (ADR 0009), and a fact change during it restarts the
    /// walk from the newest still at its next page: a still made owed while an older one is
    /// described comes next, before the rest of the backlog.
    @Test func aChangeDuringTheWalkRestartsItFromTheNewestStill() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg", "b.jpg", "c.jpg"])
        let store = library.store
        let directory = try makeTestDirectory().appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await library.readFaces(["a.jpg", "b.jpg", "c.jpg"].map { library.result(for: $0, faces: []) })
        try await Self.readText([], in: store)
        try await Self.readLabels([], in: store)
        let owed = try await store.backgroundReads.photoDescriptionCandidates(limit: 10).candidates
        #expect(owed.count == 3)
        for candidate in owed {
            try writeSubjectJPEG(to: directory.appending(path: candidate.previewPath), center: CGPoint(x: 0.5, y: 0.5))
        }
        let newest = try #require(owed.first)
        // The newest is described already; renaming a person in it owes it again.
        _ = try await store.applyPhotoDescriptions([Self.result(newest, "Before.")])
        try await library.readFaces([library.result(for: newest.id.relativePath.rawValue, faces: [FaceEnrichmentTests.face(seed: 1)])])
        let person = try #require(try await store.perform(.moveToNewPerson([FaceID(asset: newest.id, index: 0)], name: "Sam")).person)
        _ = try await store.applyPhotoDescriptions(store.backgroundReads.photoDescriptionCandidates(limit: 10).candidates.filter { $0.id == newest.id }
            .map { Self.result($0, "Sam.") })
        #expect(try await store.backgroundReads.photoDescriptionCandidates(limit: 10).candidates.map(\.id) == Array(owed.dropFirst().map(\.id)))

        let described = Mutex<[String]>([])
        let (held, hold) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        let writer = PhotoDescriptionWriter(store: store, thumbnailDirectory: directory, describe: { _, prompt in
            let count = described.withLock { described in
                described.append(prompt.facts.contains("Max") ? "max" : "other")
                return described.count
            }
            if count == 1 {
                hold.yield()
                for await _ in released {
                    break
                }
            }
            return .written("Described.")
        }, pageSize: 1)
        await writer.start()
        for await _ in held {
            break
        }
        let before = await writer.requested
        _ = try await store.perform(.edit(person, name: "Max", birthday: nil))
        try await waitUntil { await writer.requested != before }
        release.yield()
        try await waitUntil { try await store.backgroundReads.photoDescriptionCandidates(limit: 10).candidates.isEmpty }
        await writer.shutdown()

        #expect(described.withLock { $0 } == ["other", "max", "other"])
        await store.shutdown()
    }

    /// A change that names its rows owes those stills alone: the writer reads them by key and
    /// walks nothing, so a backlog's described stills are never visited again for each reading
    /// written (ADR 0009). A change that names none still walks.
    @Test func aNamedChangeIsDescribedByKeyWithoutAWalk() async throws {
        // A file-backed catalog: its connections account each transaction to its operation.
        let root = try makeTestDirectory()
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(
            in: root, files: ["a.jpg", "b.jpg"], database: root.appending(path: "db/catalog.sqlite")
        )
        let store = library.store
        let directory = try makeTestDirectory().appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await library.readFaces(["a.jpg", "b.jpg"].map { library.result(for: $0, faces: []) })
        try await Self.readLabels([], in: store)
        // Only a.jpg's text is read: b.jpg is not describable yet.
        let owedText = try await store.backgroundReads.searchTextCandidates(limit: 10).candidates
        let first = try #require(owedText.first { $0.id == library.id("a.jpg") })
        let second = try #require(owedText.first { $0.id == library.id("b.jpg") })
        _ = try await store.applySearchTexts([SearchTextResult(id: first.id, source: first.source, lines: [])])
        for path in ["a.jpg", "b.jpg"] {
            try writeSubjectJPEG(to: directory.appending(path: "preview-\(path).heic"), center: CGPoint(x: 0.5, y: 0.5))
        }
        let writer = PhotoDescriptionWriter(store: store, thumbnailDirectory: directory) { _, _ in .written("Described.") }
        await writer.start()
        try await waitUntil { try await store.backgroundReads.currentPhotoDescriptions(for: [first.id]).count == 1 }
        _ = try await writer.untilQuiescent()
        func transactions(_ operation: String) -> Int {
            store.use().connections.holds.filter { $0.operation == operation }.reduce(0) { $0 + $1.count }
        }
        let walksBefore = transactions("photoDescriptionCandidates")

        _ = try await store.applySearchTexts([SearchTextResult(id: second.id, source: second.source, lines: [])])
        try await waitUntil { try await store.backgroundReads.currentPhotoDescriptions(for: [second.id]).count == 1 }
        _ = try await writer.untilQuiescent()
        #expect(transactions("photoDescriptionCandidates") == walksBefore)
        #expect(transactions("photoDescriptionCandidatesByKey") >= 1)
        await writer.shutdown()
        await store.shutdown()
    }

    /// A model that is not available writes nothing and stops the drain; the still stays owed.
    @Test func anUnavailableModelWritesNothing() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg"])
        let store = library.store
        let directory = try makeTestDirectory().appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeSubjectJPEG(to: directory.appending(path: "preview-a.jpg.heic"), center: CGPoint(x: 0.5, y: 0.5))
        try await library.readFaces([library.result(for: "a.jpg", faces: [])])
        try await Self.readText([], in: store)
        try await Self.readLabels([], in: store)
        let writer = PhotoDescriptionWriter(store: store, thumbnailDirectory: directory) { _, _ in
            throw PhotoDescriber.ModelUnavailable(reason: "appleIntelligenceNotEnabled")
        }

        await writer.start()
        try await waitUntil { await writer.drains >= 1 }
        await writer.shutdown()

        #expect(try await store.backgroundReads.photoDescriptionCandidates(limit: 10).candidates.map(\.id) == [library.id("a.jpg")])
        await store.shutdown()
    }

    /// On This Day's title is written from the descriptions of the anniversary's photos, and
    /// an anniversary with none described has none.
    @Test func anAnniversaryIsTitledFromItsDescriptions() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg", "b.jpg"])
        let store = library.store
        try await library.readFaces([
            library.result(for: "a.jpg", faces: []), library.result(for: "b.jpg", faces: []),
        ])
        try await Self.readText([], in: store)
        try await Self.readLabels([], in: store)
        let owed = try await store.backgroundReads.photoDescriptionCandidates(limit: 10).candidates
        let a = try #require(owed.first { $0.id == library.id("a.jpg") })
        _ = try await store.applyPhotoDescriptions([Self.result(a, "Picking berries at the cottage.")])
        let descriptions = PhotoDescriptionWriter(store: store, thumbnailDirectory: nil) { _, _ in .declined }
        let prompts = Mutex<[AnniversaryTitlePrompt]>([])
        let titles = AnniversaryTitleWriter(store: store, descriptions: descriptions) { prompt in
            prompts.withLock { $0.append(prompt) }
            return "Berry Picking"
        }
        let described = CalendarDay(year: 2023, month: 11, day: 14)
        let undescribed = CalendarDay(year: 2022, month: 11, day: 14)
        let stream = await titles.titles()

        await titles.show([
            AnniversaryTitleWriter.Anniversary(day: described, ago: "3 years ago", items: [library.id("a.jpg")]),
            AnniversaryTitleWriter.Anniversary(day: undescribed, ago: "4 years ago", items: [library.id("b.jpg")]),
        ])
        var published: [CalendarDay: String] = [:]
        for await next in stream where !next.isEmpty {
            published = next
            break
        }
        await titles.shutdown()

        #expect(published == [described: "Berry Picking"])
        #expect(prompts.withLock { $0 } == [AnniversaryTitlePrompt(ago: "3 years ago", descriptions: ["Picking berries at the cottage."])])
        await store.shutdown()
    }

    // MARK: - The prompt

    @Test func anAgeIsWordedFromTheBirthdayOnTheDayTaken() throws {
        let taken = try #require(CaptureLocalTime(startOf: CalendarDay(year: 2026, month: 7, day: 18)))
        #expect(PhotoDescriptionPrompt.age(birthday: PersonBirthday("1988-03-02"), at: taken) == "38 years old")
        #expect(PhotoDescriptionPrompt.age(birthday: PersonBirthday("1988-08-02"), at: taken) == "37 years old")
        #expect(PhotoDescriptionPrompt.age(birthday: PersonBirthday("2025-03-18"), at: taken) == "16 months old")
        #expect(PhotoDescriptionPrompt.age(birthday: PersonBirthday("2026-06-10"), at: taken) == "1 month old")
        #expect(PhotoDescriptionPrompt.age(birthday: PersonBirthday("2026-07-10"), at: taken) == "under a month old")
        #expect(PhotoDescriptionPrompt.age(birthday: PersonBirthday("2026-08-01"), at: taken) == nil)
        #expect(PhotoDescriptionPrompt.age(birthday: PersonBirthday("1984"), at: taken) == "about 42 years old")
        #expect(PhotoDescriptionPrompt.age(birthday: PersonBirthday("2025"), at: taken) == "about 1 year old")
        #expect(PhotoDescriptionPrompt.age(birthday: PersonBirthday("2026"), at: taken) == "under a year old")
        #expect(PhotoDescriptionPrompt.age(birthday: nil, at: taken) == nil)
    }

    /// The model is told when and where, who is where left to right, the text and the labels.
    @Test func thePromptTellsWhoIsWhere() throws {
        let taken = try #require(CaptureLocalTime(startOf: CalendarDay(year: 2026, month: 7, day: 18)))
        let facts = PhotoDescriptionFacts(
            faces: [], capturedAt: CaptureLocalTime(seconds: taken.seconds + 16 * 3600),
            town: "Espoo", country: "Finland", textLines: ["SAUNA", "OPEN"], labels: ["blue_sky"]
        )
        let prompt = PhotoDescriptionPrompt(faces: [
            PhotoDescriptionPrompt.Face(box: CGRect(x: 0.7, y: 0.7, width: 0.1, height: 0.1), name: nil, age: nil),
            PhotoDescriptionPrompt.Face(box: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1), name: "Jamie", age: "38 years old"),
        ], facts: facts)
        #expect(prompt.facts == """
        Taken on Saturday, 18 July 2026, in the afternoon, in Espoo, Finland.
        People in the photo, by where their faces are:
        - Jamie, 38 years old: face at the top left.
        Everyone else in the photo is unnamed.
        Text in the photo: "SAUNA / OPEN".
        Recognized in the scene: blue sky.
        """)
    }

    /// A photo naming no one is described with instructions that never mention names or ages;
    /// one whose faces are all named asks for each by name and no other; only one with unnamed
    /// faces too says that everyone else stays unnamed.
    @Test func theInstructionsSpeakOfNamesOnlyWhenThePhotoGivesThem() {
        let facts = PhotoDescriptionFacts(faces: [], capturedAt: nil, town: nil, country: nil, textLines: [], labels: [])
        let unnamed = PhotoDescriptionPrompt.Face(box: CGRect(x: 0.7, y: 0.4, width: 0.1, height: 0.1), name: nil, age: nil)
        let mia = PhotoDescriptionPrompt.Face(box: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1), name: "Mia", age: nil)
        for faces in [[], [unnamed, unnamed]] {
            let prompt = PhotoDescriptionPrompt(faces: faces, facts: facts)
            #expect(prompt.facts.isEmpty)
            #expect(!prompt.instructions.contains("name") && !prompt.instructions.contains("age"))
        }
        let named = PhotoDescriptionPrompt(faces: [mia], facts: facts)
        #expect(named.facts == """
        People in the photo, by where their faces are:
        - Mia: face in the middle.
        """)
        #expect(named.instructions.contains("call each of them by name") && named.instructions.contains("Use no other names."))
        #expect(!named.instructions.contains("Everyone else"))
        #expect(named.instructions.contains("Never state anyone's age."))
        let aged = PhotoDescriptionPrompt(
            faces: [PhotoDescriptionPrompt.Face(box: mia.box, name: "Mia", age: "8 years old")], facts: facts
        )
        #expect(aged.instructions.contains("Mention a given age only when it adds something, and no other age."))
        let mixed = PhotoDescriptionPrompt(faces: [mia, unnamed], facts: facts)
        #expect(mixed.facts.hasSuffix("Everyone else in the photo is unnamed."))
        #expect(mixed.instructions.contains("Everyone else stays unnamed"))
    }

    /// A face the crop leaves out is not told; one inside it is placed on the cropped preview.
    @Test func facesArePlacedOnTheEditedPreview() throws {
        let leftHalf = EditRecipe(crop: EditCrop(left: 0, top: 0, width: 0.5, height: 1))
        let candidate = PhotoDescriptionCandidate(
            id: FaceEnrichmentTests.id("a.jpg"), previewPath: "p", source: "s", recipe: leftHalf,
            facts: PhotoDescriptionFacts(
                faces: [
                    PhotoDescriptionFacts.Face(box: CGRect(x: 0.1, y: 0.4, width: 0.1, height: 0.2), name: "Ian", birthday: nil),
                    PhotoDescriptionFacts.Face(box: CGRect(x: 0.8, y: 0.4, width: 0.1, height: 0.2), name: "Sam", birthday: nil),
                ],
                capturedAt: nil, town: nil, country: nil, textLines: [], labels: []
            )
        )
        let faces = PhotoDescriptionWriter.faces(candidate, on: CGSize(width: 600, height: 800))
        #expect(faces.map(\.name) == ["Ian"])
        let box = try #require(faces.first?.box)
        #expect(abs(box.minX - 0.2) < 0.001 && abs(box.width - 0.2) < 0.001)
    }

    // MARK: - Helpers

    private static func result(_ candidate: PhotoDescriptionCandidate, _ text: String?) -> PhotoDescriptionResult {
        PhotoDescriptionResult(id: candidate.id, source: candidate.source, text: text)
    }

    private static func readText(_ lines: [String], in store: CatalogStore) async throws {
        let owed = try await store.backgroundReads.searchTextCandidates(limit: 100).candidates
        _ = try await store.applySearchTexts(owed.map { candidate in
            SearchTextResult(
                id: candidate.id, source: candidate.source,
                lines: lines.map { RecognizedTextLine(text: $0, confidence: 1) }
            )
        })
    }

    private static func readLabels(_ labels: [String], in store: CatalogStore) async throws {
        let owed = try await store.backgroundReads.searchEmbeddingCandidates(limit: 100).candidates
        _ = try await store.applySearchEmbeddings(owed.map { candidate in
            SearchEmbeddingResult(
                id: candidate.id, source: candidate.source,
                embedding: Array(repeating: 0.1, count: SearchEmbedding.dimensions),
                confidentLabels: labels
            )
        })
    }
}
