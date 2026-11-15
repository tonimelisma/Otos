import CoreGraphics
import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// Stills' descriptions (ADR 0053): when a still is owed one, what the model is told, how a
/// change to any fact it was written from makes it owed again, how a declined or stale answer
/// is stored, the writer end to end, and On This Day's titles written from them.
@Suite(.testDirectory)
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
        #expect(try await store.photoDescriptionCandidates(limit: 10).isEmpty)

        try await Self.readText(["SAUNA"], in: store)
        #expect(try await store.photoDescriptionCandidates(limit: 10).isEmpty)
        try await Self.readLabels(["lake"], in: store)

        let first = try await store.photoDescriptionCandidates(limit: 10)
        #expect(first.map(\.id) == [still])
        #expect(first.first?.facts.faces.map(\.name) == [nil])
        #expect(first.first?.facts.textLines == ["SAUNA"])
        #expect(first.first?.facts.labels == ["lake"])
        let written = try #require(first.first)
        #expect(try await store.applyPhotoDescriptions([Self.result(written, "A lake.")]).count == 1)
        #expect(try await store.photoDescriptionCandidates(limit: 10).isEmpty)
        #expect(try await store.photoInfoOverlay(for: still)?.photoDescription == .written("A lake."))

        let sam = try #require(try await store.perform(.moveToNewPerson([FaceID(asset: still, index: 0)], name: "Sam")).person)
        #expect(try await store.photoInfoOverlay(for: still)?.photoDescription == nil)
        let named = try await store.photoDescriptionCandidates(limit: 10)
        #expect(named.first?.facts.faces.map(\.name) == ["Sam"])
        #expect(try await store.applyPhotoDescriptions([Self.result(written, "Stale.")]).isEmpty)

        _ = try await store.perform(.edit(sam, name: "Sam", birthday: PersonBirthday("2020-05-01")))
        let dated = try await store.photoDescriptionCandidates(limit: 10)
        #expect(dated.first?.facts.faces.first?.birthday == PersonBirthday("2020-05-01"))
        #expect(try await store.applyPhotoDescriptions(named.map { Self.result($0, "Sam.") }).isEmpty)
        #expect(try await store.applyPhotoDescriptions(dated.map { Self.result($0, nil) }).count == 1)
        #expect(try await store.photoInfoOverlay(for: still)?.photoDescription == .declined)
        #expect(try await store.currentPhotoDescriptions(for: [still]).isEmpty)

        _ = try await store.perform(.setHidden(sam, true))
        #expect(try await store.photoDescriptionCandidates(limit: 10).first?.facts.faces.map(\.name) == [nil])
        await store.shutdown()
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
        try await waitUntil { try await store.photoInfoOverlay(for: still)?.photoDescription == .written("Sam by a lake.") }
        _ = try await store.perform(.edit(sam, name: "Max", birthday: nil))
        try await waitUntil { try await store.photoInfoOverlay(for: still)?.photoDescription == .written("Max by a lake.") }
        await writer.shutdown()

        #expect(prompts.value.first?.facts.contains("- Sam: face on the left.") == true)
        #expect(prompts.value.first?.facts.contains("Recognized in the scene: lake.") == true)
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

        #expect(try await store.photoDescriptionCandidates(limit: 10).map(\.id) == [library.id("a.jpg")])
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
        let owed = try await store.photoDescriptionCandidates(limit: 10)
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
        - Someone not named: face at the bottom right.
        Text in the photo: "SAUNA / OPEN".
        Recognized in the scene: blue sky.
        """)
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
        let owed = try await store.searchTextCandidates(limit: 100)
        _ = try await store.applySearchTexts(owed.map { candidate in
            SearchTextResult(
                id: candidate.id, source: candidate.source,
                lines: lines.map { RecognizedTextLine(text: $0, confidence: 1) }
            )
        })
    }

    private static func readLabels(_ labels: [String], in store: CatalogStore) async throws {
        let owed = try await store.searchEmbeddingCandidates(limit: 100)
        _ = try await store.applySearchEmbeddings(owed.map { candidate in
            SearchEmbeddingResult(
                id: candidate.id, source: candidate.source,
                embedding: Array(repeating: 0.1, count: SearchEmbedding.dimensions),
                confidentLabels: labels
            )
        })
    }
}
