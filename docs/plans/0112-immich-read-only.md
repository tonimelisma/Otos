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

- An account's RAWs get RAW9 lazily: a RAW Otos renders is one whose original is
  downloaded for work that needs it (opened full size, zoomed, edited, exported); no
  background job downloads RAWs to render them. Until then a RAW shows Immich's
  libvips development (owner, 2026-11-09).

## Defaults confirmed by the owner (2026-11-09)

- Owned assets only. Partner and shared-album assets come later.
- Archived assets are shown. Locked assets are never synced.
- An asset in Immich's trash is hidden and keeps its overlay. A permanent deletion
  purges it.
- One sidebar row per account, not one per Immich external library.
- Email and password login first; OIDC in its own increment.

## Increments

Each increment lands on `main` with its own DoD.

1. **Docs:** research note, ADR 0046 (Proposed), this plan. *(done: #579, amended #582)* The `AGENTS.md`
   principle restatements land with the increment that makes each true: the byte-read
   rule with increment 3 (done), and source of truth, identity and deletion proof with
   increment 6b, when the sync that writes an account's rows and proves their deletion
   runs in the app; ADR 0046 becomes Accepted then.
2. **Refactor, no behavior change:** root-kind capabilities replace every bare kind
   comparison. Existing tests stay unmodified and green. *(done: #580)*
3. **Refactor:** `MaterializationCoordinator.locality(of:)` and `ensureLocal`. *(done: #583)* All byte
   readers ask them. Adds a test that a camera item not yet staged, opened at full
   resolution in the loupe, gets staged. Enrichment readiness moves to `locality(of:)` in
   increment 7, with the download it gates.
4. **Refactor:** kind-neutral source-enumeration Store API, and a staging location that
   is not specific to devices. *(done: #584)*
5. **Feature, offline:**
   - the `immichAccount` kind and the v15 migration (`library_root.remote_base_url`);
   - adding and removing an account;
   - its sidebar and Settings rows;
   - All Media, Places and Duplicates membership;
   - browsable while unreachable.

   Driven by a scripted source in tests.
6. **Feature**, in three PRs, each with its own DoD:
   - **6a** *(done: #586)*: `ImmichClient` (URLSession) and the Keychain session store;
     `ImmichCatalogSync` with acks after the Store applies a batch, trash
     (`hidden_by_source`, v16), permanent delete, locked and reset. Tested with a
     `URLProtocol` stub, a scripted stream, and against the disposable local server.
   - **6b** *(done: #587)*: the Add Immich Account sheet (server URL, email, password, with validation);
     the sync started at launch, on add, and when the server becomes reachable, then on a
     poll schedule; reachability and the sidebar's offline state; removal deletes the
     Keychain item and logs the session out. The `AGENTS.md` restatements land here.
   - **6c:** Immich's preview downloaded after each sync pass for every asset owed one,
     with Otos's preview and thumbnail drawn from it as source-provisional products
     (v17 stamp), sizes and profiles read from each file.
7. **Feature**, in three PRs:
   - **7a** *(done: #591)*: metadata in byte ranges of the original while the server answers (the
     Store's answering fact, `RemoteRangeAccess`, pacing an unanswered row).
   - **7b** *(done: #594)*: original download in the executor branch, for work that needs the bytes
     (full-resolution zoom, edit, export, hand-off), with every missing product, Otos's
     rendering and the digest included, written from that one read, under the free-space
     floor. RAW9 renders lazily (owner decision above).
   - **7c** *(done: #595)*: render signatures keyed by pipeline (ADR 0042).
8. **Feature** *(done)*: hand-off, drag, clipboard, Share and Open With for an original not yet
   downloaded, and what each one says while offline.
9. **Feature**, in two PRs:
   - **9a** *(done)*: Live Photo motion placement in the still's folder, and each row's
     own source item ID (v18).
   - **9b:** Duplicates presentation and refused resolutions for account copies.

## Test server

The integration increments use a disposable Immich server started from the release's
official `docker-compose.yml`, with no machine-learning container and a named volume. Its
test user's credentials are generated per run. Each run removes the stack and its volumes
when it finishes (`docker compose down -v`), including when it fails.
