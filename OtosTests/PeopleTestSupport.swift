@testable import OtosKit

extension PeopleAssignment {
    /// Runs passes on a fresh owner as the loop would after each write's change, until one
    /// assigns nothing, and returns the gallery the window then reads.
    static func settle(store: CatalogStore, libraries: [CatalogLibraryState]) async throws -> CatalogPeopleState {
        try await PeopleAssignment(store: store).settle()
        return try await store.gallery(libraries: libraries)
    }
}

extension CatalogStore {
    /// The People state the window's gallery read gives now; `.empty` while it is not known.
    func gallery(libraries: [CatalogLibraryState]) async throws -> CatalogPeopleState {
        try await windowReads.peopleGallery(availableLibraryPaths: CatalogWindowPolicy.availablePaths(from: libraries))
            .map { CatalogPeopleState(gallery: $0) } ?? .empty
    }
}

extension FaceVectors {
    /// The vectors of `faces`, numbered as `PeopleSnapshot(facts:)` numbers them: 1, 2, … in
    /// order.
    init(facts faces: [FaceFact]) {
        self.init()
        add(faces.enumerated().map { Read(vector: Int64($0.offset + 1), embedding: $0.element.embedding) })
    }
}

extension PeopleSnapshot.Face {
    /// `fact` as the snapshot stores it, its vector numbered `vector`; a face of a `.mov` is a
    /// video's.
    init(_ fact: FaceFact, vector: Int64) {
        self.init(
            id: fact.id, captureSeconds: fact.captureSeconds, vector: vector, assignment: fact.assignment,
            rejected: fact.rejected, isInVideo: fact.id.asset.relativePath.rawValue.hasSuffix(".mov")
        )
    }
}

extension PeopleSnapshot {
    /// A snapshot of `facts`, their vectors numbered 1, 2, … in order (`FaceVectors(facts:)`).
    init(
        facts: [FaceFact],
        people: [Person],
        likeness: [FaceID: Float] = [:],
        keyPhotos: [PersonID: FaceID] = [:],
        photoOf: [MediaAssetID: MediaAssetID] = [:]
    ) {
        self.init(
            faces: PeopleFaces(facts.enumerated().map { Face($0.element, vector: Int64($0.offset + 1)) }),
            people: people,
            likeness: likeness,
            keyPhotos: keyPhotos,
            photoOf: photoOf
        )
    }
}

extension PeopleGalleryRead {
    /// What the gallery's read gives once People has written `snapshot`'s gallery facts
    /// (`PeopleSnapshot.computedGalleryFacts`), with the faces' tiles `tiles`: the read a
    /// catalog holding these faces answers, without one.
    init(snapshot: PeopleSnapshot, tiles: [FaceID: FaceTile], unchecked: MediaCount = MediaCount()) {
        let facts = snapshot.computedGalleryFacts
        self.init(
            people: snapshot.people.map { person in
                PeopleGalleryRead.Person(
                    id: person.id, name: person.name, birthday: person.birthday,
                    isHidden: person.isHidden, isFavorite: person.isFavorite,
                    facts: facts[person.id] ?? PersonGalleryFacts(media: MediaCount(), newestFace: nil),
                    keyPhoto: snapshot.keyPhotos[person.id].flatMap { tiles[$0] },
                    newest: facts[person.id]?.newestFace.flatMap { tiles[$0] }
                )
            },
            anchors: snapshot.faces.compactMap { face in
                guard face.assignment.isAnchor, let person = face.assignment.person else { return nil }
                return PeopleGalleryRead.Anchor(
                    person: person,
                    face: PersonAnchor(photo: face.id.asset, isInVideo: face.isInVideo, captureSeconds: face.captureSeconds),
                    isUsers: face.assignment == .user(person)
                )
            },
            unchecked: unchecked,
            hasFaces: !snapshot.faces.isEmpty
        )
    }
}

extension CatalogPeopleState {
    /// The state the window reads once People has written `snapshot`'s gallery facts.
    init(snapshot: PeopleSnapshot, tiles: [FaceID: FaceTile], unchecked: MediaCount = MediaCount()) {
        self.init(gallery: PeopleGalleryRead(snapshot: snapshot, tiles: tiles, unchecked: unchecked))
    }
}

extension PhotoFaces {
    /// The faces of `files` as `CatalogStore.photoFaces(of:)` reads them from a catalog holding
    /// `snapshot`'s faces with `tiles`: each file's faces of people not hidden, and its
    /// unidentified ones, in reading order.
    init(snapshot: PeopleSnapshot, tiles: [FaceID: FaceTile], files: [MediaAssetID], copies: [MediaAssetID: [MediaAssetID]] = [:]) {
        let hidden = Set(snapshot.people.filter(\.isHidden).map(\.id))
        let wanted = Set(files + copies.values.joined())
        var own: [MediaAssetID: [PhotoFace]] = [:]
        for face in snapshot.faces where wanted.contains(face.id.asset) {
            guard let tile = tiles[face.id], !(face.assignment.person.map(hidden.contains) ?? false) else { continue }
            own[face.id.asset, default: []].append(PhotoFace(tile: tile, person: face.assignment.person))
        }
        self.init(photos: files, own: own, copies: copies)
    }
}
