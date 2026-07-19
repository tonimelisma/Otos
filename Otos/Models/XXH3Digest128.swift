import Foundation

/// The canonical, algorithm-specific 16-byte XXH3-128 value stored in catalog
/// overlay. The bytes are the stable big-endian representation emitted by
/// `XXH128_canonicalFromHash`; neither Swift integer layout nor hexadecimal text
/// crosses the persistence boundary.
nonisolated struct XXH3Digest128: Equatable, Hashable, Sendable {
    /// Number of bytes in the canonical representation.
    static let byteCount = 16

    /// XXH3-128 of empty input with the default seed.
    static let empty = XXH3Digest128(canonicalBytes: [
        0x99, 0xAA, 0x06, 0xD3, 0x01, 0x47, 0x98, 0xD8,
        0x60, 0x01, 0xC3, 0x24, 0x46, 0x8D, 0x49, 0x7F,
    ])!

    private let canonicalBytes: [UInt8]

    init?(canonicalBytes: [UInt8]) {
        guard canonicalBytes.count == Self.byteCount else {
            return nil
        }
        self.canonicalBytes = canonicalBytes
    }

    init?(data: Data) {
        self.init(canonicalBytes: Array(data))
    }

    var data: Data {
        Data(canonicalBytes)
    }

    var hexString: String {
        canonicalBytes.map { String(format: "%02x", $0) }.joined()
    }
}
