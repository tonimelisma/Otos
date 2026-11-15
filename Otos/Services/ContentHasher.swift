import CryptoKit
import Foundation

/// Stateless SHA-1 file reader used only by existing enrichment and import workers
/// (ADR 0018). It owns no queue, retry state, materialization policy, or task. The caller
/// performs the live materialization gate immediately before invoking it. One bounded
/// 1 MiB buffer keeps hashing a sequential read rather than a second scheduling system.
nonisolated struct ContentHasher: Sendable {
    static let chunkSize = 1024 * 1024

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
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return .failed(category: .open)
        }
        defer { try? handle.close() }

        var hasher = Insecure.SHA1()
        while true {
            guard shouldContinue() else {
                return .cancelled
            }
            let data: Data
            do {
                data = try handle.read(upToCount: Self.chunkSize) ?? Data()
            } catch {
                return .failed(category: .read)
            }
            guard !data.isEmpty else {
                guard let digest = ContentDigest(bytes: Array(hasher.finalize())) else {
                    return .failed(category: .digest)
                }
                return .complete(digest)
            }
            hasher.update(data: data)
        }
    }
}
