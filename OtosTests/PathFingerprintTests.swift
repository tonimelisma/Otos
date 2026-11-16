import Foundation
@testable import OtosKit
import Testing

/// A path's fingerprint is FNV-1a over its UTF-8, whichever way it is read: from the string's
/// contiguous storage, as identities are made, or byte by byte. An asset's continues from its
/// root's own fingerprint, so it is the same as hashing the root again.
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

    @Test func anAssetHashesFromItsRootsFingerprintAsFromTheRoot() {
        for root in Self.texts {
            for relative in Self.texts {
                var bytes = Array(root.utf8)
                bytes.append(0)
                bytes += Array(relative.utf8)
                let id = MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: root), relativePath: MediaRelativePath(rawValue: relative))
                #expect(id.fingerprint == PathFingerprint.fnv1a64(bytes))
                #expect(PathFingerprint.mediaAsset(root: root, relative: relative) == id.fingerprint)
            }
        }
    }
}
