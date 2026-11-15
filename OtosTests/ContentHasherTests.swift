import CryptoKit
import Foundation
@testable import OtosKit
import Synchronization
import Testing

@Suite(.testDirectory)
struct ContentHasherTests {
    @Test func fipsVectorsAndDigestRoundTrip() throws {
        // FIPS 180 examples: the empty message, "abc", and the 448-bit two-block message.
        let vectors: [(Data, String)] = [
            (Data(), "da39a3ee5e6b4b0d3255bfef95601890afd80709"),
            (Data("abc".utf8), "a9993e364706816aba3e25717850c26c9cd0d89d"),
            (
                Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8),
                "84983e441c3bd26ebaae4aa1f95129e5e54670f1"
            ),
        ]
        for (data, expectedHex) in vectors {
            let url = try temporaryFile(data)
            defer { try? FileManager.default.removeItem(at: url) }
            guard case let .complete(digest) = ContentHasher().hashMaterializedFile(at: url) else {
                Issue.record("expected a complete hash")
                continue
            }
            #expect(digest.hexString == expectedHex)
            #expect(try #require(ContentDigest(data: digest.data)) == digest)
        }
    }

    @Test func fileStreamingMatchesSingleUpdateAtChunkBoundaries() throws {
        let lengths = [0, 1, ContentHasher.chunkSize - 1, ContentHasher.chunkSize,
                       ContentHasher.chunkSize + 1, ContentHasher.chunkSize * 2 + 123]
        for length in lengths {
            let data = generatedData(count: length)
            let url = try temporaryFile(data)
            defer { try? FileManager.default.removeItem(at: url) }
            guard case let .complete(streamed) = ContentHasher().hashMaterializedFile(at: url) else {
                Issue.record("streaming hash failed at length \(length)")
                continue
            }
            #expect(streamed == oneShotHash(data))
        }
    }

    @Test func cancellationStopsBeforeCompletingMultiChunkInput() throws {
        let url = try temporaryFile(generatedData(count: ContentHasher.chunkSize * 2))
        defer { try? FileManager.default.removeItem(at: url) }
        let checks = Mutex(0)
        let outcome = ContentHasher().hashMaterializedFile(at: url) {
            let value = checks.withLock {
                $0 += 1
                return $0
            }
            return value < 2
        }
        #expect(outcome == .cancelled)
        #expect(checks.withLock { $0 } == 2)
    }

    @Test func missingFileReturnsTypedOpenFailure() throws {
        let url = try makeTestDirectory().appending(path: "missing")
        #expect(ContentHasher().hashMaterializedFile(at: url) == .failed(category: .open))
    }

    private func temporaryFile(_ data: Data) throws -> URL {
        let url = try makeTestDirectory().appending(path: "content")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func generatedData(count: Int) -> Data {
        var generator = UInt64(2_654_435_761)
        let multiplier = UInt64(11_400_714_785_074_694_797)
        return Data((0 ..< count).map { _ in
            let value = UInt8(generator >> 56)
            generator &*= multiplier
            return value
        })
    }

    private func oneShotHash(_ data: Data) -> ContentDigest {
        ContentDigest(bytes: Array(Insecure.SHA1.hash(data: data)))!
    }
}
