import Foundation
@testable import OtosKit
import Testing

/// The process's asset identity table (ADR 0005, "One identity table for the process"):
/// ordering by path gives exactly `String`'s order and makes no string, from one lock
/// acquisition per comparison; the index sized at catalog open is never rebuilt while IDs are made; and what the
/// grid's bind of a screenful costs the table, counted on this thread alone
/// (`IdentityTableCounting`) so other suites running beside it do not count.
struct MediaAssetIdentityTableTests {
    /// Paths whose order `String` and bytes disagree on: NFC and NFD spellings of one name,
    /// combining marks in either canonical order, Hangul syllables and their jamo, scripts
    /// outside the Basic Multilingual Plane, and plain ASCII.
    static let corpus: [String] = [
        "a.jpg", "A.jpg", "b.jpg", "ab.jpg", "a/b.jpg", "a b.jpg", "", "z",
        "Ä.jpg", "A\u{308}.jpg", "ä/ö.heic", "a\u{308}/o\u{308}.heic", "Õie.jpg", "O\u{303}ie.jpg",
        "é", "e\u{301}", "e\u{301}\u{316}", "e\u{316}\u{301}", "é\u{316}", "f", "ea", "e",
        "한글.png", "\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}.png", "漢字/写真.jpg",
        "😀.mov", "😀a.mov", "𝔸.jpg", "Ω.jpg", "\u{2126}.jpg", "ﬁ.jpg", "fi.jpg",
        "Vi\u{1EC7}t.jpg", "Vie\u{323}\u{302}t.jpg", "Ånge.jpg", "A\u{30A}nge.jpg", "\u{212B}nge.jpg",
    ]

    /// Every pair, both ways: the table's order is `String`'s `<`, canonically equivalent
    /// spellings compare equal, and the byte order is the UTF-8's.
    @Test func theOrderIsStringsOrderAndTheByteOrderIsTheBytes() {
        let table = MediaAssetIdentityTable()
        let root = LibraryRootPath(rawValue: "/Order")
        let places = Self.corpus.map { table.place(of: root, MediaRelativePath(rawValue: $0)) }
        var disagreements: [String] = []
        for (left, leftPlace) in zip(Self.corpus, places) {
            for (right, rightPlace) in zip(Self.corpus, places) {
                if table.relativePathPrecedes(leftPlace, rightPlace) != (left < right) {
                    disagreements.append("\(left.unicodeScalars.map(\.value)) < \(right.unicodeScalars.map(\.value))")
                }
                if table.relativePathBytesPrecede(leftPlace, rightPlace) != left.utf8.lexicographicallyPrecedes(right.utf8) {
                    disagreements.append("bytes \(left.unicodeScalars.map(\.value)) < \(right.unicodeScalars.map(\.value))")
                }
            }
        }
        #expect(disagreements.isEmpty, "\(disagreements.prefix(5))")
    }

