# 2026-08-16 — Can the Otos test bundle run unhosted?

## Question

`OtosTests` is a hosted bundle: `TEST_HOST` launches `Otos.app`, so `@main struct
OtosApp` and a live `NSApplication` run loop exist in every test process. ADR 0020
explicitly defers this arrangement ("**Test-suite process isolation mechanics**
beyond data locations — the hosted-bundle arrangement itself is unchanged").

Two questions had to be answered before that deferral could be closed:

1. **Is hosting causing the test-suite slowness and the intermittent multi-minute
   stalls?**
2. **Can the suite run unhosted at all**, given that it drives `NSCollectionView`,
   `NSWindow`, AVKit, and SwiftUI?

## Method

Measurement from the repo's own `logs/test-*.log` archive (11 runs, 2026-08-14 to
2026-08-16), plus three probes. Probes 1 and 2 run under `xcrun swift <file>.swift`,
which produces a **non-bundled command-line process** — the same process shape a
non-hosted XCTest bundle runs in (`xctest`), and the opposite of a `TEST_HOST`-hosted
bundle running inside `Otos.app`. Probe 3 is a throwaway SwiftPM package, because
SwiftPM test bundles are always non-hosted.

## Finding 1 — the suite's cost is main-actor contention, not work

Summed per-test duration is roughly constant across every archived run
(620–860 s). What varies is achieved concurrency, and it varies enormously:

| run | elapsed | summed test duration | effective concurrency |
| --- | --- | --- | --- |
| 2026-08-14 21:23 | 18.2 s | 636 s | 35x |
| 2026-08-15 02:14 | 18.6 s | 730 s | 39x |
| 2026-08-17 00:14 | 29.4 s | 813 s | 28x |
| 2026-08-17 01:13 | **703.2 s** | 858 s | **1.2x** |
| 2026-08-17 00:25 | **1534.7 s** | 839 s | **0.5x** |

The suite never does more work in a slow run. It stops overlapping. Two of eleven
runs collapsed this way, which is where the reported "verify.sh takes 15 minutes"
comes from — steady-state `verify.sh` is ~96 s.

Isolation predicts per-test duration with no exceptions, measured over the 703 s run:

| suite kind | tests | summed duration | per test |
| --- | --- | --- | --- |
| `@MainActor` | 202 | 566 s | **2.80 s** |
| `nonisolated` | 450 | 267 s | **0.59 s** |

Every `nonisolated` suite averages 0.00 s. Every `@MainActor` suite averages
0.47–3.26 s. The controlled comparison exists inside the repo already:

- `nonisolated enum ImportBarPresentation` — 36 tests, **0.00 s** average
- `enum MediaAssetTilePresentation` — 27 tests, **3.05 s** average

Both are pure static formatting functions over value types. The second inherits
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; the first opts out.

Direct confirmation that the 3 s figures are queueing, not work: the ten
`CatalogWindowViewModelGridZoomTests` tests report **2.94 s each** inside the full
suite and **0.007–0.018 s each** when run alone via `-only-testing`.

## Finding 2 — every AppKit capability the suite needs works unhosted

Probe 1 exercised the API surface the tests touch, in a non-bundled process.
**14/14 passed.**

| capability | result |
| --- | --- |
| `NSApplication.shared` reachable | PASS (policy `.prohibited`, settable to `.accessory`) |
| `NSView` creation + `layoutSubtreeIfNeeded` | PASS |
| `NSColor` sRGB + semantic (`controlAccentColor`) | PASS |
| `NSPasteboard` round-trip | PASS |
| `NSCollectionView` + flow layout + `reloadData` | PASS |
| `NSWindow` creation | PASS |
| `NSWindow.makeKeyAndOrderFront` | PASS, but **`isKeyWindow == false`** |
| `makeFirstResponder` | PASS (returns `true`) |
| `AVPlayerView` / `AVPlayer` construction | PASS |
| SwiftUI `NSHostingView` render + `fittingSize` | PASS |
| SF Symbol lookup | PASS |

The single gap is `isKeyWindow`, which never becomes `true` in a non-bundled
process. **No Otos test asserts `isKeyWindow`.**

## Finding 3 — the three window-using tests do not need key status

