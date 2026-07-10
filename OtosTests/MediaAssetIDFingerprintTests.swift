import Foundation
@testable import Otos
import Testing

struct MediaAssetIDFingerprintTests {
    @Test func equalPathsProduceEqualFingerprintsAndHashEqual() {
        let left = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "a/b.jpg")
        )
        let right = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "a/b.jpg")
        )
        #expect(left == right)
        #expect(left.fingerprint == right.fingerprint)
        #expect(left.libraryRootPath.fingerprint == right.libraryRootPath.fingerprint)
        #expect(left.relativePath.fingerprint == right.relativePath.fingerprint)
        #expect(left.hashValue == right.hashValue)
    }

    @Test func differingFingerprintImpliesInequality() {
        let left = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "a.jpg")
        )
        let right = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "b.jpg")
        )
        #expect(left.fingerprint != right.fingerprint)
        #expect(left != right)
    }

    @Test func fingerprintIsDeterministicAcrossConstruction() {
        let first = PathFingerprint.mediaAsset(root: "/Volumes/A", relative: "x/y.CR3")
        let second = PathFingerprint.mediaAsset(root: "/Volumes/A", relative: "x/y.CR3")
        #expect(first == second)
        #expect(first != PathFingerprint.mediaAsset(root: "/Volumes/B", relative: "x/y.CR3"))
    }

    @Test func pathComponentsRoundTripCodableAsRawStringsOnly() throws {
        let root = LibraryRootPath(rawValue: "/Users/example/Pictures")
        let relative = MediaRelativePath(rawValue: "2024/IMG_0001.NEF")
        let rootData = try JSONEncoder().encode(root)
        let relativeData = try JSONEncoder().encode(relative)
        // Persistence is the raw path string only — fingerprint is never encoded.
        let encodedRootString = try JSONDecoder().decode(String.self, from: rootData)
        let encodedRelativeString = try JSONDecoder().decode(String.self, from: relativeData)
        #expect(encodedRootString == root.rawValue)
        #expect(encodedRelativeString == relative.rawValue)
        let rootJSON = try #require(String(data: rootData, encoding: .utf8))
        #expect(!rootJSON.contains("fingerprint"))

        let decodedRoot = try JSONDecoder().decode(LibraryRootPath.self, from: rootData)
        let decodedRelative = try JSONDecoder().decode(MediaRelativePath.self, from: relativeData)
        #expect(decodedRoot == root)
        #expect(decodedRelative == relative)
        #expect(decodedRoot.fingerprint == root.fingerprint)
    }

    @Test func setMembershipUsesFingerprintFastPathWithoutFalseEquality() {
        let ids = (0 ..< 100).map { index in
            MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
                relativePath: MediaRelativePath(rawValue: "asset-\(index).jpg")
            )
        }
        let membership = Set(ids)
        #expect(membership.count == 100)
        for id in ids {
            #expect(membership.contains(id))
        }
        let outsider = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "missing.jpg")
        )
        #expect(!membership.contains(outsider))
    }
}
