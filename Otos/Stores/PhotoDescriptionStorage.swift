import CoreGraphics
import Foundation

/// Photo description storage guide (ADR 0053)
///
/// The sentences Apple's on-device language model wrote about a still (`photo_description`,
/// one row per asset; a move carries it and a proven deletion ends it, by cascade). The model
/// is shown the still's stored preview and the facts Otos holds about it: who each face is and
/// how old they were, where and when it was taken, the text read in it and its scene labels
/// (`PhotoDescriptionFacts`).
///
/// The row names everything it was written from (`currentSource`): the preview, the faces'
/// stamp, each face's person with their name, birthday and whether they are hidden, the place
/// names of its map cell, the capture time and the prompt's revision. When any of those
/// changes — a person renamed, a face given to someone, a birthday entered, a place named, a
/// new preview — the row no longer names the still as it is, and the still is owed a new
/// description. The source is SQL over the catalog itself, so no writer of those facts needs
/// to know descriptions exist.
///
/// A still is described only once what the model is told is settled for its preview: its faces
/// read from that preview, its text read and its scene labels read (`describableStill`). A
/// place name may still arrive; the description is then written again.
///
/// `text` is the description; NULL when the model declined to describe the photo (its
/// guardrails or a refusal), a verdict for those facts that is not asked again until they
/// change. A failed request writes nothing, so the still stays owed.
nonisolated enum PhotoDescriptionStorage {
    /// Each description's key with the source it names (v65): whether a still's description
    /// is current is read from it.
    static let sourceIndexName = "idx_photo_description_source"

    /// The faces of `row`'s still as its description names them: each face of the photo (not
    /// a video frame, not marked not a face) with its person's id, name, birthday and hidden
    /// flag, in face order. Read from the face table's key.
    static func facesSignature(_ row: String) -> String {
        """
        (SELECT group_concat(
            f.face_index || ':' || IFNULL(p.id, '') || ':' || IFNULL(p.name, '') || ':'
                || IFNULL(p.birthday, '') || ':' || IFNULL(p.is_hidden, ''),
            ',' ORDER BY f.face_index)
         FROM face AS f LEFT JOIN person AS p ON p.id = f.person_id
         WHERE f.library_root_id = \(row).library_root_id AND f.relative_path = \(row).relative_path
           AND f.is_not_face = 0 AND f.frame_index IS NULL)
        """
    }

    /// The place names of `row`'s map cell: its one row, named in one language (ADR 0051).
    static func placeSignature(_ row: String) -> String {
        """
        (SELECT pc.language || ':' || IFNULL(pc.town, '') || ':' || IFNULL(pc.country, '')
         FROM asset_metadata AS pm
         JOIN place_cell AS pc
           ON pc.cell_latitude = pm.place_cell_latitude AND pc.cell_longitude = pm.place_cell_longitude
         WHERE pm.library_root_id = \(row).library_root_id AND pm.relative_path = \(row).relative_path)
        """
    }

    /// The source a description row must name to be current, for `row` (a table or alias).
    static func currentSource(_ row: String) -> String {
        """
        (\(row).preview_path || '|' || \(StoredThumbnailSQL.identity(row))
            || '|' || IFNULL(\(row).faces_source_size, '') || ':' || IFNULL(\(row).faces_source_mtime, '')
            || '|' || IFNULL(\(facesSignature(row)), '')
            || '|' || IFNULL(\(placeSignature(row)), '')
            || '|' || IFNULL(\(row).best_capture_local, '')
            || '|d\(PhotoDescriptionPrompt.revision)')
        """
    }

    /// A still whose facts are settled for its stored preview, as SQL over `a`: out of the
    /// Trash, its faces read from that preview, its text and its scene labels current. The
    /// face terms (`PreviewFaceSQL`) name `media_asset`'s columns unqualified, which in
    /// `candidatesSQL` only `a` holds.
    static let describableStill = """
    a.kind IN ('image', 'raw')
      AND a.preview_path IS NOT NULL
      AND a.trash_path IS NULL
      AND a.pending_trash_batch_unix_ms IS NULL
      AND NOT (\(PreviewFaceSQL.owesFaces))
      AND \(PreviewFaceSQL.previewEditIsKnown)
      AND EXISTS (SELECT 1 FROM search_text AS t INDEXED BY \(SearchTextStorage.sourceIndexName)
          WHERE t.library_root_id = a.library_root_id AND t.relative_path = a.relative_path
            AND t.source = \(SearchTextStorage.currentSource("a")))
      AND EXISTS (SELECT 1 FROM search_embedding AS e INDEXED BY \(SearchEmbeddingStorage.sourceIndexName)
          WHERE e.library_root_id = a.library_root_id AND e.relative_path = a.relative_path
            AND e.source = \(SearchEmbeddingStorage.currentSource("a")))
    """

    /// A page of the describable stills owed a description in `rootCount` roots (bound in
    /// order), from the newest-first walk's `position` in `order` (`CandidateWalk.capturePage`):
    /// each still is tested from the product stamps index and its readings and description from
    /// their source indexes; only a still that is describable reads its faces and place, and
    /// only a returned one its edit. Then the limit.
    static func candidatesSQL(rootCount: Int, position: String, order: String) -> String {
        """
        SELECT a.best_capture_local, a.library_root_id, a.relative_path, a.preview_path, a.edit_recipe_json,
               a.rendered_revision, \(currentSource("a")) AS source
        FROM media_asset AS a INDEXED BY \(CandidateWalk.captureIndex)
        LEFT JOIN photo_description AS d INDEXED BY \(sourceIndexName)
            ON d.library_root_id = a.library_root_id AND d.relative_path = a.relative_path
        WHERE a.library_root_id IN (\(Array(repeating: "?", count: rootCount).joined(separator: ", ")))
          AND \(position)
          AND \(describableStill)
          AND d.source IS NOT \(currentSource("a"))
        \(order)
        LIMIT ?
        """
    }

    /// One still, by its key (binds the root and the path), when it is owed a description by
    /// the walk's rule: a seek of its own row, for the stills a change named
    /// (`CatalogStore.photoDescriptionCandidatesByKey(of:excluding:lane:)`).
    static let keyedCandidateSQL = """
    SELECT a.best_capture_local, a.library_root_id, a.relative_path, a.preview_path, a.edit_recipe_json,
           a.rendered_revision, \(currentSource("a")) AS source
    FROM media_asset AS a
    LEFT JOIN photo_description AS d INDEXED BY \(sourceIndexName)
        ON d.library_root_id = a.library_root_id AND d.relative_path = a.relative_path
    WHERE a.library_root_id = ? AND a.relative_path = ?
      AND \(describableStill)
      AND d.source IS NOT \(currentSource("a"))
    """

    /// One asset's current description row, by its key: the text (NULL when declined), or no
    /// row while one is owed.
    static let currentRowSQL = """
    SELECT d.text FROM photo_description AS d
    JOIN media_asset AS a ON a.library_root_id = d.library_root_id AND a.relative_path = d.relative_path
    WHERE d.library_root_id = ? AND d.relative_path = ?
      AND d.source = \(currentSource("a"))
    """

    /// The faces of one still, with their people, by the face table's key.
    static let facesSQL = """
    SELECT f.box_x, f.box_y, f.box_width, f.box_height, p.name, p.birthday, IFNULL(p.is_hidden, 0) AS hidden
    FROM face AS f LEFT JOIN person AS p ON p.id = f.person_id
    WHERE f.library_root_id = ? AND f.relative_path = ? AND f.is_not_face = 0 AND f.frame_index IS NULL
    ORDER BY f.face_index
    """

    /// One still's capture time, place names and current readings, by the asset's key: a text
    /// or search row read from an earlier preview or thumbnail is no reading of this still.
    static let readingsSQL = """
    SELECT a.best_capture_local, pc.town, pc.country, t.lines, e.confident_labels
    FROM media_asset AS a
    LEFT JOIN asset_metadata AS pm
      ON pm.library_root_id = a.library_root_id AND pm.relative_path = a.relative_path
    LEFT JOIN place_cell AS pc
      ON pc.cell_latitude = pm.place_cell_latitude AND pc.cell_longitude = pm.place_cell_longitude
    LEFT JOIN search_text AS t
      ON t.library_root_id = a.library_root_id AND t.relative_path = a.relative_path
      AND t.source = \(SearchTextStorage.currentSource("a"))
    LEFT JOIN search_embedding AS e
      ON e.library_root_id = a.library_root_id AND e.relative_path = a.relative_path
      AND e.source = \(SearchEmbeddingStorage.currentSource("a"))
    WHERE a.library_root_id = ? AND a.relative_path = ?
    """
}

