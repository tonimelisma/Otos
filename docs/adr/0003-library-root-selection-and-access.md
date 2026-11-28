# ADR 0003: Library Root Selection And Access

## Status

Accepted. Implemented: the app runs unsandboxed with no security-scoped bookmarks
(ARC-002), and the normalized filesystem path is the library-root identity
(`LibraryRootPath`, ARC-008).

## Context

Otos needs a way for users to choose media library roots before the catalog can
scan files under those roots. The current product direction is to keep the app
simple, add functionality only when required, and keep sandbox/bookmark
complexity out of the product.

Verified repo facts:

- The app is a native SwiftUI macOS app.
- ADR 0002 defines media rows as scoped by `library_root_id` and
  `relative_path`, but intentionally does not own root selection or access.
- `CLAUDE.md` requires SwiftUI-first UI and AppKit only when SwiftUI cannot
  provide the required capability or verified responsiveness.
- The Xcode project previously enabled App Sandbox and user-selected read-only
  file access. This ADR sets the posture to unsandboxed.

Captured user guidance for verification:

- Otos is not targeting Mac App Store distribution.
- Users will not know or care whether the app is sandboxed.
- Keep the app simple and add functionality only when required.
- Use an unsandboxed app.
- Use SwiftUI for the initial library-root selection flow.
- Do not introduce App Sandbox or security-scoped bookmarks.

## MECE Decision Scope

This ADR owns:

- The sandbox posture for the Otos app.
- The initial user-facing technology choice for selecting library roots.
- The initial persistence shape for library-root access.
- The boundary that App Sandbox and security-scoped bookmarks are out of scope.

This ADR references, but does not own:

- ADR 0002 media-asset filesystem reconciliation.
- MED-001 read-only originals policy.
- ARC-001 SwiftUI-first UI policy.

Separate ADRs or specs must own:

- Persistent root restoration beyond stored filesystem paths.
- File watching or incremental filesystem notifications.
- Metadata, thumbnail, preview, render, edit, export, analysis, embedding, or
  search storage.

## Decision

Run Otos unsandboxed.

Use SwiftUI for the library-root selection flow. Use AppKit only if SwiftUI
cannot provide the required folder-selection behavior or cannot meet verified
responsiveness requirements.

Represent a library root with an Otos-owned root record whose access value is a
normal filesystem path. Do not store security-scoped bookmark data. Do not add
sandbox entitlement-driven access logic. Keep originals read-only through Otos
behavior, tests, and review rather than relying on App Sandbox as the initial
enforcement mechanism.

The normalized filesystem path is the product and domain identity for a library
root. SQLite may store an internal `INTEGER PRIMARY KEY` rowid for the
`library_root` table, but that rowid is only a private foreign-key implementation
detail for child catalog rows. It is not a generated product identifier, is not
user-visible, and must not be treated as the filesystem source of truth.
For existing selected directories, normalization resolves symbolic-link
components before persistence. A user-selected convenience path such as a Desktop
OneDrive symlink therefore becomes the provider's real directory path in
`LibraryRootPath`, matching the path spelling returned by filesystem enumeration
and used for root-relative media paths.
When an older reachable saved root uses a symlink-spelled path, Store repairs the
saved row to the resolved path during startup before applying runtime root state.
If the repair cannot be written, startup preserves the saved row and records
diagnostics rather than treating a repair failure as proof that originals are
gone.

## Alternatives Considered

### Unsandboxed Path-Based Roots

Pros:

- Simplest current model.
- Matches the product direction that the filesystem is the source of truth.
- Avoids bookmark creation, bookmark resolution, stale bookmark refresh, and
  security-scope start/stop balancing.
- Keeps library-root access understandable during the first catalog increment.

Cons:

- Does not provide sandbox containment if the app or a dependency is
  compromised.
- Does not prove future Mac App Store behavior.
- A moved or renamed root path needs a later product decision.

Failure modes:

- Later work accidentally treats a stored path as a permanent identity rather
  than the current access location.

### Rejected: Sandboxed Session-Only Roots

Pros:

- Lets a user-selected folder be scanned during the current process lifetime.

Cons:

- Adds sandbox constraints outside product scope.
- Access may disappear after relaunch.
- Still needs entitlement and open-panel behavior decisions.

Failure modes:

- Developer builds pass only because selection happened in the same process.
- Relaunch behavior appears broken because bookmarks are out of scope.

### Rejected: Sandboxed Persistent Security-Scoped Bookmarks

Pros:

- Would preserve access to user-selected roots across launches.

Cons:

- Adds complexity outside product scope: bookmark data, stale bookmark refresh,
  resolution errors, unavailable volumes, and balanced access lifetimes.
- Makes the first catalog increment about access mechanics instead of catalog
  behavior.
- Users do not directly perceive the value in the current product direction.

Failure modes:

- Security scope leaks if starts and stops are not balanced.
- Root access failures are confused with catalog scan failures.
- Bookmark edge cases drive architecture before the core app behavior exists.

### AppKit Root Picker First

Pros:

- `NSOpenPanel` gives explicit macOS folder-picker configuration.
- It can be a good fallback if SwiftUI cannot provide the needed behavior.

Cons:

- Violates the SwiftUI-first requirement unless there is a specific capability
  or performance reason.
- Adds AppKit interop before the app proves SwiftUI is insufficient.

Failure modes:

- AppKit becomes the owner of workflow or domain state instead of a narrow UI
  bridge.

## Consequences

The project disables App Sandbox.

The library-root implementation can begin with straightforward SwiftUI UI and
path-based root records. Security-scoped bookmarks are explicitly not part of
the access model.

The selected pattern constrains implementation:

- no App Sandbox entitlement
- no user-selected file entitlement
- no security-scoped bookmark data in the root schema
- no bookmark start/stop lifecycle
- no AppKit root picker unless a spec or ADR identifies a SwiftUI capability or
  responsiveness gap
- originals remain read-only by Otos behavior and verification

## Retirement Proof

Before implementation, prove there are no stale sandbox/bookmark assumptions by
checking for:

- App Sandbox build settings
- user-selected file access build settings
- entitlements files
- security-scoped bookmark creation or resolution
- `startAccessingSecurityScopedResource` and
  `stopAccessingSecurityScopedResource` calls
- AppKit root-picker bridges
- docs that describe sandboxing as current behavior

## Reversal Plan

There is no planned sandbox/bookmark migration path. Reopening this decision
requires explicit user reversal of the current product requirement before any
implementation, schema, or migration work.
