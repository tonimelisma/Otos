import Foundation
import Observation
@testable import Otos

@MainActor
func windowStateStream(
    _ model: CatalogWindowViewModel,
    timeout: Duration
) -> AsyncStream<CatalogWindowState> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
        let observer = WindowStateObserver(model: model, continuation: continuation)
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            continuation.finish()
        }
        continuation.onTermination = { _ in
            timeoutTask.cancel()
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
    let stream = windowStateStream(model, timeout: .seconds(10))
    for await state in stream where predicate(state) {
        return state
    }
    throw AsyncTestTimeoutError.timedOut("window state")
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