`MediaGridStripInputTests`, `MediaGridSelectionControllerTests`, and
`MediaGridPaintInvariantTests` are the only files calling `makeKeyAndOrderFront`.
All three use the same shape: an **off-screen borderless window** at `(-4000,
-4000)` purely to host the view so AppKit completes layout, followed by
`layoutSubtreeIfNeeded()` and `RunLoop.current.run(until:)`. None asserts key
status.

Probe 2 reproduced that exact shape unhosted. **9/9 passed** after correcting an
ordering bug in the probe itself (the first run queried item 0 after scrolling to
item 60, so its two `nil` results were the probe's fault, not the environment's):

| assertion | result |
| --- | --- |
| view is hosted (`cv.window != nil`) | PASS (`isKeyWindow=false`) |
| `collectionViewContentSize` is real | PASS — `9116.0x120.0` |
| `layoutAttributesForItem(at: 25)` | PASS — `frame=1900.0,24.0 72.0x72.0` |
| `frameForItem(at: 25)` (the centering assert) | PASS — same geometry |
| `scrollToItems` moves `visibleRect` | PASS — `x: 0.0 -> 4436.0` |
| `item(at:)` realized at current position | PASS — `visibleItems=5` |
| `indexPathForItem(at:)` hit-testing | PASS — resolves to the right item |
| selection round-trip via `selectionIndexPaths` | PASS |
| `NSEvent.keyEvent` synthesis + `keyDown` dispatch | PASS |
| `bitmapImageRepForCachingDisplay` + `cacheDisplay` | PASS — `128x128` |

**Conclusion: no Otos test tier requires an app host.** The whole bundle can be
unhosted; there is no need to split off a hosted UI target.

## Finding 4 — Swift Testing, `@testable`, and per-target isolation all work unhosted

Probe 3 built a throwaway SwiftPM package (`swift-tools-version: 6.2`) with a
library target carrying `.defaultIsolation(MainActor.self)` — mirroring the app's
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — and a non-hosted test target using
Swift Testing, `@testable import`, and AppKit. All four tests passed.

Two things this proved beyond the pass/fail:

- **Per-declaration `nonisolated` overrides the target default.** An intermediate
  version of the probe failed to compile with *"call to main actor-isolated static
  method in a synchronous nonisolated context"*, which is the mechanism confirming
  the default is genuinely applied and individually overridable.
- **Unhosted `@MainActor` tests cost tens of milliseconds, not seconds.**

| test | isolation | duration |
| --- | --- | --- |
| `badgeFormatsOffMain()` | nonisolated | 0.001 s |
| `badgeFormats()` | `@MainActor` | 0.046 s |
| `collectionViewLaysOutUnhosted()` | `@MainActor` | 0.112 s |
| `windowHostsAView()` | `@MainActor` | 0.114 s |

## Finding 5 — constraints discovered that bound the implementation

These were found while checking feasibility and directly shape plan 0093.

1. **799 documentation references point at `Otos/…` source paths** (360 citations in
   `docs/requirements.md`, 439 across `docs/`), and **299 requirement citations name
   `OtosTests/<file>.swift#<test>`** across 72 test files.
   `script/requirements-authority-check.sh` resolves those paths on disk.
   → **No source or test file may move on disk.** Only Xcode target membership
   changes. Xcode does not require a directory layout that mirrors targets.

2. **The app target uses `SWIFT_OBJC_BRIDGING_HEADER = Otos/Support/OtosXXH3.h`**,
   covering vendored xxHash (`Otos/Support/OtosXXH3.c`,
   `Otos/Vendor/xxHash-0.8.3/xxhash.c`). Framework targets cannot use a bridging
   header. → The C code needs its own module before the framework can exist.

3. **Seven requirement rows are verified only by a guard script** — ARC-001,
   ARC-002, ARC-002A, ARC-011, ARC-014, ARC-015, MED-004 all cite
   `` `script/guard-*.sh#self-test` `` as their verifying test. Deleting a guard
   orphans its row.

4. **Test residue leaks and costs measurable time.** 1,343 leaked
   `net.melisma.OtosTests.*.plist` domains and ~8,700 stray temp dirs were present.
   `script/check-production-data-untouched.sh` iterates those plists per file
   (line 74), and `verify.sh` calls it twice:
   **10.36 s before purge, 0.05 s after** — a ~21 s round trip.

