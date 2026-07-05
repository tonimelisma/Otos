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
Thumbnail storage is owned by ADR 0009; this ADR owns how the visible grid
renders and refreshes those thumbnail-backed values, including the invariant that
a painted same-asset thumbnail never blanks while the asset remains on screen.
Scan-time media eligibility (UTType image or movie) is owned by ADR 0002; the grid
displays every cataloged eligible asset.

## Context

The previous large media table can enter a permanent AppKit/SwiftUI table stall
with continuous heap growth after repeated scope changes. Spec 0010 records the
sample and heap evidence. Otos needs a thumbnail-backed browser that can scale to
large libraries without putting one SwiftUI hosting tree behind every tile.

Spec 0038 adds a stricter rendering fact: a tile whose thumbnail has already
painted must never render placeholder content for that same on-screen asset.
Baseline diagnostics showed large reorder-only snapshots being applied with
`animatingDifferences: false`; the macOS 27 AppKit SDK header documents that this
path applies by calling `reloadData` (`NSDiffableDataSource.h:105`), and AppKit
does not provide `applySnapshotUsingReloadData`. ReloadData tears down visible
items, so no-blank correctness cannot rely on AppKit preserving cell instances.
The invariant is enforced by synchronous paint from a decoded memory cache plus
same-identity downgrade guards inside the tile; diffable apply semantics only
affect how much work AppKit does. Spec 0039 applied the documented fallback after
post-0038 live diagnostics found zero-duration true diffing taking 5.1 s and
25.2 s for large/reorder applies.

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
Auto Layout trees. Each square collection cell is transparent; the visible tile
face is the loaded thumbnail's native aspect-fit rect, or a full-square neutral
placeholder before the thumbnail is known. Filename and optional relative capture
date are drawn on a top-left scrim inside that face. Only content conforming to
`UTType.movie` gets a bottom-right badge inside the face: duration text when
available, otherwise a film symbol. Images have no video badge, blue tint, or
video-only backing color.

Apply a diffable snapshot when ordered IDs change. Small and user-visible
insert/remove changes may animate so surviving items move with rendered thumbnails
intact. Large applies and background reorder-only changes use AppKit's
reloadData-class diffable path (`animatingDifferences: false`) after measured
true-diff apply cost at real-library scale. This is visually safe because the
tile can synchronously repaint any decoded thumbnail and never downgrades a
painted same-asset image to placeholder content. The fallback is an apply-policy
choice only; it does not make the catalog, detail cache, or decoded image cache a
source of media truth.

For unchanged IDs, re-read visible details through the Store-backed detail reader
and reconfigure the existing visible items in place. Do not call AppKit item reload
for a detail-only refresh: reload enters the reuse lifecycle, and reusable tile
cleanup clears the thumbnail before the async loader repaints it. Permit one
structural apply at a time and retain only the latest pending grid state. Reset
scroll and selection only when the query descriptor changes; same-descriptor
structural applies restore surviving selected identities. The selection ring is
drawn on the visible tile face, so it follows the thumbnail aspect instead of the
whole square cell.

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
  visible cells; if AppKit does recycle a visible cell for structural reasons, the
  tile synchronously repaints from the decoded cache when available. Date and
  duration overlay updates do not participate in image identity.
- Missing detail rows, detail-query failures, and nil thumbnail decode results
  are information loss, not proof that a painted same-asset thumbnail should be
  cleared.
- Native AppKit selection and responder-chain copy behavior live at this boundary
  so SwiftUI and the ViewModel do not mirror high-cardinality selection state.
- Settings may continue using SwiftUI `Table`; this decision concerns only the
  high-cardinality media browser.

## References

- Apple, [NSCollectionView](https://developer.apple.com/documentation/appkit/nscollectionview)
- Apple, [NSCollectionView layout ownership](https://developer.apple.com/documentation/appkit/nscollectionview/collectionviewlayout)
- Apple, [UTType.movie](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/movie)
- `docs/specs/0024-grid-flicker-and-thumbnail-jpeg.md`
- `docs/specs/0037-thumbnail-tile-redesign.md`
- `docs/specs/0035-catalog-browser-remediation-completion.md`
- `docs/specs/0038-no-blank-grid-invariant.md`
- `docs/specs/0039-grid-preheat-and-apply-follow-up.md`
