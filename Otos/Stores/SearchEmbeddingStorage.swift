import Foundation
import GRDB

/// Search embedding storage guide (ADR 0048)
///
/// A photo's or video's search embedding is overlay on its asset, in `search_embedding`
/// (one row per asset; a move carries it, a proven deletion ends it, both by cascade). It is
/// read from the asset's **stored thumbnail**, never from an original, so making one never
/// downloads anything, and a card's, camera's or Immich account's items are searchable as
/// soon as their thumbnails are.
///
/// Each row records the thumbnail it was read from and the model revision
/// (`source`, `StoredThumbnailSQL.identity` then `|s` and `SearchEmbedding.revision`).
/// When enrichment writes a new thumbnail, or the model changes, the row's source no longer
/// matches and the asset is offered again; no thumbnail write site knows search exists. A
/// thumbnail that does not decode is not read: nothing is recorded for it, so it stays owed
/// (and the Info pane reads `Not Checked Yet`, not `Nothing Recognized`).
///
/// An embedding is `SearchEmbedding.dimensions` little-endian Float32 values. The row also
/// holds the thumbnail's scene labels, Vision's classification of the same picture, as
/// `identifier:confidence` pairs at or above `SearchSceneLabels.minimumConfidence`, comma
/// separated — what the label gate reads (`SearchLabelGate`) — and, in `confident_labels`, the
/// identifiers that pass Vision's high-precision test, most confident first, comma separated:
/// what the Info pane shows (`SearchSceneLabels`).
nonisolated enum SearchEmbeddingStorage {
    /// Each embedding's key with the source it names (v65): whether an asset's embedding is
    /// current is read from it, never from the 3 KB row.
    static let sourceIndexName = "idx_search_embedding_source"

    /// The source an asset's embedding must name to be current, for `row` (a table or alias).
    static func currentSource(_ row: String) -> String {
        "(\(StoredThumbnailSQL.identity(row)) || '|s\(SearchEmbedding.revision)')"
    }

    /// `FROM … WHERE …` over the assets owed an embedding in `rootCount` roots (bound in
    /// order): a stored thumbnail whose current embedding is missing, not waiting for or in
    /// the Trash, and not a Live Photo's movie, whose still stands for the item.
    static func owedFrom(rootCount: Int) -> String {
        """
        FROM media_asset AS a INDEXED BY \(ProductStampSQL.indexName)
        LEFT JOIN search_embedding AS e INDEXED BY \(sourceIndexName)
            ON e.library_root_id = a.library_root_id AND e.relative_path = a.relative_path
        WHERE a.library_root_id IN (\(Array(repeating: "?", count: rootCount).joined(separator: ", ")))
          AND a.thumbnail_path IS NOT NULL
          AND a.pending_trash_batch_unix_ms IS NULL
          AND a.trash_path IS NULL
          AND NOT \(LivePhotoSQL.isPairedMotion("a"))
          AND e.source IS NOT \(currentSource("a"))
        """
    }

    /// A page of the embedding owner's newest-first walk (`CandidateWalk.capturePage`): every
    /// row is tested and stamped from the product stamps index, and its embedding's source from
    /// the embedding source index, so the walk reads no table row.
    static func candidatesSQL(rootCount: Int, position: String, order: String) -> String {
        """
        SELECT a.best_capture_local, a.library_root_id, a.relative_path, a.thumbnail_path,
               \(currentSource("a")) AS source
        \(owedFrom(rootCount: rootCount))
          AND \(position)
        \(order)
        LIMIT ?
        """
    }

    /// The keys of the current embeddings in `rootCount` roots (bound in order): what the
    /// search index reconciles its memory against. Each asset's stamp is read from the product
    /// stamps index and its embedding's source from the embedding source index, the asset side
    /// outer (`CROSS JOIN`), so the check reads neither table: 12k pages against 251k for the
    /// owner-shaped catalog (`CatalogStoreQueryPlanTests`). Every stored embedding has its vector
    /// (v51 removed the rows without one, and a write always carries one).
    static func currentEmbeddingIDsSQL(rootCount: Int) -> String {
        """
        SELECT a.library_root_id, a.relative_path
        FROM media_asset AS a INDEXED BY \(ProductStampSQL.indexName)
        CROSS JOIN search_embedding AS e INDEXED BY \(sourceIndexName)
            ON e.library_root_id = a.library_root_id AND e.relative_path = a.relative_path
            AND e.source = \(currentSource("a"))
        WHERE a.library_root_id IN (\(Array(repeating: "?", count: rootCount).joined(separator: ", ")))
          AND a.thumbnail_path IS NOT NULL
        """
    }

    /// The current embeddings in `rootCount` roots (bound in order) with their vectors and loose
    /// labels. Each row is found by the embedding table's key and its asset by the asset's
    /// (`CatalogStoreQueryPlanTests`).
    static func currentEmbeddingsSQL(rootCount: Int) -> String {
        """
        SELECT e.library_root_id, e.relative_path, e.embedding, e.labels
        FROM search_embedding AS e
        JOIN media_asset AS a
            ON a.library_root_id = e.library_root_id AND a.relative_path = e.relative_path
        WHERE e.library_root_id IN (\(Array(repeating: "?", count: rootCount).joined(separator: ", ")))
          AND e.embedding IS NOT NULL
          AND e.source = \(currentSource("a"))
        """
    }

    static func labelsText(_ labels: [String: Float]) -> String {
        labels.sorted { $0.key < $1.key }.map { "\($0.key):\(String(format: "%.3f", $0.value))" }.joined(separator: ",")
    }

    static func labels(from text: String?) -> [String: Float] {
        guard let text, !text.isEmpty else { return [:] }
        var labels: [String: Float] = [:]
        for pair in text.split(separator: ",") {
            let parts = pair.split(separator: ":")
            if parts.count == 2, let confidence = Float(parts[1]) {
                labels[String(parts[0])] = confidence
            }
        }
        return labels
    }

    static func confidentLabelsText(_ identifiers: [String]) -> String {
        identifiers.joined(separator: ",")
    }

    static func confidentLabels(from text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        return text.split(separator: ",").map(String.init)
    }

    static func data(_ embedding: [Float]) -> Data {
        Float32Storage.data(embedding)
    }

    /// Nil unless `data` holds exactly one embedding.
    static func embedding(from data: Data) -> [Float]? {
        Float32Storage.floats(from: data, count: SearchEmbedding.dimensions)
    }
}

/// An asset whose stored thumbnail has no current search embedding.
nonisolated struct SearchEmbeddingCandidate: Equatable, Sendable {
    let id: MediaAssetID
    let thumbnailPath: String
    /// The source the embedding will record.
    let source: String
}

/// What reading one candidate's thumbnail produced: its embedding and scene labels.
nonisolated struct SearchEmbeddingResult: Equatable, Sendable {
    let id: MediaAssetID
    let source: String
    let embedding: [Float]
    var labels: [String: Float] = [:]
    var confidentLabels: [String] = []
}

/// One stored, current embedding and the scene labels read with it.
nonisolated struct StoredSearchEmbedding: Sendable {
    let id: MediaAssetID
    let embedding: [Float]
    var labels: [String: Float] = [:]
}
