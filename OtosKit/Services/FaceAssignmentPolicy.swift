import Accelerate
import Foundation

/// Who a face belongs to, and on whose word (ADR 0047).
///
/// The user's word and the seeds are what the catalog keeps as fact. Every guess is rebuilt
/// from them whenever faces or acts change, so correcting one face moves the guesses that
/// were reached through it.
nonisolated enum FaceAssignment: Hashable, Sendable {
    /// No person. Otos may give the face to one.
    case open
    /// Otos's guess, rebuilt on every assignment.
    case model(PersonID)
    /// One of the faces a person was first found from, when they matched nobody. A seed
    /// anchors its person as the user's word does, until the user moves it.
    case seed(PersonID)
    /// The user gave the face to this person.
    case user(PersonID)
    /// The user removed the face's name. Only the user gives it a person again.
    case held

    var person: PersonID? {
        switch self {
        case let .model(person), let .seed(person), let .user(person): person
        case .open, .held: nil
        }
    }

    /// The face defines its person: guesses are reached from it.
    var isAnchor: Bool {
        switch self {
        case .seed, .user: true
        case .open, .model, .held: false
        }
    }

    /// The user said who the face is, or that it is no one they named: overlay that a new
    /// reading of the same photo never drops (ADR 0047).
    var isUserWord: Bool {
        switch self {
        case .user, .held: true
        case .open, .model, .seed: false
        }
    }

    /// Otos decides the face's person.
    var isGuessable: Bool {
        switch self {
        case .open, .model: true
        case .seed, .user, .held: false
        }
    }
}

/// One face, as assignment reads it: where it is, when it was taken, its embedding, and
/// what the user has decided about it (ADR 0047). A detection the user marked as not a face
/// is never one: the catalog leaves it out of the People snapshot.
nonisolated struct FaceFact: Sendable, Equatable {
    let id: FaceID
    /// The photo's local capture time (`CaptureLocalTime.seconds`); nil when the photo has
    /// no date. A birthday is midnight UTC of its day, so the two compare day for day.
    let captureSeconds: Double?
    /// The face's vector as assignment compares it, at half precision (`FaceVector`).
    let vector: FaceVector
    let assignment: FaceAssignment
    /// People the user said this face is not (Remove Name).
    let rejected: Set<PersonID>

    init(id: FaceID, captureSeconds: Double?, vector: FaceVector, assignment: FaceAssignment, rejected: Set<PersonID>) {
        self.id = id
        self.captureSeconds = captureSeconds
        self.vector = vector
        self.assignment = assignment
        self.rejected = rejected
    }

    init(
        id: FaceID, captureSeconds: Double?, embedding: FaceEmbedding, assignment: FaceAssignment, rejected: Set<PersonID>
    ) {
        self.init(id: id, captureSeconds: captureSeconds, vector: FaceVector(embedding), assignment: assignment, rejected: rejected)
    }

    /// The model can tell who this face is (`FaceRecognisability`). A face it cannot is still
    /// a face, and keeps what the user says of it, but Otos never guesses it, never groups
    /// it, and never compares another face with it.
    var isRecognisable: Bool {
        vector.isRecognisable
    }

    /// The vector widened back to single precision: the values assignment compares.
    var embedding: FaceEmbedding {
        vector.embedding
    }

    /// The same face with no person: a seed whose group no longer stands is Otos's to decide
    /// again.
    var opened: FaceFact {
        FaceFact(id: id, captureSeconds: captureSeconds, vector: vector, assignment: .open, rejected: rejected)
    }
}

/// A face's vector as People holds and compares it: the stored embedding rounded to half
/// precision, with whether the model can tell anyone by it decided from the stored
/// single-precision values. Its bytes are a slice of the mapped file `FaceVectors` writes
/// (`FaceVectorFile`), or bytes of its own for a vector made from an embedding. Half precision
/// halves what People holds (103k faces: 105 MB rather than 211 MB); on the reference library's 102,978
/// stored vectors it changed no face's best person, threshold or margin decision in 3,029
/// faces sampled, the largest similarity moving 9.6e-5
/// (`docs/research/2026-11-16-people-memory-and-kernel.md`). Assignment widens a block of
/// vectors to single precision for each matrix product (`copy(into:)`).
nonisolated struct FaceVector: Sendable, Equatable {
    /// `FaceEmbeddingModel.dimensions` Float16 values, in the machine's byte order.
    let bytes: Data
    let isRecognisable: Bool

    /// The bytes of one vector.
    static let byteCount = FaceEmbeddingModel.dimensions * MemoryLayout<Float16>.stride

    init(bytes: Data, isRecognisable: Bool) {
        self.bytes = bytes
        self.isRecognisable = isRecognisable
    }

    /// `embedding` rounded to half precision, in bytes of its own.
    init(_ embedding: FaceEmbedding) {
        var bytes = Data(count: Self.byteCount)
        bytes.withUnsafeMutableBytes { target in
            Self.halve(embedding.values, into: target.baseAddress!.assumingMemoryBound(to: Float16.self))
        }
        self.bytes = bytes
        isRecognisable = FaceRecognisability.isRecognisable(embedding)
    }

    /// The values widened to single precision: what every comparison reads.
    var embedding: FaceEmbedding {
        var widened = [Float](repeating: 0, count: FaceEmbeddingModel.dimensions)
        widened.withUnsafeMutableBufferPointer { copy(into: $0.baseAddress!) }
        return FaceEmbedding(view: ArraySlice(widened))
    }

    /// Writes the values, widened to single precision, at `target`.
    func copy(into target: UnsafeMutablePointer<Float>) {
        bytes.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            let count = FaceEmbeddingModel.dimensions
            var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base), height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
            var to = vImage_Buffer(data: target, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
            vImageConvert_Planar16FtoPlanarF(&from, &to, 0)
        }
    }

    /// Writes `values` rounded to half precision at `target`.
    static func halve(_ values: ArraySlice<Float>, into target: UnsafeMutablePointer<Float16>) {
        values.withUnsafeBufferPointer { source in
            guard let from = source.baseAddress else { return }
            var input = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: from), height: 1, width: vImagePixelCount(source.count), rowBytes: source.count * 4
            )
            var output = vImage_Buffer(data: target, height: 1, width: vImagePixelCount(source.count), rowBytes: source.count * 2)
            vImageConvert_PlanarFtoPlanar16F(&input, &output, 0)
        }
    }
}

