# Plan 0112: Read-only Immich accounts

Opened 2026-11-07. Decisions: ADR 0046. API facts: `docs/research/2026-11-07-immich-api.md`.

## Owner decisions (2026-11-07)

- The user logs in to Immich from Otos. Each account is a sidebar library like a local
  one, and its photos appear everywhere Otos shows photos.
- Every Otos feature that does not change media works on Immich photos.
- **Read-only first:** nothing writes to Immich.
- Offline: Otos keeps showing its own stored thumbnail and 2560 px preview. Work that
  needs the original waits for the server and says so.

- An account's grid and loupe show Immich's own thumbnail and preview, downloaded on
  sync, instead of downloading every original to render (owner proposal, 2026-11-07;
  ADR 0046 §7, `docs/research/2026-11-07-immich-derived-assets.md`).

## Open owner decision

- Whether an account's RAWs get RAW9 renders on open or zoom, or from a background job
  while the server is reachable. Until then a RAW shows Immich's libvips development.

## Defaults taken (not yet confirmed by the owner)

- Owned assets only. Partner and shared-album assets come later.
- Archived assets are shown. Locked assets are never synced.
- An asset in Immich's trash is hidden and keeps its overlay. A permanent deletion
  purges it.
- One sidebar row per account, not one per Immich external library.
- Email and password login first; OIDC in its own increment.

## Increments

Each increment lands on `main` with its own DoD.

1. **Docs:** research note, ADR 0046 (Proposed), this plan. *(this PR)* The `AGENTS.md`
   principle restatements land with the increment that makes each true: the byte-read
   rule with increment 3, and source of truth, identity and deletion proof with
   increment 5, when ADR 0046 becomes Accepted.
2. **Refactor, no behavior change:** root-kind capabilities replace every bare kind
   comparison. Existing tests stay unmodified and green.
3. **Refactor:** `MaterializationCoordinator.locality(of:)` and `ensureLocal`. All byte
   readers ask them. Adds a test that a camera item not yet staged, opened at full
   resolution in the loupe, gets staged. Enrichment readiness moves to `locality(of:)` in
   increment 7, with the download it gates.
4. **Refactor:** kind-neutral source-enumeration Store API, and a staging location that
   is not specific to devices.
5. **Feature, offline:**
   - the `immichAccount` kind and the v15 migration (`library_root.remote_base_url`);
   - adding and removing an account;
   - its sidebar and Settings rows;
   - All Media, Places and Duplicates membership;
   - browsable while unreachable.

   Driven by a scripted source in tests.
6. **Feature:**
   - `ImmichClient` (URLSession) and the Keychain session store;
   - the Add Immich Account sheet (server URL, email, password, with validation);
   - `ImmichCatalogSync` with acks after the Store applies a batch, trash, permanent
     delete and reset;
   - Immich's thumbnail and preview downloaded on sync as source-provisional products,
     sizes and profiles read from each file;
   - reachability.

   Tested with a `URLProtocol` stub and against a disposable local Immich server.
7. **Feature:** original download in the executor branch, for work that needs the bytes
   (full-resolution zoom, edit, export, digest), with every missing product, Otos's
   rendering included, written from that one read. Render signatures keyed by pipeline.
   Includes ranged metadata reads, the free-space floor, and the RAW9 timing the owner
   decides.
8. **Feature:** hand-off, drag, clipboard, Share and Open With for an original not yet
   downloaded, and what each one says while offline.
9. **Feature:** Live Photo placement, and Duplicates presentation and refused resolutions
   for account copies.

## Test server

The integration increments use a disposable Immich server started from the release's
official `docker-compose.yml`, with no machine-learning container and a named volume. Its
test user's credentials are generated per run. Each run removes the stack and its volumes
when it finishes (`docker compose down -v`), including when it fails.
