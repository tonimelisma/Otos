# Media Grid Best Practices Research

Status: non-authoritative research note.

Date: 2026-06-30

This document records platform and architecture guidance for Otos media-grid
design. It is design input, not proof that current behavior exists and not a
commitment to implement a specific option.

## Summary

A large media grid should be built around stable structural identity and bounded
visible-detail work:

- Collection structure should be driven by stable, lightweight item identifiers,
  not full mutable media model values.
- Structural changes and detail changes should have different update paths.
- Async detail or thumbnail arrival should reconfigure existing visible cells
  when possible, not reload or recycle cells unnecessarily.
- Image-heavy grids should prepare and downsample thumbnails off the main thread.
- Visible and near-visible assets should be prefetched; offscreen background work
  should not disturb the current viewport.
- SwiftUI dependencies should be narrow. Broad observed models, broad value
  equality, and large shared collections can create unnecessary update fan-out.
- The main thread should stay well below the responsiveness hang threshold; any
  repeated work near or above 100 ms needs measurement and redesign.
- Instrumentation should prove the path from source change to visible cell update:
  what changed, whether structure changed, whether the affected item was visible,
  whether a thumbnail/detail load was cancelled or applied, and how long each
  stage took.

## View Or Cell Detail Loading

Research does not say reusable views must never initiate detail loads. In large
collection views, it is normal for visible cells or their owning collection-view
controller to trigger asynchronous image/detail requests as cells enter the
viewport, and to cancel or ignore those requests when cells are reused.

The important boundary is not "no view ever asks for data." The important boundary
is that visible rendering must not become an unbounded, broad, or ambiguous data
flow.

Acceptable:

- a reusable cell or grid controller requests detail for the asset identity it is
  currently displaying
- requests are keyed by stable domain identity
- requests are bounded to visible and prefetch windows
- stale responses are rejected by cell generation, structural generation, or both
- reuse cancels obsolete work
- image decode/downsample happens off the main thread
- a narrow provider hides Store, SQLite, filesystem, and thumbnail-storage details
  from rendering code
- instrumentation can link request, cancellation, result, and visible apply

Risky:

- many cells directly observe a broad catalog object or full asset dictionary
- cells query persistence directly
- cells start unbounded concurrent work without a cancellation owner
- a cell can apply a result after it has been reused for another asset
- thumbnail/detail completion triggers a whole-window state publication
- offscreen detail completion causes visible cell reconfiguration
- detail loading depends on SwiftUI body recomputation or broad environment reads

For Otos, the strongest blank-slate formulation is:

```text
Projection publishes ordered asset identities.
The grid owns visible/prefetch range observation.
The grid or cell requests detail by asset identity through a narrow provider.
The provider owns the Store-facing read boundary.
The cell applies only the latest result for its current identity.
```

This permits view-adjacent pull-based detail loading without turning SwiftUI or
AppKit views into catalog owners.

## Structural Identity

Diffable collection data should be based on stable identifiers. For Otos, the
stable identifier is `MediaAssetID`, derived from library root path plus relative
path. Full mutable asset values should not be the diffable identity.

Implications:

- collection snapshots should carry ordered IDs
- detail values should not be part of collection identity
- a metadata or thumbnail update should not imply a structural reload
- a true insert, delete, scope change, or reorder should publish a new ordered ID
  list

## Detail And Thumbnail Updates

Detail updates should be scoped to the item whose displayed content changed.

Preferred behavior:

- if the item is visible, reconfigure that existing item or apply the result to
  the still-current cell
- if the item is offscreen, store the new catalog truth and do no visible work
- if the item scrolls into view later, load the latest detail by ID

Avoid:

- replacing the full grid state for one thumbnail
- making full-map equality decide whether a visible tile needs work
- reload/reuse for detail-only updates
- main-thread thumbnail file reads, image decode, resize, or date formatting

## Prefetching

Prefetching is part of the core design for a large media grid, not polish.

The grid should maintain:

- visible IDs
- a near-visible prefetch window
- in-flight keyed detail loads
- in-flight keyed thumbnail loads
- cancellation or stale-result rejection for obsolete requests

The implementation can begin with a simple static prefetch window and add scroll
velocity or adaptive windows only after measurement.

## SwiftUI And AppKit Boundary

SwiftUI should own composition and high-level state assignment. AppKit should own
the high-cardinality collection viewport, cell reuse, and imperative item
reconfiguration.

The boundary should stay narrow:

- SwiftUI passes ordered identity state and small service/provider capabilities
  into the AppKit bridge
- the AppKit bridge owns visible range, prefetch range, reuse, and backpressure
- Store, Projection, SQLite, and filesystem details remain behind explicit owners
- no SwiftUI body should sort, filter, decode, query persistence, or start
  unbounded media work

## Responsiveness And Measurement

Design claims must be checked with runtime evidence.

The minimum useful evidence for media-grid responsiveness is:

- projection/publication spans
- structural snapshot apply spans
- visible reconfigure spans
- detail request latency
- thumbnail load/decode/apply latency
- cancellation/drop counts
- visible affected counts for changed IDs
- main-run-loop stall correlation
- production-size library runs

The app should not treat repeated 100 ms main-thread stalls as normal background
activity. If the grid is scrolling or the app is active, repeated stalls above
that threshold are product bugs until proven unavoidable and accepted.

## Sources

- [Apple: Updating collection views using diffable data sources](https://developer.apple.com/documentation/uikit/updating-collection-views-using-diffable-data-sources)
- [Apple: `NSDiffableDataSourceSnapshot.reconfigureItems(_:)`](https://developer.apple.com/documentation/uikit/nsdiffabledatasourcesnapshot-swift.struct/reconfigureitems%28_%3A%29)
- [Apple WWDC 2021: Make blazing fast lists and collection views](https://developer.apple.com/videos/play/wwdc2021/10252/)
- [Apple WWDC 2023: Demystify SwiftUI performance](https://developer.apple.com/videos/play/wwdc2023/10160/)
- [Apple WWDC 2023: Analyze hangs with Instruments](https://developer.apple.com/videos/play/wwdc2023/10248/)
- [Apple: `PHCachingImageManager`](https://developer.apple.com/documentation/photos/phcachingimagemanager)
- [Apple: `PHCachingImageManager.startCachingImages(for:targetSize:contentMode:options:)`](https://developer.apple.com/documentation/photos/phcachingimagemanager/startcachingimages%28for%3Atargetsize%3Acontentmode%3Aoptions%3A%29)
- [Otos process: performance evidence](../process/performance.md)
- [Otos process: Apple documentation grounding](../process/apple-docs.md)
