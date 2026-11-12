import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// A thread that spins in a function of its own until released, so a sampler finds it
/// there. It reports its own stack bounds once running.
private final class SpinningThread: Sendable {
    private let released = Atomic<Bool>(false)
    private let target = Mutex<ThreadStackSampler.Target?>(nil)

    func start() {
        Thread { [self] in
            target.withLock { $0 = .current() }
            spinUntilReleased()
        }.start()
    }

    /// The running thread, once it is running.
    func runningTarget() async throws -> ThreadStackSampler.Target {
        try await waitForValue { self.target.withLock { $0 } }
    }

    func release() {
        released.store(true, ordering: .relaxed)
    }

    @inline(never)
    private func spinUntilReleased() {
        var turns = 0
        while !released.load(ordering: .relaxed) {
            turns &+= 1
        }
        _ = turns
    }
}

struct StallStackTests {
    @Test func aSampleOfABusyThreadNamesTheFunctionItIsIn() async throws {
        let thread = SpinningThread()
        thread.start()
        defer { thread.release() }
        let target = try await thread.runningTarget()

        let sample = try #require(ThreadStackSampler.sample(target))

        #expect(sample.frames.contains { $0.symbol?.contains("spinUntilReleased") == true })
        #expect(sample.frames.count <= ThreadStackSampler.maximumFrames)
    }

    @Test func theWatcherSamplesAThreadThatStopsBeating() async throws {
        let thread = SpinningThread()
        thread.start()
        defer { thread.release() }
        let watcher = try await StalledThreadWatcher(watching: thread.runningTarget())
        watcher.start()
        defer { watcher.stop() }

        let samples = try await waitForValue { () -> [StackSample]? in
            let taken = watcher.takeSamples()
            return taken.isEmpty ? nil : taken
        }

        #expect(samples.allSatisfy { sample in
            sample.frames.contains { $0.symbol?.contains("spinUntilReleased") == true }
        })
    }

    @Test func theReportCountsEachFrameAcrossSamplesAndKeepsRepeatedStacksWhole() {
        func frame(_ symbol: String, _ offset: UInt) -> StackSample.Frame {
            StackSample.Frame(image: "Otos", offset: offset, symbol: symbol)
        }
        let root = frame("main", 0x1)
        let caller = frame("loadCatalog", 0x2)
        let deep = StackSample(frames: (0 ..< 60).map { index in
            frame("$s4Otos" + String(repeating: "Q", count: 120) + "\(index)", UInt(0x1000 + index))
        } + [caller, root])
        let leafA = StackSample(frames: [frame("readRow", 0x3), caller, root])
        let leafB = StackSample(frames: [frame("decodeRow", 0x4), caller, root])

        let lines = StallStackReport.lines(stallID: 7, samples: [leafA, deep, leafB, deep, deep])

        #expect(Set(lines.map { $0.fields["kind"] }) == ["heaviest", "leaf", "stack"])
        let leaves = lines.filter { $0.fields["kind"] == "leaf" }.map { $0.fields["frames"]! }.joined(separator: "|")
        #expect(leaves.split(separator: "|").first.map(String.init) == "3*Otos+0x1000:$s4Otos" + String(repeating: "Q", count: 120) + "0")
        let heaviest = lines.filter { $0.fields["kind"] == "heaviest" }
        let counted = heaviest.map { $0.fields["frames"]! }.joined(separator: "|").split(separator: "|").map(String.init)
        #expect(counted.prefix(2) == ["5*Otos+0x1:main", "5*Otos+0x2:loadCatalog"])
        #expect(counted.count == StallStackReport.maximumHeaviestFrames)
        #expect(counted.dropFirst(2).allSatisfy { $0.hasPrefix("3*") })
        let stacks = lines.filter { $0.fields["kind"] == "stack" }
        #expect(Set(stacks.map { $0.fields["stack"] }) == ["1"])
        #expect(stacks.allSatisfy { $0.fields["samples"] == "3" && $0.fields["ofSamples"] == "5" })
        #expect(stacks.map { $0.fields["part"] } == (1 ... stacks.count).map { "\($0)" })
        #expect(stacks.allSatisfy { $0.fields["parts"] == "\(stacks.count)" })
        let joined = stacks.map { $0.fields["frames"]! }.joined(separator: "|")
        #expect(joined == deep.frames.map(StallStackReport.text(of:)).joined(separator: "|"))
        #expect(lines.allSatisfy { "op=mainThreadStall.stack \(otosLogFields($0.fields))".count < 1017 })
    }

    @Test func theOwnViewCountsOnlyOtossImage() {
        let own = StackSample.Frame(image: StallStackReport.ownImage, offset: 0x10, symbol: "load")
        let framework = StackSample.Frame(image: "SwiftUICore", offset: 0x20, symbol: "update")
        let samples = [StackSample(frames: [framework, own]), StackSample(frames: [framework])]

        let lines = StallStackReport.lines(stallID: 1, samples: samples).filter { $0.fields["kind"] == "own" }

        #expect(lines.map { $0.fields["frames"] } == ["1*\(StallStackReport.ownImage)+0x10:load"])
        #expect(StallStackReport.ownImage != "?")
    }
}
