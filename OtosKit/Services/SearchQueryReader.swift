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
///   typed while it runs is read for its words at once too: its tower reading joins that one
///   load (warm-up included), and never starts a second.
/// - **The words and the tower race, once it is prepared.** A prepared tower can still answer
///   slowly (1.1 s for a second prediction two idle minutes after its warm-up, on a Mac with
///   91 MB free and 5.8 GB swapped), and nothing says beforehand whether it will. So both
///   readings start; whichever lands first is published. The words answer is published only
///   when no tower answer for the query has landed by the time it is ready — a fact the
///   reader holds, never a timer — so a quick tower changes the grid once, and a slow one
///   shows the words' matches (`refining`) until it lands. A words answer that matches
///   nothing changes nothing on screen (`CatalogProjection` keeps what it showed).
/// - **A first reading.** A query whose full reading waits on Translation or Apple Maps is
///   first read as typed (`firstReading`, about 40 ms: the multilingual text tower), and that
///   reading is reported (`refining`) before the full one is asked for, so the picture's first
///   result never waits on them; the full reading replaces it when it ends. A query whose full
///   reading is as quick has no first reading and is reported once.
/// - **The intent to search warms a prepared tower.** The search field taking focus comes
///   well before a query: on a prepared tower it starts one prediction whose answer nobody
///   reads (`warm`, a named task of this owner), so the model's pages macOS evicted under
///   memory pressure (about 330 MB of clean, mapped weights, outside the footprint) are read
///   back while the person types. At most one runs: an intent that comes while it or a load
///   runs starts none, since that one's end answers it. A query read meanwhile races as above:
///   its words answer never waits on the warm prediction, and its tower reading queues behind
///   it on the tower's own queue, for the page-in it would have paid itself. It is not a load
///   the admission or the background room grants: a prediction is what the person is about to
///   wait on, like the query's own.
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
    /// One prediction on the prepared tower, its answer unread (`SearchQueryEncoder.warm`).
    typealias Warm = @Sendable () async throws -> Void

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
    private let warmTower: Warm?
    /// Where a load the user waits on is admitted; nil runs it unadmitted (a test's reader).
    private let admission: LoadAdmission?
    /// Preparations asked for and the one the last finished load answered (ADR 0032 rule 2).
    private var prepareRequested: UInt64 = 0
    private var prepareCovered: UInt64 = 0
    /// The load in flight; nil when none runs.
    private var loading: Task<Void, Never>?
    /// The intent's warm prediction in flight; nil when none runs.
    private var warming: Task<Void, Never>?
    /// Warm predictions started: what a test counts.
    private(set) var warmsStarted = 0
    /// Callers waiting for the intents asked so far to be readied (`intentReadied`).
    private var readiedWaiters: [CheckedContinuation<Void, Never>] = []
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
        warm: Warm? = nil,
        admission: LoadAdmission? = nil,
        encode: @escaping Encode
    ) {
        prepareReadings = prepare
        self.isPrepared = isPrepared
        warmTower = warm
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

    /// The user showed intent to search: load what every reading needs before a query comes,
    /// or, when it is loaded, warm the tower once.
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

    /// Returns once every intent to search asked before it is readied: the warm prediction or
    /// the load it started has ended, however it ended, or the tower was found ready with no
    /// warm prediction to make. What the tour's search step waits on when it submits its query
    /// after the warm-up: a fact this owner reports, not a delay.
    func intentReadied() async {
        guard !isIntentReadied else { return }
        await withCheckedContinuation { readiedWaiters.append($0) }
    }

    private var isIntentReadied: Bool {
        prepareReadings == nil || loading == nil && warming == nil && prepareRequested == prepareCovered
    }

    private func resumeReadiedWaiters() {
        let waiters = readiedWaiters
        readiedWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Ends the loop, the load's wait for its turn and the retry now — a test's teardown; in
    /// the app they end with the actor.
    func shutdown() {
        loop?.cancel()
        loading?.cancel()
        warming?.cancel()
        retry?.cancel()
        resumeReadiedWaiters()
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
    /// rings this again. Once it is prepared, the words and the tower race.
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
        // A warm prediction in flight started on a prepared tower: the query races it rather
        // than asking the tower, whose queue answers only once that prediction has ended.
        if warming == nil, let isPrepared, prepareReadings != nil, await !isPrepared() {
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
        // The words and the tower race: a prepared tower can still be slow now (its pages
        // read in again after an idle under memory pressure), and nothing says beforehand
        // whether it is. Both start; the words answer is published only if no tower answer
        // has landed for the query when it is ready (`readWords`), so a fast tower changes
        // the grid once.
        let readsFirst = answer?.request != request || answer?.stage == .words
        async let wordsRead: Void = readWords(request)
        await readWithTower(request, readsFirst: readsFirst)
        await wordsRead
    }

    /// The tower's readings of `request`: its first reading when the full one waits on
    /// Translation or Maps, then the full one; each published as it lands.
    private func readWithTower(_ request: SearchQueryRequest, readsFirst: Bool) async {
        if readsFirst, let first {
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

    /// Readies the tower the intent to search asked for: the load when it is not prepared, one
    /// warm prediction when it is. Nothing while a load or a warm prediction runs: its end
    /// covers the intent. Never waits for either.
    private func startLoadIfAsked() async {
        guard prepareReadings != nil, prepareRequested != prepareCovered, loading == nil, warming == nil else { return }
        if let isPrepared, await isPrepared() {
            guard loading == nil, warming == nil else { return }
            startWarm()
            return
        }
        guard loading == nil else { return }
        startLoad(admitted: false)
    }

    /// One warm prediction for the intents asked so far; with nothing to warm, they are covered.
    private func startWarm() {
        guard let warmTower else {
            prepareCovered = prepareRequested
            resumeReadiedWaiters()
            return
        }
        warmsStarted += 1
        warming = Task { [weak self] in
            var failure: (any Error)?
            do {
                try await warmTower()
            } catch {
                failure = error
            }
            await self?.warmEnded(failure: failure)
        }
    }

    /// The warm prediction ended. It covers every intent asked until now, since each asked for
    /// the pages its prediction read in. One that failed is logged and covers them too: nothing
    /// reads its answer, and a query's own prediction reports such a failure as its reading's
    /// and retries it on the backoff.
    private func warmEnded(failure: (any Error)?) {
        warming = nil
        prepareCovered = prepareRequested
        if let failure, !(failure is CancellationError) {
            let error = failure as NSError
            OtosLog.catalog.errorOperation("search.tower", phase: "warmFailed", fields: [
                "domain": error.domain, "code": "\(error.code)", "error": String(describing: failure),
            ])
        }
        resumeReadiedWaiters()
        ring?.yield()
    }

    /// The load in flight, or a new one: for the user (`LoadWaiter.user`), or unadmitted for a
    /// caller that holds the background admission. Its end is applied here (`loadEnded`) and
    /// rings the loop.
    @discardableResult
    private func startLoad(admitted: Bool) -> Task<Void, Never>? {
        guard let prepareReadings else { return nil }
        if let loading {
            return loading
        }
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
            await self?.loadEnded(failure: failure)
        }
        loading = task
        return task
    }

    /// A load ended: it covers what it was asked for and every intent asked while it ran, since
    /// its warm-up is the prediction they asked for; or, failed, it is logged, and a query
    /// wanted now that has no full answer is reported failed and read again on its backoff.
    private func loadEnded(failure: (any Error)?) {
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
            prepareCovered = prepareRequested
            preparationsLoaded += 1
            // A query reported failed because a load failed is read now that one succeeded.
            if let answer, answer.request == wanted, answer.encoding == nil {
                retryDue = true
            }
        }
        // A waiter is answered by the load's end however it ended: one that failed leaves the
        // intent outstanding for the loop's next turn.
        resumeReadiedWaiters()
        ring?.yield()
    }

    /// Reads `request` without the tower and reports it, unless an answer for it is held when
    /// the reading is ready: a tower answer that landed first is the one the window shows
    /// (`op=search.words phase=dropped`). One that fails is logged and leaves the later
    /// readings to answer.
    private func readWords(_ request: SearchQueryRequest) async {
        guard let words, answer?.request != request else { return }
        let start = ContinuousClock.now
        do {
            guard let encoding = try await words(request), !Task.isCancelled, wanted == request else { return }
            guard answer?.request != request else {
                OtosLog.catalog.noticeOperation("search.words", phase: "dropped", fields: [
                    "reason": "towerFirst", "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
                ])
                return
            }
            answer = (request, encoding, .words)
            wordsReadings += 1
            OtosLog.catalog.noticeOperation("search.words", phase: "shown", fields: [
                "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
            ])
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
