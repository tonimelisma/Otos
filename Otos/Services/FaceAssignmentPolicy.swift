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
    let embedding: FaceEmbedding
    let assignment: FaceAssignment
    /// People the user said this face is not (Remove Name).
    let rejected: Set<PersonID>
    /// The model can tell who this face is (`FaceRecognisability`). A face it cannot is still
    /// a face, and keeps what the user says of it, but Otos never guesses it, never groups
    /// it, and never compares another face with it.
    let isRecognisable: Bool

    init(
        id: FaceID, captureSeconds: Double?, embedding: FaceEmbedding, assignment: FaceAssignment, rejected: Set<PersonID>
    ) {
        self.id = id
        self.captureSeconds = captureSeconds
        self.embedding = embedding
        self.assignment = assignment
        self.rejected = rejected
        isRecognisable = FaceRecognisability.isRecognisable(embedding)
    }

    /// The same face with no person: a seed whose group no longer stands is Otos's to decide
    /// again.
    var opened: FaceFact {
        FaceFact(id: id, captureSeconds: captureSeconds, embedding: embedding, assignment: .open, rejected: rejected)
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
/// The rules and values were measured on the owner's labelled faces with the shipped model
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
    /// The strongest links each face keeps for grouping. Measured on the owner's labels: 10,
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
        let usable = faces.map { lapsed.contains($0.id) ? $0.opened : $0 }
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
        for _ in 0 ..< maximumGroupings {
            let groups = unnamedGroups(fill.leftover.map { usable[$0] })
            guard !groups.isEmpty else { break }
            let indexByID = Dictionary(uniqueKeysWithValues: usable.enumerated().map { ($1.id, $0) })
            for group in groups {
                let person = FaceAssignmentResult.Person.new(result.newPeople.count)
                result.newPeople.append(group)
                for face in group {
                    if let index = indexByID[face] {
                        anchors[index] = person
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

    /// The seeds of each person the user said nothing about and gave no face that no longer
    /// stand: every unrecognisable seed, and every seed when the recognisable ones span fewer
    /// than two days.
    static func lapsedSeeds(_ faces: [FaceFact], people: [PersonFact]) -> Set<FaceID> {
        let bare = Set(people.filter(\.isBare).map(\.id))
        var seeds: [PersonID: [FaceFact]] = [:]
        var claimed: Set<PersonID> = []
        for face in faces {
            switch face.assignment {
            case let .seed(person) where bare.contains(person):
                seeds[person, default: []].append(face)
            case let .user(person):
                claimed.insert(person)
            default:
                break
            }
        }
        var lapsed: Set<FaceID> = []
        for (person, faces) in seeds where !claimed.contains(person) {
            let standing = faces.filter(\.isRecognisable)
            if Set(standing.compactMap { day($0.captureSeconds) }).count < 2 {
                lapsed.formUnion(faces.map(\.id))
            } else {
                lapsed.formUnion(faces.filter { !$0.isRecognisable }.map(\.id))
            }
        }
        return lapsed
    }

    /// The faces linked strongest first at `groupLink` or above, never joining two faces of
    /// one photo, keeping groups that span two or more days; each group in path order, the
    /// groups in path order of their first face.
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
            .map { $0.map { faces[$0].id }.sorted(by: pathOrder) }
            .sorted { pathOrder($0[0], $1[0]) }
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
                values.withUnsafeBufferPointer { buffer in
                    for row in block {
                        let start = (row - block.lowerBound) * columns.faces.count
                        let face = rows[row]
                        if let best = columns.best(for: face, row: buffer, rowStart: start, skipping: columnOfPhoto[photo(face)]) {
                            likeness[face.id] = best
                        }
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

    /// An order of faces that does not change while they exist: photo path, library, place.
    static func pathOrder(_ lhs: FaceID, _ rhs: FaceID) -> Bool {
        (lhs.asset.relativePath.rawValue, lhs.asset.libraryRootPath.rawValue, lhs.index)
            < (rhs.asset.relativePath.rawValue, rhs.asset.libraryRootPath.rawValue, rhs.index)
    }
}

/// One run of chaining: from the anchors, every guessable face given out strongest first,
/// round by round (`FaceAssignmentPolicy`). Internal so its tests can compare it with the
/// rules applied one comparison at a time.
nonisolated struct Fill {
    /// Every face with a person, anchors included, by index into the faces.
    var assigned: [Int: FaceAssignmentResult.Person]
    /// Guessable faces no person reached, by index into the faces.
    var leftover: [Int]

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
        let rowFaces = rows.map { faces[$0] }
        let rowCaptures = rowFaces.map(\.captureSeconds)
        let rowPhotos = rowFaces.map(\.id.asset)
        let rejected = rowFaces.map { face in face.rejected.compactMap { slotOf[.existing($0)] } }
        let bornSlots = people.indices.filter { birthdayOf[$0] != nil }
        var assigned = anchors
        var photoPeople: [MediaAssetID: Set<Int>] = [:]
        for (index, person) in anchors {
            photoPeople[faces[index].id.asset, default: []].insert(slotOf[person]!)
        }
        let count = max(people.count, 1)
        // `best[row * count + slot]`: the row's best similarity to that person's evidence so
        // far; -2 before any of it is within reach.
        var best = [Float](repeating: -2, count: rows.count * count)
        var open = Set(rows.indices)
        var evidence = anchors.keys.filter { faces[$0].isRecognisable }.sorted()

        // The row's best similarity per person, with the people it may not have lowered out
        // of the way, then two vectorised maxima: assignment asks this of every open row
        // every round, so it is never a loop over the people. The first maximum wins a tie.
        var candidates = [Float](repeating: -2, count: count)
        func top(_ row: Int, excludingPhoto: Bool) -> (slot: Int, value: Float, second: Float)? {
            guard !people.isEmpty else { return nil }
            candidates.replaceSubrange(0 ..< people.count, with: best[row * count ..< row * count + people.count])
            for slot in rejected[row] {
                candidates[slot] = -2
            }
            if excludingPhoto, let inPhoto = photoPeople[rowPhotos[row]] {
                for slot in inPhoto {
                    candidates[slot] = -2
                }
            }
            for slot in bornSlots where !FaceAssignmentPolicy.notBeforeBirthday(rowCaptures[row], birthdayOf[slot]) {
                candidates[slot] = -2
            }
            var value: Float = 0
            var index: vDSP_Length = 0
            vDSP_maxvi(candidates, 1, &value, &index, vDSP_Length(people.count))
            guard value > -2 else { return nil }
            candidates[Int(index)] = -2
            var second: Float = 0
            vDSP_maxv(candidates, 1, &second, vDSP_Length(people.count))
            return (Int(index), value, second)
        }

        while !evidence.isEmpty, !open.isEmpty {
            raise(
                &best, count: count, rows: rowFaces, captures: rowCaptures, open: open.sorted(),
                evidence: evidence.map { (faces[$0], slotOf[assigned[$0]!]!) }, birthdays: birthdayOf
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
                let asset = rowFaces[candidate.row].id.asset
                guard !(photoPeople[asset]?.contains(candidate.slot) ?? false) else { continue }
                photoPeople[asset, default: []].insert(candidate.slot)
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
            photoPeople[rowFaces[candidate.row].id.asset, default: []].insert(found.slot)
            assigned[rows[candidate.row]] = people[found.slot]
            open.remove(candidate.row)
        }
        return Fill(assigned: assigned, leftover: open.sorted().map { rows[$0] })
    }

    private static func order(_ person: FaceAssignmentResult.Person) -> (Int, Int64) {
        switch person {
        case let .existing(id): (0, id.rawValue)
        case let .new(index): (1, Int64(index))
        }
    }

    /// Raises each open row's best similarity per person with the new evidence within reach:
    /// one matrix product for the round, then one vectorised maximum per person and row.
    /// Every round visits each open row once per person with new evidence (75 million visits
    /// a pass on the owner's 89,474 faces and 682 people), so a visit is pointer reads and
    /// the one reach scan, `PersonRun.best(in:)`, with no copy or allocation.
    private static func raise(
        _ best: inout [Float],
        count: Int,
        rows: [FaceFact],
        captures: [Double?],
        open: [Int],
        evidence: [(face: FaceFact, slot: Int)],
        birthdays: [Double?]
    ) {
        let bySlot = Dictionary(grouping: evidence, by: \.slot)
        var runs: [PersonRun] = []
        var slots: [Int] = []
        var columns: [FaceFact] = []
        for slot in bySlot.keys.sorted() {
            let run = PersonRun(faces: bySlot[slot]!.map(\.face), birthday: birthdays[slot], start: columns.count)
            runs.append(run)
            slots.append(slot)
            columns += run.faces
        }
        // Per cell, only pointer reads: an array subscript is a checked call at -Onone, the
        // configuration the installed app runs (ADR 0030).
        var layouts: [RunLayout] = []
        var times: [Double] = []
        for (run, slot) in zip(runs, slots) {
            layouts.append(RunLayout(
                slot: slot, start: run.start, count: run.faces.count, dated: run.times.count,
                timeStart: times.count, birthday: run.birthday
            ))
            times += run.times
        }
        let openRows = open.map { (row: $0, capture: captures[$0]) }
        BlockedSimilarity(rows: open.map { rows[$0] }, columns: columns).forEachBlock { range, values in
            values.withUnsafeBufferPointer { values in
                times.withUnsafeBufferPointer { times in
                    layouts.withUnsafeBufferPointer { layouts in
                        openRows.withUnsafeBufferPointer { openRows in
                            best.withUnsafeMutableBufferPointer { best in
                                guard let values = values.baseAddress, let firstRun = layouts.baseAddress,
                                      let openRows = openRows.baseAddress, let best = best.baseAddress
                                else { return }
                                let lastRun = firstRun + layouts.count
                                let allTimes = times.baseAddress
                                for local in range {
                                    let open = (openRows + local).pointee
                                    let similarities = values + (local - range.lowerBound) * columns.count
                                    var run = firstRun
                                    while run < lastRun {
                                        let layout = run.pointee
                                        run += 1
                                        guard let value = PersonRun.best(
                                            in: similarities + layout.start,
                                            times: allTimes?.advanced(by: layout.timeStart),
                                            dated: layout.dated, count: layout.count,
                                            capture: open.capture, birthday: layout.birthday
                                        ) else { continue }
                                        let cell = best + open.row * count + layout.slot
                                        if value > cell.pointee {
                                            cell.pointee = value
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Where one person's new evidence sits among a round's columns and capture times.
    private struct RunLayout {
        let slot: Int
        let start: Int
        let count: Int
        let dated: Int
        let timeStart: Int
        let birthday: Double?
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
        let dated = faces.compactMap { face in face.captureSeconds.map { (face: face, time: $0) } }
            .sorted { ($0.time, $0.face.id.index) < ($1.time, $1.face.id.index) }
        self.faces = dated.map(\.face) + faces.filter { $0.captureSeconds == nil }
        self.birthday = birthday
        self.start = start
        times = dated.map(\.time)
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
/// within reach. Built once per assignment from every face with a person the ranking may
/// offer; ranking a few faces is then one matrix product.
nonisolated struct FaceRanker: Sendable {
    private let columns: [FaceFact]
    private let runs: [(person: PersonID, run: PersonRun)]
    private let birthdays: [PersonID: Double]

    static let empty = FaceRanker(faces: [], people: [], offered: [])

    /// `offered` are the people the ranking may name; faces of anyone else are left out.
    init(faces: [FaceFact], people: [PersonFact], offered: Set<PersonID>) {
        let birthdays = PersonFact.birthdays(of: people)
        var byPerson: [PersonID: [FaceFact]] = [:]
        for face in faces where face.isRecognisable {
            if let person = face.assignment.person, offered.contains(person) {
                byPerson[person, default: []].append(face)
            }
        }
        var columns: [FaceFact] = []
        var runs: [(person: PersonID, run: PersonRun)] = []
        for person in byPerson.keys.sorted() {
            let run = PersonRun(faces: byPerson[person]!, birthday: birthdays[person], start: columns.count)
            runs.append((person, run))
            columns += run.faces
        }
        self.columns = columns
        self.runs = runs
        self.birthdays = birthdays
    }

    /// For each face, the people it could be, most likely first: its own person, people in
    /// `photoPeople` of its photo, people it was said not to be and people born after it are
    /// left out.
    func candidates(
        for faces: [FaceFact],
        photoPeople: [MediaAssetID: Set<PersonID>]
    ) -> [FaceID: [FaceCandidate]] {
        var out: [FaceID: [FaceCandidate]] = [:]
        BlockedSimilarity(rows: faces, columns: columns).forEachBlock { range, values in
            values.withUnsafeBufferPointer { buffer in
                for row in range {
                    let face = faces[row]
                    let excluded = (photoPeople[face.id.asset] ?? []).union(face.rejected)
                        .union(face.assignment.person.map { [$0] } ?? [])
                    let start = (row - range.lowerBound) * columns.count
                    var ranked: [FaceCandidate] = []
                    for (person, run) in runs where !excluded.contains(person)
                        && FaceAssignmentPolicy.notBeforeBirthday(face.captureSeconds, birthdays[person])
                    {
                        // A face is only in its own person's run, which `excluded` already
                        // leaves out: the ranker and the faces come from one snapshot.
                        if let best = run.best(for: face, row: buffer, rowStart: start) {
                            ranked.append(FaceCandidate(person: person, similarity: best))
                        }
                    }
                    out[face.id] = ranked.sorted { ($0.similarity, $1.person) > ($1.similarity, $0.person) }
                }
            }
        }
        return out
    }
}

/// Cosine similarities of `rows` against `columns`, unit-length embeddings, computed with
/// Accelerate one block of rows at a time so a large library never holds the whole matrix.
nonisolated struct BlockedSimilarity {
    let rowMatrix: [Float]
    let columnsTransposed: [Float]
    let rowCount: Int
    let columnCount: Int
    static let dimensions = FaceEmbeddingModel.dimensions

    init(rows: [FaceFact], columns: [FaceFact]) {
        rowCount = rows.count
        columnCount = columns.count
        rowMatrix = rows.flatMap(\.embedding.values)
        var transposed = [Float](repeating: 0, count: columns.count * Self.dimensions)
        let flat = columns.flatMap(\.embedding.values)
        if !columns.isEmpty {
            vDSP_mtrans(flat, 1, &transposed, 1, vDSP_Length(Self.dimensions), vDSP_Length(columns.count))
        }
        columnsTransposed = transposed
    }

    /// Calls `body(rows, values)` for each block of at most `FaceAssignmentPolicy.blockRows`
    /// rows, in order; `values` holds those rows' similarities to every column, row-major.
    /// Every row is visited even with no columns, when `values` is empty.
    func forEachBlock(_ body: (Range<Int>, [Float]) -> Void) {
        guard rowCount > 0 else { return }
        var start = 0
        while start < rowCount {
            let count = min(FaceAssignmentPolicy.blockRows, rowCount - start)
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
