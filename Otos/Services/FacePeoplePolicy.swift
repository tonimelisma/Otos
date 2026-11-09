import Accelerate
import Foundation

/// One face, as grouping reads it: where it is, when it was taken, its embedding, and what
/// the user has decided about it (ADR 0047).
nonisolated struct FaceFact: Sendable, Equatable {
    let id: FaceID
    /// The photo's capture instant, seconds since 1970; nil when the photo has no date.
    let captureSeconds: Double?
    /// Unit length, `FaceEmbeddingModel.dimensions` values.
    let embedding: [Float]
    let person: PersonID?
    let isNotFace: Bool
    let isIgnored: Bool
    let rejected: Set<PersonID>
}

/// One face of one photo: the photo's identity and the face's place in its reading.
nonisolated struct FaceID: Hashable, Sendable {
    let asset: MediaAssetID
    let index: Int
}

/// A person row's identity in the catalog. Not an asset identity: a person is the set of
/// their confirmed faces (ADR 0047).
nonisolated struct PersonID: Hashable, Sendable, Comparable {
    let rawValue: Int64

    static func < (lhs: PersonID, rhs: PersonID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

nonisolated struct PersonFact: Sendable, Equatable {
    let id: PersonID
    /// Midnight UTC of the birthday, seconds since 1970; a face captured before it is never
    /// this person's.
    let birthdaySeconds: Double?
}

/// What grouping offers the user (ADR 0047, `docs/design/people.md`).
nonisolated struct PeopleSuggestions: Sendable, Equatable {
    /// One person clearly wins: `similarity` to `reference`, the confirmed face it rests on.
    struct Suggestion: Sendable, Equatable {
        let face: FaceID
        let person: PersonID
        let reference: FaceID
        let similarity: Float
    }

    /// The best person reaches the threshold but the runner-up is within the margin: no
    /// answer is suggested, and the user decides between `first` and `second`.
    struct Unsure: Sendable, Equatable {
        let face: FaceID
        let first: PersonID
        let second: PersonID
    }

    let suggestions: [Suggestion]
    let unsure: [Unsure]
    /// Faces matching no person, grouped among themselves; each group spans two or more days.
    let unnamedGroups: [[FaceID]]
}

/// Face people policy guide
///
/// Decides, from the faces and people the catalog holds, what grouping suggests (ADR 0047).
/// Pure: the same facts always give the same suggestions, so it runs off every actor and is
/// tested without a catalog.
///
/// The rules and values were measured on the owner's labelled faces with the shipped model
/// (`docs/research/2026-11-07-face-recognition-models.md`, section 8):
/// - **A suggestion:** an unconfirmed face is compared with each person's confirmed faces
///   taken within `window` of it. The best person's best similarity must reach `threshold`
///   and beat the runner-up's by `margin`. Measured: from one confirmed year per child, every
///   one of the three children's 744 faces is reached by chaining, with 9 wrong suggestions
///   out of 521 (each rejected once by the user).
/// - **Unsure:** the best person reaches `threshold`, the runner-up is within `margin`.
/// - **Hard rules:** a person never gets a face from a photo where they are already confirmed,
///   a face from before their birthday, or a face the user rejected for them.
/// - **Unnamed groups:** the faces left are linked when their similarity reaches
///   `groupLink`, strongest first, never two faces of one photo; a group is offered only when
///   its faces span two or more days. Measured: 100 groups holding 1,988 faces, none wrong.
///   Lower links chain different people together (238 wrong faces at 0.60).
nonisolated enum FacePeoplePolicy {
    static let threshold: Float = 0.434
    static let margin: Float = 0.08
    static let groupLink: Float = 0.65
    /// Two years, in seconds.
    static let window: Double = 2 * 365.2425 * 86400
    /// Rows compared at once, which bounds the similarity block in memory.
    static let blockRows = 512

    static func suggestions(faces: [FaceFact], people: [PersonFact]) -> PeopleSuggestions {
        let usable = faces.filter { !$0.isNotFace }
        let confirmed = usable.filter { $0.person != nil }
        let open = usable.filter { $0.person == nil && !$0.isIgnored }
        let birthdays = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.birthdaySeconds) })
        var confirmedPhotos: [PersonID: Set<MediaAssetID>] = [:]
        for face in confirmed {
            if let person = face.person {
                confirmedPhotos[person, default: []].insert(face.id.asset)
            }
        }

        var suggestions: [PeopleSuggestions.Suggestion] = []
        var unsure: [PeopleSuggestions.Unsure] = []
        var leftover: [FaceFact] = []
        BlockedSimilarity(rows: open, columns: confirmed).forEachBlock { rows, values in
            for row in rows {
                let face = open[row]
                let offset = (row - rows.lowerBound) * confirmed.count
                var best: [PersonID: (similarity: Float, reference: FaceID)] = [:]
                for (column, candidate) in confirmed.enumerated() {
                    guard let person = candidate.person, birthdays.keys.contains(person),
                          !face.rejected.contains(person),
                          !(confirmedPhotos[person]?.contains(face.id.asset) ?? false),
                          within(face.captureSeconds, candidate.captureSeconds),
                          notBeforeBirthday(face.captureSeconds, birthdays[person] ?? nil)
                    else { continue }
                    let similarity = values[offset + column]
                    if similarity > best[person]?.similarity ?? -2 {
                        best[person] = (similarity, candidate.id)
                    }
                }
                let ranked = best.sorted { ($0.value.similarity, $1.key) > ($1.value.similarity, $0.key) }
                guard let top = ranked.first, top.value.similarity >= threshold else {
                    leftover.append(face)
                    continue
                }
                if let runnerUp = ranked.dropFirst().first, top.value.similarity - runnerUp.value.similarity < margin {
                    unsure.append(.init(face: face.id, first: top.key, second: runnerUp.key))
                } else {
                    suggestions.append(.init(
                        face: face.id, person: top.key, reference: top.value.reference, similarity: top.value.similarity
                    ))
                }
            }
        }
        return PeopleSuggestions(suggestions: suggestions, unsure: unsure, unnamedGroups: unnamedGroups(leftover))
    }

    /// The leftover faces linked strongest first at `groupLink` or above, never joining two
    /// faces of one photo, keeping groups that span two or more days.
    static func unnamedGroups(_ faces: [FaceFact]) -> [[FaceID]] {
        var links: [(similarity: Float, a: Int, b: Int)] = []
        BlockedSimilarity(rows: faces, columns: faces).forEachBlock { rows, values in
            for row in rows {
                let offset = (row - rows.lowerBound) * faces.count
                for column in (row + 1) ..< faces.count where values[offset + column] >= groupLink
                    && faces[row].id.asset != faces[column].id.asset
                {
                    links.append((values[offset + column], row, column))
                }
            }
        }
        var root = Array(faces.indices)
        var photos = faces.map { Set([$0.id.asset]) }
        func find(_ x: Int) -> Int {
            var x = x
            while root[x] != x {
                root[x] = root[root[x]]
                x = root[x]
            }
            return x
        }
        for link in links.sorted(by: { ($0.similarity, $1.a, $1.b) > ($1.similarity, $0.a, $0.b) }) {
            let a = find(link.a), b = find(link.b)
            guard a != b, photos[a].isDisjoint(with: photos[b]) else { continue }
            let (into, from) = photos[a].count >= photos[b].count ? (a, b) : (b, a)
            root[from] = into
            photos[into].formUnion(photos[from])
            photos[from] = []
        }
        var groups: [Int: [Int]] = [:]
        for index in faces.indices {
            groups[find(index), default: []].append(index)
        }
        return groups.values
            .filter { members in Set(members.compactMap { day(faces[$0].captureSeconds) }).count >= 2 }
            .map { $0.map { faces[$0].id } }
            .sorted { ($0.count, $1.first?.asset.relativePath.rawValue ?? "") > ($1.count, $0.first?.asset.relativePath.rawValue ?? "") }
    }

    /// Whether two capture instants are within `window`; a face without a date is compared
    /// with every face.
    static func within(_ a: Double?, _ b: Double?) -> Bool {
        guard let a, let b else { return true }
        return abs(a - b) <= window
    }

    static func notBeforeBirthday(_ capture: Double?, _ birthday: Double?) -> Bool {
        guard let capture, let birthday else { return true }
        return capture >= birthday
    }

    /// The calendar day of a capture instant, UTC; nil without a date.
    static func day(_ seconds: Double?) -> Int? {
        seconds.map { Int(($0 / 86400).rounded(.down)) }
    }
}

