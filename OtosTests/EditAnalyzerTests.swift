import CoreGraphics
import Dispatch
@testable import OtosKit
import Testing

/// The analyzer runs one reading at a time on its own queue (ADR 0045). These pin what a
/// reading whose caller gave up does while it waits its turn.
struct EditAnalyzerTests {
    // Validates: APP-048
    /// Two readings wait behind a held queue; the first one's caller is cancelled before the
    /// queue runs. When the queue goes on, the cancelled reading throws without running its
    /// model, and the one still wanted is read.
    @Test func aReadingCancelledWhileItWaitsItsTurnNeverRuns() async throws {
        let queue = DispatchSerialQueue(label: "test.edit.analysis", qos: .userInitiated)
        let analyzer = EditAnalyzer(queue: queue)
        let image = try #require(gradientImage(width: 96, height: 64))
        // Held, the queue runs nothing, so the cancellation below lands before either turn.
        queue.suspend()
        let abandoned = Task { try await analyzer.crop(of: image) }
        let wanted = Task { try await analyzer.crop(of: image) }
        abandoned.cancel()
        queue.resume()

        await #expect(throws: CancellationError.self) { try await abandoned.value }
        // A 96×64 gradient has nothing to crop away; what matters is that it was read.
        _ = try await wanted.value
    }

    // Validates: APP-048
    /// The level reading honours cancellation the same way.
    @Test func aLevelReadingCancelledWhileItWaitsNeverRuns() async throws {
        let queue = DispatchSerialQueue(label: "test.edit.analysis", qos: .userInitiated)
        let analyzer = EditAnalyzer(queue: queue)
        let image = try #require(gradientImage(width: 96, height: 64))
        queue.suspend()
        let abandoned = Task { try await analyzer.roll(of: image) }
        abandoned.cancel()
        queue.resume()

        await #expect(throws: CancellationError.self) { try await abandoned.value }
    }
}
