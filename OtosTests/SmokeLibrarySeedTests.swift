import Foundation
@testable import Otos
import Testing

struct SmokeLibrarySeedTests {
    @Test func configuredRootURLReadsSmokeEnvironmentAndExpandsTilde() throws {
        let url = try #require(SmokeLibrarySeed.configuredRootURL(environment: [
            SmokeLibrarySeed.environmentVariable: "~/Desktop/OneDrive/Pictures",
        ]))

        #expect(url.hasDirectoryPath)
        #expect(url.pathComponents.suffix(3) == ["Desktop", "OneDrive", "Pictures"])
    }

    @Test func configuredRootURLIgnoresMissingOrEmptyEnvironment() {
        #expect(SmokeLibrarySeed.configuredRootURL(environment: [:]) == nil)
        #expect(SmokeLibrarySeed.configuredRootURL(environment: [
            SmokeLibrarySeed.environmentVariable: "  ",
        ]) == nil)
    }
}
