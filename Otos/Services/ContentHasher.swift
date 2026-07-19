import Foundation

/// Stateless XXH3-128 file reader used only by existing enrichment and import
/// workers. It owns no queue, retry state, materialization policy, or task. The
/// caller performs the live materialization gate immediately before invoking it.
/// One bounded 1 MiB buffer keeps hashing a sequential read rather than a second
/// scheduling system.
nonisolated struct ContentHasher: Sendable {
    static let chunkSize = 1024 * 1024

    enum Outcome: Equatable, Sendable {
        case complete(XXH3Digest128)
        case cancelled
        case failed(category: FailureCategory)
    }

    enum FailureCategory: String, Equatable, Sendable {
        case open
        case read
        case state
        case update
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

        guard let state = otos_xxh3_create() else {
            return .failed(category: .state)
        }
        defer { otos_xxh3_free(state) }
        guard otos_xxh3_reset(state) == 0 else {
            return .failed(category: .state)
        }

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
            if !data.isEmpty {
                let updateResult = data.withUnsafeBytes { buffer in
                    otos_xxh3_update(state, buffer.baseAddress!, buffer.count)
                }
                guard updateResult == 0 else {
                    return .failed(category: .update)
                }
            } else {
                var bytes = Array(repeating: UInt8(0), count: XXH3Digest128.byteCount)
                let digestResult = bytes.withUnsafeMutableBufferPointer { output in
                    otos_xxh3_digest(state, output.baseAddress)
                }
                guard digestResult == 0 else {
                    return .failed(category: .digest)
                }
                guard let digest = XXH3Digest128(canonicalBytes: bytes) else {
                    return .failed(category: .digest)
                }
                return .complete(digest)
            }
        }
    }
}
