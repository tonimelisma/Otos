# Three structure prototypes: an OtosKit folder, a serial lane, an owner loop (2026-11-19)

## Question

Three refactors kept coming up as ways to remove repeated structure. Each was tried as a
throwaway prototype on its own `research/` branch, with a kill criterion set before it started:

- **X1.** Move the app's sources into an `OtosKit/` folder synchronized only to the OtosKit
  target, so the app target's ~290-entry `membershipExceptions` list (ADR 0023's "durable
  trap") goes away.
- **X2.** A generic `SerialLane` for the view model's submitted/handled counter lanes, ported
  to Export and HandOff.
- **X3.** A subscribe-then-loop helper for background derived-fact owners, ported to
  `RenderSignatureRefresher` and `PhotoDescriptionWriter`, plus a generic "key not before
  instant" ledger for three retry paces.

## Method

- Each branch started from `main` and was verified with `script/check.sh` (Xcode 27 beta,
  macOS 27). An experiment counted as a success only if the existing tests passed
  **unmodified**.
- Line counts are `wc -l` and `git diff --numstat` against each branch's base. Most of the
  diff in a ported loop body is indentation, because the loop scaffolding left it.
- No experiment was opened as a PR, merged or installed. The branches were deleted after this
  note recorded their final commits.

| Experiment | Branch | Base | Final commit |
| --- | --- | --- | --- |
| X1 | `research/x1-otoskit-folder` | `998ce0d1` | `f7360fdb` |
| X2 | `research/x2-serial-lane` | `23de9bf1` | `745fdf15` |
| X3 | `research/x3-owner-loop` | `23de9bf1` | `399dec8e` |

## X1: sources in an `OtosKit/` folder

**What was done.** Every app source and resource was moved with `git mv` into `OtosKit/`:
`ContentView.swift`, `OtosApp.swift`, `Models/`, `Resources/`, `Services/`, `Stores/`,
`Support/`, `ViewModels/` and `Views/`. Only `main.swift`, `Assets.xcassets` and `Otos.icon`
stayed in `Otos/`. In `project.pbxproj`:

- a new `PBXFileSystemSynchronizedRootGroup` (`path = OtosKit`) was added and synchronized to
  the OtosKit target only;
- the `Otos` group was synchronized to the app target only;
- both exception sets were removed: the app target's 307 entries and OtosKit's 2 (`main.swift`,
  `Otos.icon`). The diff was +7 / −329 lines.

**Result.**

- ✅ **Build: green.** Two full runs: `TEST BUILD SUCCEEDED`.
- ✅ **Tests: green, unmodified.** Two full runs: `TEST EXECUTE SUCCEEDED`, no
  `op=test.failure`. No test locates a file under `Otos/` (they use `SourceTree.root` for
  `OtosTests/` and `build/` only).
- ✅ **Resource membership was handled correctly** by the Xcode 27 beta synchronized group:
  - `OtosKit.framework/Versions/A/Resources` holds the same 20 entries as the installed app's
    framework: the five `.mlpackage`s compiled to `.mlmodelc`, the `.bin`/`.tsv` files, and
    `Licenses/*` flattened to the folder's root as today;
  - the app bundle holds `Assets.car`, `Otos.icns` and the embedded framework;
  - `script/lib/xcode.sh`'s shared-model step found every source package at its new path
    (`op=build.models phase=shared` for all five models).
- ❌ **`check.sh`: red, on one gate only**, `requirements-authority-check`. `docs/requirements.md`
  cites 350 distinct `Otos/…` source paths (1,180 references), and the gate requires every
  cited path to exist. The doc rewrite was out of this trial's scope, so the gate stayed red.
  It is one mechanical substitution.

**Files and scripts that needed changes** (beyond the move and the project file):

- `script/check.sh`: the tier classifier's `Otos/* | OtosTests/*` became
  `Otos/* | OtosKit/* | OtosTests/*`.
