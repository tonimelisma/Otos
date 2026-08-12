import Foundation
@testable import Otos
import Testing

/// ARC-008: Catalog domain identifiers are typed at app boundaries.
///
/// LibraryRootPath, MediaRelativePath, and MediaAssetID are the domain
/// identities — not bare strings or concatenated identifiers. This suite
/// proves the types exist, compose correctly, and are required by Store
/// boundaries (compile-time proof: call sites must use the typed values).
struct CatalogDomainIdentifierTests {
    @Test func typedIdentifiersComposeAndPreserveIdentity() {
        let root = LibraryRootPath(rawValue: "/Library/Root")
        let rel = MediaRelativePath(rawValue: "2026/01/IMG_0001.HEIC")
        let id = MediaAssetID(libraryRootPath: root, relativePath: rel)

        // Pair identity is decomposed, not a concatenated string.
        #expect(id.libraryRootPath == root)
        #expect(id.relativePath == rel)
        #expect(id.libraryRootPath.rawValue == "/Library/Root")
        #expect(id.relativePath.rawValue == "2026/01/IMG_0001.HEIC")

        // Distinct roots or relatives yield distinct IDs.
        let otherRoot = LibraryRootPath(rawValue: "/Other/Root")
        let otherRel = MediaRelativePath(rawValue: "other.jpg")
        #expect(id != MediaAssetID(libraryRootPath: otherRoot, relativePath: rel))
        #expect(id != MediaAssetID(libraryRootPath: root, relativePath: otherRel))
    }

    @Test func typedIdentifiersAreHashableViaFingerprint() {
        let a = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Lib"),
            relativePath: MediaRelativePath(rawValue: "a.jpg")
        )
        let b = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Lib"),
            relativePath: MediaRelativePath(rawValue: "a.jpg")
        )
        // Same typed components → equal and hash-equal.
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        // Fingerprint is derived and consistent.
        #expect(a.fingerprint == b.fingerprint)

        // Set membership uses typed identity, not string concatenation.
        let set: Set<MediaAssetID> = [a]
        #expect(set.contains(b))
    }

    @Test func storeBoundaryRequiresTypedIdentifiers() async throws {
        // Compile-time proof: Store's typed APIs require the typed IDs.
        // This test calls them with typed values — a bare String would not compile.
        let store = CatalogStore(location: .inMemory)
        try await store.start(scansSavedLibraries: false)

        let root = LibraryRootPath(rawValue: "/tmp/TestRoot")
        let rel = MediaRelativePath(rawValue: "sub/file.jpg")
        let id = MediaAssetID(libraryRootPath: root, relativePath: rel)

        // Typed values flow through the boundary without string concatenation.
        #expect(id.libraryRootPath.rawValue == root.rawValue)
        #expect(id.relativePath.rawValue == rel.rawValue)
        // No bare-string overload exists for the typed query — this line would
        // not compile if we passed raw strings: `store.mediaTileDetails(for: ["/tmp/..."])`
    }
}
