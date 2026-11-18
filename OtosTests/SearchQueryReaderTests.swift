import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// ADR 0048: what the user searches for is read by its own owner, so the window never waits on
/// Translation or Maps. These drive the reader with a fake reading that the test releases, so
/// each interleaving is the one named, never a race against time.
struct SearchQueryReaderTests {
    /// A reading the test holds until it releases it, and can fail.
    private actor HeldReading {
        private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
        private var released: Set<String> = []
        private(set) var started: [String] = []
        var failing: Set<String> = []

        func read(_ request: SearchQueryRequest) async throws -> SearchQueryEncoding {
            started.append(request.text)
            if !released.contains(request.text) {
                await withCheckedContinuation { waiters[request.text, default: []].append($0) }
            }
            if failing.contains(request.text) {
                throw ReadingFailed()
            }
            return SearchQueryReaderTests.encoding(request.text)
        }

        func release(_ text: String) {
            released.insert(text)
            for waiter in waiters.removeValue(forKey: text) ?? [] {
                waiter.resume()
            }
        }

        func fail(_ text: String) {
            failing.insert(text)
        }

        func succeed(_ text: String) {
            failing.remove(text)
        }
    }

    private struct ReadingFailed: Error {}

    static func encoding(_ text: String) -> SearchQueryEncoding {
        SearchQueryEncoding(
            text: text, language: "en", reading: .english, modelText: text, facts: SearchFacts(), pictureText: text,
            picture: .none
        )
    }

    /// A query typed while another is read waits for it and is read next; the one typed between
    /// is never read, and an answer is reported only for the query it read.
    @Test func theNewestQueryWinsAndAReadingInFlightIsNeverCancelled() async throws {
        let held = HeldReading()
        let reader = SearchQueryReader { try await held.read($0) }
        let dog = SearchQueryRequest(text: "dog"), dogs = SearchQueryRequest(text: "dogs"), dogsOnBeach = SearchQueryRequest(text: "dogs on beach")
        #expect(await reader.status(for: dog) == .reading)
        try await waitUntil { await held.started == ["dog"] }
        #expect(await reader.status(for: dogs) == .reading)
        #expect(await reader.status(for: dogsOnBeach) == .reading)
        await held.release("dog")
        await held.release("dogs on beach")
        try await waitUntil { await reader.status(for: dogsOnBeach) == .read(Self.encoding("dogs on beach")) }
        #expect(await held.started == ["dog", "dogs on beach"])
        // "dog" was read, but the window no longer asks for it.
        #expect(await reader.status(for: dogsOnBeach) != .read(Self.encoding("dog")))
        await reader.shutdown()
    }

    /// A reading that fails is not a fact: the query is reported failed, and it is read again
    /// after the backoff, not by the window's asking.
    @Test func aFailedReadingIsReportedAndRetriedOnItsBackoff() async throws {
        let held = HeldReading()
        await held.fail("koira")
        await held.release("koira")
        let reader = SearchQueryReader(backoff: (.zero, .zero)) { try await held.read($0) }
        let koira = SearchQueryRequest(text: "koira", languages: ["fi"])
        _ = await reader.status(for: koira)
        try await waitUntil { await reader.status(for: koira) == .failed }
        await held.succeed("koira")
        try await waitUntil { await reader.status(for: koira) == .read(Self.encoding("koira")) }
        #expect(await held.started.count >= 2)
        await reader.shutdown()
    }

    /// A reading that has not ended (a wedged Translation) is being read for as long as it
    /// lasts: no timer reports it as anything else, and its answer is reported when it ends.
    @Test func aQueryIsBeingReadUntilItsReadingEnds() async throws {
        let held = HeldReading()
        let reader = SearchQueryReader { try await held.read($0) }
        let lake = SearchQueryRequest(text: "järvi")
        let readings = await reader.readings()
        #expect(await reader.status(for: lake) == .reading)
        try await waitUntil { await held.started == ["järvi"] }
        // Held at its suspension: the reading is in flight, and nothing has ended.
        #expect(await reader.status(for: lake) == .reading)
        #expect(await reader.readingsEnded == 0)
        await held.release("järvi")
        for await _ in readings where await reader.status(for: lake) == .read(Self.encoding("järvi")) {
            break
        }
        #expect(await reader.status(for: lake) == .read(Self.encoding("järvi")))
        #expect(await reader.readingsEnded == 1)
        await reader.shutdown()
    }

