import Foundation
@testable import OtosKit
import Testing

struct RootNamespaceTests {
    @Test func keyRespectsRootCapabilities() {
        let root = LibraryRootPath(rawValue: "/Volumes/card")
        let insensitive = RootNamespace(
            root: root,
            capabilities: VolumeNamespaceCapabilities(isCaseSensitive: false, prefersDecomposedUnicode: true)
        )
        let sensitive = RootNamespace(
            root: root,
            capabilities: VolumeNamespaceCapabilities(isCaseSensitive: true, prefersDecomposedUnicode: true)
        )

        #expect(insensitive.key(MediaRelativePath(rawValue: "IMG_1.JPG")) == insensitive.key(MediaRelativePath(rawValue: "img_1.jpg")))
        #expect(sensitive.key(MediaRelativePath(rawValue: "IMG_1.JPG")) != sensitive.key(MediaRelativePath(rawValue: "img_1.jpg")))
    }

    @Test func keyUsesByteEqualityAfterSymmetricNormalization() {
        let namespace = RootNamespace(
            root: LibraryRootPath(rawValue: "/Volumes/card"),
            capabilities: VolumeNamespaceCapabilities(isCaseSensitive: true, prefersDecomposedUnicode: true)
        )
        let nfc = MediaRelativePath(rawValue: "café.jpg")
        let nfd = MediaRelativePath(rawValue: "café.jpg")

        #expect(namespace.key(nfc) == namespace.key(nfd))
        #expect(FilesystemNameKey(rawValue: nfc.rawValue) != FilesystemNameKey(rawValue: nfd.rawValue))
    }

    @Test func persistedUnknownCapabilitiesRemainUnknown() {
        #expect(VolumeNamespaceCapabilities.unknown.isKnown == false)
        #expect(VolumeNamespaceCapabilities(isCaseSensitive: false, prefersDecomposedUnicode: true).isKnown)
    }

    @Test func normalizedNamespaceCollisionIsForeignInsteadOfTrapping() {
        let namespace = DestinationNamespace(
            entries: [
                MediaRelativePath(rawValue: "IMG_1.JPG"): .regularFile(byteSize: 1, contentModifiedAt: nil),
                MediaRelativePath(rawValue: "img_1.jpg"): .regularFile(byteSize: 2, contentModifiedAt: nil),
            ],
            enumeratedFolders: [""],
            capabilities: .caseInsensitiveAPFS
        )
        #expect(namespace.occupancy(of: MediaRelativePath(rawValue: "IMG_1.JPG")) == .foreign(kind: .other))
    }

    @Test func containsDelegatesToRootRelativeContainment() {
        let root = LibraryRootPath(rawValue: "/tmp/card")
        let namespace = RootNamespace(
            root: root,
            capabilities: VolumeNamespaceCapabilities(isCaseSensitive: false, prefersDecomposedUnicode: true)
        )

        #expect(namespace.contains(URL(fileURLWithPath: "/tmp/card/IMG_1.JPG")) == MediaRelativePath(rawValue: "IMG_1.JPG"))
        #expect(namespace.contains(URL(fileURLWithPath: "/tmp/card-sibling/IMG_1.JPG")) == nil)
    }
}
