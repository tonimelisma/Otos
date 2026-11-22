import Foundation
import FoundationModels

/// Anniversary title writer guide (ADR 0053)
///
/// On This Day's titles: for each anniversary the scope shows, Apple's on-device language
/// model reads the descriptions already written for its photos (`PhotoDescriptionWriter`) and
/// gives the day a short title ("Berry picking at the cottage"). A title is written from text
/// only, so it costs about a second and needs no picture.
///
/// The window says which anniversaries it shows (`show`, newest wins); the writer keeps one
/// title per anniversary for the descriptions it was written from, and writes again when those
/// change — a photo described, a person renamed. An anniversary none of whose photos is
/// described yet has no title. A declined request is kept as no title for those descriptions;
/// a failed one is asked again after `retryPacing`.
///
/// One loop, woken by a doorbell (ADR 0032 rule 3) that the window's requests, the description
/// writer's announcements and the retry wake ring. Titles are kept in memory: a launch writes
/// the few the scope shows again. `titles()` publishes the whole map, newest wins, for the
/// window to assign.
actor AnniversaryTitleWriter {
    /// One anniversary the window shows: its day, how long ago it is, and its photos in play
    /// order.
    struct Anniversary: Equatable, Sendable {
        let day: CalendarDay
        let ago: String
        let items: [MediaAssetID]
    }

    private let store: CatalogStore
    private let descriptions: PhotoDescriptionWriter
    private let writeTitle: AnniversaryTitling
    private let retryPacing: Duration
    private var shown: [Anniversary] = []
    /// The title written for each day, and the descriptions it was written from.
    private var written: [CalendarDay: (key: String, title: String?)] = [:]
    private var failedUntil: [CalendarDay: (key: String, until: ContinuousClock.Instant)] = [:]
    private var doorbell: AsyncStream<Void>.Continuation?
    private var loop: Task<Void, Never>?
    private var forwarder: Task<Void, Never>?
    private var wake: Task<Void, Never>?
    private var published: AsyncStream<[CalendarDay: String]>.Continuation?
    private var lastPublished: [CalendarDay: String] = [:]

    /// At most this many of an anniversary's descriptions are read for its title, in play order.
    static let maximumDescriptions = 8
    static let retryPacing: Duration = .seconds(60)

    init(
        store: CatalogStore,
        descriptions: PhotoDescriptionWriter,
        writeTitle: @escaping AnniversaryTitling,
        retryPacing: Duration = AnniversaryTitleWriter.retryPacing
    ) {
        self.store = store
        self.descriptions = descriptions
        self.writeTitle = writeTitle
        self.retryPacing = retryPacing
    }

    /// The titles, whole, each time they change. One stream; a second call replaces it.
    func titles() -> AsyncStream<[CalendarDay: String]> {
        let (stream, continuation) = AsyncStream<[CalendarDay: String]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        published?.finish()
        published = continuation
        continuation.yield(lastPublished)
        return stream
    }

    /// The anniversaries the window shows now; an empty list when it shows none.
    func show(_ anniversaries: [Anniversary]) {
        startIfNeeded()
        guard anniversaries != shown else { return }
        shown = anniversaries
        doorbell?.yield()
    }

    func shutdown() {
        forwarder?.cancel()
        loop?.cancel()
        wake?.cancel()
        published?.finish()
        forwarder = nil
        loop = nil
        wake = nil
        doorbell = nil
    }

    private func startIfNeeded() {
        guard loop == nil else { return }
        let (bell, ring) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        doorbell = ring
        forwarder = Task { [weak self, descriptions] in
            for await _ in await descriptions.changes() {
                guard self != nil else { break }
                ring.yield()
            }
        }
        loop = Task { [weak self] in
            for await _ in bell {
                guard let self else { return }
                await refresh()
            }
        }
    }

    /// Writes the title of every shown anniversary whose descriptions changed, then publishes.
    private func refresh() async {
        let anniversaries = shown
        let now = ContinuousClock.now
        for anniversary in anniversaries {
            guard !Task.isCancelled else { return }
            let items = Array(anniversary.items.prefix(Self.maximumDescriptions * 3))
            let texts: [MediaAssetID: String]
            do {
                texts = try await store.backgroundReads.currentPhotoDescriptions(for: items)
            } catch {
                OtosLog.ui.errorOperation("onThisDay.title", phase: "readFailed", fields: [
                    "day": anniversary.day.diagnosticDescription, "error": String(describing: error),
                ])
                continue
            }
            let lines = items.compactMap { texts[$0] }.prefix(Self.maximumDescriptions)
            let key = lines.joined(separator: "\n")
            guard written[anniversary.day]?.key != key else { continue }
            guard !lines.isEmpty else {
                written[anniversary.day] = (key, nil)
                continue
            }
            if let failed = failedUntil[anniversary.day], failed.key == key, failed.until > now {
                continue
            }
            let prompt = AnniversaryTitlePrompt(ago: anniversary.ago, descriptions: Array(lines))
            do {
                let title = try await writeTitle(prompt)
                written[anniversary.day] = (key, title)
                failedUntil[anniversary.day] = nil
                OtosLog.ui.noticeOperation("onThisDay.title", phase: title == nil ? "declined" : "written", fields: [
                    "day": anniversary.day.diagnosticDescription, "descriptions": "\(lines.count)",
                ])
            } catch {
                failedUntil[anniversary.day] = (key, ContinuousClock.now.advanced(by: retryPacing))
                OtosLog.ui.errorOperation("onThisDay.title", phase: "requestFailed", fields: [
                    "day": anniversary.day.diagnosticDescription, "error": String(describing: error),
                ])
            }
        }
        let days = Set(anniversaries.map(\.day))
        var titles: [CalendarDay: String] = [:]
        for (day, entry) in written where days.contains(day) {
            if let title = entry.title {
                titles[day] = title
            }
        }
        if titles != lastPublished {
            lastPublished = titles
            published?.yield(titles)
        }
        armWake()
    }

    private func armWake() {
        wake?.cancel()
        let now = ContinuousClock.now
        guard let due = failedUntil.values.map(\.until).filter({ $0 > now }).min() else {
            wake = nil
            return
        }
        let ring = doorbell
        wake = Task {
            do {
                // time: backoff — a failed request reports nothing when it would succeed.
                try await Task.sleep(until: due, clock: .continuous)
            } catch {
                return
            }
            ring?.yield()
        }
    }
}

