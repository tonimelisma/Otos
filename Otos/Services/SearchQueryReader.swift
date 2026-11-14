import Foundation
import OSLog

/// What the window can show for a query (ADR 0048).
nonisolated enum SearchQueryStatus: Sendable, Equatable {
    /// Being read, within `SearchQueryReader.deadline`: the window keeps what it shows until
    /// the reading lands.
    case reading
    case read(SearchQueryEncoding)
    /// Not read: the reading failed and waits for its retry, or it has outrun the deadline
    /// (Translation or Maps not answering). The window shows the scope unsearched rather than
    /// another query's results.
    case unanswered
}

/// Search query reader guide (ADR 0048, ADR 0032)
///
/// The one owner of reading what the user searches for, so the window's publication loop
/// never waits on Translation or Apple Maps: `CatalogProjection` asks `status(for:)`, which
/// answers at once from what this owner holds and, for a query it does not hold, asks for it
/// to be read.
///
/// - **One loop, newest wins.** A doorbell (`.bufferingNewest(1)`) wakes one loop that reads
///   the query wanted last, through `encode` (`SearchQueryEncoder`), one at a time: Translation
///   is called serially, and a reading in flight is never cancelled, because a Translation
///   session killed mid-request can stall Translation for many minutes. A query typed while
///   another is read waits for it, then is read; the one between is never read.
/// - **The answer** is kept for the query it read, and only that query's status reports it,
///   so a result for text since replaced is never shown.
/// - **A deadline** (`deadline`, ADR 0033 `time: deadline`): nothing reports that Translation
///   or Maps has stopped answering, so a reading still in flight after it reports the query
///   `unanswered`; the window then shows the scope unsearched, and the reading's answer is
///   shown when it lands.
/// - **A failed reading** is an error, not a fact (ADR 0032 rule 4): it is reported
///   `unanswered`, logged, and read again after a backoff (`time: backoff`), doubling to
///   `backoff.last`, never by the window's own cadence.
///
/// `readings()` yields whenever a status may have changed. The loop and the timers hold this
/// actor weakly and end with it.
actor SearchQueryReader {
    typealias Encode = @Sendable (SearchQueryRequest) async throws -> SearchQueryEncoding

    private let encode: Encode
    let deadline: Duration
    private let backoff: (first: Duration, last: Duration)

    /// The query asked for last; nil while nothing is searched.
    private var wanted: SearchQueryRequest?
    /// The query being read, and whether it has outrun the deadline.
    private var inFlight: SearchQueryRequest?
    private var overdue = false
    /// The last reading that ended: its query and encoding, nil for a reading that failed.
    private var answer: (request: SearchQueryRequest, encoding: SearchQueryEncoding?)?
    /// A failed reading's retry came due.
    private var retryDue = false
    private var nextRetry: Duration

    private var loop: Task<Void, Never>?
    private var ring: AsyncStream<Void>.Continuation?
    private var retry: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    /// Readings that ended, failed or not: what a test waits on.
    private(set) var readingsEnded = 0

    /// `deadline`: about three times the 0.35 s a translated query takes (ADR 0048).
    init(
        deadline: Duration = .seconds(1),
        backoff: (first: Duration, last: Duration) = (.seconds(2), .seconds(60)),
        encode: @escaping Encode
    ) {
        self.deadline = deadline
        self.backoff = backoff
        nextRetry = backoff.first
        self.encode = encode
    }

    /// What the window can show for `request` now; a query not held is asked to be read.
    func status(for request: SearchQueryRequest) -> SearchQueryStatus {
        if let answer, answer.request == request {
            return answer.encoding.map(SearchQueryStatus.read) ?? .unanswered
        }
        if wanted != request {
            want(request)
        }
        return inFlight == request && overdue ? .unanswered : .reading
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

    /// Ends the loop and the timers now — a test's teardown; in the app they end with the actor.
    func shutdown() {
        loop?.cancel()
        retry?.cancel()
        deadlineTask?.cancel()
        loop = nil
        retry = nil
        deadlineTask = nil
        ring = nil
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations = [:]
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
    /// when its retry is due.
    private func readWanted() async {
        guard let request = wanted else { return }
        if let answer, answer.request == request, answer.encoding != nil || !retryDue {
            return
        }
        retryDue = false
        inFlight = request
        overdue = false
        startDeadline(for: request)
        let encoding: SearchQueryEncoding?
        do {
            encoding = try await encode(request)
        } catch {
            OtosLog.catalog.errorOperation("search.query", phase: "readFailed", fields: [
                "error": String(describing: error),
            ])
            encoding = nil
        }
        inFlight = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        guard !Task.isCancelled else { return }
        answer = (request, encoding)
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

    private func startDeadline(for request: SearchQueryRequest) {
        deadlineTask?.cancel()
        let deadline = deadline
        deadlineTask = Task { [weak self] in
            // time: deadline — Translation and Maps may never answer; past this the window
            // shows the scope unsearched instead of another query's results.
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled, let self else { return }
            await deadlinePassed(for: request)
        }
    }

    private func deadlinePassed(for request: SearchQueryRequest) {
        guard inFlight == request, !overdue else { return }
        overdue = true
        OtosLog.catalog.noticeOperation("search.query", phase: "overdue", fields: [
            "deadline": "\(deadline)",
        ])
        announce()
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
        for continuation in continuations.values {
            continuation.yield()
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
