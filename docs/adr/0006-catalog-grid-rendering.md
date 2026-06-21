# ADR 0006: Catalog Grid Rendering

## Status

Accepted.

## Decision Scope

This ADR owns the media browser rendering technology, layout, reusable item
boundary, and structural/detail collection update mechanics.

It references but does not own catalog truth, snapshot cadence, availability,
and ordering. ADR 0007 owns structural revision and cached ordering. ADRs 0002,
0004, and 0005 retain scan/persistence, UI ownership, and publication ownership.
Thumbnail rendering, media eligibility, selection, preview, and zoom require
separate future specs/ADRs if implemented.

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
unchanged IDs, replace the value map and reload visible items. Permit one
structural apply at a time and retain only the latest pending grid state. Reset
scroll only when sidebar scope changes.

## Why This Is Simplest Correct

The verified table failure justifies leaving SwiftUI for this one rendering
surface. Collection view supplies the required bounded reuse and identity
lifecycle without a custom renderer. Compositional layout directly expresses six
responsive columns and removes flow-layout width bookkeeping.

## Consequences

- Media rendering has one narrow MainActor AppKit boundary.
- SwiftUI remains responsible for window composition and empty-state shell.
- Collection updates are imperative but isolated and state-machine tested.
- The current grid intentionally has no interaction behavior.
- Settings may continue using SwiftUI `Table`; this decision concerns only the
  high-cardinality media browser.

## References

- Apple, [NSCollectionView](https://developer.apple.com/documentation/appkit/nscollectionview)
- Apple, [NSCollectionView layout ownership](https://developer.apple.com/documentation/appkit/nscollectionview/collectionviewlayout)
- Apple, [UTType.movie](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/movie)
