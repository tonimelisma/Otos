import Foundation
@testable import OtosKit
import Testing

/// A media asset's identity is its two paths (ADR 0005, "One copy of an order"): IDs made from
/// equal paths are equal however and wherever they were made, IDs of different paths differ,
/// and an ID gives back exactly the paths it was made from.
struct MediaAssetIdentityTests {
    @Test func idsMadeFromEqualPathsAreEqualAndGiveBackTheirPaths() {
        let root = LibraryRootPath(rawValue: "/Volumes/Photos/Library \(UUID().uuidString)")
        let otherRoot = LibraryRootPath(rawValue: root.rawValue + "-other")
        let paths = ["a.jpg", "2024/IMG_0001.HEIC", "", "Ünïcødé/café.jpg", String(repeating: "deep/", count: 60) + "x.dng"]
        for path in paths {
            let relative = MediaRelativePath(rawValue: path)
            let id = MediaAssetID(libraryRootPath: root, relativePath: relative)
            // Made again from new strings with the same bytes.
            let again = MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: String(decoding: Array(root.rawValue.utf8), as: UTF8.self)),
                relativePath: MediaRelativePath(rawValue: String(decoding: Array(path.utf8), as: UTF8.self))
            )
            #expect(id == again)
            #expect(id.hashValue == again.hashValue)
            #expect(id.libraryRootPath == root)
            #expect(id.relativePath == relative)
            #expect(id.relativePath.rawValue == path)
            #expect(id.relativePath.fingerprint == relative.fingerprint)
            #expect(id != MediaAssetID(libraryRootPath: otherRoot, relativePath: relative))
            #expect(id.fileURL == root.url.appending(path: path, directoryHint: .notDirectory))
        }
        let ids = Set(paths.map { MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: $0)) })
        #expect(ids.count == paths.count)
    }

    /// A path's two Unicode spellings are two paths, as `MediaRelativePath` compares them.
    @Test func twoSpellingsOfAPathAreTwoIdentities() {
        let root = LibraryRootPath(rawValue: "/Spellings/\(UUID().uuidString)")
        let composed = MediaRelativePath(rawValue: "caf\u{E9}.jpg")
        let decomposed = MediaRelativePath(rawValue: "cafe\u{301}.jpg")
        #expect(composed != decomposed)
        #expect(MediaAssetID(libraryRootPath: root, relativePath: composed) != MediaAssetID(libraryRootPath: root, relativePath: decomposed))
    }

    /// Many tasks naming the same paths at once agree on every identity.
    @Test func concurrentReadsOfTheSamePathsMakeEqualIDs() async {
        let root = LibraryRootPath(rawValue: "/Concurrent/\(UUID().uuidString)")
        let paths = (0 ..< 5000).map { "folder \($0 % 37)/IMG_\($0).JPG" }
        let made = await withTaskGroup(of: [MediaAssetID].self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    paths.map { MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: $0)) }
                }
            }
            var all: [[MediaAssetID]] = []
            for await ids in group {
                all.append(ids)
            }
            return all
        }
        for ids in made {
            #expect(ids == made[0])
        }
        #expect(made[0].map(\.relativePath.rawValue) == paths)
        #expect(Set(made[0]).count == paths.count)
    }

    /// A diagnostic or a test's message names the asset by its paths.
    @Test func anIDDescribesItsPaths() {
        let id = MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/Described"), relativePath: MediaRelativePath(rawValue: "x/y.jpg"))
        let text = String(describing: id)
        #expect(text.contains("/Described"))
        #expect(text.contains("x/y.jpg"))
    }
}
