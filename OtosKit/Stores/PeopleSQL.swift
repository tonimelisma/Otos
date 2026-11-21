import GRDB

/// People SQL guide (ADR 0047)
///
/// The statements of the People tables: `face` (one row per face a reading found, keyed by its
/// photo's `AssetKey` and its place in the reading), `face_rejection` (a person the user said a
/// face is not), `face_embedding`'s reads, `person`, and `person_summary` (the gallery's
/// facts). `CatalogStore` owns when each runs and what it announces; this enum owns only the
/// text. A face's vector row is `FaceEmbeddingSQL`'s, and what a stored preview owes its faces
/// is `PreviewFaceSQL`'s.
nonisolated enum PeopleSQL {
    static let holdsFaceSQL = "SELECT EXISTS (SELECT 1 FROM face WHERE \(AssetKey.exactText()))"

    static let facesReadSQL = """
    SELECT m.faces_source_size IS NOT NULL AS is_read,
        (SELECT COUNT(*) FROM face AS f
         WHERE f.library_root_id = m.library_root_id AND f.relative_path = m.relative_path
           AND f.is_not_face = 0) AS faces
    FROM media_asset AS m WHERE \(AssetKey.exactText("m"))
    """

    static let photoFaceBoxesSQL = """
    SELECT box_x, box_y, box_width, box_height, landmarks, quality, vector.embedding
    FROM face \(FaceEmbeddingSQL.join(face: "face", embedding: "vector"))
    WHERE \(AssetKey.exactText("face"))
    ORDER BY face.face_index
    """

    /// Every stored face, the ones People sets aside among them (`PeopleFaceColumn.isSetAside`).
    static let peopleFacesSQL = """
    SELECT \(PeopleFaceColumn.selectList)
    FROM face f
    JOIN media_asset m ON m.library_root_id = f.library_root_id AND m.relative_path = f.relative_path
    \(FaceEmbeddingSQL.join(face: "f", embedding: "e"))
    """

    /// Whether a face of the photo (bound) is a person's gallery cover (`idx_person_summary_cover`).
    /// A new reading replaces the photo's face rows, and deleting the cover's row clears it.
    static let holdsCoverSQL = """
    SELECT EXISTS (SELECT 1 FROM person_summary WHERE cover_library_root_id = ? AND cover_relative_path = ?)
    """

    static let peopleFacesOfPhotoSQL = peopleFacesSQL + "\nWHERE \(AssetKey.exactText("f"))\nORDER BY f.face_index"

    static let writePersonSummarySQL = """
    INSERT INTO person_summary
        (person_id, photos, videos, cover_library_root_id, cover_relative_path, cover_face_index)
    SELECT p.id, ?, ?, f.library_root_id, f.relative_path, f.face_index
    FROM person p
    LEFT JOIN face f ON \(AssetKey.exactText("f")) AND f.face_index = ?
    WHERE p.id = ?
    ON CONFLICT(person_id) DO UPDATE SET
        photos = excluded.photos, videos = excluded.videos,
        cover_library_root_id = excluded.cover_library_root_id,
        cover_relative_path = excluded.cover_relative_path,
        cover_face_index = excluded.cover_face_index
    """

    static let photoFacesOfPhotoSQL = """
    SELECT \(FaceTileColumn.selectList(face: "f", asset: "m")), f.person_id
    FROM face f
    JOIN media_asset m ON m.library_root_id = f.library_root_id AND m.relative_path = f.relative_path
    LEFT JOIN person p ON p.id = f.person_id
    WHERE \(AssetKey.exactText("f"))
      AND f.is_not_face = 0 AND m.trash_path IS NULL AND NOT \(LivePhotoSQL.isPairedMotion("m"))
      AND (p.id IS NULL OR p.is_hidden = 0)
    ORDER BY f.face_index
    """

    static let lapseFaceSQL = """
    UPDATE face SET person_id = NULL, assignment = ?, is_key_photo = 0
    WHERE \(AssetKey.exactText()) AND face_index = ?
      AND assignment = ? AND person_id = ?
    """

    static let guessableAssignmentSQL = "assignment IN \(FaceAssignmentColumn.sqlList { $0.isGuessable })"

    static let seedFaceSQL = """
    UPDATE face SET person_id = ?, assignment = ?, is_key_photo = 0
    WHERE \(AssetKey.exactText()) AND face_index = ? AND is_not_face = 0 AND \(guessableAssignmentSQL)
    """

    static let guessFaceSQL = """
    UPDATE face SET person_id = ?, assignment = ?,
        is_key_photo = CASE WHEN person_id IS ? THEN is_key_photo ELSE 0 END
    WHERE \(AssetKey.exactText()) AND face_index = ? AND is_not_face = 0 AND \(guessableAssignmentSQL)
      AND (? IS NULL OR EXISTS (SELECT 1 FROM person WHERE id = ?))
    """

    static let faceLikenessSQL = "UPDATE face SET likeness = ? WHERE \(AssetKey.exactText()) AND face_index = ?"

    static let rejectFaceNameSQL = """
    INSERT OR IGNORE INTO face_rejection (library_root_id, relative_path, face_index, person_id)
    SELECT library_root_id, relative_path, face_index, person_id FROM face
    WHERE \(AssetKey.exactText()) AND face_index = ? AND person_id IS NOT NULL
    """

    static let markNotAFaceSQL = "UPDATE face SET is_not_face = 1 WHERE \(AssetKey.exactText()) AND face_index = ?"

    static let facePersonSQL = "SELECT person_id FROM face WHERE \(AssetKey.exactText()) AND face_index = ?"

    static let setKeyPhotoSQL = "UPDATE face SET is_key_photo = 1 WHERE \(AssetKey.exactText()) AND face_index = ?"

    static let restoreFaceSQL = """
    UPDATE face SET person_id = ?, assignment = ?, is_not_face = ?, is_key_photo = ?
    WHERE \(AssetKey.exactText()) AND face_index = ?
    """

    static let restoreRejectionSQL = """
    INSERT OR IGNORE INTO face_rejection (library_root_id, relative_path, face_index, person_id)
    SELECT ?, ?, ?, ? WHERE EXISTS (
        SELECT 1 FROM face WHERE \(AssetKey.exactText()) AND face_index = ?
    ) AND EXISTS (SELECT 1 FROM person WHERE id = ?)
    """

    static let otherAssignmentsInPhotoSQL = """
    SELECT assignment FROM face WHERE \(AssetKey.exactText())
      AND person_id = ? AND face_index <> ?
    """

    static let clearOtherFacesOfPersonSQL = """
    UPDATE face SET person_id = NULL, assignment = \(FaceAssignmentColumn.open.rawValue), is_key_photo = 0
    WHERE \(AssetKey.exactText()) AND person_id = ? AND face_index <> ?
    """

    static let deleteFaceRejectionSQL = """
    DELETE FROM face_rejection WHERE \(AssetKey.exactText())
      AND face_index = ? AND person_id = ?
    """

    static let setFaceSQL = """
    UPDATE face SET is_key_photo = CASE WHEN person_id IS ? THEN is_key_photo ELSE 0 END,
        person_id = ?, assignment = ?
    WHERE \(AssetKey.exactText()) AND face_index = ?
    """

    static let facesOfPhotoSQL = "SELECT library_root_id, relative_path, face_index FROM face WHERE \(AssetKey.exactText())"

    static let faceRestoreRecordSQL = """
    SELECT person_id, assignment, is_not_face, is_key_photo FROM face
    WHERE \(AssetKey.exactText()) AND face_index = ?
    """

    static let faceRejectionPeopleSQL = "SELECT person_id FROM face_rejection WHERE \(AssetKey.exactText()) AND face_index = ?"

    static let deleteFaceRejectionsSQL = "DELETE FROM face_rejection WHERE \(AssetKey.exactText()) AND face_index = ?"

    static let storedFacesSQL = """
    SELECT face.face_index, box_x, box_y, box_width, box_height, landmarks, quality, analysis_revision,
           vector.embedding, person_id, assignment, is_key_photo, is_not_face
    FROM face \(FaceEmbeddingSQL.join(face: "face", embedding: "vector"))
    WHERE \(AssetKey.exactText("face")) ORDER BY face.face_index
    """

    static let faceRejectionsOfPhotoSQL = "SELECT face_index, person_id FROM face_rejection WHERE \(AssetKey.exactText())"

    static let deleteFacesOfPhotoSQL = "DELETE FROM face WHERE \(AssetKey.exactText())"

    static let allFaceRejectionsSQL = "SELECT library_root_id, relative_path, face_index, person_id FROM face_rejection"

    static let keyPhotosSQL = """
    SELECT f.person_id, f.library_root_id, f.relative_path, f.face_index
    FROM face f INDEXED BY idx_face_key_photo
    JOIN media_asset m ON m.library_root_id = f.library_root_id AND m.relative_path = f.relative_path
    WHERE f.is_key_photo = 1 AND f.person_id IS NOT NULL AND f.is_not_face = 0
      AND m.trash_path IS NULL AND NOT \(LivePhotoSQL.isPairedMotion("m"))
    """

    static let allPeopleSQL = "SELECT id, name, birthday, is_hidden, is_favorite FROM person ORDER BY id"

    static let vectorHorizonSQL = "SELECT max(id) FROM face_embedding"

    static let personSummariesSQL = """
    SELECT person_id, photos, videos, cover_library_root_id, cover_relative_path, cover_face_index
    FROM person_summary
    """

    static let embeddingsAfterSQL = "SELECT id, embedding FROM face_embedding WHERE id > ? ORDER BY id LIMIT ?"

    static let settledAssignmentInputsSQL = "SELECT inputs FROM \(CatalogSchema.settledPeopleAssignmentTable)"

    static let writeSettledAssignmentInputsSQL = """
    INSERT INTO \(CatalogSchema.settledPeopleAssignmentTable) (id, inputs) VALUES (0, ?)
    ON CONFLICT(id) DO UPDATE SET inputs = excluded.inputs
    """

    static let photoFaceTilesSQL = """
    SELECT \(FaceTileColumn.selectList(face: "f", asset: "m")),
           CASE WHEN m.has_copies = 1 THEN m.copy_key END,
           CASE WHEN m.best_kind IN ('raw', 'image') THEN m.burst_identifier END
    FROM face f INDEXED BY idx_face_person_photo
    JOIN media_asset m ON m.library_root_id = f.library_root_id AND m.relative_path = f.relative_path
    WHERE f.person_id = ? AND f.is_not_face = 0
      AND m.trash_path IS NULL AND NOT \(LivePhotoSQL.isPairedMotion("m"))
    """

    static let deletePersonSQL = "DELETE FROM person WHERE id = ?"

    static let deleteEmptyPersonSQL = """
    DELETE FROM person WHERE id = ? AND name IS NULL AND birthday IS NULL
      AND is_hidden = 0 AND is_favorite = 0
      AND NOT EXISTS (SELECT 1 FROM face WHERE person_id = ?)
    """

    static let peopleNamedSQL = "SELECT COUNT(*) FROM person WHERE name = ?"

    static let setPersonHiddenSQL = "UPDATE person SET is_hidden = ? WHERE id = ?"

    static let setPersonFavoriteSQL = "UPDATE person SET is_favorite = ? WHERE id = ?"

    static let clearKeyPhotosOfPersonSQL = "UPDATE face SET is_key_photo = 0 WHERE person_id = ?"

    static let restorePersonSQL = """
    INSERT INTO person (id, name, birthday, is_hidden, is_favorite) VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET name = excluded.name, birthday = excluded.birthday,
        is_hidden = excluded.is_hidden, is_favorite = excluded.is_favorite
    """

    static let insertPersonSQL = "INSERT INTO person (name, birthday) VALUES (?, ?)"

    static let otherPeopleNamedSQL = "SELECT COUNT(*) FROM person WHERE name = ? AND id <> ?"

    static let setPersonNameAndBirthdaySQL = "UPDATE person SET name = ?, birthday = ? WHERE id = ?"

    static let personBirthdaySQL = "SELECT birthday FROM person WHERE id = ?"

    static let personSQL = "SELECT * FROM person WHERE id = ?"

    static let demoteAnchorsToSeedsSQL = """
    UPDATE face SET assignment = \(FaceAssignmentColumn.seed.rawValue)
    WHERE person_id = ? AND assignment = \(FaceAssignmentColumn.model.rawValue)
    """

    static let openGuessesOfPersonSQL = """
    UPDATE face SET person_id = NULL, assignment = \(FaceAssignmentColumn.open.rawValue), is_key_photo = 0
    WHERE assignment = \(FaceAssignmentColumn.model.rawValue) AND person_id IN (?, ?) AND EXISTS (
        SELECT 1 FROM face other WHERE other.library_root_id = face.library_root_id
          AND other.relative_path = face.relative_path AND other.face_index <> face.face_index
          AND other.person_id IN (?, ?) AND other.person_id <> face.person_id
    )
    """

    static let keyPhotoCountSQL = "SELECT COUNT(*) FROM face WHERE person_id = ? AND is_key_photo = 1"

    static let movePersonFacesSQL = "UPDATE face SET person_id = ? WHERE person_id = ?"

    /// A merge's rejections (bound: the person merged into, the person merged away, the person
    /// merged into): what the user said a face is not carries to the merged person, except onto
    /// a face that is theirs, which the user gave them, and the merge says the two are one.
    static let moveRejectionsSQL = """
    INSERT OR IGNORE INTO face_rejection (library_root_id, relative_path, face_index, person_id)
    SELECT r.library_root_id, r.relative_path, r.face_index, ? FROM face_rejection r
    WHERE r.person_id = ? AND NOT EXISTS (
        SELECT 1 FROM face f WHERE f.library_root_id = r.library_root_id AND f.relative_path = r.relative_path
          AND f.face_index = r.face_index AND f.person_id = ?
    )
    """

    static let setMergedPersonSQL = "UPDATE person SET name = ?, birthday = ?, is_favorite = ? WHERE id = ?"

    static let facesOfPersonSQL = "SELECT library_root_id, relative_path, face_index FROM face WHERE person_id = ?"

    static let keyPhotosOfPersonSQL = "SELECT library_root_id, relative_path, face_index FROM face WHERE person_id = ? AND is_key_photo = 1"

    static let rejectionsOfPersonSQL = "SELECT library_root_id, relative_path, face_index FROM face_rejection WHERE person_id = ?"

    static let deleteRejectionsOfPersonSQL = "DELETE FROM face_rejection WHERE person_id = ?"

    static let namedVisiblePeopleSQL = "SELECT id, name FROM person WHERE name IS NOT NULL AND name <> '' AND is_hidden = 0"

    /// The faces the user gave or Otos seeded: what defines a person.
    static let anchorAssignmentsSQL = FaceAssignmentColumn.sqlList { $0.isAnchor }

    /// The photos where both people (bound in order) have a defining face.
    static let photosAnchoringBothSQL = """
    SELECT DISTINCT a.library_root_id, a.relative_path FROM face a JOIN face b
      ON a.library_root_id = b.library_root_id AND a.relative_path = b.relative_path
    WHERE a.person_id = ? AND b.person_id = ? AND a.assignment IN \(anchorAssignmentsSQL) AND b.assignment IN \(anchorAssignmentsSQL)
    """

    /// The defining faces of either of two people (bound), with their capture and vector.
    static let definingFacesOfEitherSQL = """
    SELECT f.library_root_id, f.relative_path, f.face_index, f.person_id, f.assignment,
           m.best_capture_local, e.embedding
    FROM face f
    JOIN media_asset m ON m.library_root_id = f.library_root_id AND m.relative_path = f.relative_path
    \(FaceEmbeddingSQL.join(face: "f", embedding: "e"))
    WHERE f.person_id IN (?, ?) AND f.assignment IN \(anchorAssignmentsSQL)
    """

    /// The faces of `people` people (bound, then the birthday) in photos taken before it.
    private static func facesBeforeBirthday(people: Int) -> String {
        """
        FROM face f
        JOIN media_asset m ON m.library_root_id = f.library_root_id AND m.relative_path = f.relative_path
        WHERE f.person_id IN (\(Array(repeating: "?", count: people).joined(separator: ", "))) AND m.best_capture_local < ?
        """
    }

    /// The photos before the birthday where the user gave one of the people a face.
    static func confirmedBeforeBirthdaySQL(people: Int) -> String {
        """
        SELECT DISTINCT f.library_root_id, f.relative_path, m.best_kind = 'video'
        \(facesBeforeBirthday(people: people)) AND f.assignment = \(FaceAssignmentColumn.user.rawValue)
        """
    }

    /// Opens every face of the people from before the birthday.
    static func openFacesBeforeBirthdaySQL(people: Int) -> String {
        """
        UPDATE face SET person_id = NULL, assignment = \(FaceAssignmentColumn.open.rawValue), is_key_photo = 0
        WHERE (library_root_id, relative_path, face_index) IN (
            SELECT f.library_root_id, f.relative_path, f.face_index \(facesBeforeBirthday(people: people))
        )
        """
    }

    static let insertFaceSQL = """
    INSERT INTO face (
        library_root_id, relative_path, face_index, box_x, box_y, box_width, box_height,
        landmarks, quality, analysis_revision, frame_index, person_id, assignment, is_key_photo,
        is_not_face
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """

    static let insertFaceRejectionSQL = """
    INSERT INTO face_rejection (library_root_id, relative_path, face_index, person_id)
    VALUES (?, ?, ?, ?)
    """
}
