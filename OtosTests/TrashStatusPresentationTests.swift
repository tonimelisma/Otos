import AppKit
import Foundation
@testable import OtosKit
import SwiftUI
import Testing

/// The trash status bar (DES-089) and the delete-immediately prompts (Plan 0104 D3/D4)
/// are pure mappings from queue facts to strings.
struct TrashStatusPresentationTests {
    private func state(
        pending: Int,
        moved: Int = 0,
        bytes: Int64 = 0,
        attention: MediaTrashCoordinator.QueueState.Attention? = nil
    ) -> MediaTrashCoordinator.QueueState {
        MediaTrashCoordinator.QueueState(
            pendingCount: pending,
            movedCount: moved,
            bytesToDownload: PartialByteCount(knownBytes: bytes, unknownCount: 0),
            attention: attention
        )
    }

    @Test func nothingPendingDrawsNoBar() {
        #expect(TrashStatusPresentation.map(.idle) == nil)
    }

    @Test func workingCountsItemsAndStatesBytesToDownload() throws {
        let drawn = try #require(TrashStatusPresentation.map(state(pending: 11, moved: 3, bytes: 34_000_000)))
        #expect(drawn.badge == .none)
        #expect(drawn.primaryLine == "Moving 14 items to the Trash")
        // The import bar's byte format: whole MB under 100 MB, then GB with one decimal.
        #expect(drawn.secondaryLine == "34 MB to download")
        #expect(drawn.progress?.completed == 3)
        #expect(drawn.progress?.total == 14)
    }

    @Test func workingWithNothingToDownloadHasNoSecondLine() throws {
        let drawn = try #require(TrashStatusPresentation.map(state(pending: 1)))
        #expect(drawn.primaryLine == "Moving 1 item to the Trash")
        #expect(drawn.secondaryLine == nil)
    }

    @Test func waitingStatesNeedAttentionWithoutProgress() throws {
        let space = try #require(TrashStatusPresentation.map(state(pending: 2, attention: .waitingForSpace)))
        #expect(space.badge == .attention)
        #expect(space.primaryLine == "Waiting for free space")
        #expect(space.secondaryLine == "2 items waiting to move to the Trash")
        #expect(space.progress == nil)

        let download = try #require(TrashStatusPresentation.map(state(pending: 1, attention: .waitingForDownload)))
        #expect(download.primaryLine == "Waiting to download")
        #expect(download.secondaryLine == "1 item waiting to move to the Trash")
    }

    @Test func decisionPromptsNameTheActAndItsCount() {
        let root = LibraryRootPath(rawValue: "/Pictures")
        let one = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "Trip/IMG_1.MOV"))
        let two = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "IMG_2.JPG"))

        let failed = TrashDecisionPrompt(decision: .downloadFailed([one]))
        #expect(failed.title == "Delete “IMG_1.MOV” Immediately?")
        #expect(failed.message == "It couldn’t be downloaded, so it can’t be moved to the Trash. You can’t undo this.")

        let floor = TrashDecisionPrompt(decision: .diskFloor([one, two]))
        #expect(floor.title == "Delete 2 Items Immediately?")
        #expect(
            floor.message
                == "There isn’t enough free space to download them so they can be moved to the Trash. "
                + "You can’t undo this."
        )
        #expect(TrashDecisionPrompt.deleteTitle == "Delete")
    }

    @Test func decisionsOfOneKindMergeWithoutDuplicates() {
        let root = LibraryRootPath(rawValue: "/Pictures")
        let one = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "1.jpg"))
        let two = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "2.jpg"))
        let merged = MediaTrashCoordinator.Decision.downloadFailed([one]).merging(.downloadFailed([one, two]))
        #expect(merged == .downloadFailed([one, two]))
        #expect(!MediaTrashCoordinator.Decision.downloadFailed([one]).isSameKind(as: .diskFloor([one])))
    }
}

/// The large-download question (Plan 0104): asked only above 100 MB of downloads and
/// only while the preference allows it.
struct LargeTrashDownloadPromptTests {
    @Test func asksOnlyAboveTheThresholdWhileThePreferenceIsOn() {
        #expect(LargeTrashDownloadPrompt.asks(bytes: 100_000_001, preference: true))
        #expect(!LargeTrashDownloadPrompt.asks(bytes: 100_000_000, preference: true))
        #expect(!LargeTrashDownloadPrompt.asks(bytes: 5_000_000_000, preference: false))
    }

