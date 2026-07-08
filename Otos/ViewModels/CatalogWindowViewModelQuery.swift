import Foundation

// Catalog query intent guide
//
// The sidebar-scope, media-filter, and sort intents every SwiftUI control calls. Each is a
// thin wrapper that builds a new `CatalogQueryDescriptor` and funnels through the single
// `setQueryDescriptor(_:)` writer in `CatalogWindowViewModel.swift` — the one place
// `queryDescriptor`/`sidebarSelection` change on a user intent (both are `private(set)`, so
// that writer must stay beside them). Split out here so the main ViewModel file stays a
// focused lifecycle/state-consumption owner under the repo's file-length budget, mirroring
// the existing `CatalogWindowViewModelMutation`/`…SourceMonitoring`/`…GridTelemetry` splits.

extension CatalogWindowViewModel {
    func selectSidebar(_ selection: SidebarSelection) {
        userHasChosenSource = true
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: selection,
            filter: queryDescriptor.filter,
            sort: queryDescriptor.sort
        ))
    }

    func setMediaFilter(_ filter: MediaFilter) {
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: queryDescriptor.scope,
            filter: filter,
            sort: queryDescriptor.sort
        ))
    }

    func clearMediaFilter() {
        setMediaFilter(.all)
    }

    func toggleMediaKind(_ kind: MediaKind, formatsInKind: [MediaFormatToken]) {
        var filter = queryDescriptor.filter
        if filter.kinds.remove(kind) == nil {
            filter.kinds.insert(kind)
        }
        filter.formats.subtract(formatsInKind)
        setMediaFilter(filter)
    }

    func toggleMediaFormat(_ format: MediaFormatToken, kind: MediaKind) {
        var filter = queryDescriptor.filter
        filter.kinds.remove(kind)
        if filter.formats.remove(format) == nil {
            filter.formats.insert(format)
        }
        setMediaFilter(filter)
    }

    func setSortField(_ field: MediaSortField) {
        setSortOrder(.defaultForField(field))
    }

    func setSortDirection(_ direction: MediaSortDirection) {
        setSortOrder(MediaSortOrder(field: queryDescriptor.sort.field, direction: direction))
    }

    func setSortOrder(_ sort: MediaSortOrder) {
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: queryDescriptor.scope,
            filter: queryDescriptor.filter,
            sort: sort
        ))
    }
}
