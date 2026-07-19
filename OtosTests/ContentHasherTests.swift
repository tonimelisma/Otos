import Foundation
@testable import Otos
import Testing

struct ContentHasherTests {
    @Test func officialCanonicalVectorsAndDigestRoundTrip() throws {
        let vectors: [(Data, String)] = [
            (Data(), "99aa06d3014798d86001c324468d497f"),
            (Data([0x00]), "a6cd5e9392000f6ac44bdff4074eecdb"),
            (
                Data([0x00, 0x52, 0x92, 0x9B, 0xB7, 0x32]),
                "082afe0b8162d12a3e7039bdda43cfc6"
            ),
            (
                Data([0x00, 0x52, 0x92, 0x9B, 0xB7, 0x32, 0xA3, 0x24, 0x2D, 0x00, 0xAF, 0x95]),
                "6e3efd8fc7802b18061a192713f69ad9"
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
            #expect(try #require(XXH3Digest128(data: digest.data)) == digest)
        }
    }

    @Test func digestRejectsWrongCanonicalLengths() {
        #expect(XXH3Digest128(canonicalBytes: []) == nil)
        #expect(XXH3Digest128(canonicalBytes: Array(repeating: 0, count: 15)) == nil)
        #expect(XXH3Digest128(canonicalBytes: Array(repeating: 0, count: 17)) == nil)
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
        var checks = 0
        let outcome = ContentHasher().hashMaterializedFile(at: url) {
            checks += 1
            return checks < 2
        }
        #expect(outcome == .cancelled)
        #expect(checks == 2)
    }

    @Test func missingFileReturnsTypedOpenFailure() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("otos-content-hasher-missing-\(UUID().uuidString)")
        #expect(ContentHasher().hashMaterializedFile(at: url) == .failed(category: .open))
    }

    private func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("otos-content-hasher-\(UUID().uuidString)")
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

    private func oneShotHash(_ data: Data) -> XXH3Digest128 {
        let state = otos_xxh3_create()!
        defer { otos_xxh3_free(state) }
        precondition(otos_xxh3_reset(state) == 0)
        data.withUnsafeBytes { buffer in
            precondition(otos_xxh3_update(state, buffer.baseAddress, buffer.count) == 0)
        }
        var bytes = Array(repeating: UInt8(0), count: XXH3Digest128.byteCount)
        let digestResult = bytes.withUnsafeMutableBufferPointer { output in
            otos_xxh3_digest(state, output.baseAddress)
        }
        precondition(digestResult == 0)
        return XXH3Digest128(canonicalBytes: bytes)!
    }
}
