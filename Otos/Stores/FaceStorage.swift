import CoreGraphics
import Foundation
import GRDB

/// The byte form of a face's vectors in the catalog's `face` table (ADR 0047), in
/// `Float32Storage`'s form. An embedding is `FaceEmbeddingModel.dimensions` values; the
/// landmarks are five (x, y) pairs.
nonisolated enum FaceStorage {
    static func embeddingData(_ embedding: FaceEmbedding) -> Data {
        Float32Storage.data(embedding.values)
    }

    /// Nil unless `data` holds exactly one embedding, still unit length.
    static func embedding(from data: Data) -> FaceEmbedding? {
        Float32Storage.floats(from: data, count: FaceEmbeddingModel.dimensions).flatMap(FaceEmbedding.init(stored:))
    }

    static func landmarksData(_ landmarks: FaceAlignment.Landmarks) -> Data {
        Float32Storage.data(landmarks.points.flatMap { [Float($0.x), Float($0.y)] })
    }

    /// Nil unless `data` holds exactly five points.
    static func landmarks(from data: Data) -> FaceAlignment.Landmarks? {
        guard let values = Float32Storage.floats(from: data, count: 5 * 2) else { return nil }
        return FaceAlignment.Landmarks(points: stride(from: 0, to: values.count, by: 2).map {
            CGPoint(x: Double(values[$0]), y: Double(values[$0 + 1]))
        })
    }
}

/// Which face of a new reading each face of the previous reading of the same photo became
/// (ADR 0047): the user's acts — a confirmed person, an ignored group, rejections — move to
/// it, so reading a photo again never loses what the user decided. Faces are matched one to
/// one by the overlap of their boxes (intersection over union), the most overlapping pair
/// first; an overlap under `minimumOverlap` is a different face.
nonisolated enum FaceCarryOver {
    static let minimumOverlap = 0.5

    /// `[new index: previous index]`.
    static func matches(previous: [CGRect], new: [CGRect]) -> [Int: Int] {
        var pairs: [(overlap: Double, previous: Int, new: Int)] = []
        for (p, old) in previous.enumerated() {
            for (n, box) in new.enumerated() {
                let overlap = intersectionOverUnion(old, box)
                if overlap >= minimumOverlap {
                    pairs.append((overlap, p, n))
                }
            }
        }
        var result: [Int: Int] = [:], usedPrevious: Set<Int> = []
        for pair in pairs.sorted(by: { $0.overlap > $1.overlap })
            where result[pair.new] == nil && !usedPrevious.contains(pair.previous)
        {
            result[pair.new] = pair.previous
            usedPrevious.insert(pair.previous)
        }
        return result
    }

    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let shared = Double(intersection.width * intersection.height)
        let union = Double(a.width * a.height + b.width * b.height) - shared
        return union > 0 ? shared / union : 0
    }
}

/// A face row's key in the catalog: its library's row, the photo's path, its place in the
/// reading.
nonisolated struct FaceRowKey: Hashable {
    let rootID: Int64
    let path: MediaRelativePath
    let index: Int

    /// The photo the face is in.
    var photo: Photo {
        Photo(rootID: rootID, path: path)
    }

    struct Photo: Hashable {
        let rootID: Int64
        let path: MediaRelativePath
    }

    init(_ row: Row) {
        rootID = row["library_root_id"]
        path = MediaRelativePath(rawValue: row["relative_path"])
        index = row["face_index"]
    }

    init(rootID: Int64, path: MediaRelativePath, index: Int) {
        self.rootID = rootID
        self.path = path
        self.index = index
    }

    /// The key of `face`; throws when its library is not cataloged.
    init(_ face: FaceID, rowIDs: [LibraryRootPath: Int64]) throws {
        guard let rootID = rowIDs[face.asset.libraryRootPath] else {
            throw PeopleRuleViolation.unknownFace
        }
        self.rootID = rootID
        path = face.asset.relativePath
        index = face.index
    }
}

