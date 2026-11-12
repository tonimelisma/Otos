import CoreLocation
import Foundation
import MapKit

/// Place name reader guide (ADR 0040)
///
/// The one producer of place names: the country and town Apple Maps names for each cell of
/// the map a located photo falls in (`PlaceCell`), which the Places filter narrows by. Maps is
/// sent the cell's center, never a photo's own coordinate, and each cell is asked once per
/// language: the names are stored with the locale they are in, and a cell named in another
/// language than the Mac's is asked again.
///
/// One loop, woken by a doorbell (ADR 0032 rule 3) that the Store's change notifications
/// ring; each wake drains every unnamed cell in pages. A cell Maps names nothing for (open sea,
/// `placemarkNotFound`) is stored with no names, so it is not asked again. When Maps throttles
/// or cannot be reached, the reader waits and asks again (`time: backoff`), doubling the wait
/// up to `maximumBackoff`; nothing it already stored is touched. The forwarder and the loop
/// hold this actor weakly and end with it.
actor PlaceNameReader {
    /// How a cell is named. `mapKit` asks Apple Maps; tests substitute their own so none
    /// reaches the network.
    nonisolated struct Namer: Sendable {
        let name: @Sendable (PlaceCoordinate, Locale) async throws -> PlaceNames

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

    /// Whether a failed naming is Maps asking Otos to wait, or a network that is not there:
    /// both pass, so the reader waits and asks again. Classified by domain and code.
    static func isTransient(_ error: any Error) -> Bool {
        if let error = error as? MKError {
            return error.code == .loadingThrottled || error.code == .serverFailure
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
    }

    static let firstBackoff: Duration = .seconds(2)
    static let maximumBackoff: Duration = .seconds(300)

    private let store: CatalogStore
    private let namer: Namer
    private let locale: @Sendable () -> Locale
    private let sleep: @Sendable (Duration) async throws -> Void
    private let pageSize: Int
    private var loop: Task<Void, Never>?
    private var forwarder: Task<Void, Never>?

    init(
        store: CatalogStore,
        namer: Namer = .mapKit,
        locale: @escaping @Sendable () -> Locale = { .current },
        // time: backoff — the wait after Maps throttled or could not be reached
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

    /// Names every unnamed cell, a page at a time, until none is left.
    func drain() async {
        let locale = locale()
        let identifier = locale.identifier
        var named = 0
        var backoff = Self.firstBackoff
        while !Task.isCancelled {
            let page: [PlaceCell]
            do {
                page = try await store.unnamedPlaceCells(locale: identifier, limit: pageSize)
            } catch {
                OtosLog.metadata.errorOperation("place.names", phase: "readFailed", fields: ["error": String(describing: error)])
                return
            }
            guard !page.isEmpty else { break }
            var names: [PlaceCell: PlaceNames] = [:]
            var waited = false
            for cell in page {
                do {
                    names[cell] = try await namer.name(cell.center, locale)
                    backoff = Self.firstBackoff
                } catch where Self.isTransient(error) {
                    OtosLog.metadata.noticeOperation("place.names", phase: "backoff", fields: [
                        "seconds": "\(backoff.components.seconds)", "error": String(describing: error),
                    ])
                    do {
                        // time: backoff — Maps throttled the reader or could not be reached
                        try await sleep(backoff)
                    } catch {
                        return
                    }
                    backoff = min(backoff * 2, Self.maximumBackoff)
                    waited = true
                    break
                } catch {
                    // Not one Maps names, nor one worth asking again: stored with no names.
                    OtosLog.metadata.errorOperation("place.names", phase: "unnamed", fields: ["error": String(describing: error)])
                    names[cell] = PlaceNames.none
                }
            }
            do {
                try await store.applyPlaceNames(names, locale: identifier)
            } catch {
                OtosLog.metadata.errorOperation("place.names", phase: "writeFailed", fields: [
                    "count": "\(names.count)", "error": String(describing: error),
                ])
                return
            }
            named += names.count
            if names.isEmpty, !waited {
                break
            }
        }
        if named > 0 {
            OtosLog.metadata.noticeOperation("place.names", phase: "named", fields: ["cells": "\(named)"])
        }
    }
}
