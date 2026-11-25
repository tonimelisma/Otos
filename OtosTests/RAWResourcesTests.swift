import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// ENR-036: a RAW is developed only once Apple reports its camera's support is on the Mac
/// (`ImageRenderer.fetchResources`, the wait `openRAW` makes on `CIRAWFilter.downloadResources`).
@Suite(.testScope)
struct RAWResourcesTests {
    /// Core Image reports on a queue of its own, after the fetch has returned: the wait ends
    /// with that report, not before it.
    @Test func theWaitEndsWithTheReportFromAnotherQueue() async throws {
        let reported = ReportFlag()
        // Off the pool, as a render lane's queue runs it (`offThePool`).
        try await offThePool {
            try ImageRenderer.fetchResources { report in
                DispatchQueue.global().async {
                    reported.set()
                    report(nil)
                }
            }
        }
        #expect(reported.isSet, "the fetch returned only after Core Image reported")
    }

    /// A failed or timed-out download is classified by its domain and code, and is not a
    /// `RenderError`: it says nothing about the file.
    @Test func aFailedDownloadThrowsItsDomainAndCode() {
        let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(throws: ImageRenderer.RAWResourcesUnavailable(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)) {
            try ImageRenderer.fetchResources { report in report(timedOut) }
        }
    }
}

private final class ReportFlag: Sendable {
    private let value = Mutex(false)

    var isSet: Bool {
        value.withLock { $0 }
    }

    func set() {
        value.withLock { $0 = true }
    }
}
