import Foundation
import OSLog

/// Where a query stands with its reader (ADR 0048): what the window shows for it.
nonisolated enum SearchQueryStatus: Sendable, Equatable {
    /// Being read: the window keeps what it shows and says it is searching, until the reader
    /// reports that the reading ended.
    case reading
    /// A reading short of the full one — the words reading while the text tower loads
    /// (`SearchQueryEncoder.wordsReading`), or the first reading, as typed
    /// (`SearchQueryEncoder.firstReading`), while Translation or Maps are asked: the window
    /// shows its matches and says it is still searching, until the full reading replaces it.
    case refining(SearchQueryEncoding)
    case read(SearchQueryEncoding)
    /// The last reading failed. It is read again on its backoff; until one succeeds the window
    /// says the search could not be made, and never shows the scope unsearched.
    case failed
}

/// Search query reader guide (ADR 0048, ADR 0032)
///
/// The one owner of reading what the user searches for, so the window's publication loop
/// never waits on Translation, Apple Maps or the text tower's load: `CatalogProjection` asks
/// `status(for:)`, which answers at once from what this owner holds and, for a query it does
/// not hold, asks for it to be read.
///
/// - **One loop, newest wins.** A doorbell (`.bufferingNewest(1)`) wakes one loop that reads
///   the query wanted last, through `encode` (`SearchQueryEncoder`), one at a time: Translation
///   is called serially, and a reading in flight is never cancelled, because a Translation
///   session killed mid-request can stall Translation for many minutes. A query typed while
///   another is read waits for it, then is read; the one between is never read.
/// - **The answer** is kept for the query it read, and only that query's status reports it,
///   so a result for text since replaced is never shown.
/// - **The words first, while the tower loads.** A query that comes while the text tower is
///   not prepared is first read without it (`words`: its facts and its picture words, which
///   only the words read in photos match), and that reading is reported (`refining`) at once;
///   then the tower's load is started, and the loop goes back to its doorbell rather than
///   waiting for it. The load's end rings the loop, which then reads the query with the tower.
///   So no query's first answer waits on the load, however long Core ML takes, and a query
///   typed while it runs is read for its words at once too.
/// - **A first reading.** A query whose full reading waits on Translation or Apple Maps is
///   first read as typed (`firstReading`, about 40 ms: the multilingual text tower), and that
///   reading is reported (`refining`) before the full one is asked for, so the picture's first
///   result never waits on them; the full reading replaces it when it ends. A query whose full
///   reading is as quick has no first reading and is reported once.
/// - **The load.** One at a time, a named task of this owner (`loading`), which applies its
///   end synchronously and rings the loop. It is asked for by the user's intent to search
///   (`prepare`, a request revision the load covers, ADR 0032 rule 2) and by a query read while
///   the tower is not prepared (`isPrepared`): both are loads the user waits on
///   (`LoadWaiter.user`), admitted at once, ahead of the background loads waiting. The window's
///   first grid readies it too, as a background load whose caller holds its turn and awaits
///   the same task (`prepareWhileAdmitted`), so whoever asks first, there is one load. A load
///   that fails is logged; a query wanted then is reported failed and retried on its backoff.
/// - **No deadline.** A reading reports when it ends, so a query is `reading` until it does,
///   however long Translation or Maps take; no timer stands in for that report (ADR 0033).
/// - **A failed reading** is an error, not a fact (ADR 0032 rule 4): it is reported `failed`,
///   logged with its error's domain and code, and read again after a backoff
///   (`time: backoff`), doubling to `backoff.last`, never by the window's own cadence.
///
/// `readings()` yields whenever a status may have changed. The loop, the load and the retry
/// hold this actor weakly and end with it.
actor SearchQueryReader {
    typealias Encode = @Sendable (SearchQueryRequest) async throws -> SearchQueryEncoding
    /// The reading as typed, or nil when the full reading needs nothing slower.
    typealias FirstReading = @Sendable (SearchQueryRequest) async throws -> SearchQueryEncoding?
    /// The reading without the text tower, or nil when there is none (a scene-label chip).
    typealias WordsReading = @Sendable (SearchQueryRequest) async throws -> SearchQueryEncoding?
    /// Loads what every reading needs, ahead of the first.
    typealias Prepare = @Sendable () async throws -> Void
    /// Whether everything `Prepare` loads is loaded.
    typealias IsPrepared = @Sendable () async -> Bool

    /// How far an answer's reading went: a full one replaces the others.
    private enum Stage {
        case words
        case first
        case full
    }

    private let encode: Encode
    private let first: FirstReading?
    private let words: WordsReading?
    private let prepareReadings: Prepare?
    private let isPrepared: IsPrepared?
    /// Where a load the user waits on is admitted; nil runs it unadmitted (a test's reader).
    private let admission: LoadAdmission?
    /// Preparations asked for and the one the last finished load answered (ADR 0032 rule 2).
    private var prepareRequested: UInt64 = 0
    private var prepareCovered: UInt64 = 0
    /// The load in flight; nil when none runs.
    private var loading: Task<Void, Never>?
    /// Preparations that loaded: what a test waits on.
    private(set) var preparationsLoaded = 0
    private let backoff: (first: Duration, last: Duration)

    /// The query asked for last; nil while nothing is searched.
    private var wanted: SearchQueryRequest?
    /// The last reading that ended: its query, its encoding (nil for a reading that failed)
    /// and how far it went.
    private var answer: (request: SearchQueryRequest, encoding: SearchQueryEncoding?, stage: Stage)?
    /// A failed reading's retry came due.
    private var retryDue = false
    private var nextRetry: Duration

    private var loop: Task<Void, Never>?
    private var ring: AsyncStream<Void>.Continuation?
    private var retry: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    /// Readings that ended, failed or not: what a test waits on.
    private(set) var readingsEnded = 0
    /// First readings reported: what a test counts.
    private(set) var firstReadings = 0
    /// Words readings reported: what a test counts.
    private(set) var wordsReadings = 0
    /// Times a status changed for the window: what a test counts.
    private(set) var announcements = 0

    init(
        backoff: (first: Duration, last: Duration) = (.seconds(2), .seconds(60)),
        words: WordsReading? = nil,
        first: FirstReading? = nil,
        prepare: Prepare? = nil,
        isPrepared: IsPrepared? = nil,
        admission: LoadAdmission? = nil,
        encode: @escaping Encode
    ) {
        prepareReadings = prepare
        self.isPrepared = isPrepared
        self.admission = admission
        self.backoff = backoff
        nextRetry = backoff.first
        self.words = words
        self.first = first
        self.encode = encode
    }

    /// What the window can show for `request` now; a query not held is asked to be read.
    func status(for request: SearchQueryRequest) -> SearchQueryStatus {
        if let answer, answer.request == request {
            guard let encoding = answer.encoding else { return .failed }
            return answer.stage == .full ? .read(encoding) : .refining(encoding)
        }
        if wanted != request {
            want(request)
        }
        return .reading
    }

    /// The user showed intent to search: load what every reading needs before a query comes.
    func prepare() {
        guard prepareReadings != nil else { return }
        prepareRequested &+= 1
        startLoop()
        ring?.yield()
    }

    /// Nothing is searched: the last answer is let go, so a query typed again later is read
    /// again (a language pack installed since then counts).
    func forget() {
        wanted = nil
        answer = nil
        retry?.cancel()
        retry = nil
        retryDue = false
        nextRetry = backoff.first
    }

    /// Yields whenever a query's status may have changed.
    func readings() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    /// Ends the loop, the load's wait for its turn and the retry now — a test's teardown; in
    /// the app they end with the actor.
    func shutdown() {
        loop?.cancel()
        loading?.cancel()
        retry?.cancel()
        loop = nil
        retry = nil
        ring = nil
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations = [:]
    }

    /// Loads what every reading needs for a caller that holds the background admission for it
    /// (`BackgroundLoad.searchPrepare`, the first grid's readying): awaited, so the load runs
    /// inside that turn and no other load runs beside it. A load already in flight is the one
    /// awaited; nothing when everything is ready. Publishes nothing.
    func prepareWhileAdmitted() async {
        guard prepareReadings != nil else { return }
        if loading == nil, let isPrepared, await isPrepared() {
            return
        }
        await startLoad(admitted: true)?.value
    }

    private func want(_ request: SearchQueryRequest) {
        wanted = request
        retry?.cancel()
        retry = nil
        retryDue = false
        nextRetry = backoff.first
        startLoop()
        ring?.yield()
    }

    private func startLoop() {
        guard loop == nil else { return }
        let (doorbell, ring) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.ring = ring
        loop = Task { [weak self] in
            for await _ in doorbell {
                guard let self else { return }
                await readWanted()
            }
        }
    }

    /// Reads the query wanted now, unless its answer is held; a failed answer is read again only
    /// when its retry is due. While the tower loads, only the words are read: the load's end
    /// rings this again.
    private func readWanted() async {
        await startLoadIfAsked()
        guard !Task.isCancelled, let request = wanted else { return }
        if let answer, answer.request == request, answer.stage == .full, answer.encoding != nil || !retryDue {
            return
        }
        if loading != nil {
            await readWords(request)
            return
        }
        if let isPrepared, prepareReadings != nil, await !isPrepared() {
            await readWords(request)
            guard !Task.isCancelled else { return }
            guard wanted == request else {
                ring?.yield()
                return
            }
            retryDue = false
            prepareRequested &+= 1
            startLoad(admitted: false)
            return
        }
        guard !Task.isCancelled, wanted == request else {
            ring?.yield()
            return
        }
        retryDue = false
        if answer?.request != request || answer?.stage == .words, let first {
            await readFirst(request, with: first)
            guard !Task.isCancelled, wanted == request else {
                ring?.yield()
                return
            }
        }
        let encoding: SearchQueryEncoding?
        do {
            encoding = try await encode(request)
        } catch {
            let failure = error as NSError
            OtosLog.catalog.errorOperation("search.query", phase: "readFailed", fields: [
                "domain": failure.domain,
                "code": "\(failure.code)",
                "error": String(describing: error),
            ])
            encoding = nil
        }
        guard !Task.isCancelled else { return }
        answer = (request, encoding, .full)
        readingsEnded += 1
        if encoding == nil, wanted == request {
            scheduleRetry()
        } else if encoding != nil {
            nextRetry = backoff.first
        }
        announce()
        if wanted != request {
            ring?.yield()
        }
    }

    /// Starts the load the intent to search asked for, unless everything is ready or a load
    /// runs. Never waits for the load.
    private func startLoadIfAsked() async {
        guard prepareReadings != nil, prepareRequested != prepareCovered, loading == nil else { return }
        if let isPrepared, await isPrepared() {
            prepareCovered = prepareRequested
            return
        }
        guard loading == nil else { return }
        startLoad(admitted: false)
    }

    /// The load in flight, or a new one: for the user (`LoadWaiter.user`), or unadmitted for a
    /// caller that holds the background admission. It covers the preparation asked for when it
    /// started; its end is applied here and rings the loop.
    @discardableResult
    private func startLoad(admitted: Bool) -> Task<Void, Never>? {
        guard let prepareReadings else { return nil }
        if let loading {
            return loading
        }
        let asked = prepareRequested
        let admission = admitted ? nil : admission
        let task = Task { [weak self] in
            var failure: (any Error)?
            do {
                if let admission {
                    try await admission.run(.searchPrepare, for: .user) { try await prepareReadings() }
                } else {
                    try await prepareReadings()
                }
            } catch {
                failure = error
            }
            await self?.loadEnded(covering: asked, failure: failure)
        }
        loading = task
        return task
    }

    /// A load ended: it covers what it was asked for, or, failed, is logged, and a query
    /// wanted now that has no full answer is reported failed and read again on its backoff.
    private func loadEnded(covering asked: UInt64, failure: (any Error)?) {
        loading = nil
        if failure is CancellationError {
            // Teardown: the load's wait for its turn ended; nothing was loaded or failed.
        } else if let failure {
            let error = failure as NSError
            OtosLog.catalog.errorOperation("search.query", phase: "prepareFailed", fields: [
                "domain": error.domain, "code": "\(error.code)", "error": String(describing: failure),
            ])
            if let request = wanted, answer?.request != request || answer?.stage != .full {
                answer = (request, nil, .full)
                readingsEnded += 1
                scheduleRetry()
                announce()
            }
        } else {
            prepareCovered = asked
            preparationsLoaded += 1
            // A query reported failed because a load failed is read now that one succeeded.
            if let answer, answer.request == wanted, answer.encoding == nil {
                retryDue = true
            }
        }
        ring?.yield()
    }

    /// Reads `request` without the tower and reports it, unless an answer for it is held. One
    /// that fails is logged and leaves the later readings to answer.
    private func readWords(_ request: SearchQueryRequest) async {
        guard let words, answer?.request != request else { return }
        do {
            guard let encoding = try await words(request), !Task.isCancelled, answer?.request != request else { return }
            answer = (request, encoding, .words)
            wordsReadings += 1
            announce()
        } catch {
            let failure = error as NSError
            OtosLog.catalog.errorOperation("search.query", phase: "wordsReadFailed", fields: [
                "domain": failure.domain, "code": "\(failure.code)", "error": String(describing: error),
            ])
        }
    }

    /// Reads `request` as typed and reports it when there is a first reading. One that fails is
    /// logged and leaves the full reading to answer: it is no answer the window shows.
    private func readFirst(_ request: SearchQueryRequest, with first: FirstReading) async {
        do {
            guard let encoding = try await first(request), !Task.isCancelled else { return }
            answer = (request, encoding, .first)
            firstReadings += 1
            announce()
        } catch {
            let failure = error as NSError
            OtosLog.catalog.errorOperation("search.query", phase: "firstReadFailed", fields: [
                "domain": failure.domain, "code": "\(failure.code)", "error": String(describing: error),
            ])
        }
    }

    /// One retry at a time; each waits twice as long as the last, up to `backoff.last`.
    private func scheduleRetry() {
        guard retry == nil, ring != nil else { return }
        let delay = nextRetry
        nextRetry = min(nextRetry * 2, backoff.last)
        OtosLog.catalog.noticeOperation("search.query", phase: "retryScheduled", fields: [
            "seconds": "\(delay.components.seconds)",
        ])
        retry = Task { [weak self] in
            // time: backoff — a reading that failed; nothing reports when Translation would succeed
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await retryFired()
        }
    }

    private func retryFired() {
        retry = nil
        retryDue = true
        ring?.yield()
    }

    private func announce() {
        announcements += 1
        for continuation in continuations.values {
            continuation.yield()
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
