import Foundation
import OSLog

actor CatalogProjection {
    private let diagnostics: CatalogDiagnostics?

    init(diagnostics: CatalogDiagnostics? = .shared) {
        self.diagnostics = diagnostics
    }

    func sortedSnapshot(from snapshot: CatalogSnapshot) async -> CatalogSnapshot {
        let state = OtosSignpost.performance.beginInterval("CatalogProjectionSort")
        let roots = Self.sortRoots(snapshot.roots)
        let assets = Self.sortAssets(snapshot.assets)
        OtosSignpost.performance.endInterval("CatalogProjectionSort", state)

        await diagnostics?.record(
            operation: "catalog.projection.sort",
            phase: "finish",
            fields: [
                "roots": "\(roots.count)",
                "assets": "\(assets.count)",
            ]
        )

        return CatalogSnapshot(
            roots: roots,
            assets: assets,
            scanningRootPaths: snapshot.scanningRootPaths
        )
    }

    func browserProjection(
        snapshot: CatalogSnapshot,
        selection: CatalogSelection
    ) async -> CatalogBrowserProjection {
        let state = OtosSignpost.performance.beginInterval("CatalogProjectionFilter")
        let title = Self.title(for: selection, snapshot: snapshot)
        let assetsForSelection = Self.assets(for: selection, snapshot: snapshot)
        OtosSignpost.performance.endInterval("CatalogProjectionFilter", state)

        await diagnostics?.record(
            operation: "catalog.projection.filter",
            phase: "finish",
            fields: [
                "selection": selection.diagnosticDescription,
                "assets": "\(assetsForSelection.count)",
            ]
        )

        return CatalogBrowserProjection(title: title, assetsForSelection: assetsForSelection)
    }
}

private extension CatalogProjection {
    static func sortRoots(_ roots: [LibraryRoot]) -> [LibraryRoot] {
        roots.sorted { left, right in
            let displayComparison = left.displayName.localizedStandardCompare(right.displayName)
            if displayComparison == .orderedSame {
                return left.path.rawValue.localizedStandardCompare(right.path.rawValue) == .orderedAscending
            }
            return displayComparison == .orderedAscending
        }
    }

    static func sortAssets(_ assets: [MediaAsset]) -> [MediaAsset] {
        assets.sorted { left, right in
            let libraryComparison = left.libraryDisplayName.localizedStandardCompare(right.libraryDisplayName)
            if libraryComparison != .orderedSame {
                return libraryComparison == .orderedAscending
            }

            let pathComparison = left.libraryRootPath.rawValue.localizedStandardCompare(right.libraryRootPath.rawValue)
            if pathComparison != .orderedSame {
                return pathComparison == .orderedAscending
            }

            return left.relativePath.rawValue.localizedStandardCompare(right.relativePath.rawValue) == .orderedAscending
        }
    }

    static func assets(for selection: CatalogSelection, snapshot: CatalogSnapshot) -> [MediaAsset] {
        switch selection {
        case .allMedia:
            snapshot.assets
        case let .library(path):
            snapshot.assets.filter { $0.libraryRootPath == path }
        }
    }

    static func title(for selection: CatalogSelection, snapshot: CatalogSnapshot) -> String {
        switch selection {
        case .allMedia:
            "All Media"
        case let .library(path):
            snapshot.roots.first { $0.path == path }?.displayName ?? "Library"
        }
    }
}

private extension CatalogSelection {
    var diagnosticDescription: String {
        switch self {
        case .allMedia:
            "allMedia"
        case let .library(path):
            "library:\(path.rawValue)"
        }
    }
}
