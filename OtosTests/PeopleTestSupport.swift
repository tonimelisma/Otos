import Darwin
@testable import OtosKit

extension PeopleAssignment {
    /// Runs passes on a fresh owner as the loop would after each write's change, until one
    /// assigns nothing, and returns the gallery the window then reads.
    static func settle(store: CatalogStore, libraries: [CatalogLibraryState]) async throws -> CatalogPeopleState {
        try await PeopleAssignment(store: store, vectorSpace: .ample).settle()
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

extension FaceVectorFile.Space {
    /// The test process's temporary directory, on a volume reported with room to spare: a
    /// test's vectors never depend on how full the disk is (ADR 0027).
    static let ample = FaceVectorFile.Space.temporary(availableBytes: ampleVolumeCapacity)
}

extension FaceVectors {
    /// The vectors of `faces`, numbered as `PeopleSnapshot(facts:)` numbers them: 1, 2, … in
    /// order.
    static func held(facts faces: [FaceFact]) throws -> FaceVectors {
        var store = FaceVectorStore(space: .ample)
        try store.add(faces.enumerated().map { .init(vector: Int64($0.offset + 1), embedding: $0.element.embedding) })
        return store.vectors
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
    /// A snapshot of `facts`, their vectors numbered 1, 2, … in order (`FaceVectors.held(facts:)`).
    init(
        facts: [FaceFact],
        people: [Person],
        likeness: [FaceID: Float] = [:],
        keyPhotos: [PersonID: FaceID] = [:],
        photoOf: [MediaAssetID: MediaAssetID] = [:]
    ) {
        self.init(
            faces: PeopleFaces(facts.enumerated().map { index, fact in
                var face = Face(fact, vector: Int64(index + 1))
                face.likeness = likeness[fact.id]
                return face
            }),
            people: people,
            keyPhotos: keyPhotos,
            photoOf: photoOf
        )
    }

    /// Each face's stored likeness, by face.
    var storedLikeness: [FaceID: Float] {
        Dictionary(uniqueKeysWithValues: faces.compactMap { face in face.likeness.map { (face.id, $0) } })
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

/// The bytes every malloc zone of the process holds live now: what the heap's high-water is
/// made of. On macOS 27 a freed block stays in the footprint until the allocator reuses it
/// (`docs/research/2026-11-16-freed-memory-stays-in-the-footprint.md`), so the most a step
/// holds live at once is what it can leave behind.
nonisolated func liveHeapBytes() -> Int {
    var zones: UnsafeMutablePointer<vm_address_t>?
    var count: UInt32 = 0
    guard malloc_get_all_zones(mach_task_self_, nil, &zones, &count) == KERN_SUCCESS, let zones else { return 0 }
    var total = 0
    for index in 0 ..< Int(count) {
        guard let zone = UnsafeMutablePointer<malloc_zone_t>(bitPattern: zones[index]) else { continue }
        var stats = malloc_statistics_t()
        malloc_zone_statistics(zone, &stats)
        total += stats.size_in_use
    }
    return total
}