5. **`@AppStorage` bypasses the `PreferencesDomain` seam.**
   `Otos/Views/MediaGridView.swift:28` declares
   `@AppStorage("dismissedCameraConnectionBannerIdentities")`, and
   `defaultAppStorage` is injected nowhere in the repo, so it resolves to
   `UserDefaults.standard`. Five test files reference `MediaGridView`. This is a
   live hole in ADR 0020's stated invariant.

6. **`TemporaryDefaults` has no working automatic cleanup.** Its own documentation
   records that `deinit` "fired **zero** times" under Swift Testing, that
   `removePersistentDomain` leaves the `.plist` behind, and that a residual empty
   stub is formally "accepted" because cfprefsd re-flushes after the manual unlink.

## Steady-state `verify.sh` budget (measured 2026-08-16)

| stage | measured |
| --- | --- |
| `requirements-authority-check.sh` | 15.5 s |
| …its `self-test` (identical cost) | 15.5 s |
| `check-production-data-untouched.sh --before` | 10.4 s (0.05 s after purge) |
| …`--after` | 10.4 s (0.05 s after purge) |
| `build.sh` (warm) | 12.3 s |
| `test.sh` (rebuilds, then tests) | ~30 s healthy |
| 7 guards x2, lint, doc-citations, sendable | ~1.8 s |
| **total** | **~96 s healthy** |

`build-for-testing` alone measures 9.9 s warm, so `build.sh` ahead of `test.sh`
duplicates an `xcodebuild` invocation for no coverage.

## Conclusions

1. Hosting buys nothing the tests use, and the app's run loop is the measured
   main-thread competitor behind both the ~3 s plateau and the collapse to 1.2x
   concurrency.
2. The full suite can run unhosted; no hosted tier is needed.
3. The blocker is not capability but linkage: `@testable import Otos` resolves
   through `BUNDLE_LOADER`. An `OtosKit` framework replaces that, and the C
   bridging header must become a module first.
4. Whether unhosting eliminates the intermittent collapse is **not proven** — it
   removes the measured competitor, which is the leading hypothesis, and Stage 8
   of plan 0093 re-measures rather than assuming.

## Reproducing the probes

Probes were run inline rather than committed to `script/`, to keep this a
documentation-only increment. Each is self-contained; save and run with
`xcrun swift <file>.swift`.

### Probe 1 — AppKit capability in a non-bundled process

```swift
import AppKit
import AVKit
import SwiftUI

// Non-bundled process => Bundle.main.bundleIdentifier == nil, matching `xctest`.
print("bundled:", Bundle.main.bundleIdentifier != nil)
_ = NSApplication.shared
print("setActivationPolicy:", NSApplication.shared.setActivationPolicy(.accessory))

let v = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
v.addSubview(NSView(frame: NSRect(x: 10, y: 10, width: 50, height: 50)))
v.layoutSubtreeIfNeeded()
print("subviews:", v.subviews.count)

let pb = NSPasteboard(name: .init(rawValue: "otos.probe"))
pb.clearContents(); pb.setString("hello", forType: .string)
print("pasteboard:", pb.string(forType: .string) ?? "nil")

let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                 styleMask: [.titled], backing: .buffered, defer: false)
let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
w.contentView?.addSubview(field)
w.makeKeyAndOrderFront(nil)
print("isKeyWindow:", w.isKeyWindow, "makeFirstResponder:", w.makeFirstResponder(field))

print("AVPlayerView:", AVPlayerView(frame: .zero).controlsStyle.rawValue)
let host = NSHostingView(rootView: Text("hello"))
host.layoutSubtreeIfNeeded()
print("hosting fittingSize:", host.fittingSize)
print("symbol:", NSImage(systemSymbolName: "bolt", accessibilityDescription: nil) != nil)
```

### Probe 2 — the grid-layout pattern the three window tests use