/// One face of one photo: the photo's identity and the face's place in its reading.
nonisolated struct FaceID: Hashable, Sendable {
    let asset: MediaAssetID
    let index: Int
}

/// A person row's identity in the catalog. Not an asset identity: a person is the set of
/// their faces (ADR 0047).
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
    /// The user said nothing about the person: no name, birthday, favourite or hidden mark,
    /// and no key photo. Such a person is Otos's own finding, and keeps its seeds only while
    /// they would still make a new person.
    let isBare: Bool

    /// The birthday of each of `people` that has one.
    static func birthdays(of people: [PersonFact]) -> [PersonID: Double] {
        Dictionary(uniqueKeysWithValues: people.compactMap { person in person.birthdaySeconds.map { (person.id, $0) } })
    }
}

/// What assignment decided (ADR 0047): the person each guessable face goes to, the people
/// found among faces that matched nobody, and how like its person each face is.
nonisolated struct FaceAssignmentResult: Sendable, Equatable {
    /// A person the result names: one the catalog holds, or the `newPeople` entry at an index.
    nonisolated enum Person: Hashable, Sendable {
        case existing(PersonID)
        case new(Int)
    }

    /// The person each guessable face goes to. A guessable face missing here has no person.
    var guesses: [FaceID: Person] = [:]
    /// People found among the faces that matched nobody: each one's seed faces, from two or
    /// more days, in path order.
    var newPeople: [[FaceID]] = []
    /// How like its person each face with a person is: its best similarity to that person's
    /// other faces within reach. Missing when no other face of theirs is within reach.
    var likeness: [FaceID: Float] = [:]
    /// Seeds whose group no longer stands (`lapsedSeeds`): each loses its person and is given
    /// out like any face Otos decides, in `guesses` or in `newPeople`.
    var lapsedSeeds: Set<FaceID> = []
}

