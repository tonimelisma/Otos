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
/// - **Unnamed groups:** each face left keeps its `groupLinks` strongest links that reach
///   `groupLink`; they are joined strongest first, never two faces of one photo, and a group
///   is offered only when its faces span two or more days. Measured: 102 groups holding 1,983
///   faces, none wrong. Lower links chain different people together (238 wrong faces at 0.60).
nonisolated enum FacePeoplePolicy {
    static let threshold: Float = 0.434
    static let margin: Float = 0.08
    static let groupLink: Float = 0.65
    /// The strongest links each face keeps for grouping. Measured on the owner's labels: 10,
    /// 20 or every link give the same groups (102, 1,983 faces, none wrong); fewer links make
    /// grouping cost proportional to the faces, not their pairs.
    static let groupLinks = 10
    /// Two years, in seconds.
    static let window: Double = 2 * 365.2425 * 86400
    /// Rows compared at once, which bounds the similarity block in memory.
    static let blockRows = 512

    static func suggestions(faces: [FaceFact], people: [PersonFact]) -> PeopleSuggestions {
        let usable = faces.filter { !$0.isNotFace }
        let open = usable.filter { $0.person == nil && !$0.isIgnored }
        let groups = PersonColumns.make(confirmed: usable.filter { $0.person != nil }, people: people)
        let columns = groups.flatMap(\.faces)

        var suggestions: [PeopleSuggestions.Suggestion] = []
        var unsure: [PeopleSuggestions.Unsure] = []
        var leftover: [FaceFact] = []
        BlockedSimilarity(rows: open, columns: columns).forEachBlock { rows, values in
            values.withUnsafeBufferPointer { buffer in
                for row in rows {
                    let face = open[row]
                    let rowStart = (row - rows.lowerBound) * columns.count
                    var ranked: [(person: PersonID, similarity: Float, reference: FaceID)] = []
                    for group in groups {
                        guard let best = group.best(for: face, row: buffer, rowStart: rowStart) else { continue }
                        ranked.append((group.person, best.similarity, columns[best.column].id))
                    }
                    ranked.sort { ($0.similarity, $1.person) > ($1.similarity, $0.person) }
                    guard let top = ranked.first, top.similarity >= threshold else {
                        leftover.append(face)
                        continue
                    }
                    if ranked.count > 1, top.similarity - ranked[1].similarity < margin {
                        unsure.append(.init(face: face.id, first: top.person, second: ranked[1].person))
                    } else {
                        suggestions.append(.init(
                            face: face.id, person: top.person, reference: top.reference, similarity: top.similarity
                        ))
                    }
                }
            }
        }
        return PeopleSuggestions(suggestions: suggestions, unsure: unsure, unnamedGroups: unnamedGroups(leftover))
    }

    /// The leftover faces linked strongest first at `groupLink` or above, never joining two
    /// faces of one photo, keeping groups that span two or more days.
    static func unnamedGroups(_ faces: [FaceFact]) -> [[FaceID]] {
        var links: [(similarity: Float, a: Int, b: Int)] = []
        var scratch = [Float](repeating: 0, count: faces.count)
        BlockedSimilarity(rows: faces, columns: faces).forEachBlock { rows, values in
            for row in rows {
                // A face's `groupLinks` strongest links, each found by one vectorised maximum
                // over the row; a found column is lowered out of the way, and so is the face
                // itself. Links to a face of the same photo are skipped, never counted.
                let offset = (row - rows.lowerBound) * faces.count
                scratch.replaceSubrange(0 ..< faces.count, with: values[offset ..< offset + faces.count])
                scratch[row] = -2
                var kept = 0
                while kept < groupLinks {
                    var value: Float = 0
                    var index: vDSP_Length = 0
                    vDSP_maxvi(scratch, 1, &value, &index, vDSP_Length(faces.count))
                    guard value >= groupLink else { break }
                    let column = Int(index)
                    scratch[column] = -2
                    guard faces[row].id.asset != faces[column].id.asset else { continue }
                    links.append((value, min(row, column), max(row, column)))
                    kept += 1
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

/// One person's confirmed faces, laid out for grouping: the dated ones sorted by capture, so
/// a face's two-year window is one contiguous run found by binary search, then the undated
/// ones, which every face is compared with. Each person's best similarity is then one
/// vectorised maximum per run instead of a comparison per face.
private nonisolated struct PersonColumns {
    let person: PersonID
    let birthdaySeconds: Double?
    let photos: Set<MediaAssetID>
    let faces: [FaceFact]
    /// Where this person's faces start in the concatenated columns.
    let start: Int
    /// The dated faces' capture instants, ascending; `faces[0 ..< times.count]` are dated.
    let times: [Double]

    /// One group per person in `people` with confirmed faces, in person order.
    static func make(confirmed: [FaceFact], people: [PersonFact]) -> [PersonColumns] {
        let byPerson = Dictionary(grouping: confirmed) { $0.person }
        var start = 0
        var groups: [PersonColumns] = []
        for person in people.sorted(by: { $0.id < $1.id }) {
            guard let faces = byPerson[person.id], !faces.isEmpty else { continue }
            let dated = faces
                .compactMap { face in face.captureSeconds.map { (face: face, time: $0) } }
                .sorted { $0.time < $1.time }
            let ordered = dated.map(\.face) + faces.filter { $0.captureSeconds == nil }
            groups.append(PersonColumns(
                person: person.id,
                birthdaySeconds: person.birthdaySeconds,
                photos: Set(faces.map(\.id.asset)),
                faces: ordered,
                start: start,
                times: dated.map(\.time)
            ))
            start += ordered.count
        }
        return groups
    }

    /// The best similarity of `face` to this person's eligible faces, and its column, or nil
    /// when the person cannot be the face's: rejected, already in the photo, born after it,
    /// or no confirmed face within the window.
    func best(for face: FaceFact, row: UnsafeBufferPointer<Float>, rowStart: Int) -> (similarity: Float, column: Int)? {
        guard !face.rejected.contains(person), !photos.contains(face.id.asset),
              FacePeoplePolicy.notBeforeBirthday(face.captureSeconds, birthdaySeconds),
              let base = row.baseAddress
        else {
            return nil
        }
        var runs: [Range<Int>] = []
        if let capture = face.captureSeconds {
            let low = times.partitioningIndex { $0 >= capture - FacePeoplePolicy.window }
            let high = times.partitioningIndex { $0 > capture + FacePeoplePolicy.window }
            runs.append(low ..< high)
        } else {
            runs.append(0 ..< times.count)
        }
        runs.append(times.count ..< faces.count)
        var best: (similarity: Float, column: Int)?
        for run in runs where !run.isEmpty {
            var value: Float = 0
            var index: vDSP_Length = 0
            vDSP_maxvi(base + rowStart + start + run.lowerBound, 1, &value, &index, vDSP_Length(run.count))
            if value > best?.similarity ?? -2 {
                best = (value, start + run.lowerBound + Int(index))
            }
        }
        return best
    }
}

private extension Array {
    /// The first index whose element satisfies `predicate`, for a predicate that is false
    /// then true along the array.
    nonisolated func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if predicate(self[middle]) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
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
