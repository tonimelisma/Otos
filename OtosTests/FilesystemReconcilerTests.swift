import CoreServices
import Foundation
@testable import OtosKit
import Testing

struct FilesystemReconcilerTests {
    private let root = LibraryRootPath(rawValue: "/tmp/otos-test-root")

    // Validates: ARC-041
    /// ARC-041: a path's catalog name never depends on whether it is a directory right
    /// now. A file that became a directory keeps the name its row has, so a file event for
    /// it reconciles that row.
    @Test func aDirectoryURLMapsToTheSameNameAsTheFileItReplaced() {
        let directory = URL(fileURLWithPath: "/tmp/otos-test-root/a.jpg", isDirectory: true)
        #expect(CatalogPath.relativePath(rootPath: root, fileURL: directory) == MediaRelativePath(rawValue: "a.jpg"))
    }

    @Test func anAbsolutePathMapsByTextAlone() {
        #expect(CatalogPath.relativePath(rootPath: root, absolutePath: "/tmp/otos-test-root/d/a.jpg/")
            == MediaRelativePath(rawValue: "d/a.jpg"))
        #expect(CatalogPath.relativePath(rootPath: root, absolutePath: "/tmp/otos-test-root") == nil)
        #expect(CatalogPath.relativePath(rootPath: root, absolutePath: "/tmp/otos-test-root/") == nil)
        #expect(CatalogPath.relativePath(rootPath: root, absolutePath: "/tmp/otos-test-rootb/a.jpg") == nil)
    }

    /// A batch for a root that is gone, unarmed or unavailable is dropped, never reconciled.
    @Test(arguments: [
        (false, true, true, "removed"),
        (true, false, true, "unarmed"),
        (true, true, false, "unavailable"),
    ])
    func dropsWhenTheRootCannotBeReconciled(rootExists: Bool, isArmed: Bool, isAvailable: Bool, reason: String) {
        let decision = FilesystemReconciler.decide(
            events: [fileEvent("a.jpg")],
            root: root,
            rootExists: rootExists,
            isArmed: isArmed,
            isAvailable: isAvailable
        )
        #expect(decision == .drop(reason: reason))
    }

    @Test func rootScopeWhenAnyEventRequiresScan() {
        let events = [
            fileEvent("a.jpg", flags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
            FilesystemEvent(path: "\(root.rawValue)/subdir", flags: 0),
        ]
        let decision = FilesystemReconciler.decide(
            events: events,
            root: root,
            rootExists: true,
            isArmed: true,
            isAvailable: true
        )
        guard case let .accumulate(scopes) = decision else {
            Issue.record("expected accumulate")
            return
        }
        #expect(scopes.contains { $0.scope == .root })
        #expect(scopes.contains { $0.scope == .file(MediaRelativePath(rawValue: "a.jpg")) })
    }

    @Test func subtreeScopeForDirectoryEvent() {
        let event = FilesystemEvent(
            path: "\(root.rawValue)/2026/03",
            flags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir)
        )
        let dirt = FilesystemReconciler.classify(event: event, root: root)
        #expect(dirt.scope == .subtree(MediaRelativePath(rawValue: "2026/03")))
    }

    @Test func targetedWhenAllEventsAreSingleFile() {
        let events = [
            fileEvent(
                "a.jpg",
                flags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
            ),
            fileEvent(
                "b.jpg",
                flags: UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)
            ),
        ]
        let decision = FilesystemReconciler.decide(
            events: events,
            root: root,
            rootExists: true,
            isArmed: true,
            isAvailable: true
        )
        guard case let .accumulate(scopes) = decision else {
            Issue.record("expected accumulate")
            return
        }
        #expect(scopes.map(\.scope) == [
            .file(MediaRelativePath(rawValue: "a.jpg")),
            .file(MediaRelativePath(rawValue: "b.jpg")),
        ])
        #expect(scopes[0].fileAction == .upsert)
        #expect(scopes[1].fileAction == .deleteIfMissing)
    }

    private func fileEvent(_ name: String, flags: UInt32 = 0) -> FilesystemEvent {
        FilesystemEvent(path: "\(root.rawValue)/\(name)", flags: flags)
    }
}

struct FilesystemDirtyAccumulatorTests {
    @Test func subtreeAbsorbsDescendantFiles() {
        var dirt = FilesystemDirtyAccumulator()
        dirt.insertFile(MediaRelativePath(rawValue: "a/b/c.jpg"), action: .upsert)
        dirt.insertSubtree(MediaRelativePath(rawValue: "a/b"))
        #expect(dirt.files.isEmpty)
        #expect(dirt.subtrees == [MediaRelativePath(rawValue: "a/b")])
    }

    @Test func ancestorSubtreeAbsorbsDescendantSubtree() {
        var dirt = FilesystemDirtyAccumulator()
        dirt.insertSubtree(MediaRelativePath(rawValue: "a/b/c"))
        dirt.insertSubtree(MediaRelativePath(rawValue: "a/b"))
        #expect(dirt.subtrees == [MediaRelativePath(rawValue: "a/b")])
    }

    @Test func rootClearsNarrowerScopes() {
        var dirt = FilesystemDirtyAccumulator()
        dirt.insertFile(MediaRelativePath(rawValue: "x.jpg"), action: .upsert)
        dirt.insertSubtree(MediaRelativePath(rawValue: "y"))
        dirt.insertRoot()
        #expect(dirt.isRootDirty)
        #expect(dirt.files.isEmpty)
        #expect(dirt.subtrees.isEmpty)
    }

    @Test func siblingPrefixNotAbsorbed() {
        var dirt = FilesystemDirtyAccumulator()
        dirt.insertSubtree(MediaRelativePath(rawValue: "a/b"))
        dirt.insertFile(MediaRelativePath(rawValue: "a/b2.jpg"), action: .upsert)
        #expect(dirt.subtrees == [MediaRelativePath(rawValue: "a/b")])
        #expect(dirt.files.keys.contains(MediaRelativePath(rawValue: "a/b2.jpg")))
    }
}
