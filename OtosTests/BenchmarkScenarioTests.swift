import Foundation
@testable import OtosKit
import Testing

/// The benchmark scenarios (`BenchmarkTests`), each run once at a small size and measured
/// not at all (`BenchmarkRun.checked`). A scenario expects more than its numbers: that a
/// pass reused the reads it held, took the keyed path, built the stacks once, moved the
/// rows it named. The benchmark suite runs only in the weekly run, so without this suite a
/// change that breaks one of those expectations passes its check and the next weekly run
/// fails before it records anything.
@Suite(.testScope)
struct BenchmarkScenarioTests {
    @Test func catalog() async throws {
        try await BenchmarkTests.catalogScenario(.checked)
    }

    @Test func stack() async throws {
        try await BenchmarkTests.stackScenario(.checked)
    }

    @Test func immichListing() async throws {
        try await BenchmarkTests.immichListingScenario(.checked)
    }

    @Test func immichMirror() async throws {
        try await BenchmarkTests.immichMirrorScenario(.checked)
    }

    @Test func grid() async throws {
        try await BenchmarkTests.gridScenario(.checked)
    }

    @Test func hide() async throws {
        try await BenchmarkTests.hideScenario(.checked)
    }

    @Test func shownFirst() async throws {
        try await BenchmarkTests.shownFirstScenario(.checked)
    }

    @MainActor
    @Test func windowApply() async throws {
        try await BenchmarkTests.windowApplyScenario(.checked)
    }

    @Test func windowPublish() async throws {
        try await BenchmarkTests.windowPublishScenario(.checked)
    }
}
