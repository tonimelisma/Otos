import SwiftUI

/// The one drawing of `CatalogMediaEmptyState`, shared by the grid and the Places map
/// so an empty scope reads the same wherever it is empty (DES-017). Before the first
/// catalog load nothing is known, so nothing is said (APP-044).
struct CatalogMediaEmptyStateView: View {
    let emptyState: CatalogMediaEmptyState
    var clearFilters: () -> Void = {}

    var body: some View {
        if emptyState == .loadingCatalog {
            Color.clear
        } else {
            VStack(spacing: 12) {
                if emptyState.isProgressing {
                    ProgressView()
                        .controlSize(.large)
                }
                ContentUnavailableView {
                    Label(emptyState.title, systemImage: emptyState.systemImage)
                } description: {
                    Text(emptyState.message)
                }
                if emptyState == .noFilterMatches {
                    Button("Clear Filters", action: clearFilters)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
