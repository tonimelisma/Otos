import CoreLocation
import Foundation
import MapKit

/// A place a query named, located: a centre and the distance from it a photo may be.
nonisolated struct SearchPlace: Hashable, Sendable {
    let name: String
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double

    func contains(latitude other: Double, longitude otherLongitude: Double) -> Bool {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other, longitude: otherLongitude)) <= radiusMeters
    }
}

/// Search places guide (ADR 0048)
///
/// Where a name a query holds is, from Apple Maps (`MKLocalSearch`, addresses and areas only).
/// It is a place only when Maps names it so, a case ending aside, and it covers a town or more, at least
/// 0.03° across: the tagger hands over names that are not places ("City view", "Panorama"),
/// and Maps answers those with a street of the same name somewhere. A photo is in the place
/// within 1.5 times the area's half-diagonal, at least 15 km, because Maps' area for a lake
/// or a mountain is its town, not the shore or the slopes the photos were taken on.
///
/// Asking needs the network. Only the name is sent, as the query holds it. A name Maps cannot
/// place is no place (nil), a fact the encoder remembers; a lookup that fails (offline, a
/// server error, throttling) throws, is not remembered, and the encoder searches the name's
/// words in the picture for that reading only.
///
/// Maps names what it finds in the Mac's language, and `MKLocalSearch.Request` has no
/// language or locale to ask in, so on a Mac in another language a place may be named
/// otherwise than the query names it ("Lontoo" for "London") and be refused here; that is
/// unmeasured.
nonisolated enum SearchPlaces {
    static let minimumSpanDegrees = 0.03
    static let minimumRadiusMeters = 15000.0

    /// The place `name` is; nil when Maps says it is no place. Throws when the lookup failed.
    @concurrent
    static func locate(_ name: String) async throws -> SearchPlace? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = name
        request.resultTypes = [.address]
        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: request).start()
        } catch let error as NSError where isNowhere(error) {
            return nil
        }
        guard let item = response.mapItems.first,
              let found = item.name,
              names(found, as: name)
        else {
            return nil
        }
        let span = response.boundingRegion.span
        guard max(span.latitudeDelta, span.longitudeDelta) >= minimumSpanDegrees else { return nil }
        let center = item.location.coordinate
        let corner = CLLocation(
            latitude: center.latitude + span.latitudeDelta / 2,
            longitude: center.longitude + span.longitudeDelta / 2
        )
        let halfDiagonal = CLLocation(latitude: center.latitude, longitude: center.longitude).distance(from: corner)
        return SearchPlace(
            name: found,
            latitude: center.latitude,
            longitude: center.longitude,
            radiusMeters: max(1.5 * halfDiagonal, minimumRadiusMeters)
        )
    }

    /// Whether Maps' `found` is the place `typed` names: the same name, ignoring case and
    /// diacritics, or that name with a case ending of at most `maximumEnding` letters on its
    /// last word, because a language that inflects names writes "San Franciscos" (Estonian:
    /// in San Francisco).
    static func names(_ found: String, as typed: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .anchored]
        guard let range = typed.range(of: found, options: options) else { return false }
        let ending = typed[range.upperBound...]
        return ending.count <= maximumEnding && ending.allSatisfy(\.isLetter)
    }

    static let maximumEnding = 3

    /// Maps' answer that nothing is called `name`: `MKError.placemarkNotFound`. Every other
    /// error is a lookup that failed.
    static func isNowhere(_ error: NSError) -> Bool {
        error.domain == MKErrorDomain && error.code == Int(MKError.Code.placemarkNotFound.rawValue)
    }
}
