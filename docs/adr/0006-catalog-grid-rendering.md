# ADR 0006: Catalog Grid Rendering

## Status

Accepted.

## Decision Scope

This ADR owns the media browser rendering technology, layout, reusable item
boundary, and structural/detail collection update mechanics.

It references but does not own catalog truth, publication cadence, availability,
and ordering. ADR 0010 owns Store-executed ordering, identity-plus-generation grid
publication, and visible detail reads. ADRs 0002, 0004, and 0005 retain
scan/persistence, UI ownership, and publication ownership.
Selection, preview, and zoom require separate future specs/ADRs if implemented.
Thumbnail storage is owned by ADR 0009; this ADR owns only how the visible grid
renders and refreshes those thumbnail-backed values. Scan-time media eligibility
(UTType image or movie) is owned by ADR 0002; the grid displays every cataloged
eligible asset.

## Context

The previous large media table can enter a permanent AppKit/SwiftUI table stall
with continuous heap growth after repeated scope changes. Spec 0010 records the
sample and heap evidence. Otos needs a placeholder browser now, before thumbnail
or interaction design exists.

## Alternatives

1. SwiftUI `LazyVGrid`: smallest source surface, but preserves large SwiftUI view
   graph risk and offers weak explicit backpressure.
2. `NSCollectionViewFlowLayout`: reusable cells, but requires manual six-column
   sizing and resize invalidation.
3. `NSCollectionViewCompositionalLayout`: reusable cells plus native six-item
   fractional groups and diffable identity.
4. Custom AppKit tiler: maximum control, but needlessly rebuilds scrolling,
   reuse, layout, and accessibility.

## Decision

Use a narrow `NSViewControllerRepresentable` containing `NSCollectionView`,
`NSCollectionViewCompositionalLayout`, and `NSCollectionViewDiffableDataSource`.
The layout has one full-width group with exactly six square fractional items,
12-point section insets, and 8-point effective gaps.

Tiles are layer-backed frame-layout AppKit views, not SwiftUI hosting views or
Auto Layout trees. They display a one-line filename. Only content conforming to
`UTType.movie` gets a small video symbol and blue tint.

Apply a diffable snapshot without animation only when ordered IDs change. For
unchanged IDs, re-read visible details through the Store-backed detail reader and
reconfigure the existing visible items in place. Do not call AppKit item reload for
a detail-only refresh: reload enters the reuse lifecycle, and reusable tile cleanup
clears the thumbnail before the async loader repaints it. Permit one structural
apply at a time and retain only the latest pending grid state. Reset scroll only
when sidebar scope changes.

## Why This Is Simplest Correct

The verified table failure justifies leaving SwiftUI for this one rendering
surface. Collection view supplies the required bounded reuse and identity
lifecycle without a custom renderer. Compositional layout directly expresses six
responsive columns and removes flow-layout width bookkeeping.

## Consequences

- Media rendering has one narrow MainActor AppKit boundary.
- SwiftUI remains responsible for window composition and empty-state shell.
- Collection updates are imperative but isolated and state-machine tested.
- Same-identity background enrichment or fact-detail updates do not recycle
  visible cells, so thumbnails remain painted while unchanged content is skipped
  by the tile content key.
- The current grid intentionally has no interaction behavior.
- Settings may continue using SwiftUI `Table`; this decision concerns only the
  high-cardinality media browser.

## References

- Apple, [NSCollectionView](https://developer.apple.com/documentation/appkit/nscollectionview)
- Apple, [NSCollectionView layout ownership](https://developer.apple.com/documentation/appkit/nscollectionview/collectionviewlayout)
- Apple, [UTType.movie](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/movie)
- `docs/specs/0024-grid-flicker-and-thumbnail-jpeg.md`
