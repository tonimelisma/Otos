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
/// One loop, woken by a doorbell (ADR 0032 rule 3) that the Store's change notifications
/// ring; each wake drains every unnamed cell in pages, in cell order. The forwarder and the
/// loop hold this actor weakly and end with it.
actor PlaceNameReader {
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

    static let firstBackoff: Duration = .seconds(2)
    static let maximumBackoff: Duration = .seconds(300)

    private let store: CatalogStore
    private let namer: Namer
    private let locale: @Sendable () -> Locale
    private let sleep: @Sendable (Duration) async throws -> Void
    private let pageSize: Int
    /// The language whose names alone the catalog holds, once a drain has forgotten the
    /// others; nil before that.
    private var keptLanguage: PlaceNameLanguage?
    private var loop: Task<Void, Never>?
    private var forwarder: Task<Void, Never>?

    init(
        store: CatalogStore,
        namer: Namer = .mapKit,
        locale: @escaping @Sendable () -> Locale = { .current },
        // time: backoff — the wait after a naming failed
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        pageSize: Int = 32
    ) {
        self.store = store
        self.namer = namer
        self.locale = locale
        self.sleep = sleep
        self.pageSize = pageSize
    }

    func start() async {
        guard loop == nil else { return }
        let (doorbell, ring) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let changes = await store.changeNotifications()
        ring.yield()
        forwarder = Task { [weak self] in
            for await change in changes {
                guard self != nil else { break }
                if change == .catalogChanged || change == .assetsDetailChanged {
                    ring.yield()
                }
            }
            ring.finish()
        }
        loop = Task { [weak self] in
            for await _ in doorbell {
                guard let self else { return }
                await drain()
            }
        }
    }

    /// Ends the loop now — a test's teardown; in the app, the loops end with the actor.
    func shutdown() {
        forwarder?.cancel()
        loop?.cancel()
        forwarder = nil
        loop = nil
    }

    /// Names every unnamed cell, a page at a time in cell order, until a pass names them all.
    func drain() async {
        let locale = locale()
        let language = PlaceNameLanguage(locale)
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
                return
            }
        }
        var named = 0
        var backoff = Self.firstBackoff
        var after: PlaceCell?
        var passLeftCells = false
        while !Task.isCancelled {
            let page: [PlaceCell]
            do {
                page = try await store.unnamedPlaceCells(language: language, after: after, limit: pageSize)
            } catch {
                OtosLog.metadata.errorOperation("place.names", phase: "readFailed", fields: ["error": String(describing: error)])
                return
            }
            guard let last = page.last else {
                guard passLeftCells else { break }
                // Another pass for the cells this one could not name; each failure has
                // already waited its backoff.
                after = nil
                passLeftCells = false
                continue
            }
            var names: [PlaceCell: PlaceNames] = [:]
            var cancelled = false
            for cell in page {
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
                    passLeftCells = true
                    do {
                        // time: backoff — Maps failed to name a cell (throttled, unreachable, or
                        // an error it does not explain); the next naming waits
                        try await sleep(backoff)
                    } catch {
                        cancelled = true
                        break
                    }
                    backoff = min(backoff * 2, Self.maximumBackoff)
                }
            }
            do {
                try await store.applyPlaceNames(names, language: language)
            } catch {
                OtosLog.metadata.errorOperation("place.names", phase: "writeFailed", fields: [
                    "count": "\(names.count)", "error": String(describing: error),
                ])
                return
            }
            named += names.count
            guard !cancelled else { break }
            after = last
        }
        if named > 0 {
            OtosLog.metadata.noticeOperation("place.names", phase: "named", fields: ["cells": "\(named)"])
        }
    }
}