    /// A sort of IDs by path, by root and path, and of faces by path order reads no string and
    /// takes the table's lock once per comparison at most, and orders as sorting the decoded
    /// strings did.
    @Test func aSortOfIDsDecodesNothingAndLocksOncePerComparison() {
        let root = LibraryRootPath(rawValue: "/IdentitySort-\(UUID().uuidString)")
        var generator = SplitMix64(seed: 17)
        let ids = (0 ..< 5000).map { _ in
            let name = Self.corpus[Int(generator.next() % UInt64(Self.corpus.count))]
            return MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "\(generator.next() % 97)/\(name)"))
        }
        var comparisons = 0
        let (byPath, pathCost) = IdentityTableCounting.count {
            ids.sorted { lhs, rhs in
                comparisons += 1
                return lhs.relativePathPrecedes(rhs)
            }
        }
        #expect(pathCost.decodes == 0 && pathCost.lockAcquisitions <= comparisons, "\(pathCost) over \(comparisons) comparisons")
        comparisons = 0
        let (byRootAndPath, rootCost) = IdentityTableCounting.count {
            ids.sorted { lhs, rhs in
                comparisons += 1
                return lhs.pathPrecedes(rhs)
            }
        }
        #expect(rootCost.decodes == 0 && rootCost.lockAcquisitions <= comparisons, "\(rootCost) over \(comparisons) comparisons")
        comparisons = 0
        let faces = ids.enumerated().map { FaceID(asset: $1, index: $0 % 3) }
        let (facesInOrder, faceCost) = IdentityTableCounting.count {
            faces.sorted { lhs, rhs in
                comparisons += 1
                return FaceAssignmentPolicy.pathOrder(lhs, rhs)
            }
        }
        #expect(faceCost.decodes == 0 && faceCost.lockAcquisitions <= comparisons, "\(faceCost) over \(comparisons) comparisons")

        // The same order the decoded strings give, up to canonically equal paths.
        let decoded = ids.map(\.relativePath.rawValue).sorted()
        #expect(byPath.map(\.relativePath.rawValue) == decoded)
        #expect(byRootAndPath.map(\.relativePath.rawValue) == decoded)
        #expect(facesInOrder.map(\.asset.relativePath.rawValue) == decoded)
        // What the decoded comparison costs, for the record: a string each side of every one.
        let (_, decodingCost) = IdentityTableCounting.count {
            ids.sorted { $0.relativePath.rawValue < $1.relativePath.rawValue }
        }
        #expect(decodingCost.decodes >= ids.count)
    }

    /// The pause a maker of an ID can wait behind, counted as the slots one rebuild of the
    /// index moves under the lock: without sizing, crossing half the index rebuilds every
    /// place already made; sized at open from the catalog's rows, making that many IDs never
    /// rebuilds it.
    @Test(arguments: [165_000, 330_000])
    func anIndexSizedAtOpenIsNeverRebuiltWhileIDsAreMade(entries: Int) {
        let root = LibraryRootPath(rawValue: "/Sized")
        let paths = (0 ..< entries).map { MediaRelativePath(rawValue: "2026/\($0 % 365)/IMG_\($0).HEIC") }

        let unsized = MediaAssetIdentityTable()
        for path in paths {
            _ = unsized.place(of: root, path)
        }
        let sized = MediaAssetIdentityTable()
        sized.reserve(entries + entries / 4)
        let atOpen = sized.largestRebuild
        for path in paths {
            _ = sized.place(of: root, path)
        }
        #expect(unsized.largestRebuild >= entries, "unsized: \(unsized.largestRebuild) slots moved at once")
        #expect(sized.largestRebuild == atOpen, "sized: \(sized.largestRebuild) slots moved at once")
        #expect(atOpen <= 4096, "the rebuild at open moves the few places made before it")
        #expect(sized.count == entries && unsized.count == entries)
    }

    /// The table's usage, as the memory line reports it: its pairs and roughly a hundred
    /// bytes each.
    @Test func usageCountsThePairsAndTheirBytes() {
        let table = MediaAssetIdentityTable()
        let root = LibraryRootPath(rawValue: "/Usage")
        for index in 0 ..< 10000 {
            _ = table.place(of: root, MediaRelativePath(rawValue: "folder/IMG_\(index).HEIC"))
        }
        let usage = table.usage
        #expect(usage.pairs == 10000)
        #expect(usage.bytes > 10000 * 40)
    }

    /// The grid's bind of one screenful (120 tiles), as `MediaGridBridge` binds a tile — pin it,
    /// hold its stub, read its content — and then the catalog's details merged: what the
    /// table pays per tile, bounded so it cannot grow unseen.
    @MainActor
    @Test func bindingAScreenfulOfTilesCostsTheTableAFewStepsATile() {
        let root = LibraryRootPath(rawValue: "/Screenful-\(UUID().uuidString)")
        let ids = (0 ..< 120).map { MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "IMG_\($0).HEIC")) }
        let store = TileContentStore()
        let (_, bind) = IdentityTableCounting.count {
            for id in ids {
                store.pin(id)
                store.holdUnreadDetail(for: id)
                _ = store.content(for: id)
            }
        }
        let details = Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, MediaTileDetail(libraryRootPath: root, relativePath: id.relativePath, thumbnailPath: "t.jpg"))
        })
        let (_, merge) = IdentityTableCounting.count { _ = store.mergeDetails(details) }
        // Measured: binding a tile reads its two paths for the stub it holds (one string) and
        // finds the stub's ID again; merging its detail finds the detail's ID three times
        // (`MediaTileDetail.id` is derived from its paths). A few hundred nanoseconds a tile.
        #expect(bind.decodes <= ids.count && bind.lockAcquisitions <= 3 * ids.count, "\(bind)")
        #expect(merge.decodes == 0 && merge.lockAcquisitions <= 3 * ids.count, "\(merge)")
    }
}