/// What the model is told to title one anniversary: how long ago it is and its photos'
/// descriptions, in play order.
nonisolated struct AnniversaryTitlePrompt: Equatable, Sendable {
    static let instructions = """
    You give a day of family photos a short title, like the title of a page in a photo album. \
    Use at most six words. Use the people's names when they fit. Use only what the descriptions \
    say. No dates, no quotation marks, no emoji. Write in English.
    """

    let text: String

    init(ago: String, descriptions: [String]) {
        text = (["Photos from \(ago):"] + descriptions.map { "- \($0)" }).joined(separator: "\n")
    }
}

/// Writes one anniversary's title, nil when the model declined: the live model in the app, a
/// fake in tests.
typealias AnniversaryTitling = @Sendable (AnniversaryTitlePrompt) async throws -> String?

nonisolated enum AnniversaryTitler {
    /// Titles `prompt` through the system model; nil when it declined. A model that is not
    /// available throws, so the request is asked again later.
    static func live(_ prompt: AnniversaryTitlePrompt) async throws -> String? {
        let model = SystemLanguageModel.default
        if case let .unavailable(reason) = model.availability {
            throw PhotoDescriber.ModelUnavailable(availability: PhotoDescriber.availability(reason))
        }
        let session = LanguageModelSession(model: model, instructions: AnniversaryTitlePrompt.instructions)
        do {
            let response = try await session.respond(to: prompt.text, generating: GeneratedAnniversaryTitle.self)
            let title = response.content.title.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
            return title.isEmpty ? nil : title
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal: return nil
            default: throw error
            }
        } catch let error as LanguageModelError {
            switch error {
            case .guardrailViolation, .refusal: return nil
            default: throw error
            }
        }
    }
}

/// The model's typed answer for one anniversary.
@Generable
nonisolated struct GeneratedAnniversaryTitle {
    @Guide(description: "A short, warm title of at most six words, in title case.")
    var title: String
}
