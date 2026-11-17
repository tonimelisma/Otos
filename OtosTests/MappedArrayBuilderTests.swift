import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// The builder an owner-scale read collects into (`MappedArrayBuilder`): the same elements in
/// the same order as appending to an array, in an array of exactly their count, and nothing
/// left alive by a build that is dropped unfinished.
struct MappedArrayBuilderTests {
    /// How many tracked elements are alive.
    private final class Alive: Sendable {
        private let count = Mutex(0)

        func change(by delta: Int) {
            count.withLock { $0 += delta }
        }

        var value: Int {
            count.withLock { $0 }
        }
    }

    private final class Tracked: Sendable {
        let value: Int
        let alive: Alive

        init(_ value: Int, alive: Alive) {
            self.value = value
            self.alive = alive
            alive.change(by: 1)
        }

        deinit {
            alive.change(by: -1)
        }
    }

    @Test func aBuildGivesTheAppendedElementsInOrderAtTheirLength() {
        for count in [0, 1, 511, 512, 513, 100_000] {
            var builder = MappedArrayBuilder<String>()
            for index in 0 ..< count {
                builder.append("path/\(index).jpg")
            }
            #expect(builder.count == count)
            let built = builder.finish()
            #expect(built == (0 ..< count).map { "path/\($0).jpg" })
        }
    }

    @Test func aCollectLeavesOutWhatItsTransformRejects() {
        let kept = MappedArrayBuilder.collect(0 ..< 10000) { $0.isMultiple(of: 3) ? $0 * 2 : nil }
        #expect(kept == (0 ..< 10000).filter { $0.isMultiple(of: 3) }.map { $0 * 2 })
    }

    @Test func aBuildDroppedUnfinishedReleasesItsElements() {
        let alive = Alive()
        do {
            var builder = MappedArrayBuilder<Tracked>()
            for index in 0 ..< 5000 {
                builder.append(Tracked(index, alive: alive))
            }
            #expect(alive.value == 5000)
            builder.withElements { elements in
                #expect(elements.map(\.value) == Array(0 ..< 5000))
            }
        }
        #expect(alive.value == 0)
    }

    @Test func aFinishedBuildHandsItsElementsOverOnce() {
        let alive = Alive()
        do {
            var builder = MappedArrayBuilder<Tracked>()
            for index in 0 ..< 3000 {
                builder.append(Tracked(index, alive: alive))
            }
            let built = builder.finish()
            #expect(alive.value == 3000)
            #expect(built.map(\.value) == Array(0 ..< 3000))
        }
        #expect(alive.value == 0)
    }

    @Test func anExactGroupingGroupsAsGroupingDoes() {
        let paths = (0 ..< 5000).map { "root\($0 % 7)/\($0)" }
        let exact = Dictionary(exactlyGrouping: paths) { $0.prefix(5) }
        #expect(exact == Dictionary(grouping: paths) { $0.prefix(5) })
    }
}