/// A person's birthday as the catalog stores it: `YYYY-MM-DD`, or `YYYY` when only the year
/// is known.
nonisolated enum PersonBirthday {
    /// Midnight UTC of the day, or of 1 January when only the year is known, seconds since
    /// 1970; nil unless the text is one of the two forms and a valid date. A year alone counts
    /// from its first day, so no face from that year is ever excluded by it.
    static func seconds(_ text: String) -> Double? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.allSatisfy({ $0 != nil }), parts.count == 1 || parts.count == 3,
              text.split(separator: "-").first?.count == 4
        else {
            return nil
        }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts.count == 3 ? parts[1] : 1
        components.day = parts.count == 3 ? parts[2] : 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else { return nil }
        return date.timeIntervalSince1970
    }

    /// Refuses a birthday that is neither form, so a mistyped one is never stored and
    /// silently ignored.
    static func validate(_ text: String?) throws {
        if let text, seconds(text) == nil {
            throw PeopleRuleViolation.invalidBirthday
        }
    }
}

/// `face.assignment` as the catalog stores it, beside `person_id` (ADR 0047).
nonisolated enum FaceAssignmentColumn: Int {
    case open = 0
    case model = 1
    case seed = 2
    case user = 3
    case held = 4

    init(_ assignment: FaceAssignment) {
        switch assignment {
        case .open: self = .open
        case .model: self = .model
        case .seed: self = .seed
        case .user: self = .user
        case .held: self = .held
        }
    }

    /// The assignment a stored row holds. A row with no person is open or held, whatever
    /// else its column says: deleting a person clears `person_id` under its faces.
    static func assignment(column: Int, person: Int64?) -> FaceAssignment {
        let kind = FaceAssignmentColumn(rawValue: column) ?? .open
        guard let person = person.map(PersonID.init(rawValue:)) else {
            return kind == .held ? .held : .open
        }
        return switch kind {
        case .open, .held: .open
        case .model: .model(person)
        case .seed: .seed(person)
        case .user: .user(person)
        }
    }
}

/// An act on faces or people that ADR 0047's hard rules refuse.
nonisolated enum PeopleRuleViolation: Error, Equatable {
    /// Two of the faces are in one photo, and one person is in a photo once.
    case twoFacesOfOnePhoto
    /// The user already gave another face of the photo to the person.
    case personAlreadyInPhoto
    /// The photo was taken before the person's birthday.
    case beforeBirthday
    /// `count` photos the user gave the person predate the birthday.
    case confirmedBeforeBirthday(count: Int)
    /// The user gave both people a face in `count` photos.
    case bothInPhotos(count: Int)
    /// Another person already has the name; merging them is the act.
    case nameTaken
    /// The face's library is not cataloged.
    case unknownFace
    /// A birthday that is neither `YYYY-MM-DD` nor `YYYY`.
    case invalidBirthday
}

/// A still whose faces are owed from its stored preview (ADR 0047): the preview's file under
/// the thumbnail directory, the source stamp it was made from, the edit revision it shows and
/// that edit, by which its faces are carried back onto the upright photo.
nonisolated struct PreviewFaceCandidate: Equatable, Sendable {
    let id: MediaAssetID
    let previewPath: String
    let sourceSize: Int64?
    let sourceMTimeSeconds: Int?
    let renderedRevision: Int64
    /// The edit the preview shows; neutral for a preview of the unedited photo.
    let recipe: EditRecipe
}

/// Where a page of preview face candidates ended: its last row, in catalog order.
nonisolated struct PreviewFaceCursor: Equatable, Sendable {
    let rootID: Int64
    let relativePath: String
}

/// One page of stills owed faces, and where the next page starts; no next page when this one
/// reached the end.
nonisolated struct PreviewFacePage: Equatable, Sendable {
    let candidates: [PreviewFaceCandidate]
    let next: PreviewFaceCursor?
}

