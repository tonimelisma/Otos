import Foundation
@testable import OtosKit
import Testing

/// A path's fingerprint is FNV-1a over its UTF-8, whichever way it is read: from the string's
/// contiguous storage, as identities are made, or byte by byte. An asset's is its two paths'
/// fingerprints mixed.
struct PathFingerprintTests {
    private static let texts = [
        "", "/library/", "2019/12/IMG_0001.HEIC", "Kuvat/kesä 2024/järvi.jpg", "Cafe\u{301}/photo.jpg",
        "写真/海.png", "🙂/a.jpg", "a\u{0}b",
    ]

    @Test func aStringHashesAsItsBytes() {
        for text in Self.texts {
            #expect(PathFingerprint.fnv1a64(PathFingerprint.offsetBasis, text) == PathFingerprint.fnv1a64(Array(text.utf8)))
            #expect(LibraryRootPath(rawValue: text).fingerprint == PathFingerprint.fnv1a64(Array(text.utf8)))
        }
    }

    /// An asset's fingerprint is its two paths' fingerprints mixed, so making an ID reads
    /// neither path again; swapping the root and the relative path makes another.
    @Test func anAssetHashesFromItsPathsFingerprints() {
        var seen = Set<UInt64>()
        for root in Self.texts {
            for relative in Self.texts {
                let rootPath = LibraryRootPath(rawValue: root)
                let relativePath = MediaRelativePath(rawValue: relative)
                let id = MediaAssetID(libraryRootPath: rootPath, relativePath: relativePath)
                #expect(id.fingerprint == PathFingerprint.mediaAsset(root: rootPath.fingerprint, relative: relativePath.fingerprint))
                seen.insert(id.fingerprint)
            }
        }
        #expect(seen.count == Self.texts.count * Self.texts.count)
    }
}
