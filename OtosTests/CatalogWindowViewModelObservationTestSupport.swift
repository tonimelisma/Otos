import Foundation
import Observation
@testable import OtosKit

/// Every value `model.state` takes that a waiter can still act on, newest first.
///
/// The stream carries no wall-clock deadline. A deadline here measures machine load,
/// not correctness: under a full parallel suite one projection publication can lag
/// for seconds, and a fixed limit then fails a test whose state was still on its way.
/// The stream ends only when the waiting task is cancelled or the model is released.
/// A state that never arrives is a hang, and `script/check.sh` detects and names a
/// hung suite.
///
/// No state is lost between observations: each re-registration reads `model.state`
/// again, so a change made while the next registration was pending is delivered by
/// that read, and `bufferingNewest(1)` keeps the newest value for a slow consumer.
@MainActor
func windowStateStream(_ model: CatalogWindowViewModel) -> AsyncStream<CatalogWindowState> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
        let observer = WindowStateObserver(model: model, continuation: continuation)
        continuation.onTermination = { _ in
            Task { @MainActor in
                observer.cancel()
            }
        }
        observer.start()
    }
}

@MainActor
func waitForWindowState(
    _ model: CatalogWindowViewModel,
    predicate: @escaping @MainActor @Sendable (CatalogWindowState) -> Bool
) async throws -> CatalogWindowState {
    for await state in windowStateStream(model) where predicate(state) {
        return state
    }
    throw AsyncTestTimeoutError.streamEnded("window state")
}

@MainActor
private final class WindowStateObserver {
    private weak var model: CatalogWindowViewModel?
    private let continuation: AsyncStream<CatalogWindowState>.Continuation
    private var isActive = true

    init(model: CatalogWindowViewModel, continuation: AsyncStream<CatalogWindowState>.Continuation) {
        self.model = model
        self.continuation = continuation
    }

    func start() {
        guard isActive, let model else {
            continuation.finish()
            return
        }
        _ = withObservationTracking {
            continuation.yield(model.state)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.start()
            }
        }
    }

    func cancel() {
        isActive = false
        continuation.finish()
    }
}

func fixedViewModelSelectionScanner(filesByRoot: [LibraryRootPath: String]) -> CatalogScanner {
    CatalogScanner { rootPath, _, batchHandler in
        guard let fileName = filesByRoot[rootPath] else {
            return .empty
        }
        let relativePath = MediaRelativePath(rawValue: fileName)
        try await batchHandler([
            ScannedMediaFile(
                relativePath: relativePath,
                name: fileName,
                contentTypeIdentifier: "public.jpeg",
                byteSize: 100,
                createdAt: nil,
                contentModifiedAt: Date(timeIntervalSince1970: 1000)
            ),
        ])
        return .mediaOnly([relativePath])
    }
}
