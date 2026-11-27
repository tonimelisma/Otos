import Foundation

/// The Activity surface's words (ADR 0058, DES-124): the board's snapshot beside what the
/// window already holds of the accounts' syncs, People's unchecked tally and the libraries'
/// names. Read on the
/// MainActor, from state SwiftUI observes; composing it is string work only.
extension CatalogWindowViewModel {
    var activityPresentation: ActivityPresentation {
        let accounts = parts.libraries.compactMap { library in
            immichAccountStatuses[library.path].map { ActivityAccount(name: library.displayName, status: $0) }
        }
        let sourceNames = Dictionary(parts.libraries.map { ($0.path, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        return ActivityPresentation.map(
            activity, accounts: accounts, uncheckedFaces: parts.people?.unchecked, sourceNames: sourceNames
        )
    }
}