    @Test func titleNamesSizeAndCount() {
        let root = LibraryRootPath(rawValue: "/Pictures")
        let one = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "Trip/clip.mov"))
        let two = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "b.jpg"))
        #expect(
            LargeTrashDownloadPrompt(ids: [one], bytes: 1_200_000_000).title
                == "Download 1.2 GB to Move “clip.mov” to Trash?"
        )
        #expect(
            LargeTrashDownloadPrompt(ids: [one, two], bytes: 340_000_000).title
                == "Download 0.3 GB to Move 2 Items to Trash?"
        )
        #expect(LargeTrashDownloadPrompt.confirmTitle == "Download and Move to Trash")
    }

    /// A download with sizes the catalog does not know states the known part as a lower
    /// bound, asks only when that part is already over the threshold, and the status bar
    /// states no figure when no size is known.
    @Test func unknownSizesAreALowerBoundNeverZero() {
        let one = MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/Pictures"), relativePath: MediaRelativePath(rawValue: "a.mov"))
        let two = MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/Pictures"), relativePath: MediaRelativePath(rawValue: "b.mov"))
        let partial = PartialByteCount(knownBytes: 1_200_000_000, unknownCount: 1)
        #expect(LargeTrashDownloadPrompt(ids: [one, two], bytes: partial).title
            == "Download at Least 1.2 GB to Move 2 Items to Trash?")
        #expect(LargeTrashDownloadPrompt.asks(bytes: partial, preference: true))
        #expect(!LargeTrashDownloadPrompt.asks(bytes: PartialByteCount(knownBytes: 0, unknownCount: 3), preference: true))
        let working = TrashStatusPresentation.map(
            .init(pendingCount: 2, movedCount: 0, bytesToDownload: partial, attention: nil)
        )
        #expect(working?.secondaryLine == "at least 1.2 GB to download")
        let unsized = TrashStatusPresentation.map(
            .init(pendingCount: 2, movedCount: 0, bytesToDownload: PartialByteCount(knownBytes: 0, unknownCount: 2), attention: nil)
        )
        #expect(unsized?.secondaryLine == nil)
    }
}

/// DES-018/DES-053: the bar keeps one height in every state. Each state is also
/// rendered in light and dark as the design check's screenshots (DES-022), into
/// `build/DesignEvidence/trash-status-bar/` of the checkout that ran the test — the
/// worktree's own, ignored `build/`, so parallel runs in other worktrees never
/// overwrite each other's evidence and the images outlive the test for review.
@MainActor
struct TrashStatusBarRenderingTests {
    private static let states: [(String, MediaTrashCoordinator.QueueState)] = [
        ("working", .init(pendingCount: 11, movedCount: 3, bytesToDownload: 1_200_000_000, attention: nil)),
        ("working-local", .init(pendingCount: 2, movedCount: 0, bytesToDownload: 0, attention: nil)),
        ("waiting-space", .init(pendingCount: 14, movedCount: 0, bytesToDownload: 0, attention: .waitingForSpace)),
        ("waiting-download", .init(pendingCount: 1, movedCount: 0, bytesToDownload: 0, attention: .waitingForDownload)),
    ]

    /// `<checkout>/build/DesignEvidence/trash-status-bar`, found from this file's own
    /// location in `<checkout>/OtosTests/`.
    private static func evidenceDirectory(filePath: String = #filePath) -> URL {
        URL(filePath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "build/DesignEvidence/trash-status-bar", directoryHint: .isDirectory)
    }

    @Test func everyStateRendersAtOneHeight() throws {
        let directory = Self.evidenceDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var heights: Set<CGFloat> = []
        for (name, queueState) in Self.states {
            let presentation = try #require(TrashStatusPresentation.map(queueState))
            for scheme in [ColorScheme.light, .dark] {
                let view = TrashStatusBar(presentation: presentation)
                    .environment(\.colorScheme, scheme)
                    .frame(width: 900)
                let host = NSHostingView(rootView: view)
                heights.insert(host.fittingSize.height)
                // Real AppKit drawing (ImageRenderer cannot draw AppKit-backed controls
                // such as the progress indicator), at the view's own appearance.
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(
                    to: directory.appending(path: "trash-bar-\(name)-\(scheme == .dark ? "dark" : "light").png")
                )
            }
        }
        #expect(heights.count == 1)
    }
}
