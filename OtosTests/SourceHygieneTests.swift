import Foundation
import Testing

struct SourceHygieneTests {
    @Test func retiredCatalogStateNamesAreNotUsedInAppSource() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceFiles = try swiftFiles(under: repoRoot.appending(path: "Otos"))
        let disallowedTerms = [
            "OtosAppModel",
            "visibleAssets",
            "selectedAssets",
            "dismissMessage",
            ".alert(\"Catalog\"",
        ]

        for file in sourceFiles {
            let content = try String(contentsOf: file, encoding: .utf8)
            for term in disallowedTerms {
                #expect(!content.contains(term), "\(term) should not appear in \(file.path(percentEncoded: false))")
            }
        }
    }

    @Test func sqliteRowIDDoesNotLeakOutsideStore() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceFiles = try swiftFiles(under: repoRoot.appending(path: "Otos"))
            .filter { file in
                let path = file.path(percentEncoded: false)
                return !path.hasSuffix("Otos/Stores/CatalogStore.swift")
                    && !path.hasSuffix("Otos/Stores/CatalogStorePersistence.swift")
            }

        for file in sourceFiles {
            let content = try String(contentsOf: file, encoding: .utf8)
            #expect(!content.contains("storageID"), "storageID should not be a public catalog model concept")
        }
    }

    @Test func noManualScanControlsAreExposedInSwiftUISurfaces() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            "Otos/ContentView.swift",
            "Otos/OtosApp.swift",
            "Otos/Views/MediaTableView.swift",
            "Otos/Views/SettingsView.swift",
            "Otos/Views/SidebarView.swift",
        ]
        let disallowedLabels = [
            "Scan Library",
            "Scan Libraries",
            "Rescan",
            "Refresh Library",
            "Refresh Libraries",
        ]

        for file in files {
            let content = try String(contentsOf: repoRoot.appending(path: file), encoding: .utf8)
            for label in disallowedLabels {
                #expect(!content.contains(label), "\(label) should not appear in \(file)")
            }
        }
    }
}

private func swiftFiles(under directory: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    return try enumerator.compactMap { item in
        guard let url = item as? URL else {
            return nil
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true, url.pathExtension == "swift" else {
            return nil
        }
        return url
    }
}
