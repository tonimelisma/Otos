import Foundation
import OSLog

/// Content equality checker guide
///
/// Exact chunk-by-chunk byte comparison for equal-size import candidates.
/// Never persists digests or content fingerprints. An ephemeral cross-generation
/// memo keyed by cheap filesystem facts survives replans within one process.
///
/// Always consults `FileMaterialization` before reading. Background greedy
/// planning must not unexpectedly materialize dataless fixed-library files;
/// explicit import intent may authorize materialization (Stage D/E).
final nonisolated class ContentEqualityChecker: @unchecked Sendable {
    private let lock = NSLock()
    private var memo: [ComparisonMemoKey: ComparisonResult] = [:]
    private var memoOrder: [ComparisonMemoKey] = []
    private let memoCapacity: Int
    private let authorizeMaterialization: Bool

    init(memoCapacity: Int = 2048, authorizeMaterialization: Bool = false) {
        self.memoCapacity = memoCapacity
        self.authorizeMaterialization = authorizeMaterialization
    }

    func result(for request: ComparisonRequest) -> ComparisonResult {
        let key = ComparisonMemoKey(request)
        lock.lock()
        if let cached = memo[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let computed = compare(request)
        lock.lock()
        memo[key] = computed
        memoOrder.append(key)
        while memoOrder.count > memoCapacity {
            let evicted = memoOrder.removeFirst()
            memo.removeValue(forKey: evicted)
        }
        lock.unlock()
        return computed
    }

    func resolve(_ requests: [ComparisonRequest]) -> [ComparisonRequest: ComparisonResult] {
        var results: [ComparisonRequest: ComparisonResult] = [:]
        for request in requests {
            results[request] = result(for: request)
        }
        return results
    }

    private func compare(_ request: ComparisonRequest) -> ComparisonResult {
        let sourceStatus = FileMaterialization.status(of: request.sourceURL)
        let destinationStatus = FileMaterialization.status(of: request.destinationURL)
        if sourceStatus == .dataless || destinationStatus == .dataless {
            if authorizeMaterialization {
                OtosLog.mediaIO.notice(
                    "op=import.compare phase=materializeAuthorized source=\(request.sourceRelativePath.rawValue, privacy: .public)"
                )
            } else {
                OtosLog.mediaIO.notice(
                    "op=import.compare phase=requiresMaterialization source=\(request.sourceRelativePath.rawValue, privacy: .public)"
                )
                return .requiresMaterialization
            }
        }

        do {
            let equal = try filesAreByteEqual(request.sourceURL, request.destinationURL)
            return equal ? .equal : .unequal
        } catch {
            return .unavailable(detail: String(describing: error))
        }
    }

    private func filesAreByteEqual(_ left: URL, _ right: URL) throws -> Bool {
        let leftHandle = try FileHandle(forReadingFrom: left)
        let rightHandle = try FileHandle(forReadingFrom: right)
        defer {
            try? leftHandle.close()
            try? rightHandle.close()
        }
        let chunkSize = 1024 * 1024
        while true {
            let leftData = try leftHandle.read(upToCount: chunkSize) ?? Data()
            let rightData = try rightHandle.read(upToCount: chunkSize) ?? Data()
            if leftData != rightData {
                return false
            }
            if leftData.isEmpty {
                return true
            }
        }
    }
}
