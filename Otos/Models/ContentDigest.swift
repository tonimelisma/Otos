import Foundation

/// The SHA-1 of a file's bytes, the one content fact the catalog stores (ADR 0018): the
/// 20 bytes of the digest, as CryptoKit and Immich's `checksum` give them. SHA-1 is the
/// digest Immich reports for every uploaded original, so a copy in a library and the same
/// file in an account compare without downloading it. It is a content fact, not a security
/// boundary. No hexadecimal or Base64 text crosses the persistence boundary.
nonisolated struct ContentDigest: Equatable, Hashable, Sendable {
    /// Number of bytes in a SHA-1 digest.
    static let byteCount = 20

    /// SHA-1 of empty input.
    static let empty = ContentDigest(bytes: [
        0xDA, 0x39, 0xA3, 0xEE, 0x5E, 0x6B, 0x4B, 0x0D, 0x32, 0x55,
        0xBF, 0xEF, 0x95, 0x60, 0x18, 0x90, 0xAF, 0xD8, 0x07, 0x09,
    ])!

    private let bytes: [UInt8]

    init?(bytes: [UInt8]) {
        guard bytes.count == Self.byteCount else {
            return nil
        }
        self.bytes = bytes
    }

    init?(data: Data) {
        self.init(bytes: Array(data))
    }

    /// A digest written as Base64 text, as Immich writes an asset's `checksum`; nil for text
    /// that is not 20 bytes of Base64.
    init?(base64: String) {
        guard let data = Data(base64Encoded: base64) else {
            return nil
        }
        self.init(data: data)
    }

    var data: Data {
        Data(bytes)
    }

    var hexString: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
