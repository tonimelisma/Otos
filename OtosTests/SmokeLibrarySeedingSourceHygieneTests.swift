import Foundation
import Testing

@Suite("Smoke library seeding source hygiene")
struct SmokeLibrarySeedingSourceHygieneTests {
    @Test func appStartupSubmitsSmokeSeedThroughViewModel() throws {
        let app = try source("Otos/OtosApp.swift")
        let seed = try source("Otos/Support/SmokeLibrarySeed.swift")
        let viewModel = try source("Otos/ViewModels/CatalogWindowViewModel.swift")
        let mutation = try source("Otos/ViewModels/CatalogWindowViewModelMutation.swift")

        #expect(app.contains("SmokeLibrarySeed.applyIfPresent(to: catalogViewModel)"))
        #expect(seed.contains("OTOS_SMOKE_LIBRARY_ROOT"))
        #expect(seed.contains("viewModel.ensureLibrary(url: rootURL)"))
        #expect(viewModel.contains("case ensureLibrary(URL)"))
        #expect(mutation.contains("try await store.ensureLibrary(url: url)"))
    }

    @Test func smokeScriptsSeedRealLibraryAndDriveScrolling() throws {
        let buildAndRun = try source("script/build_and_run.sh")
        let smokeRun = try source("script/smoke-run.sh")
        let smokeScroll = try source("script/smoke-scroll.swift")

        #expect(buildAndRun.contains("OTOS_SMOKE_LIBRARY_ROOT"))
        #expect(buildAndRun.contains("\"$APP_BUNDLE/Contents/MacOS/$APP_NAME\""))
        #expect(smokeRun.contains("DEFAULT_ROOT=\"$HOME/Desktop/OneDrive/Pictures\""))
        #expect(smokeRun.contains("pwd -P"))
        #expect(smokeRun.contains("SETTLE_SECONDS=\"${OTOS_SMOKE_SETTLE_SECONDS:-10}\""))
        #expect(smokeRun.contains("script/smoke-scroll.swift"))
        #expect(smokeRun.contains("script/catalog-diagnostics.sh"))
        #expect(smokeScroll.contains("scrollWheelEvent2Source"))
        #expect(smokeScroll.contains("try postScroll(delta: -config.delta)"))
        #expect(smokeScroll.contains("try postScroll(delta: config.delta)"))
    }

    @Test func processDocsRequireSeededSmokeLaunches() throws {
        let workflow = try source("docs/process/development-workflow.md")
        let performance = try source("docs/process/performance.md")

        #expect(workflow.contains("script/smoke-run.sh"))
        #expect(workflow.contains("OneDrive Pictures"))
        #expect(workflow.contains("empty catalog"))
        #expect(performance.contains("script/smoke-run.sh"))
        #expect(performance.contains("10 seconds"))
        #expect(performance.contains("scroll"))
    }

    private func source(_ path: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appending(path: path), encoding: .utf8)
    }
}