```swift
import AppKit

final class Source: NSObject, NSCollectionViewDataSource {
    func collectionView(_: NSCollectionView, numberOfItemsInSection _: Int) -> Int { 120 }
    func collectionView(_ cv: NSCollectionView,
                        itemForRepresentedObjectAt path: IndexPath) -> NSCollectionViewItem {
        cv.makeItem(withIdentifier: .init("cell"), for: path)
    }
}

_ = NSApplication.shared
NSApplication.shared.setActivationPolicy(.accessory)

let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
let cv = NSCollectionView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
let layout = NSCollectionViewFlowLayout()
layout.itemSize = NSSize(width: 72, height: 72)
layout.scrollDirection = .horizontal
cv.collectionViewLayout = layout
cv.register(NSCollectionViewItem.self, forItemWithIdentifier: .init("cell"))
let source = Source()
cv.dataSource = source
scroll.documentView = cv

// Off-screen borderless window, exactly as the three test files do.
let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 120),
                      styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = scroll
window.makeKeyAndOrderFront(nil)
scroll.layoutSubtreeIfNeeded()
cv.layoutSubtreeIfNeeded()
cv.reloadData()
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

// Query realization and hit-testing BEFORE scrolling away.
print("item(at:0):", cv.item(at: IndexPath(item: 0, section: 0)) != nil,
      "visible:", cv.visibleItems().count)
let f1 = cv.frameForItem(at: 1)
print("hitTest:", cv.indexPathForItem(at: NSPoint(x: f1.midX, y: f1.midY))?.item as Any)
print("contentSize:", cv.collectionViewLayout?.collectionViewContentSize ?? .zero)
print("frameForItem(25):", cv.frameForItem(at: 25))

cv.scrollToItems(at: [IndexPath(item: 60, section: 0)], scrollPosition: .centeredHorizontally)
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
print("after scroll visibleRect.x:", cv.visibleRect.origin.x)
print("item(at:60):", cv.item(at: IndexPath(item: 60, section: 0)) != nil)
```

### Probe 3 — unhosted Swift Testing against a MainActor-default library

`Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "SpikeKit",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SpikeKit", swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "SpikeKitTests", dependencies: ["SpikeKit"]),
    ]
)
```

`Sources/SpikeKit/TilePresentation.swift`:

```swift
import AppKit

public enum TilePresentation {                       // inherits MainActor default
    public static func badgeText(seconds: Double?) -> String? { format(seconds) }
}

public nonisolated enum TilePresentationNonisolated { // opts out, like ImportBarPresentation
    public static func badgeText(seconds: Double?) -> String? { format(seconds) }
}

nonisolated func format(_ seconds: Double?) -> String? {
    guard let s = seconds, s.isFinite else { return nil }
    let total = Int(s)
    return total >= 3600
        ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        : String(format: "%d:%02d", total / 60, total % 60)
}
```

`Tests/SpikeKitTests/SpikeTests.swift`:

```swift
import AppKit
import Testing
@testable import SpikeKit

@MainActor
struct MainActorSuite {
    @Test func badgeFormats() { #expect(TilePresentation.badgeText(seconds: 187) == "3:07") }

    @Test func collectionViewLaysOutUnhosted() {
        let cv = NSCollectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 80, height: 80)
        cv.collectionViewLayout = layout
        cv.layoutSubtreeIfNeeded()
        #expect(cv.collectionViewLayout != nil)
    }

    @Test func windowHostsAView() {
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 120),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        w.contentView = v
        w.makeKeyAndOrderFront(nil)
        v.layoutSubtreeIfNeeded()
        #expect(v.window != nil)
    }
}

struct NonisolatedSuite {
    @Test func badgeFormatsOffMain() {
        #expect(TilePresentationNonisolated.badgeText(seconds: 42) == "0:42")
    }
}
```

Run with `swift test`.

## Sources

- Repo measurement: `logs/test-*.log` (11 archived runs, 2026-08-14 → 2026-08-16),
  read via `IDETestOperationsObserverDebug: <n> elapsed` and per-test
  `(<n> seconds)` lines.
- `xcodebuild -only-testing:` isolation runs, 2026-08-16.
- `Otos.xcodeproj/project.pbxproj` build settings, `docs/adr/0020-*.md`,
  `OtosTests/TemporaryDefaults.swift`, `Otos/OtosApp.swift`.
- Toolchain: Xcode 27 beta (`/Applications/Xcode-beta.app`), Swift 6,
  Swift Testing library version 2074, macOS deployment target 27.0.
