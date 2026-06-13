# ADR 0003: Library Root Selection And Access

## Status

Proposed

## Context

Otos needs a way for users to choose media library roots before the catalog can
scan files under those roots. The current product direction is to keep the app
simple, add functionality only when required, and avoid sandbox/bookmark
complexity unless a concrete future requirement needs it.

Verified repo facts:

- The app is a native SwiftUI macOS app.
- ADR 0002 defines media rows as scoped by `library_root_id` and
  `relative_path`, but intentionally does not own root selection or access.
- `AGENTS.md` requires SwiftUI-first UI and AppKit only when SwiftUI cannot
  provide the required capability or verified responsiveness.
- The Xcode project previously enabled App Sandbox and user-selected read-only
  file access. This ADR changes the initial posture to unsandboxed.

Captured user guidance for verification:

- Otos is not targeting Mac App Store distribution.
- Users will not know or care whether the app is sandboxed.
- Keep the app simple and add functionality only when required.
- Use an unsandboxed app for the initial implementation.
- Use SwiftUI for the initial library-root selection flow.
- Do not introduce security-scoped bookmarks unless a future requirement makes
  them necessary.

## MECE Decision Scope

This ADR owns:

- The initial sandbox posture for the Otos app.
- The initial user-facing technology choice for selecting library roots.
- The initial persistence shape for library-root access.
- The boundary that security-scoped bookmarks are deferred.

This ADR references, but does not own:

- ADR 0002 media-asset filesystem reconciliation.
- MED-001 read-only originals policy.
- FND-017 SwiftUI-first UI policy.

Separate ADRs or specs must own:

- Security-scoped bookmarks, if sandboxing becomes a future requirement.
- Persistent root restoration beyond stored filesystem paths.
- Media eligibility beyond regular files.
- File watching or incremental filesystem notifications.
- Metadata, thumbnail, preview, render, edit, export, analysis, embedding, or
  search storage.

## Decision

Run Otos unsandboxed for the initial implementation.

Use SwiftUI for the library-root selection flow. Use AppKit only if SwiftUI
cannot provide the required folder-selection behavior or cannot meet verified
responsiveness requirements.

Represent a library root with an Otos-owned root record whose access value is a
normal filesystem path. Do not store security-scoped bookmark data. Do not add
sandbox entitlement-driven access logic. Keep originals read-only through Otos
behavior, tests, and review rather than relying on App Sandbox as the initial
enforcement mechanism.

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
- A future distribution requirement needs sandboxing and forces a migration to
  bookmarks.

### Sandboxed Session-Only Roots

Pros:

- Preserves App Sandbox while avoiding durable bookmark storage.
- Lets a user-selected folder be scanned during the current process lifetime.

Cons:

- Adds sandbox constraints that are not user-visible requirements.
- Access may disappear after relaunch.
- Still needs entitlement and open-panel behavior decisions.

Failure modes:

- Developer builds pass only because selection happened in the same process.
- Relaunch behavior appears broken until bookmarks are added.

### Sandboxed Persistent Security-Scoped Bookmarks

Pros:

- Best fit if future Mac App Store distribution or sandbox posture becomes a
  requirement.
- Preserves access to user-selected roots across launches.
- Gives a strong privacy story around user-selected folders.

Cons:

- Adds complexity before it is required: bookmark data, stale bookmark refresh,
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

The initial project disables App Sandbox.

The library-root implementation can begin with straightforward SwiftUI UI and
path-based root records. Security-scoped bookmarks are explicitly not part of
the initial access model.

The selected pattern constrains implementation:

- no App Sandbox entitlement for the initial app
- no user-selected file entitlement for the initial app
- no security-scoped bookmark data in the initial root schema
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

If sandboxing becomes a future requirement, add a new ADR that defines the
sandbox posture, bookmark schema, stale bookmark handling, access lifecycle, and
migration from path-based roots.