    /// A query whose full reading waits on Translation is first reported as typed and then
    /// as read, in that order; one with no first reading (English) is reported once, read.
    @Test func aQueryWithAFirstReadingIsReportedTwiceInOrderAndOneWithoutOnce() async throws {
        let held = HeldReading()
        let first: SearchQueryReader.FirstReading = { request in
            request.text == "järvi" ? SearchQueryReaderTests.encoding("järvi as typed") : nil
        }
        let reader = SearchQueryReader(first: first) { try await held.read($0) }
        let lake = SearchQueryRequest(text: "järvi")
        let readings = await reader.readings()
        #expect(await reader.status(for: lake) == .reading)
        for await _ in readings where await reader.status(for: lake) == .refining(Self.encoding("järvi as typed")) {
            break
        }
        // The full reading is in flight, held: the first reading is what is reported.
        try await waitUntil { await held.started == ["järvi"] }
        #expect(await reader.status(for: lake) == .refining(Self.encoding("järvi as typed")))
        await held.release("järvi")
        for await _ in readings where await reader.status(for: lake) == .read(Self.encoding("järvi")) {
            break
        }
        #expect(await reader.firstReadings == 1)

        let dog = SearchQueryRequest(text: "dog")
        await held.release("dog")
        var reported: [SearchQueryStatus] = await [reader.status(for: dog)]
        for await _ in readings {
            let status = await reader.status(for: dog)
            reported.append(status)
            if status == .read(Self.encoding("dog")) {
                break
            }
        }
        #expect(!reported.contains {
            if case .refining = $0 {
                true
            } else {
                false
            }
        })
        #expect(await reader.firstReadings == 1)
        await reader.shutdown()
    }

    /// Once nothing is searched, a query typed again is read again: a language pack installed
    /// meanwhile counts.
    @Test func aForgottenQueryIsReadAgain() async throws {
        let held = HeldReading()
        await held.release("koira")
        let reader = SearchQueryReader { try await held.read($0) }
        let koira = SearchQueryRequest(text: "koira")
        _ = await reader.status(for: koira)
        try await waitUntil { await reader.status(for: koira) == .read(Self.encoding("koira")) }
        await reader.forget()
        #expect(await reader.status(for: koira) == .reading)
        try await waitUntil { await held.started == ["koira", "koira"] }
        await reader.shutdown()
    }

    /// What a reading needs, loaded once whoever asks first: the intent to search or a query.
    private actor Encoder {
        let gate = ArrivalGate()
        private(set) var loads = 0
        private(set) var loadedBeforeEncoding: [Bool] = []
        private var loaded = false

        func load() async {
            loads += 1
            await gate.arrive()
            loaded = true
        }

        func encode(_ request: SearchQueryRequest) async -> SearchQueryEncoding {
            loadedBeforeEncoding.append(loaded)
            if !loaded {
                loads += 1
                loaded = true
            }
            return SearchQueryReaderTests.encoding(request.text)
        }
    }

    /// ADR 0048, "The first query": the intent to search loads the encoder before a query is
    /// typed. A query typed while that load is in flight — held at its suspension — waits for it
    /// and is read with the encoder it loaded: one load, never a second, and the load
    /// publishes nothing itself.
    @Test func aQueryTypedWhileTheIntentsLoadIsInFlightIsReadWithIt() async {
        let encoder = Encoder()
        let reader = SearchQueryReader(prepare: { await encoder.load() }) { await encoder.encode($0) }
        let readings = await reader.readings()
        await reader.prepare()
        await encoder.gate.waitForArrivals(1)

        let dog = SearchQueryRequest(text: "dog")
        #expect(await reader.status(for: dog) == .reading)
        #expect(await encoder.loadedBeforeEncoding.isEmpty, "the query waits for the load in flight")
        await encoder.gate.open()
        for await _ in readings where await reader.status(for: dog) == .read(Self.encoding("dog")) {
            break
        }
        #expect(await encoder.loads == 1)
        #expect(await encoder.loadedBeforeEncoding == [true])
        #expect(await reader.preparationsLoaded == 1)
        #expect(await reader.readingsEnded == 1)
        await reader.shutdown()
    }

    static func words(_ text: String) -> SearchQueryEncoding {
        SearchQueryEncoding(
            text: text, language: "en", reading: .english, modelText: text, facts: SearchFacts(), pictureText: text,
            picture: .unread
        )
    }

    /// ADR 0048: a query issued while the text tower's load is in flight — the first grid's
    /// readying, held at its suspension — publishes its words reading without awaiting the
    /// load, and so does a query typed after it while the load still runs; neither is read
    /// with the tower until the load ends, and then the newest is, once. Publications counted,
    /// no time.
    @Test func aQueryIssuedWhileTheLoadIsInFlightPublishesItsWordsWithoutAwaitingIt() async {
        let load = ArrivalGate()
        let prepared = Mutex(false)
        let encoded = Mutex<[String]>([])
        let reader = SearchQueryReader(
            words: { Self.words($0.text) },
            prepare: {
                await load.arrive()
                prepared.withLock { $0 = true }
            },
            isPrepared: { prepared.withLock { $0 } }
        ) { request in
            encoded.withLock { $0.append(request.text) }
            return Self.encoding(request.text)
        }
        let readings = await reader.readings()
        let readying = Task { await reader.prepareWhileAdmitted() }
        await load.waitForArrivals(1)

        let dog = SearchQueryRequest(text: "dog")
        #expect(await reader.status(for: dog) == .reading)
        for await _ in readings where await reader.status(for: dog) == .refining(Self.words("dog")) {
            break
        }
        #expect(await reader.announcements == 1)
        let dogs = SearchQueryRequest(text: "dogs")
        #expect(await reader.status(for: dogs) == .reading)
        for await _ in readings where await reader.status(for: dogs) == .refining(Self.words("dogs")) {
            break
        }
        // Both answered while the load is held: nothing was read with the tower.
        #expect(await reader.announcements == 2)
        #expect(await reader.wordsReadings == 2)
        #expect(encoded.withLock { $0 }.isEmpty)
        #expect(!prepared.withLock { $0 })

        await load.open()
        await readying.value
        for await _ in readings where await reader.status(for: dogs) == .read(Self.encoding("dogs")) {
            break
        }
        #expect(encoded.withLock { $0 } == ["dogs"])
        #expect(await reader.announcements == 3)
        #expect(await load.arrivalCount == 1, "one load, whoever asked")
        #expect(await reader.preparationsLoaded == 1)
        await reader.shutdown()
    }

    /// "Prepared" means the tower has answered once: preparing loads it and makes exactly one
    /// warm-up prediction, preparing again makes none, and a query's embedding is the next.
    @Test func preparingTheTowerMakesExactlyOneWarmUpPrediction() async throws {
        let encoder = SearchQueryEncoder(bundle: Bundle(for: CatalogWindowViewModel.self))
        #expect(await encoder.towerPredictions == 0)
        try await encoder.prepare()
        #expect(await encoder.isPrepared)
        #expect(await encoder.towerPredictions == 1)
        try await encoder.prepare()
        #expect(await encoder.towerPredictions == 1)
        _ = try await encoder.englishEncoding(of: "a dog on a beach")
        #expect(await encoder.towerPredictions == 2)
    }

    /// The intent's warm prediction predicts once on a prepared tower and never loads one that
    /// is not: a tower let go under memory pressure is loaded by the next query instead.
    @Test func aWarmPredictionPredictsOnlyOnAPreparedTower() async throws {
        let encoder = SearchQueryEncoder(bundle: Bundle(for: CatalogWindowViewModel.self))
        #expect(try await !encoder.warm())
        #expect(await !encoder.isLoaded)
        #expect(await encoder.towerPredictions == 0)
        try await encoder.prepare()
        #expect(try await encoder.warm())
        #expect(await encoder.towerPredictions == 2)
        await encoder.releaseIfIdle()
        #expect(try await !encoder.warm())
        #expect(await !encoder.isLoaded)
        #expect(await encoder.towerPredictions == 2)
    }

    /// A prepared tower that answers before the words reading is ready is the one answer
    /// published: the words reading that lands after it is dropped, so the grid changes once.
    @Test func aTowerThatAnswersBeforeTheWordsIsPublishedOnce() async {
        let words = HeldReading()
        let reader = SearchQueryReader(
            words: { request in
                _ = try await words.read(request)
                return Self.words(request.text)
            },
            prepare: {},
            isPrepared: { true }
        ) { Self.encoding($0.text) }
        let readings = await reader.readings()
        let lake = SearchQueryRequest(text: "lake")
        _ = await reader.status(for: lake)
        for await _ in readings where await reader.status(for: lake) == .read(Self.encoding("lake")) {
            break
        }
        await words.release("lake")
        // One loop reads one query at a time: the next query's reading starts only once the
        // first race has ended, its words dropped.
        let pond = SearchQueryRequest(text: "pond")
        _ = await reader.status(for: pond)
        for await _ in readings where await reader.status(for: pond) == .read(Self.encoding("pond")) {
            break
        }
        #expect(await reader.wordsReadings == 0, "the words landed after the tower's answer")
        #expect(await reader.announcements == 2, "one publication a query")
        await words.release("pond")
        await reader.shutdown()
    }

    /// A prepared tower whose embedding is held (pages read in again after an idle) does not
    /// hold the first results: the words answer is published with its matches, still
    /// searching, then the tower's full answer once.
    @Test func aHeldTowerLetsTheWordsAnswerPublishFirst() async {
        let tower = HeldReading()
        let reader = SearchQueryReader(
            words: { Self.words($0.text) },
            prepare: {},
            isPrepared: { true }
        ) { try await tower.read($0) }
        let readings = await reader.readings()
        let dog = SearchQueryRequest(text: "dog")
        #expect(await reader.status(for: dog) == .reading)
        for await _ in readings where await reader.status(for: dog) == .refining(Self.words("dog")) {
            break
        }
        #expect(await reader.announcements == 1)
        await tower.release("dog")
        for await _ in readings where await reader.status(for: dog) == .read(Self.encoding("dog")) {
            break
        }
        #expect(await reader.wordsReadings == 1)
        #expect(await reader.announcements == 2)
        await reader.shutdown()
    }

    /// A load that fails is not a fact: the query whose words are shown is reported failed and
    /// read again on its backoff, which loads again.
    @Test func aLoadThatFailsReportsTheQueryFailedAndRetries() async throws {
        let attempts = Mutex(0)
        let prepared = Mutex(false)
        let reader = SearchQueryReader(
            backoff: (.zero, .zero),
            words: { Self.words($0.text) },
            prepare: {
                let attempt = attempts.withLock { $0 += 1
                    return $0
                }
                guard attempt > 1 else { throw ReadingFailed() }
                prepared.withLock { $0 = true }
            },
            isPrepared: { prepared.withLock { $0 } }
        ) { Self.encoding($0.text) }
        let koira = SearchQueryRequest(text: "koira")
        _ = await reader.status(for: koira)
        try await waitUntil { await reader.status(for: koira) == .read(Self.encoding("koira")) }
        #expect(attempts.withLock { $0 } == 2)
        #expect(await reader.preparationsLoaded == 1)
        await reader.shutdown()
    }

    /// ADR 0055: the first query, typed while a People pass runs and a duplicates build and
    /// the first grid's readying wait their turn, is served without waiting for them. Its
    /// encoder load is admitted for the user at once, beside the running pass, and nothing
    /// waiting starts while it runs; a second query loads nothing. Admissions are counted, not
    /// timed.
    @Test func theFirstQueryIsServedWithoutWaitingForTheBackgroundLoads() async throws {
        let admission = LoadAdmission(isOpen: true)
        let people = ArrivalGate()
        let pass = Task { try await admission.run(.people) { await people.arrive() } }
        await people.waitForArrivals(1)
        let duplicates = Task { try await admission.run(.duplicates) {} }
        let readying = Task { try await admission.run(.searchPrepare) {} }
        try await waitUntil { admission.snapshot.waiting.count == 2 }

        let seenByLoads = Mutex<[LoadAdmissionMachine]>([])
        let prepared = Mutex(false)
        let reader = SearchQueryReader(
            prepare: {
                seenByLoads.withLock { $0.append(admission.snapshot) }
                prepared.withLock { $0 = true }
            },
            isPrepared: { prepared.withLock { $0 } },
            admission: admission
        ) { request in
            #expect(prepared.withLock { $0 }, "the query is read with the encoder its own need loaded")
            return Self.encoding(request.text)
        }
        let dog = SearchQueryRequest(text: "dog")
        _ = await reader.status(for: dog)
        try await waitUntil { await reader.status(for: dog) == .read(Self.encoding("dog")) }

        let seen = seenByLoads.withLock { $0 }
        #expect(seen.count == 1)
        #expect(seen.first?.running?.load == .people)
        #expect(seen.first?.runningForUser.map(\.load) == [.searchPrepare])
        #expect(seen.first?.waiting.map(\.load) == [.duplicates, .searchPrepare])
        #expect(admission.snapshot.running?.load == .people)
        #expect(admission.snapshot.runningForUser.isEmpty)
        #expect(admission.snapshot.waiting.map(\.load) == [.duplicates, .searchPrepare])
        #expect(await reader.preparationsLoaded == 1)

        let cat = SearchQueryRequest(text: "cat")
        _ = await reader.status(for: cat)
        try await waitUntil { await reader.status(for: cat) == .read(Self.encoding("cat")) }
        #expect(seenByLoads.withLock { $0.count } == 1, "a prepared encoder is not loaded again")

        await people.open()
        try await pass.value
        try await duplicates.value
        try await readying.value
        await reader.shutdown()
    }

    /// A query with no intent to search before it is read as it always was: it loads what it
    /// needs itself.
    @Test func aQueryWithoutAnIntentFirstIsStillRead() async throws {
        let encoder = Encoder()
        await encoder.gate.open()
        let reader = SearchQueryReader(prepare: { await encoder.load() }) { await encoder.encode($0) }
        let lake = SearchQueryRequest(text: "lake")
        _ = await reader.status(for: lake)
        try await waitUntil { await reader.status(for: lake) == .read(Self.encoding("lake")) }
        #expect(await encoder.loadedBeforeEncoding == [false])
        #expect(await encoder.loads == 1)
        #expect(await reader.preparationsLoaded == 0)
        await reader.shutdown()
    }

    /// A prepared text tower on one serial queue, as `SearchTextTower` is: the warm prediction
    /// is held at its gate, and whatever else asks the tower while it runs (whether it is
    /// prepared, a query's prediction) waits for it to end. Predictions are counted.
    private actor ScriptedTower {
        let warmGate = ArrivalGate()
        private(set) var predictions = 0
        private var warming = false
        private var queued: [CheckedContinuation<Void, Never>] = []

        func warm() async {
            predictions += 1
            warming = true
            await warmGate.arrive()
            warming = false
            let waiters = queued
            queued = []
            waiters.forEach { $0.resume() }
        }

        func isPrepared() async -> Bool {
            await behindTheWarmPrediction()
            return true
        }

        func encode(_ request: SearchQueryRequest) async -> SearchQueryEncoding {
            await behindTheWarmPrediction()
            predictions += 1
            return SearchQueryReaderTests.encoding(request.text)
        }

        private func behindTheWarmPrediction() async {
            guard warming else { return }
            await withCheckedContinuation { queued.append($0) }
        }
    }

    private static func reader(on tower: ScriptedTower, admission: LoadAdmission? = nil) -> SearchQueryReader {
        SearchQueryReader(
            words: { Self.words($0.text) },
            prepare: {},
            isPrepared: { await tower.isPrepared() },
            warm: { await tower.warm() },
            admission: admission
        ) { await tower.encode($0) }
    }

    /// ADR 0048, "The intent to search": the field's focus on a prepared tower starts exactly
    /// one warm prediction, and the intent is readied when it ends. A later focus, after it
    /// ended, starts one more: once per focus.
    @Test func aFocusOnAPreparedTowerStartsExactlyOneWarmPrediction() async {
        let tower = ScriptedTower()
        let reader = Self.reader(on: tower)
        await reader.prepare()
        await tower.warmGate.waitForArrivals(1)
        #expect(await reader.warmsStarted == 1)
        await tower.warmGate.open()
        await reader.intentReadied()
        #expect(await tower.predictions == 1)
        #expect(await reader.preparationsLoaded == 0, "a prepared tower is not loaded again")

        await reader.prepare()
        await reader.intentReadied()
        #expect(await reader.warmsStarted == 2)
        #expect(await tower.predictions == 2)
        await reader.shutdown()
    }

    /// A second focus while the warm prediction runs starts none: the one in flight answers
    /// both.
    @Test func aSecondFocusWhileTheWarmPredictionRunsStartsNone() async {
        let tower = ScriptedTower()
        let reader = Self.reader(on: tower)
        await reader.prepare()
        await tower.warmGate.waitForArrivals(1)
        await reader.prepare()
        await reader.prepare()
        await tower.warmGate.open()
        await reader.intentReadied()
        #expect(await reader.warmsStarted == 1)
        #expect(await tower.predictions == 1)
        await reader.shutdown()
    }

    /// A query typed while the warm prediction is held publishes its words answer without
    /// waiting on it, and its tower answer after exactly one further prediction: it joined the
    /// tower's queue behind the warm-up rather than starting a load or a second warm-up.
    @Test func aQueryTypedDuringTheWarmPredictionShowsItsWordsAtOnceAndItsTowerAnswerAfterOneMorePrediction() async {
        let tower = ScriptedTower()
        let reader = Self.reader(on: tower)
        let readings = await reader.readings()
        await reader.prepare()
        await tower.warmGate.waitForArrivals(1)

        let dog = SearchQueryRequest(text: "dog")
        #expect(await reader.status(for: dog) == .reading)
        for await _ in readings where await reader.status(for: dog) == .refining(Self.words("dog")) {
            break
        }
        #expect(await reader.announcements == 1)
        #expect(await tower.predictions == 1, "only the held warm-up has predicted")

        await tower.warmGate.open()
        for await _ in readings where await reader.status(for: dog) == .read(Self.encoding("dog")) {
            break
        }
        #expect(await tower.predictions == 2)
        #expect(await reader.announcements == 2)
        #expect(await reader.warmsStarted == 1)
        #expect(await reader.preparationsLoaded == 0)
        await reader.shutdown()
    }

    /// A focus while the tower is still loading starts no prediction of its own: the load's
    /// warm-up is the one it asked for, and the intent is readied when the load ends.
    @Test func aFocusWhileTheTowerLoadsStartsNoWarmPrediction() async {
        let load = ArrivalGate()
        let prepared = Mutex(false)
        let warms = Mutex(0)
        let reader = SearchQueryReader(
            words: { Self.words($0.text) },
            prepare: {
                await load.arrive()
                prepared.withLock { $0 = true }
            },
            isPrepared: { prepared.withLock { $0 } },
            warm: { warms.withLock { $0 += 1 } }
        ) { Self.encoding($0.text) }
        let readying = Task { await reader.prepareWhileAdmitted() }
        await load.waitForArrivals(1)
        await reader.prepare()
        await load.open()
        await readying.value
        await reader.intentReadied()
        #expect(await reader.warmsStarted == 0)
        #expect(warms.withLock { $0 } == 0)
        #expect(await load.arrivalCount == 1)
        #expect(await reader.preparationsLoaded == 1)
        await reader.shutdown()
    }

    /// ADR 0057: a background room that holds heavy loads does not hold the warm prediction,
    /// which is no load the admission grants: it runs while a held background load still waits,
    /// and the admission grants nothing for it.
    @Test func aHeldBackgroundRoomDoesNotHoldTheWarmPrediction() async throws {
        let room = BackgroundRoom(conditions: MachineConditions(memory: .warning, thermal: .nominal, lowPower: false, userInApp: false))
        let admission = LoadAdmission(isOpen: true, room: room)
        let duplicates = Task { try await admission.run(.duplicates) {} }
        try await waitUntil { admission.snapshot.waiting.count == 1 }
        #expect(admission.snapshot.room.heavyLoad == .memoryWarning)

        let tower = ScriptedTower()
        let reader = Self.reader(on: tower, admission: admission)
        await reader.prepare()
        await tower.warmGate.waitForArrivals(1)
        #expect(admission.snapshot.runningForUser.isEmpty)
        #expect(admission.snapshot.running == nil)
        #expect(admission.snapshot.waiting.map(\.load) == [.duplicates])
        await tower.warmGate.open()
        await reader.intentReadied()
        #expect(await tower.predictions == 1)
        await reader.shutdown()
        admission.shutdown()
        await #expect(throws: CancellationError.self) { try await duplicates.value }
    }
}
