#!/usr/bin/env swift
// Offscreen(ish) benchmark: NSCollectionViewDiffableDataSource apply cost on macOS.
// Mimics Otos media grid: compositional layout (6 columns, square cells),
// two-string Hashable identifiers, n=23k items, K items moved per apply.
import AppKit

struct BenchID: Hashable {
    let root: String
    let rel: String
}

final class BenchItem: NSCollectionViewItem {
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }
}

@MainActor
func makeLayout(columnCount: Int) -> NSCollectionViewLayout {
    let itemSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1),
        heightDimension: .fractionalHeight(1)
    )
    let item = NSCollectionLayoutItem(layoutSize: itemSize)
    item.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
    let groupSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1),
        heightDimension: .fractionalWidth(1.0 / CGFloat(columnCount))
    )
    let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitem: item, count: columnCount)
    let section = NSCollectionLayoutSection(group: group)
    section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
    return NSCollectionViewCompositionalLayout(section: section)
}

@MainActor
func spin(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

@MainActor
func freshString(_ s: String) -> String {
    // Force a unique backing store per instance, like per-row DB decodes.
    String(decoding: Array(s.utf8), as: UTF8.self)
}

@MainActor
func makeIDs(_ n: Int) -> [BenchID] {
    let rootBase = "/Users/example/Library/CloudStorage/OneDrive-Personal/Pictures"
    return (0 ..< n).map { i in
        BenchID(
            root: freshString(rootBase),
            rel: freshString(String(format: "%04d/%02d/IMG_%06d.HEIC", 2000 + i % 25, 1 + i % 12, i))
        )
    }
}

@MainActor
func movedOrder(_ order: [BenchID], k: Int, seed: inout UInt64) -> [BenchID] {
    func rand(_ bound: Int) -> Int {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(seed >> 33) % bound
    }
    var next = order
    for _ in 0 ..< k {
        let from = rand(next.count)
        let id = next.remove(at: from)
        let to = rand(next.count)
        next.insert(id, at: to)
    }
    return next
}

@MainActor
func run() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let n = Int(ProcessInfo.processInfo.environment["BENCH_N"] ?? "") ?? 23043
    let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 1200, height: 800),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.title = "diffable-bench"

    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
    let collectionView = NSCollectionView()
    collectionView.collectionViewLayout = makeLayout(columnCount: 6)
    collectionView.register(
        BenchItem.self,
        forItemWithIdentifier: NSUserInterfaceItemIdentifier("BenchItem")
    )
    scrollView.documentView = collectionView
    window.contentView = scrollView

    enum Section { case media }
    let dataSource = NSCollectionViewDiffableDataSource<Int, BenchID>(collectionView: collectionView) {
        collectionView, indexPath, _ in
        collectionView.makeItem(
            withIdentifier: NSUserInterfaceItemIdentifier("BenchItem"),
            for: indexPath
        )
    }

    var order = makeIDs(n)
    var base = NSDiffableDataSourceSnapshot<Int, BenchID>()
    base.appendSections([0])
    base.appendItems(order, toSection: 0)
    let t0 = CFAbsoluteTimeGetCurrent()
    dataSource.apply(base, animatingDifferences: false)
    print(String(format: "initial apply(false) n=%d: %.1f ms", n, (CFAbsoluteTimeGetCurrent() - t0) * 1000))
    spin(0.5)

    window.orderFrontRegardless()
    window.makeKey()
    spin(0.5)
    print("visible items: \(collectionView.visibleItems().count)")

    var seed: UInt64 = 0x0705_2026
    let reps = Int(ProcessInfo.processInfo.environment["BENCH_REPS"] ?? "") ?? 3
    let spinAfter = TimeInterval(ProcessInfo.processInfo.environment["BENCH_SPIN"] ?? "") ?? 0.6

    func measure(k: Int, animating: Bool) {
        for rep in 1 ... reps {
            let next = k == -1 ? order.reversed().map(\.self) : movedOrder(order, k: k, seed: &seed)
            var snapshot = NSDiffableDataSourceSnapshot<Int, BenchID>()
            snapshot.appendSections([0])
            snapshot.appendItems(next, toSection: 0)
            var completionAt: CFAbsoluteTime = 0
            let start = CFAbsoluteTimeGetCurrent()
            dataSource.apply(snapshot, animatingDifferences: animating) {
                completionAt = CFAbsoluteTimeGetCurrent()
                print(String(
                    format: "  completion fired k=%d rep=%d after %.1f ms (main=%@)",
                    k, rep, (completionAt - start) * 1000,
                    Thread.isMainThread ? "yes" : "no"
                ))
            }
            let callReturn = CFAbsoluteTimeGetCurrent()
            order = next
            spin(spinAfter)
            let callMs = (callReturn - start) * 1000
            let completionMs = completionAt > 0 ? (completionAt - start) * 1000 : -1
            print(String(
                format: "n=%d k=%d animating=%@ rep=%d applyCallMs=%.1f toCompletionMs=%.1f",
                n, k, animating ? "true" : "false", rep, callMs, completionMs
            ))
            if callMs > 3000 {
                print("n=\(n) k=\(k) animating=\(animating): exceeds 3 s, aborting further reps at this k")
                break
            }
        }
    }

    let kListEnv = ProcessInfo.processInfo.environment["BENCH_KLIST"]
    if let kListEnv {
        // k = -1 means full order reversal.
        for k in kListEnv.split(separator: ",").compactMap({ Int($0) }) {
            measure(k: k, animating: true)
        }
    } else {
        // Identical-order apply first: pure diff overhead floor at this n.
        measure(k: 0, animating: true)
        for k in [1, 3, 10, 50, 200] {
            measure(k: k, animating: true)
        }
        // Baseline: today's reloadData-class path for a small reorder.
        for k in [3, 200] {
            measure(k: k, animating: false)
        }
    }

    print("done")
    exit(0)
}

DispatchQueue.main.async {
    run()
}

NSApplication.shared.run()
