import Foundation
import MediaMetadata
import Synchronization

/// One original a server serves in byte ranges (ADR 0046): its size and how to ask for a
/// range. An Immich asset's `/original` honours `Range` (research 2026-11-07).
nonisolated struct RemoteRangeReader: Sendable {
    /// Issues one ranged read and calls back when it settles.
    typealias Fetch = @Sendable (
        _ offset: UInt64,
        _ length: Int,
        _ completion: @escaping @Sendable (Result<Data, any Error>) -> Void
    ) -> Void

    let size: UInt64
    let fetch: Fetch
}

/// Resolves an account row to a reader for its original while its server answers, so
/// enrichment reads its metadata in ranges instead of downloading it (ADR 0046 §5).
nonisolated struct RemoteRangeAccess: Sendable {
    private let resolve: @Sendable (MediaAssetID, UInt64) async -> RemoteRangeReader?
    private let serves: @Sendable (LibraryRootPath) async -> Bool

    init(
        serves: @escaping @Sendable (LibraryRootPath) async -> Bool,
        resolve: @escaping @Sendable (MediaAssetID, UInt64) async -> RemoteRangeReader?
    ) {
        self.serves = serves
        self.resolve = resolve
    }

    /// Whether `rootPath`'s rows are read in ranges from a server that answers now.
    func serves(_ rootPath: LibraryRootPath) async -> Bool {
        await serves(rootPath)
    }

    /// A reader for `id`'s original of `size` bytes, or nil when its server does not
    /// answer now.
    func reader(for id: MediaAssetID, size: UInt64) async -> RemoteRangeReader? {
        await resolve(id, size)
    }
}

/// Reads byte ranges of a remote original for `MediaMetadata`, the network counterpart of
/// `CameraByteSource`, with the same rules: a range outside the file is nil without a
/// request, a short or failed read throws — never a definitive absence, so a server that
/// stops answering is a retry, not a file with no capture date — and the wait for an
/// answer has a deadline.
final nonisolated class RemoteByteSource: MediaByteSource {
    let size: UInt64
    private let fetch: RemoteRangeReader.Fetch
    private let readDeadline: Duration

    init(reader: RemoteRangeReader, readDeadline: Duration = .seconds(30)) {
        size = reader.size
        fetch = reader.fetch
        self.readDeadline = readDeadline
    }

    func data(offset: UInt64, length: Int) throws -> Data? {
        guard length >= 0, offset <= size, UInt64(length) <= size - offset else {
            return nil
        }
        guard length > 0 else {
            return Data()
        }
        let outcome = Mutex<Result<Data, any Error>?>(nil)
        let settled = DispatchSemaphore(value: 0)
        fetch(offset, length) { result in
            outcome.withLock { $0 = result }
            settled.signal()
        }
        // time: deadline — a server that accepted the request may never answer it
        guard settled.wait(timeout: .now() + .milliseconds(DiagnosticsTiming.milliseconds(readDeadline))) == .success else {
            throw RemoteByteSourceError.timedOut
        }
        guard let result = outcome.withLock({ $0 }) else {
            throw RemoteByteSourceError.noAnswer
        }
        let data = try result.get()
        guard data.count == length else {
            throw RemoteByteSourceError.shortRead(expected: length, received: data.count)
        }
        return data
    }

    func close() {}
}

nonisolated enum RemoteByteSourceError: Error, Equatable {
    case timedOut
    case noAnswer
    case shortRead(expected: Int, received: Int)
}

/// Parses a remote original's metadata from ranged reads on a dedicated serial queue —
/// neither the main actor nor the cooperative pool, because `MediaByteSource.data` blocks
/// its thread while the server answers.
nonisolated enum RemoteMetadataReader {
    private static let queue = DispatchQueue(label: "net.melisma.Otos.remote-metadata", qos: .utility)

    /// The chunk the read-through cache asks for. A miss is a network round trip, as over
    /// MTP, so the camera's measured 128 KB serves the same purpose (`CameraMetadataReader`).
    static let chunkSize = CameraMetadataReader.chunkSize

    static func read(_ reader: RemoteRangeReader, filenameHint: String) async -> MediaMetadataResult {
        await withCheckedContinuation { continuation in
            queue.async {
                let source = CachingByteSource(wrapping: RemoteByteSource(reader: reader), chunkSize: chunkSize)
                continuation.resume(returning: MediaMetadataReader.read(source: source, filenameHint: filenameHint))
            }
        }
    }
}
