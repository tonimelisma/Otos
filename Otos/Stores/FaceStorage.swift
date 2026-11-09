import CoreGraphics
import Foundation
import GRDB

/// The byte form of a face's vectors in the catalog's `face` table (ADR 0047): little-endian
/// Float32, so a catalog reads the same on any machine. An embedding is
/// `FaceEmbeddingModel.dimensions` values; the landmarks are five (x, y) pairs.
nonisolated enum FaceStorage {
    static func embeddingData(_ embedding: [Float]) -> Data {
        floatData(embedding)
    }

    /// Nil unless `data` holds exactly one embedding.
    static func embedding(from data: Data) -> [Float]? {
        guard data.count == FaceEmbeddingModel.dimensions * 4 else { return nil }
        return floats(from: data)
    }

    static func landmarksData(_ points: [CGPoint]) -> Data {
        floatData(points.flatMap { [Float($0.x), Float($0.y)] })
    }

    /// Nil unless `data` holds exactly five points.
    static func landmarks(from data: Data) -> [CGPoint]? {
        guard data.count == 5 * 2 * 4 else { return nil }
        let values = floats(from: data)
        return stride(from: 0, to: values.count, by: 2).map { CGPoint(x: Double(values[$0]), y: Double(values[$0 + 1])) }
    }

    private static func floatData(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * 4)
        for value in values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func floats(from data: Data) -> [Float] {
        stride(from: 0, to: data.count, by: 4).map { offset in
            let bits = data[data.startIndex + offset ..< data.startIndex + offset + 4]
                .enumerated()
                .reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
            return Float(bitPattern: bits)
        }
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

/// A person's birthday as the catalog stores it, `YYYY-MM-DD`.
nonisolated enum PersonBirthday {
    /// Midnight UTC of the day, seconds since 1970; nil unless the text is a valid date.
    static func seconds(_ text: String) -> Double? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else { return nil }
        return date.timeIntervalSince1970
    }
}

/// An act on faces or people that ADR 0047's hard rules refuse.
nonisolated enum PeopleRuleViolation: Error, Equatable {
    /// Two of the faces are in one photo, and one person is in a photo once.
    case twoFacesOfOnePhoto
    /// The person is already confirmed in the photo.
    case personAlreadyInPhoto
    /// The photo was taken before the person's birthday.
    case beforeBirthday
    /// `count` confirmed photos of the person predate the birthday.
    case confirmedBeforeBirthday(count: Int)
    /// The two people are both confirmed in `count` photos.
    case bothInPhotos(count: Int)
    /// The face's library is not cataloged.
    case unknownFace
}

/// An Immich still whose faces are owed from its stored preview (ADR 0047): the preview's
/// file under the thumbnail directory, and the source stamp it was made for.
nonisolated struct PreviewFaceCandidate: Equatable, Sendable {
    let id: MediaAssetID
    let previewPath: String
    let sourceSize: Int64?
    let sourceMTimeSeconds: Int?
}

/// The faces read from one candidate's preview; none when the preview does not decode, which
/// is recorded so the row is not offered again until a new preview arrives.
nonisolated struct PreviewFaceResult: Equatable, Sendable {
    let candidate: PreviewFaceCandidate
    let faces: EnrichedFaces
}
