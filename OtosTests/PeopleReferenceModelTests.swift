import Foundation
import GRDB
@testable import OtosKit
import Testing

/// People's rules as a reference model (ADR 0047): a small in-memory statement of what each of
/// the user's acts does to the stored faces, people and rejections, checked against the catalog
/// after every step of random sequences of acts, undos, redos, new readings and assignment
/// passes. The model predicts each act exactly except the one choice a merge makes by likeness
/// (which face of a photo both people are in stays theirs), which it checks is a legal one.
/// After every step the catalog must also hold the rules that no single act owns: a person in
/// a photo once, a held or rejected face never given back, one key photo per person, no face
/// before a birthday, and `person_photo` exactly what the faces say. Three of its photos are
/// each two identical files (ADR 0054), so every pass is also checked against what copies mean:
/// a photo counted once, a likeness only to other photos, no person Otos found in one photo
/// only, and a face named like its copy's twin where nothing forbids it.
@Suite(.testScope)
struct PeopleReferenceModelTests {
    // MARK: The stored state, as the model reads it

    struct FaceKey: Hashable, Comparable, CustomStringConvertible {
        let path: String
        let index: Int
        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.path, lhs.index) < (rhs.path, rhs.index)
        }

        var description: String {
            "\(path)#\(index)"
        }
    }

    struct Face: Equatable {
        var person: Int64?
        var column: Int
        var isNotFace: Bool
        var isKeyPhoto: Bool
        var likeness: Double?

        /// The assignment the store reads from the row; nil for a row no read accepts.
        var assignment: FaceAssignment? {
            try? FaceAssignmentColumn.assignment(column: column, person: person)
        }

        var isAnchor: Bool {
            column == FaceAssignmentColumn.user.rawValue || column == FaceAssignmentColumn.seed.rawValue
        }
    }

    struct Person: Equatable {
        var name: String?
        var birthday: String?
        var isHidden: Bool
        var isFavorite: Bool
        var birthdaySeconds: Double? {
            birthday.flatMap(PersonBirthday.init)?.seconds
        }
    }

    struct Rejection: Hashable {
        let face: FaceKey
        let person: Int64
    }

    struct PersonPhoto: Hashable {
        let person: Int64
        let path: String
    }

    struct State: Equatable {
        var faces: [FaceKey: Face]
        var people: [Int64: Person]
        var rejections: Set<Rejection>
        var personPhotos: Set<PersonPhoto>
        /// Each photo's local capture time; not changed by any People act.
        var capture: [String: Double]

        func facesOf(photo: String) -> [FaceKey] {
            faces.keys.filter { $0.path == photo }.sorted()
        }

        func facesOf(person: Int64) -> [FaceKey] {
            faces.filter { $0.value.person == person }.map(\.key).sorted()
        }

        func isBefore(_ face: FaceKey, birthday: Double?) -> Bool {
            guard let birthday, let capture = capture[face.path] else { return false }
            return capture < birthday
        }
    }

    static func read(_ queue: DatabaseQueue) throws -> State {
        try queue.read { db in
            var faces: [FaceKey: Face] = [:]
            for row in try Row.fetchAll(db, sql: """
            SELECT relative_path, face_index, person_id, assignment, is_not_face, is_key_photo, likeness FROM face
            """) {
                faces[FaceKey(path: row[0], index: row[1])] = Face(
                    person: row[2], column: row[3], isNotFace: (row[4] as Int) != 0, isKeyPhoto: (row[5] as Int) != 0,
                    likeness: row[6]
                )
            }
            var people: [Int64: Person] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, name, birthday, is_hidden, is_favorite FROM person") {
                people[row[0]] = Person(name: row[1], birthday: row[2], isHidden: (row[3] as Int) != 0, isFavorite: (row[4] as Int) != 0)
            }
            let rejections = try Set(Row.fetchAll(db, sql: "SELECT relative_path, face_index, person_id FROM face_rejection").map {
                Rejection(face: FaceKey(path: $0[0], index: $0[1]), person: $0[2])
            })
            let personPhotos = try Set(Row.fetchAll(db, sql: "SELECT person_id, relative_path FROM person_photo").map {
                PersonPhoto(person: $0[0], path: $0[1])
            })
            var capture: [String: Double] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT relative_path, best_capture_local FROM media_asset") {
                if let seconds: Double = row[1] {
                    capture[row[0]] = seconds
                }
            }
            return State(faces: faces, people: people, rejections: rejections, personPhotos: personPhotos, capture: capture)
        }
    }

    // MARK: The model of each act

    /// What an act is predicted to do: refused (the catalog unchanged), or the state after it.
    /// For a merge, `kept` names the face the catalog kept in each photo both people anchor;
    /// the model checks the choice is legal and predicts everything else.
    enum Prediction: Equatable {
        case refused
        case state(State)
    }

    struct ModelError: Error, CustomStringConvertible {
        let description: String
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func predict(_ act: PeopleAct, from before: State, key: (FaceID) -> FaceKey, created: Int64?, after: State) throws -> Prediction {
        var state = before
        /// `setFace`: a face that changes person stops being its old person's key photo.
        func setFace(_ face: FaceKey, person: Int64?, column: FaceAssignmentColumn) {
            guard var row = state.faces[face] else { return }
            if row.person != person {
                row.isKeyPhoto = false
            }
            row.person = person
            row.column = column.rawValue
            state.faces[face] = row
        }
        /// `give`: the user's word that the faces are `person`'s, or nil when refused.
        func give(_ faces: [FaceKey], to person: Int64) -> Bool {
            guard Set(faces.map(\.path)).count == faces.count, let target = state.people[person] else { return false }
            for face in faces {
                let others = state.facesOf(photo: face.path).filter { $0 != face && state.faces[$0]?.person == person }
                if others.contains(where: { state.faces[$0]?.column == FaceAssignmentColumn.user.rawValue }) {
                    return false
                }
                if state.isBefore(face, birthday: target.birthdaySeconds) {
                    return false
                }
            }
            for face in faces {
                for other in state.facesOf(photo: face.path) where other != face && state.faces[other]?.person == person {
                    state.faces[other]?.person = nil
                    state.faces[other]?.column = FaceAssignmentColumn.open.rawValue
                    state.faces[other]?.isKeyPhoto = false
                }
                setFace(face, person: person, column: .user)
                state.rejections.remove(Rejection(face: face, person: person))
            }
            return true
        }
        /// `holdToBirthday`: refused when the user gave one of `people` a face from before it;
        /// Otos's own faces of theirs from before it lose their person.
        func hold(to birthday: Double?, people: [Int64]) -> Bool {
            guard let birthday else { return true }
            let earlier = state.faces.filter { face in
                face.value.person.map(people.contains) == true && state.isBefore(face.key, birthday: birthday)
            }
            if earlier.contains(where: { $0.value.column == FaceAssignmentColumn.user.rawValue }) {
                return false
            }
            for face in earlier.keys {
                state.faces[face]?.person = nil
                state.faces[face]?.column = FaceAssignmentColumn.open.rawValue
                state.faces[face]?.isKeyPhoto = false
            }
            return true
        }

        switch act {
        case let .move(faces, person):
            guard give(faces.map(key), to: person.rawValue) else { return .refused }
        case let .moveToNewPerson(faces, name, birthday):
            let keys = faces.map(key)
            guard Set(keys.map(\.path)).count == keys.count else { return .refused }
            if let name, state.people.values.contains(where: { $0.name == name }) {
                return .refused
            }
            // A refused act creates no one; the model names the person it would make by the id
            // the catalog gave, or a placeholder no row holds.
            let person = created ?? -1
            state.people[person] = Person(name: name, birthday: birthday?.text, isHidden: false, isFavorite: false)
            guard give(keys, to: person) else { return .refused }
        case let .removeName(faces):
            for face in faces.map(key) {
                if let person = state.faces[face]?.person {
                    state.rejections.insert(Rejection(face: face, person: person))
                }
                setFace(face, person: nil, column: .held)
            }
        case let .notAFace(faces):
            for face in faces.map(key) {
                setFace(face, person: nil, column: .open)
                state.faces[face]?.isNotFace = true
            }
        case let .edit(id, name, birthday):
            let person = id.rawValue
            if let name, state.people.contains(where: { $0.key != person && $0.value.name == name }) {
                return .refused
            }
            guard hold(to: birthday?.seconds, people: [person]) else { return .refused }
            if state.people[person] != nil {
                state.people[person]?.name = name
                state.people[person]?.birthday = birthday?.text
            }
        case let .setHidden(person, hidden):
            state.people[person.rawValue]?.isHidden = hidden
        case let .setFavorite(person, favorite):
            state.people[person.rawValue]?.isFavorite = favorite
        case let .makeKeyPhoto(faceID, id):
            let person = id.rawValue
            let face = key(faceID)
            guard state.faces[face]?.person == person, give([face], to: person) else { return .refused }
            for other in state.facesOf(person: person) {
                state.faces[other]?.isKeyPhoto = false
            }
            state.faces[face]?.isKeyPhoto = true
        case let .merge(fromID, intoID):
            let from = fromID.rawValue
            let into = intoID.rawValue
            guard from != into, let target = state.people[into], let source = state.people[from] else { return .refused }
            let birthday = target.birthday ?? source.birthday
            guard hold(to: birthday.flatMap(PersonBirthday.init)?.seconds, people: [from, into]) else { return .refused }
            // The merged-away person's guesses become seeds.
            for face in state.facesOf(person: from) where state.faces[face]?.column == FaceAssignmentColumn.model.rawValue {
                state.faces[face]?.column = FaceAssignmentColumn.seed.rawValue
            }
            // A guess of either in a photo where the other has a face makes way.
            let pair: Set<Int64> = [from, into]
            for (face, row) in state.faces where row.column == FaceAssignmentColumn.model.rawValue {
                guard let person = row.person, pair.contains(person) else { continue }
                let other = state.facesOf(photo: face.path).contains { $0 != face && state.faces[$0]?.person.map { pair.contains($0) && $0 != person } == true }
                if other {
                    state.faces[face]?.person = nil
                    state.faces[face]?.column = FaceAssignmentColumn.open.rawValue
                    state.faces[face]?.isKeyPhoto = false
                }
            }
            // In each photo both anchor, one anchor stays; the catalog's choice must be one of
            // them, and every other is held.
            let anchors = state.faces.filter { $0.value.isAnchor && $0.value.person.map(pair.contains) == true }
            let byPhoto = Dictionary(grouping: anchors.keys, by: \.path)
            for (photo, faces) in byPhoto {
                let people = Set(faces.compactMap { state.faces[$0]?.person })
                guard people.count == 2 else { continue }
                let kept = faces.filter { after.faces[$0]?.person == into }
                guard kept.count == 1, let keep = kept.first else {
                    throw ModelError(description: "merge kept \(kept.count) of \(faces.sorted()) in \(photo)")
                }
                for face in faces where face != keep {
                    setFace(face, person: nil, column: .held)
                }
            }
            let intoHasKeyPhoto = state.facesOf(person: into).contains { state.faces[$0]?.isKeyPhoto == true }
            if intoHasKeyPhoto {
                for face in state.facesOf(person: from) {
                    state.faces[face]?.isKeyPhoto = false
                }
            }
            for face in state.facesOf(person: from) {
                state.faces[face]?.person = into
            }
            // What the user said a face is not carries to the merged person; no face is
            // rejected for its own person, whichever of the two the user gave it.
            for rejection in state.rejections where rejection.person == from {
                state.rejections.remove(rejection)
                state.rejections.insert(Rejection(face: rejection.face, person: into))
            }
            for rejection in state.rejections where rejection.person == into && state.faces[rejection.face]?.person == into {
                state.rejections.remove(rejection)
            }
            state.people[from] = nil
            state.people[into] = Person(
                name: target.name ?? source.name, birthday: birthday, isHidden: target.isHidden || source.isHidden,
                isFavorite: target.isFavorite || source.isFavorite
            )
        }
        state.personPhotos = Self.personPhotos(of: state)
        return .state(state)
    }

    /// The person-photo projection the faces define: one row per person and photo holding a
    /// face of theirs that is a face (ADR 0047, v78).
    static func personPhotos(of state: State) -> Set<PersonPhoto> {
        Set(state.faces.compactMap { face, row in
            guard let person = row.person, !row.isNotFace else { return nil }
            return PersonPhoto(person: person, path: face.path)
        })
    }

    // MARK: Rules no single act owns

    /// `dateMoved`: a photo's date moved since the last pass, which alone puts Otos's faces
    /// before a birthday until that pass.
    static func violations(of state: State, dateMoved: Bool = false) -> [String] {
        var found: [String] = []
        for (face, row) in state.faces {
            if row.assignment == nil {
                found.append("\(face): malformed row (column \(row.column), person \(row.person.map(String.init) ?? "nil"))")
            }
            if let person = row.person, state.people[person] == nil {
                found.append("\(face): names person \(person), who does not exist")
            }
            if row.isNotFace, let person = row.person {
                found.append("\(face): not a face, yet \(person)'s")
            }
            if row.column == FaceAssignmentColumn.held.rawValue, let person = row.person {
                found.append("\(face): held, yet \(person)'s")
            }
            if let person = row.person, state.rejections.contains(Rejection(face: face, person: person)) {
                found.append("\(face): given to \(person), whom the user said it is not")
            }
            // A photo whose date moved keeps the user's word; Otos's own face there loses its
            // person at the next pass (owner decision, 2026-11-21).
            if let person = row.person, row.column != FaceAssignmentColumn.user.rawValue, !dateMoved,
               state.isBefore(face, birthday: state.people[person]?.birthdaySeconds)
            {
                found.append("\(face): Otos's \(person), from before their birthday")
            }
            if row.isKeyPhoto, row.person == nil {
                found.append("\(face): a key photo of no one")
            }
        }
        for photo in Set(state.faces.keys.map(\.path)) {
            let people = state.facesOf(photo: photo).compactMap { face in
                state.faces[face].flatMap { $0.isNotFace ? nil : $0.person }
            }
            if Set(people).count != people.count {
                found.append("\(photo): one person holds two faces (\(people.sorted()))")
            }
        }
        for person in state.people.keys {
            let keys = state.facesOf(person: person).filter { state.faces[$0]?.isKeyPhoto == true }
            if keys.count > 1 {
                found.append("person \(person): \(keys.count) key photos")
            }
        }
        if state.personPhotos != personPhotos(of: state) {
            found.append("person_photo differs from the faces: \(state.personPhotos.symmetricDifference(personPhotos(of: state)))")
        }
        return found.sorted()
    }

    /// What an assignment pass must never change: the user's word, a held face, a face that
    /// is no face, the rejections and the people the user said something about.
    static func passViolations(before: State, after: State) -> [String] {
        var found: [String] = []
        for (face, row) in before.faces {
            guard let now = after.faces[face] else { continue }
            if row.column == FaceAssignmentColumn.user.rawValue, now.person != row.person || now.column != row.column {
                found.append("\(face): the user's word for \(row.person.map(String.init) ?? "nil") changed by a pass")
            }
            if row.column == FaceAssignmentColumn.held.rawValue, now.column != row.column {
                found.append("\(face): held, given a person by a pass")
            }
            if row.isNotFace != now.isNotFace || row.isKeyPhoto && !now.isKeyPhoto && now.person == row.person {
                found.append("\(face): its not-a-face or key-photo mark changed by a pass")
            }
        }
        // A pass deletes only a person Otos found and no face holds; what was said about them
        // goes with them.
        if before.rejections.filter({ after.people[$0.person] != nil }) != after.rejections {
            found.append("a pass changed the rejections of people it kept")
        }
        for (id, person) in before.people where person.name != nil || person.birthday != nil || person.isHidden || person.isFavorite {
            if after.people[id] != person {
                found.append("person \(id), whom the user named or marked, changed by a pass")
            }
        }
        return found
    }

    /// Each person's photo count as People stored it for the gallery (`person_summary`).
    static func galleryPhotos(_ queue: DatabaseQueue) throws -> [Int64: Int] {
        try queue.read { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT person_id, photos FROM person_summary").map {
                ($0[0] as Int64, $0[1] as Int)
            })
        }
    }

    /// What a pass must make of a photo that is several identical files (ADR 0054), whose
    /// files read alike: `photoOf` names the file each file's photo is counted as, `copyOf`
    /// each file's copy, `photos` the gallery's stored counts.
    /// - A person's photos count each photo once.
    /// - A likeness compares a face only with the person's faces in other photos, so a person
    ///   in one photo only has none.
    /// - A person Otos found, whom the user said nothing about, stands only in two photos or
    ///   more: a photo's copies are one photo read twice.
    /// - A face Otos may name is its copy's twin: where the copy's face is anchored to a person
    ///   it may have, it has them.
    static func copyViolations(
        of state: State,
        photoOf: (String) -> String,
        copyOf: [String: String],
        photos: [Int64: Int]
    ) -> [String] {
        var found: [String] = []
        for (id, person) in state.people {
            let faces = state.facesOf(person: id)
            let counted = Set(faces.map { photoOf($0.path) })
            if photos[id] ?? 0 != counted.count {
                found.append("person \(id): \(photos[id] ?? 0) photos stored, in \(counted.count)")
            }
            for face in faces where state.faces[face]?.likeness != nil && counted.subtracting([photoOf(face.path)]).isEmpty {
                found.append("\(face): a likeness to \(id), who is in no other photo")
            }
            let bare = person.name == nil && person.birthday == nil && !person.isHidden && !person.isFavorite
                && !faces.contains { state.faces[$0]?.isKeyPhoto == true || state.faces[$0]?.column == FaceAssignmentColumn.user.rawValue }
            if bare, counted.count == 1 {
                found.append("person \(id): found by Otos in one photo only, \(faces)")
            }
        }
        for (face, row) in state.faces where row.assignment?.isGuessable == true && !row.isNotFace {
            guard let copy = copyOf[face.path], let twin = state.faces[FaceKey(path: copy, index: face.index)],
                  twin.isAnchor, !twin.isNotFace, let person = twin.person, row.person != person else { continue }
            let elsewhere = state.facesOf(photo: face.path).contains { $0 != face && state.faces[$0]?.person == person }
            if !elsewhere, !state.rejections.contains(Rejection(face: face, person: person)),
               !state.isBefore(face, birthday: state.people[person]?.birthdaySeconds)
            {
                found.append("\(face): \(row.person.map(String.init) ?? "no one"), its copy's twin \(person)'s")
            }
        }
        return found.sorted()
    }

    // MARK: The random walk

    struct Undo {
        let act: PeopleAct
        let restore: PeopleRestore
        let before: State
        let after: State
        /// Something other than this act changed the catalog since it was performed.
        var overtaken = false
    }

    // swiftlint:disable:next cyclomatic_complexity
    func walk(seed: UInt64, steps: Int) async throws -> Walk {
        let names = (0 ..< 10).map { "p\($0).jpg" }
        let directory = try makeTestDirectory()
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(
            in: directory, files: names, database: directory.appending(path: "db/catalog.sqlite")
        )
        let queue = try makeTestDatabaseQueue(path: #require(library.databaseURL).path(percentEncoded: false))
        var random = SplitMix64(seed: seed)
        func roll(_ count: Int) -> Int {
            Int(random.next() % UInt64(count))
        }
        func pick<T>(_ values: [T]) -> T? {
            values.isEmpty ? nil : values[roll(values.count)]
        }
        func faceID(_ key: FaceKey) -> FaceID {
            FaceID(asset: library.id(key.path), index: key.index)
        }
        func key(_ id: FaceID) -> FaceKey {
            FaceKey(path: id.asset.relativePath.rawValue, index: id.index)
        }

        // Four people, each a direction of the embedding; a photo holds up to three of them, on
        // one of twelve days across 2020–2023, so a pass finds people and birthdays matter. A
        // reading that moves the photo's date is the file's date corrected after it was named.
        // Three photos are each two identical files (ADR 0054): p0/p1, p2/p3 and p4/p5 share a
        // digest, a date and, read alike, their faces; each file keeps its own face rows.
        let copyOf = Dictionary(uniqueKeysWithValues: (0 ..< 6).map { ("p\($0).jpg", "p\($0 ^ 1).jpg") })
        let photoOf = { (name: String) in min(name, copyOf[name] ?? name) }
        let photos = Array(Set(names.map(photoOf))).sorted()
        // Each photo's date: one of the twelve days, by its name, until a reading moves it.
        var dates = Dictionary(uniqueKeysWithValues: names.enumerated().map { index, name in
            (name, Date(timeIntervalSince1970: 1_580_000_000 + Double(index * 5 % 12) * 100 * 86400))
        })
        var lastFaces: [String: [DetectedFace]] = [:]
        var dateMoved = false
        /// A reading of `name`'s photo: new faces for the photo, written to the file and its
        /// copy; `alone` reads only the file, with the faces the photo last showed (the same
        /// bytes read again), and never moves its date.
        func read(_ name: String, movingItsDate moves: Bool = false, alone: Bool = false) async throws {
            let photo = photoOf(name)
            if moves {
                dates[photo] = Date(timeIntervalSince1970: 1_580_000_000 + Double(roll(12)) * 100 * 86400)
            }
            var faces = alone ? lastFaces[photo] : nil
            if faces == nil {
                let identities = Array(Set((0 ..< 1 + roll(3)).map { _ in roll(4) })).sorted()
                faces = identities.enumerated().map { index, identity in
                    PeopleStoreTests.face(x: 0.05 + 0.3 * Double(index), toward: [identity * 8: 1, 200 + roll(200): 0.15])
                }
            }
            lastFaces[photo] = faces
            let files = alone ? [name] : [name] + (copyOf[name].map { [$0] } ?? [])
            try await library.readFaces(files.map { library.result(for: $0, faces: faces ?? [], captured: dates[photo]) })
            // The copies' digest, as enrichment reads it for identical bytes.
            if let index = photos.firstIndex(of: photo), copyOf[name] != nil {
                let digest = try #require(ContentDigest(bytes: Array(repeating: UInt8(index + 1), count: ContentDigest.byteCount)))
                for (id, asset) in try await library.store.windowReads.mediaAssets(for: files.map(library.id)) {
                    _ = await library.store.applyContentHash(ContentHashResult(
                        id: id, contentHash: digest, sourceSize: asset.byteSize,
                        sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt)
                    ))
                }
            }
        }
        for photo in photos {
            try await read(photo)
        }
        let stored = try Self.read(queue)
        let snapshotFaces = try await library.store.backgroundReads.peopleSnapshot().faces.count
        #expect(stored.faces.count >= names.count && snapshotFaces == stored.faces.count, "seed \(seed): \(stored.faces.count) stored faces, \(snapshotFaces) in the snapshot, \(stored.capture.count) dated photos")
        let owner = PeopleAssignment(store: library.store, vectorSpace: .ample)
        var undos: [Undo] = []
        var redos: [(restore: PeopleRestore, expected: State)] = []
        var failures: [String] = []
        var tally: [String: Int] = [:]
        func record(_ step: Int, _ what: String, _ problems: [String]) {
            failures += problems.map { "seed \(seed) step \(step) \(what): \($0)" }
        }
        let birthdays = ["2019", "2021", "2021-07-01", "2022", nil] as [String?]

        for step in 0 ..< steps {
            let before = try Self.read(queue)
            let visible = before.faces.filter { !$0.value.isNotFace }.map(\.key).sorted()
            let people = before.people.keys.sorted()
            let choice = roll(16)
            if choice < 10 {
                // An act of the user's.
                let act: PeopleAct?
                switch choice {
                case 0, 1:
                    act = pick(visible).flatMap { face in pick(people).map { .move([faceID(face)], to: PersonID(rawValue: $0)) } }
                case 2:
                    let faces = (0 ..< 1 + roll(2)).compactMap { _ in pick(visible) }
                    act = faces.isEmpty ? nil : .moveToNewPerson(
                        Array(Set(faces)).sorted().map(faceID), name: roll(3) == 0 ? nil : "P\(roll(6))",
                        birthday: birthdays[roll(birthdays.count)].flatMap(PersonBirthday.init)
                    )
                case 3:
                    act = pick(visible.filter { before.faces[$0]?.person != nil }).map { .removeName([faceID($0)]) }
                case 4:
                    act = pick(visible).map { .notAFace([faceID($0)]) }
                case 5:
                    act = pick(people).map {
                        .edit(
                            PersonID(rawValue: $0), name: roll(3) == 0 ? nil : "P\(roll(6))",
                            birthday: birthdays[roll(birthdays.count)].flatMap(PersonBirthday.init)
                        )
                    }
                case 6, 7:
                    let from = pick(people)
                    // Now and then a person into themself, which no surface offers and the
                    // catalog refuses.
                    let into = roll(8) == 0 ? from : pick(people.filter { $0 != from })
                    act = from.flatMap { from in into.map { .merge(PersonID(rawValue: from), into: PersonID(rawValue: $0)) } }
                case 8:
                    act = pick(people).map { person in
                        let id = PersonID(rawValue: person)
                        return roll(2) == 0 ? .setHidden(id, roll(2) == 0) : .setFavorite(id, roll(2) == 0)
                    }
                default:
                    act = pick(visible.compactMap { face in before.faces[face]?.person.map { (face, $0) } }).map {
                        .makeKeyPhoto(faceID($0.0), of: PersonID(rawValue: $0.1))
                    }
                }
                guard let act else { continue }
                let outcome: PeopleActOutcome?
                do {
                    outcome = try await library.store.perform(act)
                } catch is PeopleRuleViolation {
                    outcome = nil
                }
                let after = try Self.read(queue)
                let created: Int64? = if case .moveToNewPerson = act {
                    outcome?.person?.rawValue
                } else {
                    nil
                }
                do {
                    let predicted = try Self.predict(act, from: before, key: key, created: created, after: after)
                    switch (predicted, outcome) {
                    case (.refused, nil):
                        tally["refused", default: 0] += 1
                        if after != before {
                            record(step, "refused \(act.logName)", ["a refused act changed the catalog"])
                        }
                    case (.refused, .some):
                        record(step, act.logName, ["the model refuses \(act), the catalog performed it"])
                    case (.state, nil):
                        record(step, act.logName, ["the model performs \(act), the catalog refused it"])
                    case let (.state(expected), .some):
                        tally[act.logName, default: 0] += 1
                        if expected != after {
                            record(step, act.logName, Self.differences(expected: expected, actual: after, act: act))
                        }
                    }
                } catch {
                    record(step, act.logName, ["\(error)"])
                }
                record(step, "after \(act.logName)", Self.violations(of: after, dateMoved: dateMoved))
                if let outcome {
                    for index in undos.indices {
                        undos[index].overtaken = true
                    }
                    undos.append(Undo(act: act, restore: outcome.restore, before: before, after: after))
                    redos = []
                }
            } else if choice < 12 {
                // Undo the newest act. Undone at once it restores the catalog exactly; after
                // other writes it restores the rows it recorded.
                guard let undo = undos.popLast() else { continue }
                let redo: PeopleRestore
                do {
                    redo = try await library.store.restore(undo.restore)
                } catch {
                    record(step, "undo \(undo.act.logName)", ["undo threw \(error)"])
                    continue
                }
                let now = try Self.read(queue)
                tally[undo.overtaken ? "lateUndo" : "undo", default: 0] += 1
                if !undo.overtaken, now != undo.before {
                    record(step, "undo \(undo.act.logName)", Self.differences(expected: undo.before, actual: now, act: undo.act))
                }
                record(step, "after undo \(undo.act.logName)", Self.violations(of: now, dateMoved: dateMoved))
                for index in undos.indices {
                    undos[index].overtaken = true
                }
                redos.append((redo, undo.overtaken ? now : undo.after))
                if !undo.overtaken {
                    // Redo at once, then undo again: both restore exactly.
                    try await library.store.restore(redo)
                    let redone = try Self.read(queue)
                    if redone != undo.after {
                        record(step, "redo \(undo.act.logName)", Self.differences(expected: undo.after, actual: redone, act: undo.act))
                    }
                    try await library.store.restore(undo.restore)
                    if try Self.read(queue) != undo.before {
                        record(step, "undo again \(undo.act.logName)", ["the second undo did not restore the catalog"])
                    }
                }
            } else if choice < 15 {
                // An assignment pass.
                await owner.request()
                try await owner.settle()
                let after = try Self.read(queue)
                tally["pass", default: 0] += 1
                tally["peopleAfterPass", default: 0] = max(tally["peopleAfterPass"] ?? 0, after.people.count)
                // The rules for copies decided something: the catalog read the copies as one
                // photo, and a person stood on both files of one.
                try await tally["copiesRead", default: 0] = max(
                    tally["copiesRead"] ?? 0, library.store.backgroundReads.peopleSnapshot().photoOf.count
                )
                for (face, row) in after.faces {
                    guard let person = row.person, let copy = copyOf[face.path],
                          let twin = after.faces[FaceKey(path: copy, index: face.index)], twin.person == person else { continue }
                    tally["personOnBothCopies", default: 0] += 1
                }
                dateMoved = false
                try record(
                    step, "pass",
                    Self.violations(of: after) + Self.passViolations(before: before, after: after)
                        + Self.copyViolations(of: after, photoOf: photoOf, copyOf: copyOf, photos: Self.galleryPhotos(queue))
                )
                if after != before {
                    for index in undos.indices {
                        undos[index].overtaken = true
                    }
                }
            } else if let name = pick(names) {
                // A new reading of a photo: its faces are replaced, the user's word carried;
                // one in three moves the photo's date, and a copy is now and then read alone.
                let moves = roll(3) == 0
                try await read(name, movingItsDate: moves, alone: !moves && copyOf[name] != nil && roll(2) == 0)
                dateMoved = dateMoved || moves
                for index in undos.indices {
                    undos[index].overtaken = true
                }
                try record(step, "read \(name)", Self.violations(of: Self.read(queue), dateMoved: dateMoved))
            }
        }
        await library.store.shutdown()
        let notActs: Set = ["refused", "undo", "lateUndo", "pass", "peopleAfterPass", "copiesRead", "personOnBothCopies"]
        let performed = tally.filter { !notActs.contains($0.key) }.values.reduce(0, +)
        return Walk(
            performed: performed, mostPeople: tally["peopleAfterPass"] ?? 0, copiesRead: tally["copiesRead"] ?? 0,
            personOnBothCopies: tally["personOnBothCopies"] ?? 0, failures: failures
        )
    }

    /// What one walk did and found.
    struct Walk {
        /// The acts the catalog performed.
        let performed: Int
        /// The most people any pass left.
        let mostPeople: Int
        /// The most files the catalog counted as another file's photo after a pass.
        var copiesRead = 0
        /// Faces after passes whose copy's twin face had the same person.
        var personOnBothCopies = 0
        /// Every divergence from the model and every broken rule, by seed and step.
        let failures: [String]
    }

    static func differences(expected: State, actual: State, act: PeopleAct) -> [String] {
        var found: [String] = []
        for face in Set(expected.faces.keys).union(actual.faces.keys).sorted() where expected.faces[face] != actual.faces[face] {
            found.append("\(face): expected \(String(describing: expected.faces[face])), got \(String(describing: actual.faces[face]))")
        }
        for person in Set(expected.people.keys).union(actual.people.keys).sorted() where expected.people[person] != actual.people[person] {
            found.append("person \(person): expected \(String(describing: expected.people[person])), got \(String(describing: actual.people[person]))")
        }
        if expected.rejections != actual.rejections {
            let missing = expected.rejections.subtracting(actual.rejections)
            let extra = actual.rejections.subtracting(expected.rejections)
            found.append("rejections: \(missing) missing, \(extra) not expected")
        }
        if expected.personPhotos != actual.personPhotos {
            found.append("person_photo differs: \(expected.personPhotos.symmetricDifference(actual.personPhotos))")
        }
        return found.isEmpty ? ["states differ (\(act))"] : found
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6] as [UInt64])
    func theCatalogFollowsTheModel(seed: UInt64) async throws {
        let walk = try await walk(seed: seed, steps: 60)
        // The walk compared acts on people, not an empty catalog.
        #expect(walk.performed >= 15, "seed \(seed): only \(walk.performed) acts performed")
        #expect(walk.mostPeople > 0, "seed \(seed): no pass found anyone")
        #expect(walk.copiesRead == 3, "seed \(seed): the catalog read \(walk.copiesRead) files as copies, not 3")
        #expect(walk.personOnBothCopies > 0, "seed \(seed): no person stood on both files of a photo")
        #expect(walk.failures.isEmpty, "\(walk.failures.count) failures:\n\(walk.failures.prefix(40).joined(separator: "\n"))")
    }
}
