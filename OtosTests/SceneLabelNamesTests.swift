import Foundation
@testable import OtosKit
import Testing
import Vision

/// The Info pane's scene-label names (ADR 0050): the Mac's language where a name read back,
/// English everywhere else.
struct SceneLabelNamesTests {
    // Validates: APP-041
    @Test func aLabelIsNamedInTheMacsLanguageOrElseInEnglish() throws {
        let table = try SceneLabelNames.Table(text: """
        # comment
        identifier\tfi\tzh-Hant
        baseball_hat\tbaseballlippis\t棒球帽
        pear\t\t梨
        dill
        """)
        #expect(table.columns == ["fi": 0, "zh-Hant": 1])
        #expect(table.names["pear"] == ["", "梨"])
        #expect(table.names["dill"] == ["", ""])
        #expect(SceneLabelNames.englishName("baseball_hat") == "baseball hat")
        #expect(SceneLabelNames.column(for: Locale.Language(identifier: "fi-FI")) == "fi")
        #expect(SceneLabelNames.column(for: Locale.Language(identifier: "zh-Hant-TW")) == "zh-Hant")
        #expect(SceneLabelNames.column(for: Locale.Language(identifier: "zh-CN")) == "zh-Hans")
        #expect(SceneLabelNames.column(for: Locale.Language(identifier: "en-GB")) == nil)
    }

    @Test func aRowWithTheWrongNumberOfNamesIsRefused() {
        #expect(throws: SceneLabelNames.Table.ReadError.self) {
            try SceneLabelNames.Table(text: "identifier\tfi\npear\tpäärynä\tpäron\n")
        }
    }

    // Validates: APP-041
    /// The shipped table names every label Vision can report, in every language it holds, or
    /// leaves it to English; English is never a column.
    @Test func theShippedTableCoversEveryLabelVisionReports() async throws {
        let bundle = Bundle(for: CatalogWindowViewModel.self)
        let table = try SceneLabelNames.Table(bundle: bundle)
        let request = VNClassifyImageRequest()
        request.revision = SearchSceneLabels.revision
        let identifiers = try request.supportedIdentifiers()
        #expect(Set(table.names.keys) == Set(identifiers))
        #expect(!table.columns.isEmpty)
        let offered = Set(SearchQueryEncoder.photoWords.keys).union(["zh-Hans", "zh-Hant"]).subtracting(["zh"])
        #expect(Set(table.columns.keys).isSubset(of: offered))
        let names = SceneLabelNames(bundle: bundle)
        #expect(try await names.names(of: ["baseball_hat", "pool"], in: Locale.Language(identifier: "en-US")) == ["baseball hat", "pool"])
        let finnish = try await names.names(of: ["people", "adult"], in: Locale.Language(identifier: "fi"))
        #expect(finnish.allSatisfy { !$0.isEmpty })
    }

    // Validates: APP-041
    /// Every language names some of Vision's labels alike (Finnish "koira" for dog and canine):
    /// the chips show each name once, keeping the first label's identifier for the search.
    @Test func chipsNameEachNameOnce() async throws {
        let names = SceneLabelNames(bundle: Bundle(for: CatalogWindowViewModel.self))
        let finnish = Locale.Language(identifier: "fi")
        let identifiers = ["dog", "canine", "pool"]
        let named = try await names.names(of: identifiers, in: finnish)
        let chips = try await names.labels(of: identifiers.map { SceneLabel(identifier: $0, confidence: nil) }, in: finnish)
        #expect(chips.map(\.name) == named.reduce(into: [String]()) {
            if !$0.contains($1) {
                $0.append($1)
            }
        })
        #expect(chips.first?.identifier == "dog")
        #expect(Set(chips.map(\.identifier)).count == chips.count)
    }

    // Validates: APP-041
    /// A chip that only repeats a more specific one is left out, by the shipped hierarchy and
    /// the confidences Vision gave (`SceneLabelHierarchy.tsv`). A red SUV and a
    /// family photo of the reference library, as Vision scored them.
    @Test func aChipThatOnlyRepeatsAMoreSpecificOneIsLeftOut() async throws {
        let names = SceneLabelNames(bundle: Bundle(for: CatalogWindowViewModel.self))
        let english = Locale.Language(identifier: "en-US")
        func scored(_ pairs: KeyValuePairs<String, Float>) -> [SceneLabel] {
            pairs.map { SceneLabel(identifier: $0.key, confidence: $0.value) }
        }
        let suv = try await names.labels(of: scored([
            "machine": 0.535, "vehicle": 0.523, "automobile": 0.523, "outdoor": 0.514, "land": 0.514, "license_plate": 0.339,
        ]), in: english)
        #expect(suv.map(\.identifier) == ["automobile", "land", "license_plate"])
        let family = try await names.labels(of: scored(["people": 0.901, "adult": 0.881, "child": 0.566, "baby": 0.454]), in: english)
        #expect(family.map(\.identifier) == ["adult", "child", "baby"])
        let unknown = try await names.labels(
            of: [SceneLabel(identifier: "people", confidence: nil), SceneLabel(identifier: "adult", confidence: 0.9)], in: english
        )
        #expect(unknown.map(\.identifier) == ["people", "adult"])
    }

    @Test func aHierarchyRowWithoutAncestorsIsRefused() {
        #expect(throws: SceneLabelNames.Table.ReadError.self) {
            try SceneLabelNames.Hierarchy(text: "identifier\tancestors\treadings\nadult\t\t5\n")
        }
        #expect(throws: (any Error).self) {
            try SceneLabelNames.Hierarchy(text: "adult\tpeople\t5\n")
        }
    }
}
