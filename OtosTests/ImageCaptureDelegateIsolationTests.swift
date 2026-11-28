import Foundation
@preconcurrency import ImageCaptureCore
@testable import OtosKit
import Testing

/// ImageCaptureCore delegate isolation (APP-018).
///
/// ImageCaptureCore delivers some delegate callbacks on its own
/// `ICDeviceOperationQueue` rather than the main thread. While the delegate
/// conformances were `@preconcurrency` on `@MainActor` types, every such delivery ran a
/// runtime executor check and killed the process in `_dispatch_assert_queue_fail` — a
/// camera attaching was enough. These tests deliver a callback from a non-main thread,
/// which is the failure exactly: under the old conformance the check fired at method
/// entry, before any body ran, so an empty method trapped just as hard as a busy one.
struct ImageCaptureDelegateIsolationTests {
    // Validates: APP-018
    @Test func browserCallbackDeliveredOffTheMainThreadDoesNotTrap() async {
        let monitor = await CameraSourceMonitor(
            stagingContainers: StagingContainers(base: URL.temporaryDirectory), onAttach: { _ in }, onDetach: { _ in }
        )
        let browser = ICDeviceBrowser()

        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                #expect(!Thread.isMainThread)
                monitor.deviceBrowserDidEnumerateLocalDevices(browser)
                continuation.resume()
            }
        }
    }
}