/// Face assignment policy guide
///
/// Gives every face its most likely person (ADR 0047). Pure: the same facts always give the
/// same result, so it runs off every actor and is tested without a catalog. It reads only
/// the anchors (the user's faces and the seeds) and rebuilds every guess from them, so its
/// result does not depend on the guesses it made before: run on its own output, it gives the
/// same output.
///
/// The rules and values were measured on a private labelled set of faces with the shipped model
/// (`docs/research/2026-11-07-face-recognition-models.md`;
/// `docs/research/2026-11-12-face-auto-assignment.md`):
/// - **Reach:** a face is compared with each person's faces: all of them when the person was
///   an adult (`adultAge`) on the face's date, those within `window` of it otherwise,
///   including when the age is unknown. A child's face changes from year to year, an adult's
///   hardly.
/// - **Chaining:** faces are given out strongest first, round by round. A face whose best
///   person reaches `threshold` and beats the runner-up by `margin` joins that person and is
///   evidence for the next round, so a child is followed from year to year.
/// - **Close calls:** a face whose best person reaches `threshold` but whose runner-up is
///   within `margin` still goes to the best person (siblings are guessed too), but is
///   evidence for nobody: a guess between two siblings never carries one into the next year.
/// - **Hard rules:** a person never gets a face from a photo they are already in, a face from
///   before their birthday, or a face the user said is not theirs.
/// - **New people:** faces left over are linked to each other (`groupLink`, `groupLinks`) and
///   joined strongest first, never two faces of one photo. A group of faces from two or more
///   days becomes a new person, seeded with its faces, and chaining runs again with them. A
///   face matching nobody and like no face of another day stays without a person.
/// - **Unrecognisable faces:** a face the model cannot tell anyone by
///   (`FaceRecognisability`) is never guessed, grouped or compared with; one the user gave a
///   person still keeps that person out of the rest of its photo.
/// - **Lapsed seeds:** a person the user said nothing about keeps its unrecognisable seeds
///   never, and its others only while they still span two or more days, as a new person's
///   must. When faces leave it (re-read
///   under stricter admission, deleted, or moved by the user), the seeds left are Otos's to
///   decide again, and the person is forgotten once no face is theirs.
nonisolated enum FaceAssignmentPolicy {
    static let threshold: Float = 0.434
    static let margin: Float = 0.16
    static let groupLink: Float = 0.65
    /// The strongest links each face keeps for grouping. Measured on the labelled set: 10,
    /// 20 or every link give the same groups; fewer links make grouping cost proportional to
    /// the faces, not their pairs.
    static let groupLinks = 10
    /// Two years, in seconds.
    static let window: Double = 2 * 365.2425 * 86400
    /// The age from which a person's face is compared across all years, in seconds.
    static let adultAge: Double = 18 * 365.2425 * 86400
    /// Rows compared at once, which bounds the similarity block in memory.
    static let blockRows = 512
    /// New people are found at most this many times per assignment. Each time can only add
    /// people from the faces the time before left over, which ends a run that would not.
    static let maximumGroupings = 8

    /// Raised whenever a rule changes what assignment gives for the same faces, so a catalog
    /// settled by an earlier build assigns again (`AssignmentInputs`). The constants are
    /// hashed beside it (`constants`), so changing one needs no raise.
    static let revision = 1

    /// Every value the rules read, for `AssignmentInputs`.
    static var constants: [Double] {
        [
            Double(threshold), Double(margin), Double(groupLink), Double(groupLinks), window, adultAge,
            Double(maximumGroupings), Double(FaceRecognisability.limit),
        ]
    }

    /// `photoOf` maps a file that is one of several of a photo — an identical copy (ADR
    /// 0054), a stack's file (ADR 0052) — to the file that stands for it: each file is read for
    /// its faces, so one person's faces in one photo are one face read twice, and a likeness
    /// compares a face only with the person's faces in other photos.
    static func assign(
        faces: [FaceFact],
        people: [PersonFact],
        photoOf: [MediaAssetID: MediaAssetID] = [:]
    ) -> FaceAssignmentResult {
        let lapsed = lapsedSeeds(faces, people: people)
        // A copy of every face only when a seed lapsed: the faces are the largest thing the
        // kernel holds, and most assignments release no seed.
        let usable = lapsed.isEmpty ? faces : faces.map { lapsed.contains($0.id) ? $0.opened : $0 }
        let known = Set(people.map(\.id))
        let birthdays = PersonFact.birthdays(of: people)
        var anchors: [Int: FaceAssignmentResult.Person] = [:]
        for (index, face) in usable.enumerated() where face.assignment.isAnchor {
            guard let person = face.assignment.person, known.contains(person) else { continue }
            anchors[index] = .existing(person)
        }
        var result = FaceAssignmentResult()
        result.lapsedSeeds = lapsed
        var fill = Fill.run(faces: usable, anchors: anchors, birthdays: birthdays)
        // Each face's index, built once and only when grouping finds a person.
        var indexByID: [FaceID: Int]?
        for _ in 0 ..< maximumGroupings {
            let groups = unnamedGroups(fill.leftover.map { usable[$0] })
            guard !groups.isEmpty else { break }
            let index = indexByID ?? Dictionary(uniqueKeysWithValues: usable.enumerated().map { ($1.id, $0) })
            indexByID = index
            for group in groups {
                let person = FaceAssignmentResult.Person.new(result.newPeople.count)
                result.newPeople.append(group)
                for face in group {
                    if let position = index[face] {
                        anchors[position] = person
                    }
                }
            }
            // From scratch, so the result is what a run that started with these seeds as
            // anchors gives: assignment run on its own output changes nothing.
            fill = Fill.run(faces: usable, anchors: anchors, birthdays: birthdays)
        }
        let seeded = Set(result.newPeople.joined())
        for (index, person) in fill.assigned where usable[index].assignment.isGuessable && !seeded.contains(usable[index].id) {
            result.guesses[usable[index].id] = person
        }
        result.likeness = likeness(faces: usable, assigned: fill.assigned, birthdays: birthdays, photoOf: photoOf)
        return result
    }

    /// The seeds that no longer stand:
    /// - any person's seed from before that person's birthday: a photo's date can move after
    ///   it was seeded (a new reading, a corrected date), and on Otos's word the birthday wins;
    ///   the user's own faces keep their person;
    /// - of each person the user said nothing about and gave no face, every unrecognisable
    ///   seed, and every seed when the recognisable ones span fewer than two days.
    static func lapsedSeeds(_ faces: [FaceFact], people: [PersonFact]) -> Set<FaceID> {
        let bare = Set(people.filter(\.isBare).map(\.id))
        let birthdays = PersonFact.birthdays(of: people)
        var lapsed: Set<FaceID> = []
        // Each bare person's seeds by position, never copies of the faces.
        var seeds: [PersonID: [Int32]] = [:]
        var claimed: Set<PersonID> = []
        for (position, face) in faces.enumerated() {
            if case let .seed(person) = face.assignment, !notBeforeBirthday(face.captureSeconds, birthdays[person]) {
                lapsed.insert(face.id)
                continue
            }
            switch face.assignment {
            case let .seed(person) where bare.contains(person):
                seeds[person, default: []].append(Int32(position))
            case let .user(person):
                claimed.insert(person)
            default:
                break
            }
        }
        for (person, positions) in seeds where !claimed.contains(person) {
            let seedFaces = positions.lazy.map { faces[Int($0)] }
            let days = Set(seedFaces.filter(\.isRecognisable).compactMap { day($0.captureSeconds) })
            if days.count < 2 {
                lapsed.formUnion(seedFaces.map(\.id))
            } else {
                lapsed.formUnion(seedFaces.filter { !$0.isRecognisable }.map(\.id))
            }
        }
        return lapsed
    }

    /// The faces linked strongest first at `groupLink` or above, never joining two faces of
    /// one photo, keeping groups that span two or more days; each group in path order, the
    /// groups in path order of their first face.
    static func unnamedGroups(_ faces: [FaceFact]) -> [[FaceID]] {
        // At most `groupLinks` per face, in a region of their own and sorted in place: at the
        // reference library's scale an array of them and its sorted copy were tens of megabytes of heap
        // that stayed in the footprint after the pass (`ScratchBuffer`).
        let links = ScratchBuffer<GroupLink>(count: faces.count * groupLinks)
        defer { withExtendedLifetime(links) {} }
        var linkCount = 0
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
                    links.base[linkCount] = GroupLink(similarity: value, a: Int32(min(row, column)), b: Int32(max(row, column)))
                    linkCount += 1
                    kept += 1
                }
            }
        }
        var root = Array(faces.indices)
        // The photos of each group of two or more faces, by its root; a face alone is its own
        // photo, so no set is made for the many faces no link joins.
        var grouped: [Int: Set<MediaAssetID>] = [:]
        func photos(_ root: Int) -> Set<MediaAssetID> {
            grouped[root] ?? [faces[root].id.asset]
        }
        func find(_ x: Int) -> Int {
            var x = x
            while root[x] != x {
                root[x] = root[root[x]]
                x = root[x]
            }
            return x
        }
        var found = UnsafeMutableBufferPointer(start: links.base, count: linkCount)
        found.sort { ($0.similarity, $1.a, $1.b) > ($1.similarity, $0.a, $0.b) }
        for link in found {
            let a = find(Int(link.a)), b = find(Int(link.b))
            let (photosA, photosB) = (photos(a), photos(b))
            guard a != b, photosA.isDisjoint(with: photosB) else { continue }
            let (into, from) = photosA.count >= photosB.count ? (a, b) : (b, a)
            root[from] = into
            grouped[into] = photosA.union(photosB)
            grouped[from] = nil
        }
        // A face alone spans one day at most, so only the joined groups can stand.
        var groups: [Int: [Int]] = [:]
        for index in faces.indices {
            let group = find(index)
            if grouped[group] != nil {
                groups[group, default: []].append(index)
            }
        }
        return groups.values
            .filter { members in Set(members.compactMap { day(faces[$0].captureSeconds) }).count >= 2 }
            .map { $0.map { faces[$0].id }.sorted(by: pathOrder) }
            .sorted { pathOrder($0[0], $1[0]) }
    }

    /// One link between two faces of different photos, `a` before `b`.
    struct GroupLink: BitwiseCopyable {
        let similarity: Float
        let a: Int32
        let b: Int32
    }

    /// Each candidate's best similarity to a person, as `likeness` measures it: to `members`,
    /// the faces that define the person, one per photo and none in a candidate's photo. A
    /// merge keeps, of the faces two people had in one photo, the one most like the person
    /// they become (`CatalogStore.mergePerson`). A candidate the model cannot tell anyone by,
    /// or with no member within its reach, has none.
    static func likeness(of candidates: [FaceFact], toPersonWith members: [FaceFact], birthday: Double?) -> [FaceID: Float] {
        let candidatePhotos = Set(candidates.map(\.id.asset))
        var seen: Set<MediaAssetID> = []
        let columns = PersonRun(
            faces: members.filter { $0.isRecognisable && !candidatePhotos.contains($0.id.asset) && seen.insert($0.id.asset).inserted },
            birthday: birthday
        )
        let rows = candidates.filter(\.isRecognisable)
        guard !columns.faces.isEmpty, !rows.isEmpty else { return [:] }
        var likeness: [FaceID: Float] = [:]
        BlockedSimilarity(rows: rows, columns: columns.faces).forEachBlock { block, values in
            for row in block {
                let face = rows[row]
                if let best = columns.best(for: face, row: values, rowStart: (row - block.lowerBound) * columns.faces.count) {
                    likeness[face.id] = best
                }
            }
        }
        return likeness
    }

    /// Each face's best similarity to its person's faces within reach in their other photos:
    /// one face per photo is compared with, the first of the photo's files in face order, and
    /// a face is never compared with its own photo's.
    private static func likeness(
        faces: [FaceFact],
        assigned: [Int: FaceAssignmentResult.Person],
        birthdays: [PersonID: Double],
        photoOf: [MediaAssetID: MediaAssetID]
    ) -> [FaceID: Float] {
        var byPerson: [FaceAssignmentResult.Person: [Int]] = [:]
        for (index, person) in assigned where faces[index].isRecognisable {
            byPerson[person, default: []].append(index)
        }
        let photo = { (face: FaceFact) in photoOf[face.id.asset] ?? face.id.asset }
        var likeness: [FaceID: Float] = [:]
        for (person, members) in byPerson where members.count > 1 {
            let birthday: Double? = if case let .existing(id) = person {
                birthdays[id]
            } else {
                nil
            }
            let rows = members.sorted().map { faces[$0] }
            var seen: Set<MediaAssetID> = []
            let columns = PersonRun(faces: rows.filter { seen.insert(photo($0)).inserted }, birthday: birthday)
            let columnOfPhoto = Dictionary(uniqueKeysWithValues: columns.faces.enumerated().map { (photo($1), $0) })
            BlockedSimilarity(rows: rows, columns: columns.faces).forEachBlock { block, values in
                for row in block {
                    let start = (row - block.lowerBound) * columns.faces.count
                    let face = rows[row]
                    if let best = columns.best(for: face, row: values, rowStart: start, skipping: columnOfPhoto[photo(face)]) {
                        likeness[face.id] = best
                    }
                }
            }
        }
        return likeness
    }

    /// Whether a face taken at `capture` is compared with a face of the person taken at
    /// `other`: always for an adult or an undated face, within `window` otherwise.
    static func reaches(_ capture: Double?, _ other: Double?, birthday: Double?) -> Bool {
        guard let capture, let other else { return true }
        if isAdult(at: capture, birthday: birthday) {
            return true
        }
        return abs(capture - other) <= window
    }

    /// Whether a person born at `birthday` was an adult at `capture`; unknown without a
    /// birthday, which counts as not.
    static func isAdult(at capture: Double, birthday: Double?) -> Bool {
        guard let birthday else { return false }
        return capture - birthday >= adultAge
    }

    static func notBeforeBirthday(_ capture: Double?, _ birthday: Double?) -> Bool {
        guard let capture, let birthday else { return true }
        return capture >= birthday
    }

    /// The day a photo was taken, from its local capture time; nil without a date.
    static func day(_ seconds: Double?) -> Int? {
        seconds.map { Int(($0 / 86400).rounded(.down)) }
    }

    /// An order of faces that does not change while they exist: photo path, library, place,
    /// each as `String`'s `<` orders it, read from the identity table without a string.
    static func pathOrder(_ lhs: FaceID, _ rhs: FaceID) -> Bool {
        let order = lhs.asset == rhs.asset ? 0 : lhs.asset.relativePathThenRootOrder(rhs.asset)
        return order != 0 ? order < 0 : lhs.index < rhs.index
    }
}

