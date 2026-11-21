import CryptoKit
import Foundation

/// Stateless SHA-1 file reader used only by existing enrichment and import workers
/// (ADR 0018). It owns no queue, retry state, materialization policy, or task. The caller
/// performs the live materialization gate immediately before invoking it. The bytes stream
/// through `FileBytes`' one reused buffer, so hashing a file of any size adds one chunk to the
/// footprint and leaves nothing behind.
nonisolated struct ContentHasher: Sendable {
    static let chunkSize = FileBytes.chunkSize

    enum Outcome: Equatable, Sendable {
        case complete(ContentDigest)
        case cancelled
        case failed(category: FailureCategory)
    }

    enum FailureCategory: String, Equatable, Sendable {
        case open
        case read
        case digest
    }

    func hashMaterializedFile(
        at url: URL,
        shouldContinue: @Sendable () -> Bool = { !Task.isCancelled }
    ) -> Outcome {
        var hasher = Insecure.SHA1()
        let finished: Bool
        do {
            finished = try FileBytes.forEachChunk(of: url, chunkSize: Self.chunkSize, shouldContinue: shouldContinue) { chunk in
                hasher.update(bufferPointer: chunk)
            }
        } catch {
            switch error {
            case .open: return .failed(category: .open)
            case .read, .stat, .truncated: return .failed(category: .read)
            }
        }
        guard finished else {
            return .cancelled
        }
        guard let digest = ContentDigest(bytes: Array(hasher.finalize())) else {
            return .failed(category: .digest)
        }
        return .complete(digest)
    }
}
