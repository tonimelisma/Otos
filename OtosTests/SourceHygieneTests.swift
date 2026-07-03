import Foundation
import Testing

@Suite(.serialized)
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

        // This is a structural scene invariant; checking source avoids adding a UI-introspection
        // dependency just to prove the app still declares exactly one main-window scene.
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

        // The invariant is absence of specific transient labels in a passive SwiftUI view;
        // source-level coverage keeps that guard narrow without UI-introspection machinery.
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
        #expect(!content.contains("func currentSnapshot()"))
        #expect(!content.contains("func makeSnapshot()"))
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

    @Test func viewModelUsesQueryGenerationForProjectedStateFreshness() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewModelURL = repoRoot.appending(path: "Otos/ViewModels/CatalogWindowViewModel.swift")
        let content = try String(contentsOf: viewModelURL, encoding: .utf8)

        #expect(content.contains("private var queryGeneration"))
        #expect(content.contains("nextState.queryGeneration >= queryGeneration"))
        #expect(content.contains("AsyncStream<CatalogQueryRequest>"))
        #expect(!content.contains("hasPendingQueryIntent"))
        #expect(!content.contains("isRemovedLibraryFallback"))
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
        #expect(content.contains("queryForwardingTask"))
        #expect(content.contains("mutationForwardingTask"))
        #expect(content.contains("bufferingPolicy: .unbounded"))
        #expect(content.contains("Task { [weak self, projection, store, initialRequest]"))
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
        #expect(!content.contains("diagnostics?.record"))
        #expect(content.contains("Task { [weak self, detailReader, visibleIDs]"))
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

        #expect(content.contains("case let .refreshVisible(_, resetScroll, resetSelection):"))
        #expect(content.contains("requestVisibleDetails(reason: \"detailRefresh\")"))
        #expect(content.contains("reconfigureVisibleItems(reason: \"detailQuery\")"))
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

        // This absence-of-controls invariant spans several SwiftUI surfaces. Grepping labels
        // keeps it explicit without introducing a UI-test target only to inspect menus/views.
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

@Suite(.serialized)
struct QualityIncrementSourceHygieneTests {
    @Test func sourceContainsNoUncheckedSendableConformances() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceFiles = try swiftFiles(under: repoRoot.appending(path: "Otos"))
            + swiftFiles(under: repoRoot.appending(path: "OtosTests"))
        let forbidden = "@unchecked" + " Sendable"

        for file in sourceFiles {
            let content = try String(contentsOf: file, encoding: .utf8)
            #expect(
                !content.contains(forbidden),
                "unchecked Sendable should not appear in source: \(file.path(percentEncoded: false))"
            )
        }
    }

    @Test func rootMarkdownIsLimitedToEntryPoints() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let allowed = Set(["AGENTS.md", "README.md"])
        let rootMarkdown = try rootMarkdownFiles(under: repoRoot).map(\.lastPathComponent)

        #expect(Set(rootMarkdown).isSubset(of: allowed))
    }

    @Test func currentDocsAndSourceDoNotCallMaterializationDeadOrUnwired() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = try markdownFiles(under: repoRoot.appending(path: "docs"))
            + swiftFiles(under: repoRoot.appending(path: "Otos"))
        let disallowed = [
            "NOT WIRED" + " UP",
            "dead `FileMaterialization`" + " detector",
            "dead File" + "Materialization detector",
        ]

        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            for term in disallowed {
                #expect(
                    !content.contains(term),
                    "\(term) should not appear in current docs/source: \(file.path(percentEncoded: false))"
                )
            }
        }
    }

    @Test func deterministicAsyncTestHelpersGuardTopTimingHeavyTests() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let support = try String(
            contentsOf: repoRoot.appending(path: "OtosTests/AsyncTestSupport.swift"),
            encoding: .utf8
        )
        #expect(support.contains("actor AsyncValueRecorder"))
        #expect(support.contains("actor ManualSleepGate"))

        let checkedFiles = [
            "OtosTests/CatalogStoreTests.swift",
            "OtosTests/CatalogStoreFilesystemEventTests.swift",
            "OtosTests/CatalogStoreLifecycleRaceTests.swift",
            "OtosTests/CatalogProjectionTests.swift",
            "OtosTests/CatalogWindowViewModelTests.swift",
        ]
        for file in checkedFiles {
            let content = try String(contentsOf: repoRoot.appending(path: file), encoding: .utf8)
            #expect(!content.contains("timeoutAttempts"), "timeoutAttempts should not appear in \(file)")
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

private func rootMarkdownFiles(under directory: URL) throws -> [URL] {
    let contents = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )
    return try contents.filter { url in
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        return values.isRegularFile == true && url.pathExtension == "md"
    }
}
