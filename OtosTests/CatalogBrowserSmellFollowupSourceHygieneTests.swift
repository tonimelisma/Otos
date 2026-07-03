import Foundation
import Testing

@Suite("Catalog browser smell follow-up source hygiene")
struct CatalogSmellSourceHygieneTests {
    @Test func appKitGridDoesNotPruneTileDetailsDuringStructuralApply() throws {
        let content = try source("Otos/Views/MediaAssetCollectionView.swift")
        let applyStart = try #require(content.range(of: "func applyStructure("))
        let visibleDetailStart = try #require(content.range(of: "func requestVisibleDetails("))
        let applyBody = content[applyStart.lowerBound ..< visibleDetailStart.lowerBound]

        #expect(!applyBody.contains("tileDetailsByID = tileDetailsByID.filter"))
        #expect(!applyBody.contains("grid.orderedAssetIDs.contains($0.key)"))
    }

    @Test func projectionDiagnosticsAndPolicyAreSplitFromPublicationActor() throws {
        let projection = try source("Otos/Services/CatalogProjection.swift")
        let diagnostics = try source("Otos/Services/CatalogProjectionDiagnostics.swift")
        let policy = try source("Otos/Services/CatalogWindowPolicy.swift")

        #expect(!projection.contains("swiftlint:disable file_length"))
        #expect(!projection.contains("struct CatalogProjectionPublicationDiagnostics"))
        #expect(!projection.contains("static func sortLibraries"))
        #expect(projection.contains("CatalogWindowPolicy"))
        #expect(diagnostics.contains("struct CatalogProjectionPublicationDiagnostics"))
        #expect(diagnostics.contains("struct CatalogProjectionChangeSummary"))
        #expect(policy.contains("enum CatalogWindowPolicy"))
        #expect(policy.contains("static func sortLibraries"))
    }

    @Test func filterSurfacesUseAvailableKindsNotFormatEmptiness() throws {
        let toolbar = try source("Otos/Views/CatalogToolbarControls.swift")
        let app = try source("Otos/OtosApp.swift")

        #expect(toolbar.contains("struct CatalogFilterMenuContent"))
        #expect(toolbar.contains("options.availableKinds"))
        #expect(toolbar.contains("kindSymbol(kind, formats: formats)"))
        #expect(!toolbar.contains("MediaKind.displayOrder.filter { !options.formats"))
        #expect(app.contains("CatalogFilterMenuContent("))
        #expect(!app.contains("catalogViewModel.queryDescriptor.filter.kinds.contains(kind)"))
        #expect(!app.contains("if !formats.isEmpty"))
    }

    private func source(_ path: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appending(path: path), encoding: .utf8)
    }
}
