import AVFoundation
import Foundation
import Synchronization
import UniformTypeIdentifiers

/// Remote video asset guide (ADR 0046, ADR 0047)
///
/// A video on a server, as an `AVURLAsset` whose bytes AVFoundation asks for range by range
/// through a resource loader, each range read with the account's `RemoteRangeReader`. So a
/// video's frames are decoded from the parts of the file they need, never from a download of
/// the whole original: nothing is staged, and the read is the same ranged access metadata
/// takes.
///
/// A request is served in chunks, each read only once the last has answered, and stops when
/// AVFoundation cancels it, cancelling the read in flight. A read the server does not answer
/// within `readDeadline` is cancelled too. A read the deadline settles, or one the server
/// answers with an error, fails its request and marks the asset `failed`, so the caller knows
/// a missing frame was the server's and not the file's: such a read is a retry, never a
/// video with no faces.
final nonisolated class RemoteVideoAsset: NSObject, AVAssetResourceLoaderDelegate, Sendable {
    /// The scheme AVFoundation does not know, so it asks the loader for every byte.
    static let scheme = "otos-ranges"
    /// The largest range one read asks for.
    static let chunkSize = 1 << 20

    let asset: AVURLAsset
    private let reader: RemoteRangeReader
    private let contentType: String
    private let readDeadline: Duration
    private let queue = DispatchQueue(label: "net.melisma.Otos.remote.video", qos: .utility)
    private let state = Mutex(State())

    private struct State {
        var bytesRead = 0
        var reads = 0
        var failed = false
        /// The requests being served, by a key the reads' callbacks carry, so no callback
        /// holds a request across threads.
        var requests: [Int: AVAssetResourceLoadingRequest] = [:]
        /// The read in flight for each request, which its deadline or AVFoundation's cancel
        /// stops.
        var inFlight: [Int: RemoteRangeRead] = [:]
        var nextKey = 0
    }

    init(reader: RemoteRangeReader, filename: String, readDeadline: Duration = .seconds(30)) {
        self.reader = reader
        self.readDeadline = readDeadline
        let fileExtension = (filename as NSString).pathExtension
        contentType = UTType(filenameExtension: fileExtension)?.identifier ?? UTType.quickTimeMovie.identifier
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "video"
        components.path = "/video." + (fileExtension.isEmpty ? "mov" : fileExtension)
        asset = AVURLAsset(url: components.url!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    /// Whether a read failed or went unanswered: the frames missing are the server's, not the
    /// file's.
    var failed: Bool {
        state.withLock(\.failed)
    }

    /// The bytes the reads returned, and how many reads there were.
    var cost: (bytes: Int, reads: Int) {
        state.withLock { ($0.bytesRead, $0.reads) }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = contentType
            information.contentLength = Int64(reader.size)
            information.isByteRangeAccessSupported = true
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }
        let start = UInt64(max(dataRequest.currentOffset, dataRequest.requestedOffset))
        let end = dataRequest.requestsAllDataToEndOfResource
            ? reader.size
            : min(reader.size, UInt64(dataRequest.requestedOffset) + UInt64(dataRequest.requestedLength))
        let key = state.withLock { state in
            defer { state.nextKey += 1 }
            state.requests[state.nextKey] = loadingRequest
            return state.nextKey
        }
        serve(key, from: start, to: end)
        return true
    }

    /// A cancelled request's read in flight stops its transfer; its late answer finds the
    /// request gone.
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let stopped = state.withLock { state in
            let keys = state.requests.filter { $0.value === loadingRequest }.map(\.key)
            return keys.compactMap { key in
                state.requests[key] = nil
                return state.inFlight.removeValue(forKey: key)
            }
        }
        for read in stopped {
            read.cancel()
        }
    }

    /// The request `key` names while it is still wanted; a finished or cancelled one is
    /// forgotten.
    private func request(_ key: Int) -> AVAssetResourceLoadingRequest? {
        state.withLock { state in
            guard let request = state.requests[key], !request.isCancelled else {
                state.requests[key] = nil
                state.inFlight[key] = nil
                return nil
            }
            return request
        }
    }

    private func forget(_ key: Int) {
        state.withLock { state in
            state.requests[key] = nil
            state.inFlight[key] = nil
        }
    }

    /// Reads `offset..<end` for request `key` a chunk at a time, on the loader's queue.
    private func serve(_ key: Int, from offset: UInt64, to end: UInt64) {
        guard let request = request(key) else { return }
        guard offset < end else {
            request.finishLoading()
            forget(key)
            return
        }
        let length = Int(min(UInt64(Self.chunkSize), end - offset))
        let settled = Mutex(false)
        let settle: @Sendable (Result<Data, any Error>) -> Void = { [weak self] result in
            guard let self, settled.withLock({ done in
                defer { done = true }
                return !done
            }) else { return }
            queue.async {
                self.finish(key, result, offset: offset, end: end)
            }
        }
        let read = reader.fetch(offset, length, settle)
        state.withLock { state in
            if state.requests[key] != nil {
                state.inFlight[key] = read
            }
        }
        // time: deadline — a server that accepted the request may never answer it
        queue.asyncAfter(deadline: .now() + .milliseconds(DiagnosticsTiming.milliseconds(readDeadline))) {
            // A read already answered ignores the cancel; one still running stops costing bytes.
            settle(.failure(RemoteByteSourceError.timedOut))
            read.cancel()
        }
    }

    private func finish(_ key: Int, _ result: Result<Data, any Error>, offset: UInt64, end: UInt64) {
        guard let request = request(key) else { return }
        switch result {
        case let .success(data):
            guard !data.isEmpty else {
                fail(key, request, RemoteByteSourceError.noAnswer)
                return
            }
            state.withLock {
                $0.bytesRead += data.count
                $0.reads += 1
            }
            request.dataRequest?.respond(with: data)
            serve(key, from: offset + UInt64(data.count), to: end)
        case let .failure(error):
            fail(key, request, error)
        }
    }

    private func fail(_ key: Int, _ request: AVAssetResourceLoadingRequest, _ error: any Error) {
        state.withLock {
            $0.failed = true
            $0.requests[key] = nil
            $0.inFlight[key] = nil
        }
        OtosLog.mediaIO.noticeOperation("remote.videoRange", phase: "failed", fields: [
            "error": String(describing: error),
        ])
        request.finishLoading(with: error)
    }
}
