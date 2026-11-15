import Foundation
import OSLog

/// Tile-detail read guide
///
/// The one read of `MediaTileDetail` rows shared by the grid's visible-detail query and
/// prefetch, the pane thumbnail fallback, and the view model's pane previews, focus kind,
/// loupe video, edit target and current-target choice, so a view is handed this read
/// instead of the catalog store.
///
/// A failed read throws (ADR 0032, rule 4). An empty map is a fact — none of the asked
/// IDs has a row — so a failure never arrives as one: each caller publishes nothing for
/// it and leaves its request to be asked again. The reader logs every failure once
/// (`op=tileDetail.read phase=failed`), so callers do not log it again; a cancelled read
/// throws `CancellationError` and is not logged.
///
/// Every answer carries the choices the window holds and the catalog has not recorded yet
/// (`MediaChoiceOverlay`): the read is numbered as it starts and answered through the overlay
/// after its one await, so a read that started before a choice's write landed shows the
/// choice, and one that started after retires it.
struct MediaTileDetailReader {
    private let store: CatalogStore
    private let choices: MediaChoiceOverlay

    init(store: CatalogStore, choices: MediaChoiceOverlay = MediaChoiceOverlay()) {
        self.store = store
        self.choices = choices
    }

    /// The rows for `ids`; an ID the catalog holds no row for is absent from the map.
    func details(for ids: [MediaAssetID]) async throws -> [MediaAssetID: MediaTileDetail] {
        let started = choices.readStarted()
        do {
            let details = try await store.mediaTileDetails(for: ids)
            return choices.answer(details, asked: ids, startedAt: started)
        } catch {
            if !(error is CancellationError) {
                OtosLog.catalog.errorOperation("tileDetail.read", phase: "failed", fields: [
                    "requested": "\(ids.count)",
                    "error": String(describing: error),
                ])
            }
            throw error
        }
    }

    /// The row for `id`, or nil when the catalog holds none. A failure throws, so nil is
    /// never a read that did not happen.
    func detail(for id: MediaAssetID) async throws -> MediaTileDetail? {
        try await details(for: [id])[id]
    }
}
