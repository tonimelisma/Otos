import Foundation
@testable import OtosKit
import Testing

@Suite(.testDirectory)
struct FilesystemNamespaceSemanticsTests {
    private func key(_ path: String, _ capabilities: VolumeNamespaceCapabilities) -> FilesystemNameKey {
        FilesystemNamespaceSemantics.nameKey(
            relativePath: MediaRelativePath(rawValue: path),
            capabilities: capabilities
        )
    }

    @Test func caseSensitivityIsTheOneCapabilityThatChangesAKey() {
        #expect(key("IMG_1.JPG", .caseInsensitive) == key("img_1.jpg", .caseInsensitive))
        #expect(key("IMG_1.JPG", .caseSensitive) != key("img_1.jpg", .caseSensitive))
    }

    /// Normalization is not a capability: the same path must produce the same key
    /// under every capability value there is. Modelling it per volume is what let
    /// two disagreeing "unknown" values key one accented path two ways.
    @Test func normalizationNeverVariesWithCapabilities() {
        let nfc = "cafe\u{0301}.jpg".precomposedStringWithCanonicalMapping
        let nfd = nfc.decomposedStringWithCanonicalMapping
        #expect(Array(nfc.utf8) != Array(nfd.utf8))

        for capabilities in [VolumeNamespaceCapabilities.caseSensitive, .caseInsensitive, .unknown] {
            #expect(key(nfc, capabilities) == key(nfd, capabilities))
        }
        // Every capability value keys an accented path identically, so no caller
        // can disagree with another about what the same file is called.
        #expect(key(nfc, .unknown) == key(nfc, .caseInsensitive))
    }

    /// `FilesystemNameKey`'s byte-exact `==` is what makes the normalization above
    /// load-bearing: Swift's own `String ==` would call these equal unnormalized,
    /// hiding the bug rather than the key doing the work.
    @Test func nameKeyEqualityIsByteExactNotCanonical() {
        let nfc = "cafe\u{0301}.jpg".precomposedStringWithCanonicalMapping
        let nfd = nfc.decomposedStringWithCanonicalMapping
        #expect(nfc == nfd, "Swift String equality is canonical, which is exactly what the key must not inherit")
        #expect(FilesystemNameKey(rawValue: nfc) != FilesystemNameKey(rawValue: nfd))
    }

    @Test func anInconclusiveProbeReportsUnknownRatherThanGuessing() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/root")
        let probed = FilesystemNamespaceSemantics.probeVolumeCapabilities(rootURL: missing)
        #expect(probed.isKnown == false)
        #expect(probed == .unknown)
    }

    @Test func aRealVolumeProbeIsKnown() throws {
        let root = try makeTestDirectory()
        #expect(FilesystemNamespaceSemantics.probeVolumeCapabilities(rootURL: root).isKnown)
    }

    /// `isKnown` and the persisted column are one fact. Writing `0` for an
    /// unprobed root made it read back as a confidently case-insensitive one.
    @Test func unknownCapabilitiesPersistAsNullNotAsFalse() {
        #expect(VolumeNamespaceCapabilities.unknown.storedCaseSensitiveColumn == nil)
        #expect(VolumeNamespaceCapabilities.caseInsensitive.storedCaseSensitiveColumn == 0)
        #expect(VolumeNamespaceCapabilities.caseSensitive.storedCaseSensitiveColumn == 1)
        for capabilities in [VolumeNamespaceCapabilities.caseSensitive, .caseInsensitive, .unknown] {
            #expect(VolumeNamespaceCapabilities(storedCaseSensitiveColumn: capabilities.storedCaseSensitiveColumn)
                == capabilities)
        }
    }

    @Test func normalizedNamespaceCollisionIsForeignInsteadOfTrapping() {
        let namespace = DestinationNamespace(
            entries: [
                MediaRelativePath(rawValue: "IMG_1.JPG"): .regularFile(byteSize: 1, contentModifiedAt: nil),
                MediaRelativePath(rawValue: "img_1.jpg"): .regularFile(byteSize: 2, contentModifiedAt: nil),
            ],
            enumeratedFolders: [""],
            capabilities: .caseInsensitive
        )
        #expect(namespace.occupancy(of: MediaRelativePath(rawValue: "IMG_1.JPG")) == .foreign(kind: .other))
    }
}