/// One run of chaining: from the anchors, every guessable face given out strongest first,
/// round by round (`FaceAssignmentPolicy`). Internal so its tests can compare it with the
/// rules applied one comparison at a time.
///
/// Each open face keeps, per person, its best similarity to that person's evidence so far
/// (`Bests`). Only a best of `kept` or more is kept: a decision reads a best only when it
/// reaches `threshold`, and a runner-up only when it is within `margin` of a best that does,
/// so a lower one decides nothing. On the reference library's faces a face keeps about 6 of 752 people.
nonisolated struct Fill {
    /// Every face with a person, anchors included, by index into the faces.
    var assigned: [Int: FaceAssignmentResult.Person]
    /// Guessable faces no person reached, by index into the faces.
    var leftover: [Int]

    /// Below this a best decides nothing (see the type's guide); 0.01 under the lowest value
    /// a decision reads, so float rounding of `threshold - margin` cannot reach it.
    static let kept = FaceAssignmentPolicy.threshold - FaceAssignmentPolicy.margin - 0.01

    static func run(
        faces: [FaceFact],
        anchors: [Int: FaceAssignmentResult.Person],
        birthdays: [PersonID: Double]
    ) -> Fill {
        let people = Array(Set(anchors.values)).sorted { order($0) < order($1) }
        let slotOf = Dictionary(uniqueKeysWithValues: people.enumerated().map { ($1, $0) })
        let birthdayOf = people.map { person -> Double? in
            if case let .existing(id) = person {
                birthdays[id]
            } else {
                nil
            }
        }
        // An unrecognisable face is never a row or evidence; as an anchor it still keeps its
        // person out of the rest of its photo.
        let rows = faces.indices.filter { faces[$0].assignment.isGuessable && anchors[$0] == nil && faces[$0].isRecognisable }
        // The rows are read through `rows`, never copied: a copy of every open face was the
        // largest thing a run held.
        let rowCaptures = rows.map { faces[$0].captureSeconds }
        let rowPhotos = rows.map { faces[$0].id.asset }
        let rejected = rows.map { row in Set(faces[row].rejected.compactMap { slotOf[.existing($0)] }) }
        var assigned = anchors
        // Which person slots each photo holds, as one set of pairs rather than a set per photo.
        var photoPeople: Set<PhotoSlot> = []
        for (index, person) in anchors {
            photoPeople.insert(PhotoSlot(photo: faces[index].id.asset, slot: slotOf[person]!))
        }
        let layout = RowLayout(captures: rowCaptures)
        var bests = Bests(rows: rows.count)
        var open = Set(rows.indices)
        var evidence = anchors.keys.filter { faces[$0].isRecognisable }.sorted()

        /// The row's best person and runner-up among those it may have: not rejected, not
        /// born after it, and, when `excludingPhoto`, not already in its photo. The first
        /// person in slot order wins a tie, as a vectorised maximum over every slot would.
        func top(_ row: Int, excludingPhoto: Bool) -> (slot: Int, value: Float, second: Float)? {
            var best: (slot: Int, value: Float)?
            var second: Float = -2
            for (slot, value) in bests.entries(row) {
                guard !rejected[row].contains(slot),
                      !(excludingPhoto && photoPeople.contains(PhotoSlot(photo: rowPhotos[row], slot: slot))),
                      FaceAssignmentPolicy.notBeforeBirthday(rowCaptures[row], birthdayOf[slot])
                else { continue }
                if let current = best {
                    if value > current.value || (value == current.value && slot < current.slot) {
                        second = current.value
                        best = (slot, value)
                    } else {
                        second = max(second, value)
                    }
                } else {
                    best = (slot, value)
                }
            }
            return best.map { ($0.slot, $0.value, second) }
        }

        while !evidence.isEmpty, !open.isEmpty {
            raise(
                &bests, layout: layout, faces: faces, rows: rows, open: open, people: people.count,
                evidence: evidence.map { (face: $0, slot: slotOf[assigned[$0]!]!) }, birthdays: birthdayOf
            )
            let ranked = open.compactMap { row -> (row: Int, slot: Int, value: Float)? in
                guard let found = top(row, excludingPhoto: true),
                      found.value >= FaceAssignmentPolicy.threshold,
                      found.value - found.second >= FaceAssignmentPolicy.margin
                else { return nil }
                return (row, found.slot, found.value)
            }
            evidence = []
            for candidate in ranked.sorted(by: { ($0.value, $1.row) > ($1.value, $0.row) }) {
                let asset = rowPhotos[candidate.row]
                guard photoPeople.insert(PhotoSlot(photo: asset, slot: candidate.slot)).inserted else { continue }
                assigned[rows[candidate.row]] = people[candidate.slot]
                open.remove(candidate.row)
                evidence.append(rows[candidate.row])
            }
        }
        // Close calls: the best person reaches the threshold, the runner-up is within the
        // margin. Each goes to its best person still free in its photo, strongest first, and
        // is evidence for nobody.
        let close = open.compactMap { row -> (row: Int, value: Float)? in
            guard let found = top(row, excludingPhoto: false), found.value >= FaceAssignmentPolicy.threshold else { return nil }
            return (row, found.value)
        }
        for candidate in close.sorted(by: { ($0.value, $1.row) > ($1.value, $0.row) }) {
            guard let found = top(candidate.row, excludingPhoto: true), found.value >= FaceAssignmentPolicy.threshold else { continue }
            photoPeople.insert(PhotoSlot(photo: rowPhotos[candidate.row], slot: found.slot))
            assigned[rows[candidate.row]] = people[found.slot]
            open.remove(candidate.row)
        }
        return Fill(assigned: assigned, leftover: open.sorted().map { rows[$0] })
    }

    /// One person slot in one photo.
    private struct PhotoSlot: Hashable {
        let photo: MediaAssetID
        let slot: Int
    }

    private static func order(_ person: FaceAssignmentResult.Person) -> (Int, Int64) {
        switch person {
        case let .existing(id): (0, id.rawValue)
        case let .new(index): (1, Int64(index))
        }
    }

    /// Raises each open face's kept bests with the round's new evidence within its reach.
    ///
    /// The open faces are taken in blocks of `FaceAssignmentPolicy.blockRows`, in layout order
    /// (`RowLayout`), and the evidence in chunks of `evidenceChunk` faces; each block and
    /// chunk is one matrix product, evidence by face, so every evidence face's similarities to
    /// the block lie in one contiguous row. For each evidence face the rows that reach it are
    /// at most two runs of the block — the rows within `window` of it, and the rows for whom
    /// its person was an adult with the undated rows after them — and one vectorised maximum
    /// per run raises that person's column of the block. The work per round is one visit per
    /// evidence face and block, never one per face and person, and nothing it allocates grows
    /// with the faces or the people.
    private static func raise(
        _ bests: inout Bests,
        layout: RowLayout,
        faces: [FaceFact],
        rows: [Int],
        open: Set<Int>,
        people: Int,
        evidence: [(face: Int, slot: Int)],
        birthdays: [Double?]
    ) {
        let dimensions = FaceEmbeddingModel.dimensions
        // The evidence by person, each person's faces one run of columns, by position, never
        // copies of the faces: a column's maximum into the rows is the same in any order.
        var bySlot: [Int: [Int]] = [:]
        for (face, slot) in evidence {
            bySlot[slot, default: []].append(face)
        }
        var columns: [Int] = []
        columns.reserveCapacity(evidence.count)
        var columnRun: [Int] = []
        columnRun.reserveCapacity(evidence.count)
        var runSlots: [Int] = []
        for slot in bySlot.keys.sorted() {
            let run = bySlot[slot]!
            columns += run
            columnRun += repeatElement(runSlots.count, count: run.count)
            runSlots.append(slot)
        }
        let columnTimes = columns.map { faces[$0].captureSeconds }
        let placed = open.map { layout.place[$0] }.sorted()
        let blockRows = FaceAssignmentPolicy.blockRows
        // The round's matrices, each its own region returned to the system when the round
        // ends (`ScratchBuffer`), so a pass leaves none of them in the footprint.
        let block = ScratchBuffer<Float>(count: blockRows * dimensions)
        let blockT = ScratchBuffer<Float>(count: blockRows * dimensions)
        let chunk = ScratchBuffer<Float>(count: evidenceChunk * dimensions)
        let products = ScratchBuffer<Float>(count: evidenceChunk * blockRows)
        let maxima = ScratchBuffer<Float>(count: runSlots.count * blockRows)
        var adultStart = [Int](repeating: -1, count: runSlots.count)
        var start = 0
        while start < placed.count {
            let count = min(blockRows, placed.count - start)
            let positions = placed[start ..< start + count]
            let datedCount = positions.prefix { $0 < layout.dated }.count
            let blockLow = positions.prefix(datedCount).map { layout.low[$0] }
            let blockHigh = positions.prefix(datedCount).map { layout.high[$0] }
            let blockCaptures = positions.prefix(datedCount).map { layout.captures[$0] }
            for (k, position) in positions.enumerated() {
                faces[rows[layout.order[position]]].vector.copy(into: block.base + k * dimensions)
            }
            vDSP_mtrans(block.base, 1, blockT.base, 1, vDSP_Length(dimensions), vDSP_Length(count))
            maxima.fill(with: -2)
            for index in adultStart.indices {
                adultStart[index] = -1
            }
            var chunkStart = 0
            while chunkStart < columns.count {
                let chunkCount = min(evidenceChunk, columns.count - chunkStart)
                for j in 0 ..< chunkCount {
                    faces[columns[chunkStart + j]].vector.copy(into: chunk.base + j * dimensions)
                }
                vDSP_mmul(
                    chunk.base, 1, blockT.base, 1, products.base, 1,
                    vDSP_Length(chunkCount), vDSP_Length(count), vDSP_Length(dimensions)
                )
                for j in 0 ..< chunkCount {
                    let column = chunkStart + j
                    let run = columnRun[column]
                    let into = maxima.base + run * blockRows
                    let from = UnsafePointer(products.base) + j * count
                    guard let time = columnTimes[column] else {
                        raise(into, from, 0 ..< count)
                        continue
                    }
                    if adultStart[run] < 0 {
                        adultStart[run] = adults(blockCaptures, birthday: birthdays[runSlots[run]])
                    }
                    // Rows within the window of this face: the dated rows whose high
                    // edge is at or past it and whose low edge is not past it.
                    let low = partition(blockHigh) { $0 < time }
                    let high = partition(blockLow) { $0 <= time }
                    let adults = adultStart[run]
                    if adults <= high {
                        raise(into, from, min(low, adults) ..< count)
                    } else {
                        raise(into, from, low ..< high)
                        raise(into, from, adults ..< count)
                    }
                }
                chunkStart += chunkCount
            }
            for (run, slot) in runSlots.enumerated() {
                let values = maxima.base + run * blockRows
                var top: Float = 0
                vDSP_maxv(values, 1, &top, vDSP_Length(count))
                guard top >= kept else { continue }
                for k in 0 ..< count where values[k] >= kept {
                    bests.raise(layout.order[positions[positions.startIndex + k]], slot: slot, to: values[k])
                }
            }
            start += count
        }
    }

    /// Evidence faces per matrix product: with a block of rows, a product of at most 4 MB.
    static let evidenceChunk = 2048

    /// The first of `captures` (ascending) for whom a person born at `birthday` was an adult;
    /// all of them when there is no birthday, which makes no one an adult.
    private static func adults(_ captures: [Double], birthday: Double?) -> Int {
        guard birthday != nil else { return captures.count }
        return partition(captures) { !FaceAssignmentPolicy.isAdult(at: $0, birthday: birthday) }
    }

    /// The first index of `values` for which `before` is false; `before` holds for a prefix.
    private static func partition(_ values: [Double], _ before: (Double) -> Bool) -> Int {
        var low = 0, high = values.count
        while low < high {
            let middle = (low + high) / 2
            if before(values[middle]) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// Raises `into` to the elementwise maximum of itself and `from` over `part`.
    private static func raise(_ into: UnsafeMutablePointer<Float>, _ from: UnsafePointer<Float>, _ part: Range<Int>) {
        guard !part.isEmpty else { return }
        vDSP_vmax(into + part.lowerBound, 1, from + part.lowerBound, 1, into + part.lowerBound, 1, vDSP_Length(part.count))
    }
}

/// Each open face's kept bests (`Fill.kept` or more), per person slot: a few a face, held as
/// one list per face threaded through four flat arrays (`head`, `next`, `slot`, `value`), so a
/// run of chaining allocates a handful of arrays that grow by doubling, never one per face.
nonisolated struct Bests {
    /// Each row's first entry, or -1.
    private var head: [Int32]
    private var next: [Int32] = []
    private var slots: [Int32] = []
    private var values: [Float] = []

    init(rows: Int) {
        head = [Int32](repeating: -1, count: rows)
    }

    /// The row's entries, as (slot, best).
    func entries(_ row: Int) -> Entries {
        Entries(bests: self, entry: head[row])
    }

    nonisolated struct Entries: Sequence, IteratorProtocol {
        let bests: Bests
        var entry: Int32

        mutating func next() -> (Int, Float)? {
            guard entry >= 0 else { return nil }
            let index = Int(entry)
            entry = bests.next[index]
            return (Int(bests.slots[index]), bests.values[index])
        }
    }

    /// Raises the row's best for `slot` to `value`.
    mutating func raise(_ row: Int, slot: Int, to value: Float) {
        let slot = Int32(slot)
        var entry = head[row]
        while entry >= 0 {
            let index = Int(entry)
            if slots[index] == slot {
                values[index] = max(values[index], value)
                return
            }
            entry = next[index]
        }
        next.append(head[row])
        slots.append(slot)
        values.append(value)
        head[row] = Int32(slots.count - 1)
    }
}

/// The open faces laid out by capture time, so the faces a dated face of a person reaches —
/// those taken within `window` of it, those for whom the person was an adult, and the undated
/// — are at most two runs of consecutive rows. Dated faces first, oldest first, then the
/// undated; within one time, by row.
nonisolated struct RowLayout {
    /// Rows in layout order.
    let order: [Int]
    /// Each row's place in `order`.
    let place: [Int]
    /// How many of `order` are dated.
    let dated: Int
    /// For the dated, in layout order: capture − window and capture + window, the same
    /// expressions `PersonRun.best` compares, so a reach is decided by the same arithmetic.
    let low: [Double]
    let high: [Double]
    let captures: [Double]

    init(captures rowCaptures: [Double?]) {
        let datedRows = rowCaptures.indices.filter { rowCaptures[$0] != nil }
            .sorted { (rowCaptures[$0]!, $0) < (rowCaptures[$1]!, $1) }
        order = datedRows + rowCaptures.indices.filter { rowCaptures[$0] == nil }
        var place = [Int](repeating: 0, count: rowCaptures.count)
        for (index, row) in order.enumerated() {
            place[row] = index
        }
        self.place = place
        dated = datedRows.count
        captures = datedRows.map { rowCaptures[$0]! }
        low = captures.map { $0 - FaceAssignmentPolicy.window }
        high = captures.map { $0 + FaceAssignmentPolicy.window }
    }
}

/// One person's faces laid out for comparison: the dated ones by capture, so a face's
/// window is one contiguous run found by binary search, then the undated ones, which every
/// face reaches. A face's best similarity to the person is then one vectorised maximum per
/// run instead of a comparison per face.
nonisolated struct PersonRun: Sendable {
    let faces: [FaceFact]
    let birthday: Double?
    /// Where these faces start in the columns they were laid out into.
    let start: Int
    /// The dated faces' capture instants, ascending; `faces[0 ..< times.count]` are dated.
    let times: [Double]

    init(faces: [FaceFact], birthday: Double?, start: Int = 0) {
        // Ordered by position, so ordering copies no face: a person's run is the one copy of
        // their faces it holds.
        let dated = faces.indices.filter { faces[$0].captureSeconds != nil }.sorted { lhs, rhs in
            (faces[lhs].captureSeconds!, faces[lhs].id.index) < (faces[rhs].captureSeconds!, faces[rhs].id.index)
        }
        var ordered: [FaceFact] = []
        ordered.reserveCapacity(faces.count)
        ordered.append(contentsOf: dated.lazy.map { faces[$0] })
        ordered.append(contentsOf: faces.lazy.filter { $0.captureSeconds == nil })
        self.faces = ordered
        self.birthday = birthday
        self.start = start
        times = dated.map { faces[$0].captureSeconds! }
    }

    /// The best similarity of `face` to these faces within its reach, from its row of
    /// similarities to every column; `skipping` is a local index left out (the face itself).
    func best(for face: FaceFact, row: UnsafeBufferPointer<Float>, rowStart: Int, skipping: Int? = nil) -> Float? {
        guard let base = row.baseAddress else { return nil }
        return times.withUnsafeBufferPointer { times in
            Self.best(
                in: base + rowStart + start, times: times.baseAddress, dated: times.count, count: faces.count,
                capture: face.captureSeconds, birthday: birthday, skipping: skipping
            )
        }
    }

    /// The best of a face's similarities to one person's faces within its reach: `row`
    /// points at its similarity to that person's first face, `times` at the dated faces'
    /// capture instants ascending (the first `dated` of `count` faces), the rest undated.
    /// A face is compared with every face of a person who was an adult on its date, and
    /// with every undated one; otherwise with those within `window` of it. Nil when no face
    /// is within reach. It allocates nothing: assignment calls it once per face and person
    /// every round.
    static func best(
        in row: UnsafePointer<Float>,
        times: UnsafePointer<Double>?,
        dated datedCount: Int,
        count: Int,
        capture: Double?,
        birthday: Double?,
        skipping: Int? = nil
    ) -> Float? {
        var dated = 0 ..< datedCount
        if let times, let capture, !FaceAssignmentPolicy.isAdult(at: capture, birthday: birthday) {
            dated = firstIndex(in: times, count: datedCount, from: capture - FaceAssignmentPolicy.window, inclusive: true)
                ..< firstIndex(in: times, count: datedCount, from: capture + FaceAssignmentPolicy.window, inclusive: false)
        }
        var best: Float = -2
        var reached = false
        guard let skipping else {
            raise(&best, &reached, row, dated)
            raise(&best, &reached, row, datedCount ..< count)
            return reached ? best : nil
        }
        let (datedBefore, datedAfter) = split(dated, skipping: skipping)
        let (undatedBefore, undatedAfter) = split(datedCount ..< count, skipping: skipping)
        raise(&best, &reached, row, datedBefore)
        raise(&best, &reached, row, datedAfter)
        raise(&best, &reached, row, undatedBefore)
        raise(&best, &reached, row, undatedAfter)
        return reached ? best : nil
    }

    /// Raises `best` to the maximum of `row` over `part`, a parameter rather than a captured
    /// variable so no call allocates.
    private static func raise(_ best: inout Float, _ reached: inout Bool, _ row: UnsafePointer<Float>, _ part: Range<Int>) {
        guard !part.isEmpty else { return }
        var value: Float = 0
        vDSP_maxv(row + part.lowerBound, 1, &value, vDSP_Length(part.count))
        best = max(best, value)
        reached = true
    }

    /// `range` without `skipping`, as at most two ranges.
    private static func split(_ range: Range<Int>, skipping: Int) -> (Range<Int>, Range<Int>) {
        guard range.contains(skipping) else { return (range, range.upperBound ..< range.upperBound) }
        return (range.lowerBound ..< skipping, skipping + 1 ..< range.upperBound)
    }

    /// The first index whose time is at least `bound` (`inclusive`) or above it.
    private static func firstIndex(in times: UnsafePointer<Double>, count: Int, from bound: Double, inclusive: Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if inclusive ? times[middle] >= bound : times[middle] > bound {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }
}

/// Ranks faces against the people of the last assignment (ADR 0047): for each face, the
/// people it could be, most likely first, each by its best similarity to that person's faces
/// within reach. Built from every face with a person the ranking may offer; ranking a few
/// faces compares them with one person's faces at a time.
nonisolated struct FaceRanker: Sendable {
    private let runs: [(person: PersonID, run: PersonRun)]
    private let birthdays: [PersonID: Double]

    static let empty = FaceRanker(faces: [], people: [], offered: [])

    /// `offered` are the people the ranking may name; faces of anyone else are left out.
    init(faces: [FaceFact], people: [PersonFact], offered: Set<PersonID>) {
        let birthdays = PersonFact.birthdays(of: people)
        var byPerson: [PersonID: [Int32]] = [:]
        for (index, face) in faces.enumerated() where face.isRecognisable {
            if let person = face.assignment.person, offered.contains(person) {
                byPerson[person, default: []].append(Int32(index))
            }
        }
        runs = byPerson.keys.sorted().map { person in
            (person, PersonRun(faces: byPerson[person]!.map { faces[Int($0)] }, birthday: birthdays[person]))
        }
        self.birthdays = birthdays
    }

    /// For each face, the people it could be, most likely first: its own person, people in
    /// `photoPeople` of its photo, people it was said not to be and people born after it are
    /// left out. One person's faces at a time, so ranking holds one person's vectors and never
    /// a copy of everyone's.
    func candidates(
        for faces: [FaceFact],
        photoPeople: [MediaAssetID: Set<PersonID>]
    ) -> [FaceID: [FaceCandidate]] {
        let excluded = faces.map { face in
            (photoPeople[face.id.asset] ?? []).union(face.rejected).union(face.assignment.person.map { [$0] } ?? [])
        }
        var ranked = [[FaceCandidate]](repeating: [], count: faces.count)
        for (person, run) in runs {
            let asked = faces.indices.filter {
                !excluded[$0].contains(person)
                    && FaceAssignmentPolicy.notBeforeBirthday(faces[$0].captureSeconds, birthdays[person])
            }
            guard !asked.isEmpty else { continue }
            BlockedSimilarity(rows: asked.map { faces[$0] }, columns: run.faces).forEachBlock { block, values in
                for row in block {
                    // A face is only in its own person's run, which `excluded` already leaves
                    // out: the ranker and the faces come from one read.
                    if let best = run.best(for: faces[asked[row]], row: values, rowStart: (row - block.lowerBound) * run.faces.count) {
                        ranked[asked[row]].append(FaceCandidate(person: person, similarity: best))
                    }
                }
            }
        }
        var out: [FaceID: [FaceCandidate]] = [:]
        for (index, face) in faces.enumerated() {
            out[face.id] = ranked[index].sorted { ($0.similarity, $1.person) > ($1.similarity, $0.person) }
        }
        return out
    }
}

/// Cosine similarities of `rows` against `columns`, unit-length embeddings, computed with
/// Accelerate a block of rows at a time into one reused buffer, so a large library never holds
/// the whole matrix and a pass allocates the same few megabytes however many faces it holds:
/// the columns once, transposed, and one block of rows and its products.
nonisolated struct BlockedSimilarity {
    private let rows: [FaceFact]
    private let columnsTransposed: ScratchBuffer<Float>
    let columnCount: Int
    /// Rows per block: `FaceAssignmentPolicy.blockRows`, fewer when the columns are many,
    /// so a block's products stay within `blockValues`.
    private let blockRows: Int
    static let dimensions = FaceEmbeddingModel.dimensions
    /// The most products a block holds: 16 MB.
    static let blockValues = 4 * 1024 * 1024

    init(rows: [FaceFact], columns: [FaceFact]) {
        self.rows = rows
        columnCount = columns.count
        blockRows = max(1, min(FaceAssignmentPolicy.blockRows, Self.blockValues / max(columns.count, 1)))
        let transposed = ScratchBuffer<Float>(count: columns.count * Self.dimensions)
        var widened = [Float](repeating: 0, count: Self.dimensions)
        for (column, face) in columns.enumerated() {
            widened.withUnsafeMutableBufferPointer { row in
                guard let from = row.baseAddress else { return }
                face.vector.copy(into: from)
                vDSP_mmov(from, transposed.base + column, 1, vDSP_Length(Self.dimensions), 1, vDSP_Length(columns.count))
            }
        }
        columnsTransposed = transposed
    }

    /// Calls `body(rows, values)` for each block of rows, in order; `values` holds those rows'
    /// similarities to every column, row-major, and is reused by the next block. Every row is
    /// visited even with no columns, when `values` is empty.
    func forEachBlock(_ body: (Range<Int>, UnsafeBufferPointer<Float>) -> Void) {
        guard !rows.isEmpty else { return }
        let block = ScratchBuffer<Float>(count: blockRows * Self.dimensions)
        let products = ScratchBuffer<Float>(count: blockRows * columnCount)
        var start = 0
        while start < rows.count {
            let count = min(blockRows, rows.count - start)
            if columnCount > 0 {
                for k in 0 ..< count {
                    rows[start + k].vector.copy(into: block.base + k * Self.dimensions)
                }
                vDSP_mmul(
                    block.base, 1, columnsTransposed.base, 1, products.base, 1,
                    vDSP_Length(count), vDSP_Length(columnCount), vDSP_Length(Self.dimensions)
                )
            }
            body(start ..< start + count, UnsafeBufferPointer(start: products.base, count: count * columnCount))
            start += count
        }
    }
}
