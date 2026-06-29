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
            "CatalogSession",
            "CatalogBrowserState",
            "CatalogBrowserProjection",
            "CatalogWindowModel",
            "CatalogWindowProjection",
            "visibleAssets",
            "selectedAssets",
            "assetsForSelection",
            "scanningRootPaths",
            "CatalogSelection",
            "dismissMessage",
            ".alert(\"Catalog\"",
            "assetStructureRevision",
            "libraryDisplayName",
            "CatalogUIUpdateTracker",
            "isApplyingResolvedSidebarSelection",
            "syncSidebarSelectionToProjection",
        ]

        for file in sourceFiles {
            let content = try String(contentsOf: file, encoding: .utf8)
            for term in disallowedTerms {
                #expect(!content.contains(term), "\(term) should not appear in \(file.path(percentEncoded: false))")
            }
        }
    }

    @Test func contentViewDoesNotCoordinateCatalogWork() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let content = try String(
            contentsOf: repoRoot.appending(path: "Otos/ContentView.swift"),
            encoding: .utf8
        )

        #expect(!content.contains(".onChange"))
        #expect(!content.contains("applyCatalogSnapshot"))
        #expect(!content.contains("update(snapshot:"))
        #expect(!content.contains("catalogStore"))
        #expect(!content.contains("CatalogProjection"))
    }

    @Test func appUsesSingleMainWindowScene() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let content = try String(contentsOf: repoRoot.appending(path: "Otos/OtosApp.swift"), encoding: .utf8)

        #expect(!content.contains("WindowGroup"))
        #expect(content.contains("Window(\"Otos\", id: \"main\")"))
        #expect(content.contains("CommandGroup(replacing: .newItem)"))
    }

    @Test func sidebarDoesNotReceiveWholeCatalogSnapshot() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sidebarURL = repoRoot.appending(path: "Otos/Views/SidebarView.swift")
        let content = try String(contentsOf: sidebarURL, encoding: .utf8)

        #expect(!content.contains("CatalogSnapshot"))
        #expect(content.contains("let libraries: [CatalogLibraryState]"))
    }

    @Test func sidebarDoesNotRenderLibraryStatusText() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sidebarURL = repoRoot.appending(path: "Otos/Views/SidebarView.swift")
        let content = try String(contentsOf: sidebarURL, encoding: .utf8)

        #expect(!content.contains("sidebarSubtitle"))
        #expect(!content.contains("\"Checking\""))
        #expect(!content.contains("\"Scanning\""))
        #expect(!content.contains("\"Unavailable\""))
    }

    @Test func settingsUsesProjectedLibraryRowsWithoutDisplayingScanStatus() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsURL = repoRoot.appending(path: "Otos/Views/SettingsView.swift")
        let content = try String(contentsOf: settingsURL, encoding: .utf8)

        #expect(!content.contains("CatalogSession"))
        #expect(content.contains("let libraries: [CatalogLibraryState]"))
        #expect(!content.contains("isScanning"))
        #expect(!content.contains(".scanning"))
    }

    @Test func storeDoesNotPublishSnapshotsToUISubscribers() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let storeURL = repoRoot.appending(path: "Otos/Stores/CatalogStore.swift")
        let content = try String(contentsOf: storeURL, encoding: .utf8)

        #expect(!content.contains("func snapshots()"))
        #expect(!content.contains("publishSnapshot"))
        #expect(content.contains("func changeNotifications()"))
        #expect(content.contains("AsyncStream<CatalogStoreChange>"))
        #expect(content.contains("case libraryRemoved(LibraryRootPath)"))
        #expect(content.contains("func currentSnapshot()"))
    }

    @Test func storeUsesPersistenceInstanceScanOwnershipWithoutDurableScanIDs() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let store = try String(
            contentsOf: repoRoot.appending(path: "Otos/Stores/CatalogStore.swift"),
            encoding: .utf8
        )
        let persistence = try String(
            contentsOf: repoRoot.appending(path: "Otos/Stores/CatalogStorePersistence.swift"),
            encoding: .utf8
        )

        #expect(store.contains("private struct ActiveScan"))
        #expect(store.contains("let rootRowID: Int64"))
        #expect(store.contains("private func owns(_ scan: ActiveScan)"))
        #expect(!store.contains("currentScanRootPath"))
        #expect(!store.contains("scanUUID"))
        #expect(!persistence.contains("filesystem_scan"))
    }

    @Test func viewModelDoesNotUseGenerationBasedProjectionRejection() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewModelURL = repoRoot.appending(path: "Otos/ViewModels/CatalogWindowViewModel.swift")
        let content = try String(contentsOf: viewModelURL, encoding: .utf8)

        #expect(!content.contains("generation"))
        #expect(!content.contains("projectionTask"))
        #expect(!content.contains("applyCatalogSnapshot"))
        #expect(!content.contains("didSet"))
        #expect(content.contains("func selectSidebar("))
        #expect(content.contains("bufferingPolicy: .bufferingNewest(1)"))
    }

    @Test func viewModelOwnsWeakStateConsumptionAndSerialMutationDelivery() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewModelURL = repoRoot.appending(path: "Otos/ViewModels/CatalogWindowViewModel.swift")
        let content = try String(contentsOf: viewModelURL, encoding: .utf8)

        #expect(content.contains("stateConsumptionTask"))
        #expect(content.contains("catalogStartupTask"))
        #expect(content.contains("selectionForwardingTask"))
        #expect(content.contains("mutationForwardingTask"))
        #expect(content.contains("bufferingPolicy: .unbounded"))
        #expect(content.contains("Task { [weak self, projection, store, initialSelection]"))
        #expect(!content.contains("private var stateTask:"))
        #expect(!content.contains("private var startTask:"))
        #expect(!content.contains("private var selectionTask:"))

        let addMethod = try #require(content.range(of: "func addLibrary(url: URL)"))
        let removeMethod = try #require(content.range(of: "func removeLibrary(_ library: LibraryRoot)"))
        let selectMethod = try #require(content.range(of: "func selectSidebar(_ selection: SidebarSelection)"))
        let addBody = content[addMethod.lowerBound ..< removeMethod.lowerBound]
        let removeBody = content[removeMethod.lowerBound ..< selectMethod.lowerBound]
        #expect(!addBody.contains("Task {"))
        #expect(!removeBody.contains("Task {"))
        #expect(!addBody.contains("catalogStore"))
        #expect(!removeBody.contains("catalogStore"))
    }

    @Test func appKitGridUsesNativeTelemetryWithoutJSONLTasks() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let content = try String(
            contentsOf: repoRoot.appending(path: "Otos/Views/MediaAssetCollectionView.swift"),
            encoding: .utf8
        )

        #expect(!content.contains("CatalogDiagnostics"))
        #expect(!content.contains("Task {"))
        #expect(content.contains("OtosLog.ui"))
        #expect(content.contains("OtosSignpost.ui"))
    }

    @Test func appKitGridDoesNotReloadItemsForDetailRefresh() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let content = try String(
            contentsOf: repoRoot.appending(path: "Otos/Views/MediaAssetCollectionView.swift"),
            encoding: .utf8
        )

        #expect(content.contains("case let .refreshVisible(grid, resetScroll):"))
        #expect(content.contains("reconfigureVisibleItems(reason: \"detailRefresh\")"))
        #expect(content.contains("collectionView.item(at: indexPath)"))
        #expect(!content.contains("reloadItems(at:"))
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
            "Otos/Views/MediaGridView.swift",
            "Otos/Views/MediaAssetCollectionView.swift",
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

    @Test func mediaBrowserUsesReusableSixColumnAppKitGrid() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let content = try String(
            contentsOf: repoRoot.appending(path: "Otos/Views/MediaAssetCollectionView.swift"),
            encoding: .utf8
        )

        #expect(content.contains("NSViewControllerRepresentable"))
        #expect(content.contains("NSCollectionView"))
        #expect(content.contains("NSCollectionViewCompositionalLayout"))
        #expect(content.contains("count: 6"))
        #expect(!content.contains("NSTableView"))
        #expect(!content.contains("NSHostingView"))
        #expect(!FileManager.default.fileExists(
            atPath: repoRoot.appending(path: "Otos/Views/MediaTableView.swift").path(percentEncoded: false)
        ))
    }

    @Test func livingDocumentationHasNoKnownRetiredCurrentStateClaims() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let docsRoot = repoRoot.appending(path: "docs")
        let markdownFiles = try markdownFiles(under: docsRoot)
        let retiredClaims = [
            "CatalogWindowModel",
            "CatalogSession",
            "CatalogBrowserState",
            "CatalogUIUpdateTracker",
            "catalog.window.state.apply",
            "assetsInSelectedScope",
            "0007-catalog-order-invalidation",
        ]

        for file in markdownFiles {
            let content = try String(contentsOf: file, encoding: .utf8)
            for claim in retiredClaims {
                #expect(
                    !content.contains(claim),
                    "\(claim) should not appear in current docs: \(file.path(percentEncoded: false))"
                )
            }
        }

        #expect(!FileManager.default.fileExists(
            atPath: docsRoot.appending(path: "specs/0002-product-roadmap.md").path(percentEncoded: false)
        ))
        #expect(FileManager.default.fileExists(
            atPath: docsRoot.appending(path: "adr/0007-catalog-order-reuse.md").path(percentEncoded: false)
        ))

        let requirements = try String(
            contentsOf: docsRoot.appending(path: "requirements.md"),
            encoding: .utf8
        )
        #expect(!requirements.contains("| Changed |"))

        let agentInstructions = try String(
            contentsOf: repoRoot.appending(path: "AGENTS.md"),
            encoding: .utf8
        )
        #expect(agentInstructions.contains("## Living Documentation"))
        #expect(agentInstructions.contains("repository-wide stale-document audit"))
        #expect(agentInstructions.contains("code-comment accuracy audit"))
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

private func markdownFiles(under directory: URL) throws -> [URL] {
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
        guard values.isRegularFile == true, url.pathExtension == "md" else {
            return nil
        }
        return url
    }
}