- `script/lib/xcode.sh`: the source package path for shared models.
- Guards, each scan root and each self-test seed path:
  - `script/guard-design-system.sh`
  - `script/guard-view-passivity.sh`
  - `script/guard-no-audio.sh`
  - `script/guard-no-writes-into-media.sh` (its allow-list paths too)
  - `script/guard-unsandboxed.sh`
  - `script/guard-single-main-window.sh` (a hard-coded `$1/Otos/OtosApp.swift`)
  - `script/guard-presentation-yield.sh`
- `script/ci-text-hygiene.sh` (its `git grep -- Otos`, allow-listed path and Python scan roots),
  `script/check-doc-citations.sh` and `script/check-no-unchecked-sendable.sh`.
- `script/time-guard.sh` (`git ls-files Otos OtosKit OtosTests script`) and
  `script/scene-label-hierarchy.sh` (its output path).
- `script/requirements-authority-check.sh`'s self-test fixtures.
- `.swiftlint.yml`: 14 `included`/`excluded` regexes. As a side effect, `OtosKit/.*` no longer
  matches the checkout folder itself, which is why some app rules exclude `OtosTests/` today.
- `.gitattributes` (`OtosKit/Resources/*.bin binary`).

**Problems hit.**

1. **Guards scanning a folder that no longer exists pass silently.** The first run's mechanical
   rewrite missed `"$root/Otos/Views"` in `guard-view-passivity.sh` and `guard-design-system.sh`.
   `grep -R … || true` and `find … 2>/dev/null` then scanned nothing and reported clean. Only
   `guard-single-main-window.sh`, which greps one named file, failed loudly (`FAIL: ARC-014`).
   Several self-tests wrote into a `mkdir`-less seed folder (`No such file or directory`). This
   is a defect in the guards, whatever the folder layout: a guard whose scan root is missing
   should fail.
2. The doc gate couples `docs/requirements.md` to source paths, so a move always rewrites the
   requirements registry in the same PR.
3. No synchronized-group problem was found. Xcode 27 beta read the two-group layout without the
   project needing anything beyond the new group and the target's
   `fileSystemSynchronizedGroups`.

**Doc references that would change** (counted, not rewritten): 1,339 `Otos/…` references
across `docs/`, of which 1,326 name a moved folder:

- `docs/requirements.md`: 1,180 (350 distinct paths);
- `docs/design/`: 80;
- `docs/research/`: 43;
- `docs/adr/`: 22, in 12 ADRs;
- `docs/architecture.md`: 1.

One more is in a source comment (`CatalogMediaEmptyStatePresentation.swift`). None are in
`AGENTS.md` or `README.md`. ADR 0023's Decision ("No source or test file moved on disk") and
its trap paragraph would be rewritten.

**Verdict: not killed.** Resources were handled correctly. The check is green except for the one
doc gate, and its fix is mechanical. A real increment would carry the 1,326 doc-path rewrites
and the ADR 0023 rewrite, and should first make each guard fail on a missing scan root.

## X2: a generic `SerialLane`

**What was done.** `Otos/Support/SerialLane.swift` (97 lines) holds the parts every lane repeats:

- the `.unbounded` stream and its continuation;
- the one consumer task;
- the generation counter (rule 2) and `cancelledThrough`;
- the submitted and handled counts, `isSettled`, and an awaitable `untilSettled()`, resumed in
  the step that makes it hold;
- `finish()`, which resumes any waiter at teardown.

`submit { generation in Request(…) }` numbers the request. `cancel(through:)` and
`isCancelled(_:)` express Export's and HandOff's per-request cancellation as values, with no
nested closures. Export and HandOff were ported. The loop body became the closure passed to
`start`, and `continue` became `return`.

**Lines** (base `23de9bf1`):