/// Cosine similarities of `rows` against `columns`, unit-length embeddings, computed with
/// Accelerate one block of rows at a time so a large library never holds the whole matrix.
private nonisolated struct BlockedSimilarity {
    let rowMatrix: [Float]
    let columnsTransposed: [Float]
    let rowCount: Int
    let columnCount: Int
    static let dimensions = FaceEmbeddingModel.dimensions

    init(rows: [FaceFact], columns: [FaceFact]) {
        rowCount = rows.count
        columnCount = columns.count
        rowMatrix = rows.flatMap(\.embedding)
        var transposed = [Float](repeating: 0, count: columns.count * Self.dimensions)
        let flat = columns.flatMap(\.embedding)
        if !columns.isEmpty {
            vDSP_mtrans(flat, 1, &transposed, 1, vDSP_Length(Self.dimensions), vDSP_Length(columns.count))
        }
        columnsTransposed = transposed
    }

    /// Calls `body(rows, values)` for each block of at most `FacePeoplePolicy.blockRows` rows,
    /// in order; `values` holds those rows' similarities to every column, row-major. Every
    /// row is visited even with no columns, when `values` is empty: a library with nobody
    /// confirmed still has faces to group.
    func forEachBlock(_ body: (Range<Int>, [Float]) -> Void) {
        guard rowCount > 0 else { return }
        var start = 0
        while start < rowCount {
            let count = min(FacePeoplePolicy.blockRows, rowCount - start)
            body(start ..< start + count, products(start: start, count: count))
            start += count
        }
    }

    private func products(start: Int, count: Int) -> [Float] {
        guard columnCount > 0 else { return [] }
        var out = [Float](repeating: 0, count: count * columnCount)
        rowMatrix.withUnsafeBufferPointer { rows in
            columnsTransposed.withUnsafeBufferPointer { columns in
                guard let rowBase = rows.baseAddress, let columnBase = columns.baseAddress else { return }
                vDSP_mmul(
                    rowBase + start * Self.dimensions, 1,
                    columnBase, 1,
                    &out, 1,
                    vDSP_Length(count), vDSP_Length(columnCount), vDSP_Length(Self.dimensions)
                )
            }
        }
        return out
    }
}