/// Which stored preview a still has and what its faces are owed, as SQL over `media_asset`
/// (ADR 0047). The stored preview is Otos's rendering when it has one (ADR 0035), else the
/// source's own preview (an Immich preview, ADR 0046 §7).
/// The People snapshot's face columns, in `SELECT` order (`selectList`), so the snapshot
/// reads each by position and the list and the reads cannot disagree.
nonisolated enum PeopleFaceColumn: Int, CaseIterable {
    case rootID, path, faceIndex, embedding, personID, assignment, likeness, isKeyPhoto, isNotFace
    case boxX, boxY, boxWidth, boxHeight
    case captureLocal, previewPath, renderedRevision, editRecipeJSON, previewEditIsKnown
    case faceFramesPath, frameIndex, isVideo

    /// The expression each column is read from, over `face f` joined to `media_asset m`.
    var sql: String {
        switch self {
        case .rootID: "f.library_root_id"
        case .path: "f.relative_path"
        case .faceIndex: "f.face_index"
        case .embedding: "f.embedding"
        case .personID: "f.person_id"
        case .assignment: "f.assignment"
        case .likeness: "f.likeness"
        case .isKeyPhoto: "f.is_key_photo"
        case .isNotFace: "f.is_not_face"
        case .boxX: "f.box_x"
        case .boxY: "f.box_y"
        case .boxWidth: "f.box_width"
        case .boxHeight: "f.box_height"
        case .captureLocal: "m.best_capture_local"
        case .previewPath: "m.preview_path"
        case .renderedRevision: "m.rendered_revision"
        case .editRecipeJSON: "m.edit_recipe_json"
        case .previewEditIsKnown: PreviewFaceSQL.previewEditIsKnown
        case .faceFramesPath: "m.face_frames_path"
        case .frameIndex: "f.frame_index"
        case .isVideo: "m.best_kind = 'video'"
        }
    }

    static let selectList = allCases.map(\.sql).joined(separator: ", ")
}

nonisolated enum PreviewFaceSQL {
    /// The stamp of the source the stored preview was made from: the rendering's, else the
    /// source preview's. NULL when neither is known.
    static let previewSize = "CASE WHEN rendered_source_size IS NOT NULL THEN rendered_source_size ELSE source_products_size END"
    static let previewMTime = "CASE WHEN rendered_source_size IS NOT NULL THEN rendered_source_mtime ELSE source_products_mtime END"

    /// The stored preview's edit is known: revision 0, the unedited photo, or the edit the
    /// row holds now. Otherwise a rendering of the new edit is owed, and its faces wait for
    /// it rather than be read through an edit no longer stored.
    static let previewEditIsKnown = "(rendered_revision = 0 OR rendered_revision = edit_revision)"

    /// A still with a stored preview whose faces were not read from it: their stamp does not
    /// name that preview's source.
    static let owesFaces = """
    preview_path IS NOT NULL
      AND (\(previewSize)) IS NOT NULL
      AND (faces_source_size IS NOT (\(previewSize)) OR faces_source_mtime IS NOT (\(previewMTime)))
    """

    /// A still whose stored preview is still to come: no preview yet, and a rendering or a
    /// source preview still owed. A still rendered without a preview (QuickLook's thumbnail,
    /// a decoder that could not read it) is not waiting: it has no faces Otos can read.
    static let awaitsPreview = """
    preview_path IS NULL
      AND source_products_size IS NULL
      AND (\(EnrichmentClaimGateway.renderingStalenessSQLPredicate()))
    """
}

/// The faces read from one candidate's preview; none when the preview does not decode, which
/// is recorded so the row is not offered again until a new preview arrives.
nonisolated struct PreviewFaceResult: Equatable, Sendable {
    let candidate: PreviewFaceCandidate
    let faces: EnrichedFaces
}