| File | Before → after | Net |
| --- | --- | --- |
| `CatalogWindowViewModel.swift` (declarations, init, teardown) | 2,396 → 2,376 | −20 |
| `CatalogWindowViewModelExport.swift` | 264 → 263 | −1 |
| `CatalogWindowViewModelHandOff.swift` | 357 → 356 | −1 |
| `SerialLane.swift` (new) | 0 → 97 | +97 |

That is about 11 lines saved per port, and the change is +75 lines overall.

**Hooks needed.** Five test sites in four files reach the consumer task directly:
`defer { model.exportTask?.cancel() }` (2 in `ExportTests`) and
`defer { model.handOffTask?.cancel() }` (3). The first scoped run failed to build on them. To
keep the tests unmodified, the lane exposes `task`, and the view model keeps `exportTask` and
`handOffTask` as computed properties: 5 lines each, which are counted in the per-file numbers
above. Nothing else was needed.

**Tests.**

- ✅ Scoped run: `ExportTests`, `HandOffTests`, `CatalogWindowViewModelMediaItemMenuTests` and
  `CatalogWindowViewModelViewModeTests` passed (`--only`, `evidence=no`).
- ✅ Full run: green (see Full verification).

**Could the waits use `untilSettled()`?** There are 45 `waitUntil { model.hasSettled… }` sites
(not 53): 26 Edits, 13 MediaChoices, 4 HandOffs and 2 Exports, plus 3 doc comments that name the
fact.

- Each site is a bare "everything submitted has been handled" wait, so each could become
  `await model.<lane>.untilSettled()`. That holds once all four lanes are on the type; today
  only the 6 Export and HandOff sites could.
- No test was changed, so `untilSettled()` ran in no test. It is unexercised code.

**Verdict: killed** on the line-count criterion: about 11 lines saved per port, against a
threshold of about 25. The type does express the lanes' cancellation, so the first kill clause
was not met. What it removes is scaffolding (stream, continuation, task, four counters, init and
teardown lines), not logic. With the Edit and MediaChoice lanes ported too, the 97-line type
would still cost more than the four ports save.

## X3a: one subscribe-then-loop helper

**What was done.** `Otos/Services/OwnerLoop.swift` (116 lines) adds `OwnerLoop`, the loop's
bookkeeping: doorbell, loop task, forwarder task, `changesHeard` and `wakes`. It is used only on
its owner's isolation, as `OwnerActivity` is. It also adds a `LoopingOwner: QuiescentOwner`
protocol whose extension supplies:

- `startLoop(name:)`: subscribe, read the inputs' facts, re-check after the awaits, ask for the
  first pass, then start a forwarder and a loop that both hold the owner weakly;
- `requestPass()`;
- a default `heard` (ring when the change touches the inputs) and a default `subscribed`;
- `pass(draining:)`, which covers the request it started from only when the drain succeeded;
- `ringIdle()`.

**Lines:**

- `RenderSignatureRefresher`: 169 → 127 (−42).
- `PhotoDescriptionWriter`: 534 → 493 (−41).
- `OwnerLoop.swift` is new: +116.

**Hooks beyond `drain`:**

- **`RenderSignatureRefresher`: none in behavior.** `pass()` is a one-line delegate to
  `pass(draining:)`. It also needs plumbing the protocol requires: `ownerLoop`, a `loopStore`
  accessor (the protocol cannot see a `private let store`), the `changesHeard`/`wakes`
  forwarders its tests read, and `start()`/`shutdown()` wrappers.
- **`PhotoDescriptionWriter`: four.**
  - `heard`: a named change owes those stills alone.
  - `subscribed`: the first ask is an owed walk, not a bare request.
  - `pass`: its drain answers a request revision, not a success flag.
  - shutdown extras: its retry wake and its change continuations.

**A behavior the helper forced.** The two owners subscribed differently:

- `RenderSignatureRefresher.start()` awaited the subscription before returning.
  `CatalogOwnerInputsTests.theRenderSignatureRefresherWakesOnlyOnWhatItReads` relies on that:
  it delivers changes right after `await refresher.start()`.
