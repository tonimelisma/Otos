# Otos documentation

Documentation is organized around current truth, not increments; each kind of fact has one
home. When docs conflict with code, inspect the code before changing behavior, and fix the doc in
the same PR as the code. Git history owns old implementation history; future work lives in
GitHub issues.

## Current-state documents

| Document | Owns |
| --- | --- |
| [../CLAUDE.md](../CLAUDE.md) | How to work here: product invariants, engineering rules, commands, the increment lifecycle, Git/CI/PRs and the Definition of Done. `CLAUDE.md` is a link to it. |
| [requirements.md](requirements.md) | The registry of implemented behavior: `ARC-`, `APP-`, `ENR-` and `MED-` requirements as EARS sentences, each `[verified]` by tests tagged `Validates: <ID>` or `unverified: <why>`. |
| [architecture.md](architecture.md) | The one-page code map: one-directional dataflow, actor ownership, and where to make a change. |
| [design/design-system.md](design/design-system.md) | The design rules for user-facing surfaces (`DES-*`). |
| [lessons.md](lessons.md) | Rules learned the hard way, and open problems. |
| [scorecard-targets.json](scorecard-targets.json) | The felt performance targets, for a reference library of 160,000 items (ADR 0043). |

## Design specifications

Each starts with `GOVERNS:`, the code it specifies.

- [design/activity.md](design/activity.md) — Activity
- [design/duplicates.md](design/duplicates.md) — Duplicates
- [design/edit-panel.md](design/edit-panel.md) — Edit panel
- [design/hig-validation.md](design/hig-validation.md) — HIG and Accessibility Validation — `design-system.md` v0.1
- [design/import-bar.md](design/import-bar.md) — Import Screen — Spec
- [design/info-pane.md](design/info-pane.md) — Info pane
- [design/on-this-day.md](design/on-this-day.md) — On This Day — Spec
- [design/people.md](design/people.md) — People
- [design/places.md](design/places.md) — Places — Spec
- [design/search.md](design/search.md) — Search — Spec
- [design/trash-status-bar.md](design/trash-status-bar.md) — Trash status bar
- [design/mockups/](design/mockups/) — HTML visual references for the design system and the
  import bar. The markdown is authoritative; where a mockup disagrees, the markdown wins.

## Architecture decision records

One decision per ADR, superseded and never deleted. New ADRs follow
[adr/0000-template.md](adr/0000-template.md) (MADR with Confirmation, Retirement proof and
Reversal plan).

