import Foundation

// Grid zoom intent guide
//
// User-adjustable grid density (spec 0048), 3–9. This is rendering/UI state, not
// catalog truth, so it never touches the query-descriptor stream (`setQueryDescriptor`)
// or Store/Projection: it is a plain published property with a persistence side effect.
// Every zoom surface — the View menu and toolbar slider directly, the AppKit pinch
// gesture through a callback — calls `setGridColumnCount(_:)`, so there is exactly one
// clamp/persist/publish path regardless of which surface originated the request.

extension CatalogWindowViewModel {
    /// Not `private`: `init` also reads this key to load the stored preference.
    static let gridColumnCountDefaultsKey = "mediaGridColumnCount"

    /// Clamps into 3–9, persists, and publishes; a no-op re-request does not re-persist.
    func setGridColumnCount(_ requested: Int) {
        let clamped = GridColumnCount.clamped(requested)
        guard clamped != gridColumnCount else {
            return
        }
        gridColumnCount = clamped
        gridColumnCountDefaults.set(clamped, forKey: Self.gridColumnCountDefaultsKey)
    }

    func zoomInGrid() {
        setGridColumnCount(gridColumnCount - 1)
    }

    func zoomOutGrid() {
        setGridColumnCount(gridColumnCount + 1)
    }
}
