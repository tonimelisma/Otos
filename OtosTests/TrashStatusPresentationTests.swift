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
            bytesToDownload: bytes,
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
        #expect(floor.message == "There isn’t enough free space to download them so they can be moved to the Trash. You can’t undo this.")
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

/// DES-018/DES-053: the bar keeps one height in every state. Each state is also
/// rendered in light and dark to `$TMPDIR/OtosDesignEvidence/trash-status-bar/` as the
/// design check's screenshots (DES-022).
@MainActor
struct TrashStatusBarRenderingTests {
    private static let states: [(String, MediaTrashCoordinator.QueueState)] = [
        ("working", .init(pendingCount: 11, movedCount: 3, bytesToDownload: 1_200_000_000, attention: nil)),
        ("working-local", .init(pendingCount: 2, movedCount: 0, bytesToDownload: 0, attention: nil)),
        ("waiting-space", .init(pendingCount: 14, movedCount: 0, bytesToDownload: 0, attention: .waitingForSpace)),
        ("waiting-download", .init(pendingCount: 1, movedCount: 0, bytesToDownload: 0, attention: .waitingForDownload)),
    ]

    @Test func everyStateRendersAtOneHeight() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OtosDesignEvidence/trash-status-bar", directoryHint: .isDirectory)
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
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.nsImage,
                   let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                {
                    try png.write(to: directory.appending(path: "trash-bar-\(name)-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
        #expect(heights.count == 1)
    }
}