| ADR | Decision |
| --- | --- |
| [0001](adr/0001-repository-foundation.md) | Repository Foundation |
| [0002](adr/0002-catalog-persistence-and-filesystem-scan.md) | Catalog Persistence And Filesystem Reconciliation |
| [0003](adr/0003-library-root-selection-and-access.md) | Library Root Selection And Access |
| [0004](adr/0004-catalog-ui-ownership.md) | Catalog UI Ownership |
| [0005](adr/0005-catalog-publication-and-availability.md) | Catalog Publication, Selection Delivery, And Availability |
| [0006](adr/0006-catalog-grid-rendering.md) | Catalog Grid Rendering |
| [0007](adr/0007-catalog-order-reuse.md) | Catalog Ordering And Value Materialization |
| [0008](adr/0008-filesystem-source-of-truth-and-overlay-lifecycle.md) | Filesystem Source Of Truth And Overlay Lifecycle |
| [0009](adr/0009-enrichment-storage-and-staleness.md) | Enrichment Storage And Staleness |
| [0010](adr/0010-store-owned-query-catalog-and-identity-grid.md) | Store-Owned Query Catalog And Identity Grid |
| [0011](adr/0011-catalog-query-descriptor-best-values-and-cadence.md) | Catalog Query Descriptor, Best Values, And Cadence |
| [0012](adr/0012-media-asset-clipboard-representation.md) | Media Asset Clipboard Representation |
| [0013](adr/0013-removable-and-device-sources.md) | Removable And Device Sources |
| [0014](adr/0014-sidebar-selection-and-source-lifecycle.md) | Sidebar Selection And Source Lifecycle |
| [0015](adr/0015-observability.md) | Observability (Unified Logging + Instruments) |
| [0016](adr/0016-view-modes-and-preview-decode.md) | View Modes And Preview Decode |
| [0017](adr/0017-media-operation-ownership.md) | Media Operation Ownership |
| [0018](adr/0018-sha1-content-digest.md) | SHA-1 Content Digest Overlay |
| [0019](adr/0019-import-plan-namespace-and-build-ownership.md) | Import Plan Namespace Resolution And Build Ownership |
| [0020](adr/0020-production-data-locations-and-the-developer-smoke-seam.md) | — Production data locations are named at the entry point, and the smoke seam is read-only |
| [0021](adr/0021-concurrent-import-planning-and-destination-reservations.md) | Concurrent Import Planning And Destination Name Reservation |
| [0022](adr/0022-recoverable-media-deletion.md) | Recoverable Media Deletion Through System Trash |
| [0023](adr/0023-test-architecture.md) | — Test architecture: an OtosKit framework, an unhosted bundle, and an in-memory preference store |
| [0024](adr/0024-import-source-readiness-gate.md) | Import Source Readiness Gate And Single Presentation Writer |
| [0025](adr/0025-volume-aware-path-equality.md) | Volume-Aware Path Equality |
| [0026](adr/0026-settled-naming-and-card-erase.md) | Settled Naming And Explicit Card Erase |
| [0027](adr/0027-destination-free-space-is-measured-at-the-attempt.md) | Destination Free Space Is Measured Only At The Attempt |
| [0028](adr/0028-grid-drag-out-representation.md) | Grid Drag-Out Representation |
| [0030](adr/0030-local-installation.md) | — The installed app is a debuggable Debug build with its own identity |
| [0031](adr/0031-browser-place-restored-on-relaunch.md) | — The browser place is saved at quit and restored at launch |
| [0032](adr/0032-owner-state-requests-and-intent-ordering.md) | — Owner state changes synchronously, a request is a counter, and intents arrive in order |
| [0033](adr/0033-time-is-never-a-stand-in-for-a-fact.md) | Time is never a stand-in for a fact that can be known |
| [0034](adr/0034-move-witness.md) | A move outside Otos keeps its overlay when a byte-free witness proves it |
| [0035](adr/0035-rendered-stills-and-stored-previews.md) | Stills are rendered once and kept as a thumbnail and a preview |
| [0036](adr/0036-edit-recipes.md) | A photo's edit is a recipe in its catalog row |
| [0037](adr/0037-hand-off-of-edited-photos.md) | A hand-off is the photo as Otos shows it |
| [0038](adr/0038-export.md) | Export writes new files into a folder the person chooses |
| [0039](adr/0039-mediametadata-boundary.md) | MediaMetadata is Otos's own library, and owns everything about the bytes |
| [0040](adr/0040-places-scope-and-map-clustering.md) | Places is a scope whose presentation is a map |
| [0041](adr/0041-live-photos-as-one-item.md) | A Live Photo is one item |
| [0042](adr/0042-duplicates.md) | Duplicates are a projection over digests and authored overlay |
| [0043](adr/0043-benchmarks.md) | Performance is measured once a week, in one run with one verdict |
| [0044](adr/0044-verification-builds-share-compile-results.md) | Verification builds share compile results across worktrees, gates run in one pass, and a check can be scoped while iterating |
| [0045](adr/0045-auto-crop-and-auto-straighten-models.md) | Auto crop and Auto straighten use two converted models |
| [0046](adr/0046-immich-accounts-as-read-only-sources.md) | Immich accounts are read-only sources |
| [0047](adr/0047-face-recognition.md) | Face recognition with Vision detection and AdaFace IR-101 |
| [0048](adr/0048-keyword-search.md) | Keyword search with SigLIP 2 and on-device translation |
| [0049](adr/0049-on-this-day-and-its-story-player.md) | On This Day is a scope of anniversaries, played as a story |
| [0050](adr/0050-info-pane-shows-everything-otos-holds.md) | The Info pane shows everything Otos holds, and looks up one thing |
| [0051](adr/0051-place-names-and-the-places-filter.md) | Place names, named once per map cell, and the Places filter |
| [0052](adr/0052-stacks-pairs-and-bursts.md) | A RAW+JPEG pair and a burst are stacks, one photo until expanded |
| [0053](adr/0053-photo-descriptions-and-on-this-day-titles.md) | Photo descriptions and On This Day titles, written by Apple's on-device model |
| [0054](adr/0054-one-photo-many-copies.md) | Identical copies are one photo wherever the libraries and accounts are combined |
| [0055](adr/0055-staged-launch-and-load-admission.md) | Background owners start after the first grid, and heavy loads take turns |
| [0056](adr/0056-mapped-memory-for-transient-buffers.md) | Transient and library-scale buffers live in mapped memory, and a failed mapping traps |
| [0057](adr/0057-background-work-makes-room-for-the-machine.md) | Heavy background work starts only when the machine has room for it |
| [0058](adr/0058-one-activity-surface-for-background-work.md) | Background work is shown in one Activity surface, read from the owners' own status |
| [0059](adr/0059-the-installed-app-updates-itself-with-sparkle.md) | The installed app updates itself with Sparkle |
| [0060](adr/0060-diagnostics-the-user-hands-over.md) | Diagnostics the user hands over |
| [0061](adr/0061-ci-is-the-only-mac.md) | CI is the only Mac |
| [0062](adr/0062-release-overlaps-ci-and-main-skips-a-tested-tree.md) | The release overlaps CI, and main skips a tree its pull request tested |
| [0063](adr/0063-curation-without-ratings-labels-or-albums.md) | Curation without star ratings, color labels or albums |

## Research

[research/](research/) holds every dated research pass, proof of concept and benchmark, with
sources and conclusions, written in the increment that relies on it. Non-authoritative: it
records what was learned and when, and cites paths as they were then. Measurements on user data
are described by a reference library's size, never by whose it was.

Code reviews and final increment reports live on the PR, never in the repository.
