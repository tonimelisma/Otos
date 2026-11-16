@testable import OtosKit

extension PeopleAssignment {
    /// Runs passes on a fresh owner as the loop would after each write's change, until one
    /// assigns nothing, and returns the gallery it publishes.
    static func settle(store: CatalogStore, libraries: [CatalogLibraryState]) async throws -> CatalogPeopleState {
        try await PeopleAssignment(store: store, builder: nil).settle(libraries: libraries)
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
    /// `fact` as the snapshot stores it, its vector numbered `vector`.
    init(_ fact: FaceFact, vector: Int64) {
        self.init(id: fact.id, captureSeconds: fact.captureSeconds, vector: vector, assignment: fact.assignment, rejected: fact.rejected)
    }
}

extension PeopleSnapshot {
    /// A snapshot of `facts`, their vectors numbered 1, 2, … in order (`FaceVectors(facts:)`).
    init(
        facts: [FaceFact],
        tiles: [FaceID: FaceTile],
        people: [Person],
        likeness: [FaceID: Float] = [:],
        keyPhotos: [PersonID: FaceID] = [:],
        photoOf: [MediaAssetID: MediaAssetID] = [:],
        unchecked: MediaCount
    ) {
        self.init(
            faces: facts.enumerated().map { Face($0.element, vector: Int64($0.offset + 1)) },
            tiles: tiles,
            people: people,
            likeness: likeness,
            keyPhotos: keyPhotos,
            photoOf: photoOf,
            unchecked: unchecked
        )
    }
}