/// A still owed a description, with what reading its preview needs: the preview, and the edit
/// it shows, through which its faces are placed on it.
nonisolated struct PhotoDescriptionCandidate: Equatable, Sendable {
    let id: MediaAssetID
    let previewPath: String
    let source: String
    let recipe: EditRecipe
    let facts: PhotoDescriptionFacts
}

/// What the model is told about a still, beside its preview (ADR 0053).
nonisolated struct PhotoDescriptionFacts: Equatable, Sendable {
    /// One face of the photo, on the upright photo (fractions from the top-left corner).
    nonisolated struct Face: Equatable, Sendable {
        let box: CGRect
        /// The person's name; nil for a face given to no one, to an unnamed person, or to a
        /// hidden one, whom the description never names.
        let name: String?
        let birthday: PersonBirthday?
    }

    var faces: [Face]
    var capturedAt: CaptureLocalTime?
    var town: String?
    var country: String?
    /// The lines a person reads as the photo's text (`SearchTextReading.shown`).
    var textLines: [String]
    /// Vision's confident scene labels, as identifiers.
    var labels: [String]
}

/// What one request came to, for one candidate.
nonisolated struct PhotoDescriptionResult: Equatable, Sendable {
    let id: MediaAssetID
    let source: String
    /// The description; nil when the model declined.
    let text: String?
}

/// The Info pane's view of a still's description.
nonisolated enum PhotoDescriptionReading: Equatable, Sendable {
    case written(String)
    /// The model declined to describe these facts.
    case declined
}
