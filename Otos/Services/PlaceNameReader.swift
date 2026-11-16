import CoreLocation
import Foundation
import MapKit

/// Place name reader guide (ADR 0051)
///
/// The one producer of place names: the country and town Apple Maps names for each cell of
/// the map a located photo falls in (`PlaceCell`), which the Places filter narrows by. Maps is
/// sent the cell's center, never a photo's own coordinate, and each cell is asked once per
/// language (`PlaceNameLanguage`): the catalog keeps one language's names, so a drain in a new
/// language first forgets the old one's and then names every cell again.
///
/// Only an answer is stored (ADR 0032 rule 4). The namer returns names, or no names when
/// Maps's answer means there are none (`placemarkNotFound`, an empty result); it throws for
/// everything else. A thrown naming stores nothing and is logged; the reader waits
/// (`time: backoff`, doubling up to `maximumBackoff`) and goes on to the next cell, and a pass
/// that left a cell unnamed is followed by another, so the cell is asked again. Nothing it
/// already stored is touched by a failure.
///
/// One loop, woken by a doorbell (ADR 0032 rule 3) that a Store change of a kind its read
/// reads (`inputs`; its own name writes do not) and a change of the user's locale ring; each
/// wake drains every unnamed cell in pages, in cell order. The forwarder and the
/// loop hold this actor weakly and end with it. Each ring is a request (`OwnerActivity`),
/// covered by a drain that read and wrote without failing (`QuiescentOwner`).
actor PlaceNameReader: QuiescentOwner {
    /// How a cell is named. `mapKit` asks Apple Maps; tests substitute their own so none
    /// reaches the network. It returns the names, `PlaceNames.none` only for an answer that
    /// there are none, and throws for every failure.
    nonisolated struct Namer: Sendable {
        let name: @Sendable (PlaceCoordinate, Locale) async throws -> PlaceNames

        /// `MKReverseGeocodingRequest` documents no error list. What is an answer: its
        /// initializer refusing the coordinate (nil), `MKError.placemarkNotFound`, and a result
        /// with no map item. Everything else — `loadingThrottled`, `serverFailure`, `unknown`,
        /// `decodingFailed`, a network error, a cancellation — is a failure and is thrown.
        static let mapKit = Namer { coordinate, locale in
            guard let request = MKReverseGeocodingRequest(
                location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            ) else {
                return .none
            }
            request.preferredLocale = locale
            do {
                let address = try await request.mapItems.first?.addressRepresentations
                return PlaceNames(
                    country: address?.regionName,
                    town: address?.cityWithContext(.short) ?? address?.cityName
                )
            } catch let error as MKError where error.code == .placemarkNotFound {
                return .none
            }
        }
    }

    /// The system's locale changes, one element each; the stream ends with its consumer.
    static let systemLocaleChanges: @Sendable () -> AsyncStream<Void> = {
        AsyncStream { continuation in
            let relay = Task {
                for await _ in NotificationCenter.default.notifications(named: NSLocale.currentLocaleDidChangeNotification) {
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                relay.cancel()
            }
        }
    }

    static let firstBackoff: Duration = .seconds(2)
    static let maximumBackoff: Duration = .seconds(300)

    private let store: CatalogStore
    private let namer: Namer
    private let locale: @Sendable () -> Locale
    /// Yields when the user's locale changes (`NSLocale.currentLocaleDidChangeNotification`);
    /// a test delivers its own.
    private let localeChanges: @Sendable () -> AsyncStream<Void>
    private let sleep: @Sendable (Duration) async throws -> Void
    private let pageSize: Int
    /// The language whose names alone the catalog holds, once a drain has forgotten the
    /// others; nil before that.
    private var keptLanguage: PlaceNameLanguage?
    private var loop: Task<Void, Never>?
    private var forwarder: Task<Void, Never>?
    private var doorbell: AsyncStream<Void>.Continuation?
    let activity = OwnerActivity(owner: "placeNames")

    init(
        store: CatalogStore,
        namer: Namer = .mapKit,
        locale: @escaping @Sendable () -> Locale = { .current },
        localeChanges: @escaping @Sendable () -> AsyncStream<Void> = PlaceNameReader.systemLocaleChanges,
        // time: backoff — the wait after a naming failed
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        pageSize: Int = 32
    ) {
        self.store = store
        self.namer = namer
        self.locale = locale
        self.localeChanges = localeChanges
        self.sleep = sleep
        self.pageSize = pageSize
    }

    /// What a drain reads (`CatalogOwnerInputs`): the located records' cells, less its own
    /// writes (place names). Not root-scoped: every located item counts wherever it is.
    static let inputs = CatalogOwnerInputs(
        statements: [CatalogQueryGateway.unnamedPlaceCellsSQL(after: true)], ownWrites: .placeNames, beyondSQL: []
    )

    /// Store changes heard, and the changes that rang the doorbell, the locale's included:
    /// what a test waits on.
    private(set) var changesHeard = 0
    private(set) var wakes = 0

    /// The locale changed: a drain in its language is owed.
    private func woke() {
        wakes += 1
        request()
    }

    /// Asks for a drain (ADR 0032 rule 2).
    private func request() {
        activity.request()
        doorbell?.yield()
    }

    func ringIdle() {
        request()
    }

    /// What the next drain owes: every unnamed cell (at start, after a change that names no
    /// rows, a new language, or a failed keyed read), or only the cells of the rows the
    /// changes since named. A change of a located record's cell can leave only that record's
    /// cell unnamed, so a write that names its rows is answered by a keyed read of their cells,
    /// never a walk of every located record: an enrichment flush names its rows, and on the
    /// owner's catalog the walk ran once per flush (152 runs, 6.6 s, in one tour).
    private var owesFullDrain = true
    private var owedRows: Set<MediaAssetID> = []

    /// Rings for `change` when it is of a kind a drain reads, naming rows or not.
    private func heard(_ change: CatalogStoreChange, inputs: CatalogChangedFacts) {
        changesHeard += 1
        defer {
            activity.actedOnChange()
            settleQuiescence()
        }
        guard change.touches(inputs) else { return }
        switch change.rows {
        case .unnamed:
            owesFullDrain = true
        case let .named(rows):
            owedRows.formUnion(rows.ids)
        case .none:
            return
        }
        wakes += 1
        request()
    }

    func start() async {
        guard loop == nil else { return }
        let (bell, ring) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let changes = await store.changeNotifications(deliveries: activity.deliveries)
        let inputs = await Self.inputs.facts(in: store, owner: "place.names")
        // Read after the awaits: a concurrent `start()` may have won.
        guard loop == nil else { return }
        let languages = localeChanges()
        doorbell = ring
        request()
        forwarder = Task { [weak self] in
            await withDiscardingTaskGroup { group in
                // The language a drain names cells in is the locale's, read at its start: a
                // change of locale is an input the catalog does not hold.
                group.addTask { [weak self] in
                    for await _ in languages {
                        guard let self else { break }
                        await woke()
                    }
                }
                for await change in changes {
                    guard let self else { break }
                    await self.heard(change, inputs: inputs)
                }
                group.cancelAll()
            }
            ring.finish()
        }
        loop = Task { [weak self] in
            for await _ in bell {
                guard let self else { return }
                await pass()
            }
        }
    }

    private func pass() async {
        guard activity.isOwed else { return }
        let answering = activity.beginPass()
        let drained = await drain()
        activity.endPass(covering: drained ? answering : nil)
        settleQuiescence()
    }

    /// Ends the loop now — a test's teardown; in the app, the loops end with the actor.
    func shutdown() {
        forwarder?.cancel()
        loop?.cancel()
        forwarder = nil
        loop = nil
        doorbell = nil
    }

    /// Names what is owed: every unnamed cell, a page at a time in cell order, until a pass
    /// names them all; or, when only named rows changed, the unnamed cells of those rows. A
    /// read or write that fails leaves what it owed owed, and is logged. Returns whether the
    /// drain named what it owed without a failed read or write.
    @discardableResult
    func drain() async -> Bool {
        let locale = locale()
        let language = PlaceNameLanguage(locale)
        let full = owesFullDrain || keptLanguage != language
        let rows = owedRows
        owesFullDrain = false
        owedRows = []
        if full {
            return await drainEveryCell(language: language, locale: locale)
        }
        return await drainCells(of: rows, language: language, locale: locale)
    }

    private func drainEveryCell(language: PlaceNameLanguage, locale: Locale) async -> Bool {
        if keptLanguage != language {
            do {
                let forgotten = try await store.forgetPlaceNames(notIn: language)
                keptLanguage = language
                if forgotten > 0 {
                    OtosLog.metadata.noticeOperation("place.names", phase: "languageChanged", fields: [
                        "language": language.identifier, "forgotten": "\(forgotten)",
                    ])
                }
            } catch {
                OtosLog.metadata.errorOperation("place.names", phase: "forgetFailed", fields: ["error": String(describing: error)])
                owesFullDrain = true
                return false
            }
        }
        var named = 0
        var backoff = Self.firstBackoff
        var after: PlaceCell?
        var passLeftCells = false
        while !Task.isCancelled {
            let page: [PlaceCell]
            do {
                page = try await store.backgroundReads.unnamedPlaceCells(language: language, after: after, limit: pageSize)
            } catch {
                OtosLog.metadata.errorOperation("place.names", phase: "readFailed", fields: ["error": String(describing: error)])
                owesFullDrain = true
                return false
            }
            activity.read(rows: page.count)
            guard let last = page.last else {
                guard passLeftCells else { break }
                // Another pass for the cells this one could not name; each failure has
                // already waited its backoff.
                after = nil
                passLeftCells = false
                continue
            }
            let naming = await name(page, locale: locale, backoff: &backoff)
            passLeftCells = passLeftCells || naming.leftCells
            guard await apply(naming.names, language: language) else {
                owesFullDrain = true
                return false
            }
            named += naming.names.count
            guard !naming.cancelled else {
                // A drain stopped mid-walk leaves cells unnamed: the next drain walks them all.
                owesFullDrain = true
                return false
            }
            after = last
        }
        if named > 0 {
            OtosLog.metadata.noticeOperation("place.names", phase: "named", fields: ["cells": "\(named)"])
        }
        return !Task.isCancelled
    }

    /// Names the unnamed cells of `rows`. A cell Maps could not name, or a read or write that
    /// failed, leaves a whole drain owed: the next pass walks every cell, as a pass that left
    /// a cell unnamed does.
    private func drainCells(of rows: Set<MediaAssetID>, language: PlaceNameLanguage, locale: Locale) async -> Bool {
        let cells: [PlaceCell]
        do {
            cells = try await store.backgroundReads.unnamedPlaceCells(language: language, of: rows)
        } catch {
            OtosLog.metadata.errorOperation("place.names", phase: "readFailed", fields: ["error": String(describing: error)])
            owedRows.formUnion(rows)
            return false
        }
        activity.read(rows: cells.count)
        guard !cells.isEmpty else {
            return true
        }
        var backoff = Self.firstBackoff
        let naming = await name(cells, locale: locale, backoff: &backoff)
        guard await apply(naming.names, language: language), !naming.leftCells else {
            owesFullDrain = true
            guard !naming.cancelled else { return false }
            return await drainEveryCell(language: language, locale: locale)
        }
        OtosLog.metadata.noticeOperation("place.names", phase: "named", fields: [
            "cells": "\(naming.names.count)", "rows": "\(rows.count)",
        ])
        return true
    }

    /// Asks Maps to name each cell, waiting out a doubling backoff after each failure.
    private func name(
        _ cells: [PlaceCell],
        locale: Locale,
        backoff: inout Duration
    ) async -> (names: [PlaceCell: PlaceNames], leftCells: Bool, cancelled: Bool) {
        var names: [PlaceCell: PlaceNames] = [:]
        var leftCells = false
        for cell in cells {
            do {
                names[cell] = try await namer.name(cell.center, locale)
                backoff = Self.firstBackoff
            } catch {
                let nsError = error as NSError
                OtosLog.metadata.noticeOperation("place.names", phase: "backoff", fields: [
                    "seconds": "\(backoff.components.seconds)",
                    "domain": nsError.domain, "code": "\(nsError.code)",
                    "error": String(describing: error),
                ])
                leftCells = true
                do {
                    // time: backoff — Maps failed to name a cell (throttled, unreachable, or
                    // an error it does not explain); the next naming waits
                    try await sleep(backoff)
                } catch {
                    return (names, leftCells, true)
                }
                backoff = min(backoff * 2, Self.maximumBackoff)
            }
        }
        return (names, leftCells, false)
    }

    /// Stores `names`; false, logged, when the write failed.
    private func apply(_ names: [PlaceCell: PlaceNames], language: PlaceNameLanguage) async -> Bool {
        do {
            try await store.applyPlaceNames(names, language: language)
            activity.wrote(names.count)
            return true
        } catch {
            OtosLog.metadata.errorOperation("place.names", phase: "writeFailed", fields: [
                "count": "\(names.count)", "error": String(describing: error),
            ])
            return false
        }
    }
}
