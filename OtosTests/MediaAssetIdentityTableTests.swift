import Foundation
@testable import OtosKit
import Testing

/// The process's asset identity table (ADR 0005, "One identity table for the process"):
/// ordering by path gives exactly `String`'s order and makes no string, from one lock
/// acquisition per comparison; the index sized at catalog open is never rebuilt while IDs are
/// made; and what the grid's bind of a screenful costs the table. Costs are counted on a table
/// the test makes (`countingSteps`), which nothing else in the process uses.
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

    // Validates: ARC-070
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

    // Validates: ARC-070
    /// A sort by path, by root and path, and by path then root (the order of faces) reads no
    /// string and takes the table's lock once per comparison at most, and orders as sorting the
    /// decoded strings does; IDs, faces and their policies order exactly so.
    @Test func aSortOfIDsDecodesNothingAndLocksOncePerComparison() {
        let root = LibraryRootPath(rawValue: "/IdentitySort")
        var generator = SplitMix64(seed: 17)
        let paths = (0 ..< 5000).map { _ in
            let name = Self.corpus[Int(generator.next() % UInt64(Self.corpus.count))]
            return MediaRelativePath(rawValue: "\(generator.next() % 97)/\(name)")
        }
        let decoded = paths.map(\.rawValue).sorted()

        // What each comparison costs, on a table of the test's own.
        let table = MediaAssetIdentityTable(countingSteps: true)
        let places = paths.map { table.place(of: root, $0) }
        func cost(_ precedes: (UInt32, UInt32) -> Bool) -> (order: [String], steps: MediaAssetIdentityTable.Steps, comparisons: Int) {
            var comparisons = 0
            let before = table.steps
            let sorted = places.sorted { lhs, rhs in
                comparisons += 1
                return precedes(lhs, rhs)
            }
            let after = table.steps
            let steps = MediaAssetIdentityTable.Steps(
                lockAcquisitions: after.lockAcquisitions - before.lockAcquisitions,
                decodes: after.decodes - before.decodes
            )
            return (sorted.map { table.relativePath(at: $0).rawValue }, steps, comparisons)
        }
        for (name, precedes) in [
            ("path", { table.relativePathPrecedes($0, $1) }),
            ("rootAndPath", { table.pathOrder($0, $1, rootFirst: true) < 0 }),
            ("pathAndRoot", { table.pathOrder($0, $1, rootFirst: false) < 0 }),
        ] as [(String, (UInt32, UInt32) -> Bool)] {
            let sorted = cost(precedes)
            #expect(sorted.steps.decodes == 0 && sorted.steps.lockAcquisitions <= sorted.comparisons, "\(name): \(sorted.steps) over \(sorted.comparisons) comparisons")
            #expect(sorted.order == decoded, "\(name)")
        }
        // What the decoded comparison costs, for the record: a string each side of every one.
        let decoding = cost { table.relativePath(at: $0).rawValue < table.relativePath(at: $1).rawValue }
        #expect(decoding.steps.decodes >= paths.count)

        // The process's IDs, and the faces' policy, order the same way.
        let ids = paths.map { MediaAssetID(libraryRootPath: root, relativePath: $0) }
        #expect(ids.sorted { $0.relativePathPrecedes($1) }.map(\.relativePath.rawValue) == decoded)
        #expect(ids.sorted { $0.pathPrecedes($1) }.map(\.relativePath.rawValue) == decoded)
        let faces = ids.enumerated().map { FaceID(asset: $1, index: $0 % 3) }
        #expect(faces.sorted(by: FaceAssignmentPolicy.pathOrder).map(\.asset.relativePath.rawValue) == decoded)
    }

    // Validates: ARC-070
    /// A pass that tells libraries apart over a whole grouping — Duplicates' same-photo buckets
    /// — reads every ID's root number under one lock acquisition and decodes nothing, however
    /// many IDs it reads; the numbers are equal exactly where the roots are.
    @Test func aPassReadsEveryRootNumberUnderOneLock() {
        let table = MediaAssetIdentityTable(countingSteps: true)
        let roots = ["/Roots/A", "/Roots/B", "/Roots/C"].map(LibraryRootPath.init(rawValue:))
        let pairs = (0 ..< 5000).map { (root: roots[$0 % roots.count], path: MediaRelativePath(rawValue: "IMG_\($0).HEIC")) }
        let places = pairs.map { table.place(of: $0.root, $0.path) }
        let before = table.steps
        let numbers = table.rootNumbers(of: places)
        let after = table.steps
        #expect(after.lockAcquisitions - before.lockAcquisitions == 1 && after.decodes == before.decodes, "\(before) → \(after)")
        let disagreeing = pairs.indices.filter { index in
            roots.indices.contains { other in
                (numbers[index] == numbers[other]) != (pairs[index].root == pairs[other].root)
            }
        }
        #expect(numbers.count == pairs.count && disagreeing.isEmpty, "\(disagreeing.prefix(5))")
        #expect(Set(numbers).count == roots.count)
    }

    // Validates: ARC-070
    /// The pause a maker of an ID can wait behind, counted as the slots one rebuild of the
    /// index moves under the lock: without sizing, crossing half the index rebuilds every
    /// place already made; sized at open from the catalog's rows, making that many IDs never
    /// rebuilds it.
    @Test func anIndexSizedAtOpenIsNeverRebuiltWhileIDsAreMade() {
        // 20,000 places cross four doublings unsized, the last moving 32,768 slots, and none
        // sized for them: the property the reference library's 165,000 shows, at an eighth of the inserts.
        let entries = 20000
        let root = LibraryRootPath(rawValue: "/Sized")
        let paths = (0 ..< entries).map { MediaRelativePath(rawValue: "2026/\($0 % 365)/IMG_\($0).HEIC") }

        let unsized = MediaAssetIdentityTable()
        for path in paths {
            _ = unsized.place(of: root, path)
        }
        let sized = MediaAssetIdentityTable()
        sized.reserve(entries + entries / 4)
        let atOpen = sized.usage.largestRebuild
        for path in paths {
            _ = sized.place(of: root, path)
        }
        #expect(unsized.usage.largestRebuild >= entries, "unsized: \(unsized.usage.largestRebuild) slots moved at once")
        #expect(sized.usage.largestRebuild == atOpen, "sized: \(sized.usage.largestRebuild) slots moved at once")
        #expect(atOpen <= 4096, "the rebuild at open moves the few places made before it")
        #expect(sized.count == entries && unsized.count == entries)
    }

    // Validates: ARC-070
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

    // Validates: ARC-070
    /// The grid's bind of one screenful (120 tiles), as `MediaGridBridge` binds a tile — pin it,
    /// hold its stub, read its content — and then the catalog's details merged: what the
    /// table pays per tile, bounded so it cannot grow unseen.
    @MainActor
    @Test func bindingAScreenfulOfTilesCostsTheTableAFewStepsATile() {
        let root = LibraryRootPath(rawValue: "/Screenful")
        let table = MediaAssetIdentityTable(countingSteps: true)
        let paths = (0 ..< 120).map { MediaRelativePath(rawValue: "IMG_\($0).HEIC") }
        let ids = paths.map { table.id(root, $0) }
        let store = TileContentStore(identities: table)
        let start = table.steps
        for id in ids {
            store.pin(id)
            store.holdUnreadDetail(for: id)
            _ = store.content(for: id)
        }
        let bound = table.steps
        let bind = MediaAssetIdentityTable.Steps(
            lockAcquisitions: bound.lockAcquisitions - start.lockAcquisitions, decodes: bound.decodes - start.decodes
        )
        let details = Dictionary(uniqueKeysWithValues: zip(ids, paths).map { id, path in
            (id, MediaTileDetail(libraryRootPath: root, relativePath: path, thumbnailPath: "t.jpg"))
        })
        _ = store.mergeDetails(details)
        let merged = table.steps
        let merge = MediaAssetIdentityTable.Steps(
            lockAcquisitions: merged.lockAcquisitions - bound.lockAcquisitions, decodes: merged.decodes - bound.decodes
        )
        // Measured: binding a tile reads its two paths for the stub it holds (one string) and
        // finds the stub's ID again; merging its detail finds the detail's ID three times
        // (`MediaTileDetail.id` is derived from its paths). A few hundred nanoseconds a tile.
        #expect(bind.decodes <= ids.count && bind.lockAcquisitions <= 3 * ids.count, "\(bind)")
        #expect(merge.decodes == 0 && merge.lockAcquisitions <= 3 * ids.count, "\(merge)")
    }
}