- `PhotoDescriptionWriter.start()` was synchronous. It subscribed inside the forwarder, and a
  `subscribing` flag reported `holdsWork` until then.

One helper had to pick one form. It took the first, so `PhotoDescriptionWriter` lost
`subscribing` and its `holdsWork`. Every test still passed, but that is a change to an owner's
quiescence contract, made to fit a shared helper.

**Verdict:**

- ✅ `RenderSignatureRefresher` passes the criterion: 42 lines saved and no hook beyond `drain`.
- ❌ `PhotoDescriptionWriter` meets the kill criterion: four hooks beyond `drain`, against a
  limit of 2.
- The helper is worth having only if several owners share `RenderSignatureRefresher`'s plain
  shape. With two adopters it saves 83 lines and costs 116.

## X3b: a "key not before instant" ledger

**What was done.** `Otos/Services/PacingLedger.swift` (72 lines) adds
`PacingLedger<Key, Stamp>`. A held key carries the stamp it failed on and its `notBefore`. It is
admitted again when its pacing ends, or at once when it is asked with a different stamp.

Key identity is the `Stamp` type parameter, not a per-owner flag:

- **ENR-026 face retries**: `Stamp = PreviewFaceCandidate`, so a new preview is read at once;
- **ENR-032 descriptions**: `Stamp = PacingLedgerUnstamped`, so a held still is re-admitted only
  by time, and the walk's SQL still excludes `heldKeys`;
- **anniversary titles (APP-078)**: `Stamp = String`, the joined descriptions the title was asked
  for.

The model gates (`modelNotBefore`) stayed single values in their owners. A ledger of one key adds
nothing.

**Lines:**

- `PreviewFaceReader.swift`: 518 → 515 (−3).
- `PhotoDescriptionWriter.swift`: ±0.
- `AnniversaryTitleWriter.swift`: 234 → 235 (+1).
- `PacingLedger.swift` is new: +72.

`PreviewFaceRetries` could not be replaced. `PreviewFaceReaderTests` constructs it and calls its
API directly (`failed`, `admits`, `modelFailed`, `admitsModel`, `read`, `keep(only:)`,
`nextWake`, `stills`). It stayed as a wrapper over the ledger, which is why it saves 3 lines.

**Tests: green, unmodified.** The ENR-026, ENR-032 and anniversary-title tests needed no change.
No flag was needed for key identity.

**Verdict:** the kill criterion was not met, but the ledger is not worth adopting. It saves 2
lines across three owners and costs 72. Each owner's pacing is a dictionary and a `min()`.

## Full verification

- **X1**: two full `script/check.sh` runs. Build ✅ and tests ✅ in both. Red only on
  `requirements-authority-check` (both runs) and on the guard defects (first run only; fixed
  before the second).
- **X2**: one full `script/check.sh` on `745fdf15`: `verify: all stages passed`, `check: PASSED`, with tests unmodified (the `exportTask`/`handOffTask` properties kept).
- **X3**: one full `script/check.sh` on `399dec8e`: `verify: all stages passed`,
  `check: PASSED`, with tests unmodified.

## Conclusions

1. **X1 (folder move): feasible.** The Xcode 27 beta synchronized groups handled resource
   membership correctly, and every test passed unmodified. The real cost is documentation:
   1,326 path references, ADR 0023 rewritten, and `requirements.md` rewritten in the same PR
   because its gate checks paths.
   - Separately, the guards pass silently when their scan root is missing. That is a defect
     today, whatever the layout.
2. **X2 (`SerialLane`): killed.** It saves about 11 lines per port against a threshold of 25.
3. **X3a (owner-loop helper): killed for `PhotoDescriptionWriter`** (four hooks beyond `drain`).
   It fits `RenderSignatureRefresher`, but it forced one subscription form on both owners.
4. **X3b (pacing ledger): not killed, not worth it.** Tests passed unmodified and no identity
   flag was needed, but it saves 2 lines for 72.
