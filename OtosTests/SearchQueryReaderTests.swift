import Foundation
@testable import OtosKit
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
            embedding: nil
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
}
