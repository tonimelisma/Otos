import Foundation
@testable import OtosKit
import Testing

/// A bundled model is loaded from the path its link resolves to, so every checkout's tests
/// give Core ML one path per model version and share its compiled copy (ADR 0044 §11).
@Suite(.testScope)
struct BundledModelTests {
    @Test func aLinkedModelIsLoadedFromWhereItsLinkLeads() throws {
        let temp = try makeTestDirectory()
        let shared = temp.appending(path: "Shared/Model.mlmodelc", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let resources = temp.appending(path: "Bundle", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: resources.appending(path: "Model.mlmodelc"), withDestinationURL: shared
        )
        let bundle = try #require(Bundle(url: resources))
        let url = try #require(BundledModel.url(named: "Model", in: bundle))
        #expect(url.path == shared.resolvingSymlinksInPath().path)
        #expect(BundledModel.url(named: "Missing", in: bundle) == nil)
    }
}
