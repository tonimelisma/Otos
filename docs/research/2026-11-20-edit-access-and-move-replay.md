# Edit state's outside accesses, and how concurrent work survives the `OtosKit/` move (2026-11-20)

## Question

Plan 0117 asks for one de-risking step before each of two structural changes:

- **E7 (step 7).** Make every edit stored property `private` to an `EditSession` type. Each
  compile error is then a real access from outside. The plan stops if any is a **write** from
  outside Edit, Crop and EditCommands to edit state, other than to the undo manager or view mode.
- **E8 (step 8).** Replay recent commits that touched `Otos/` onto the moved tree, as stand-ins
  for in-flight branches. Count clean picks, conflicts, and added files. Decide whether a
  rejecting guard plus merging when quiet is enough.

## Method

- Throwaway local branches, never pushed, opened as a PR, merged or installed. They were
  deleted after this note recorded their final commits.
- Builds ran only through `script/check.sh --only <Suite>` (Xcode 27.2, 27B52).

| Experiment | Branch | Base | Final commit |
| --- | --- | --- | --- |
| E7 | `research/e7-edit-session` | `5938d8dd` (`origin/main`) | `ff266b69` |
| E8 replay | `research/e8-move-replay` | `73b19b97` | `b4c5367e` (move `678d302c`, replay head `6d3ba52f`) |
| E8 synthetic adds, unmoved | `research/e8-synth` | `ca01a04d` | `53d77b99` |
| E8 synthetic adds, replayed | `research/e8-cf` | `5e703c7d` (replayed `ca01a04d`) | `2ebe25b0` |

## E7: what reaches edit state from outside Edit

### Method

- The 40 stored properties `CatalogWindowViewModel` declares for editing were moved into
  `final class EditSession` (`@MainActor @Observable`) as `private` members:
  - the panel state (`editTarget`, `editDraft`, `editSectionsOff`, `editLivePreview`,
    `editPhotoFacts`, `editOriginalPixelSize`, `editHistogram`, `editOriginalPreview`,
    `selectedEditControl`, `isEnteringEditValue`, `isPickingNeutral`, `isShowingOriginal`);
  - the crop tool (`isCropping`, `isDrawingStraightenLine`, `editCropBase`, `cropAspect`,
    `cropAspectLandscapeChoice`, `editAutoLevel`, `editAutoCrop`, `isDraggingCrop`);
  - the lanes and their counters (`editSavedRecipe`, `editDraggingControl`, `editTargetTask`,
    `editTargetRequestedID`, `liveEditRenderer`, the render, command and analysis streams,
    continuations and tasks, `editRenderRequested`, `editRenderPublished`,
    `editHistogramPublished`, `editAnalysisRequested`, `submittedEditCommandCount`,
    `handledEditCommandCount`).
- The view model holds one `let editSession = EditSession()`. No accessors were added.
- Left on the window: `inspectorPane` (Inspector's), and `videoTrimCommand` /
  `videoTrimGeneration` (declared among hand-off state, but written by Edit; see below).
- **A first build reported only one compile batch's errors.** The build system stops
  scheduling batches after the first failed one, and `-continue-building-after-errors` did not
  change that. The counted build set `SWIFT_COMPILATION_MODE = wholemodule` for Debug, so one
  frontend type-checks every file and reports every error.
- `OtosTests` does not compile while OtosKit fails, so test accesses were counted with
  `grep`, cross-checked against the compiler's list for the app files.

### Result

**307 compile errors.** 276 are inside Edit, Crop and EditCommands, which is the code that
moves into `EditSession`: Edit 174, Crop 74, EditCommands 28. The **31 outside** are:

| File | Errors | Reads | Writes | Properties |
| --- | --- | --- | --- | --- |
| `ContentView.swift` | 14 (16 accesses) | 16 | 0 | `isPickingNeutral`, `isCropping`, `editCropBase`, `editDraft`, `isDrawingStraightenLine`, `editTarget`, `editPhotoFacts`, `editHistogram`, `isShowingOriginal`, `selectedEditControl`, `cropAspect` |
| `OtosApp.swift` (Image menu) | 2 | 2 | 0 | `isCropping` |
| `CatalogWindowViewModelLoupeZoom.swift` (`loupeEscape`) | 2 | 2 | 0 | `isPickingNeutral`, `isCropping` |
| `CatalogWindowViewModel.swift`, `init` | 6 | 0 | 6 | the three lanes' streams and continuations |
| `CatalogWindowViewModel.swift`, teardown | 7 | 7 calls | 0 | `editTargetTask`, `editRenderTask`, `editCommandTask`, `editAnalysisTask` `.cancel()`; three continuations `.finish()` |

- `ContentView.swift` has two more reads inside a closure that the compiler did not report
  separately, because an error higher in the same expression hid them (lines 614 and 617).
- `EditPanelView` and `LoupeView` match the names in `grep`, but only as their own inputs. The
  view model hands them the values, so the compiler reported nothing there.
- **Tests: 77 lines that access edit state, in 4 files; 2 of them write.**
  - `CatalogWindowViewModelEditTests` 48, `CatalogWindowViewModelEditCommandsTests` 24,
    `CatalogWindowViewModelDetailReadFailureTests` 4, `EditTestSupport` 1.
  - The writes seed `model.editAutoCrop` (`CatalogWindowViewModelEditTests.swift:409`, `:416`).
  - The rest read panel state, wait on `submittedEditCommandCount` or the tasks, or await
    `editTargetTask?.value`.

**Methods.** Other features also call Edit's methods. These are intents, not state writes:

- `CatalogWindowViewModel.swift` calls `startEditing(store:)`.
- Inspector calls `endEditing()` and `refreshEditTarget()`.
- OpenWith calls `refreshEditTarget()`.
- LoupeZoom calls `toggleNeutralPicker()` and `endCropping()`.
- ViewMode calls `displayedPanePreview(_:)`.
- `OtosApp` calls the Image and Edit menu intents (`toggleCropTool`, `turnPhoto`, `flipPhoto`,
  `toggleNeutralPicker`, `toggleShowOriginal`, `revertToOriginal`, `nudgeSelectedEditControl`,
  `selectAdjacentEditControl`, `trimVideo`) and reads `canEdit`, `textHoldsKeyboard` and
  `canTrimVideo`.

### Verdict: not stopped

**No write from another feature reaches edit state.**

- Every outside error is either a read (view bindings, a menu's title and enablement, Escape's
  routing) or the window's own lifecycle wiring.
- That wiring is building the lanes in `init`, and cancelling and finishing them at teardown.
  It moves into `EditSession`'s own `init` and teardown.
- The plan's stop rule does not fire.

### The narrow context `EditSession` needs

**From the window**, by count of reads in Edit, Crop and EditCommands:

- **Values:**
  - the current target (`targetIDs(.current)`);
  - `viewMode` and `story`;
  - `focusedAssetID` and `focusedAssetKind`;
  - `loupeVideoState`;
  - `showsSelectedScope`;
  - `exportSheet`, only to answer `textHoldsKeyboard`;
  - `panePreviews` and `expectedAsset(for:)`;
  - `isEditPanelPresented`.
- **Services:** `tileDetailReader`, `store`, `materializationCoordinator` and
  `windowUndoManager`, which gets 8 registrations and groupings.
- **Intents it calls on the window:**
  - `setInspectorPane(.edit)` and `setViewMode(.loupe)`, from the crop tool;
  - `updateLoupeVideoState`, which applies a trim to the open video;
  - `requestPanePreview`, after a save lands;
  - `publishUndoState` and `revealUndoneChange`.

**Two writes go the other way, from Edit into window state:**

- `refreshEditedPanes` clears a loupe's `fullResolutionRequestedIDs` entry, which is
  LoupeZoom's state, so a zoomed decode is redone with the edit. In the new shape this becomes
  a window intent.
- `trimVideo` writes `videoTrimCommand` and `videoTrimGeneration`. Trim saves through the edit
  lane, so this state moves into `EditSession` with it.

**What the window reads from it:**

- for `ContentView`'s panel and loupe: the 11 properties in the table above and Edit's
  derived values (`canCrop`, `cropFractionRatio`, `sectionsTurnedOff`, `loupeShowsOriginal`,
  `displayedPanePreview`, …);
- `isCropping` and `isPickingNeutral`, for the Image menu and Escape;
- its intents, for the menus and the panel.

## E8: replaying recent work onto the moved tree

### Method

- **The move.** The X1 move was recreated on `73b19b97`, the parent of the oldest of the last 30
  non-merge commits on `main` that touched `Otos/`:
  - `git mv` of everything except `main.swift`, `Assets.xcassets` and `Otos.icon` into
    `OtosKit/`;
  - X1's script and lint changes applied with `git apply -3`;
  - the project file rewritten by a script that removes both exception sets, adds the
    `OtosKit` synchronized group and points the framework target at it.

  The script's output is byte-identical to X1's `project.pbxproj`, and to the same rewrite of
  today's `main`.
- **The replay.** All 52 commits from `73b19b97` to `origin/main` were cherry-picked in order
  with `git cherry-pick -X find-renames`. That is the last 30 that touch `Otos/`, plus the 22
  between them that do not, so every commit's context is the real one. This is exactly a
  rebase of a 52-commit branch across the move.
- **After every commit:**
  - Each conflict's kind and path was recorded.
  - Every file left under `Otos/`, other than the app's three entries, was flagged as a
    mistarget.
  - The replayed tree, with `OtosKit/` mapped back to `Otos/`, was compared with the
    original commit's tree.
- **Resolving a conflict:**
  - each file got the commit's own content at its moved path;
  - the project file got the commit's version, with the move's rewrite applied again;
  - the scripts got the commit's version, with the move's path edits merged in by hand at the
    end.

### Result

**Of the 30 commits that touch `Otos/`, 28 picked clean and 2 conflicted.** Both conflicts were
commits that **add** a file under `Otos/`:

| Commit | Adds | Conflicts |
| --- | --- | --- |
| `ee6efe0d` (#968) | `Otos/Resources/SceneLabelHierarchy.tsv` | `CONFLICT (file location)` for the file; `CONFLICT (content)` in `project.pbxproj` |
| `3c1002df` (#982) | `Otos/Views/MediaGridScrub.swift` | `CONFLICT (file location)` for the file; `CONFLICT (content)` in `project.pbxproj` |

- **Modified files rebased cleanly through rename detection.** That covers 163 file
  modifications across 28 commits, including `ed9454c2`'s 24 files.
- **Every replayed tree matched its original.** After each of the 52 commits, the moved tree
  mapped back to `Otos/` equalled the original commit's tree (`treeDiffVsOriginal=0`, scripts
  and project file excluded). At the end, the replayed tree equals `origin/main` plus the move:
  all 316 renames have no content change, and the project file is identical.
- **Where an added file lands.**
  - git 2.54's default (`merge.directoryRenames=conflict`) detects that `Otos/Views/` and
    `Otos/Resources/` were renamed. It stops with `CONFLICT (file location)` and stages the
    file at the suggested `OtosKit/…` path, so `git add` keeps it in the framework.
  - Each add also carried a new `membershipExceptions` line, which conflicts with the deleted
    exception set. Today's layout needs that line for every new framework file.
  - So in this sample, neither add could land silently.
- **One non-`Otos/` commit also conflicted:** `60db8ea0` (#978), the guard-scan fix, in 7
  scripts, against the move's path edits. Taking #978's side alone reverted the path edits.
  The next `check.sh` then failed at the fast gates in seconds:

  ```text
  FAIL: guard-design-system scans …/Otos/Views, which does not exist
  ```

  That confirms #978 makes a stale scan root fail loudly. #968's new
  `script/scene-label-hierarchy.sh` also arrived naming `Otos/Resources/…`. It is not a gate,
  so nothing failed for it.
- **The build.** The final replayed tree (`b4c5367e`) passed the fast gates and built:
  `check.sh --only MediaGridScrubPolicyTests` gave `TEST BUILD SUCCEEDED` and
  `TEST EXECUTE SUCCEEDED`. That suite belongs to the replayed add commit. The only red stage
  was `requirements-authority-check`, from the doc paths, as in X1.

### Synthetic adds: the cases the sample did not contain

Two one-file commits were made on the unmoved `ca01a04d`, neither touching the project file.
Each was then cherry-picked onto its moved twin:

- **New file in an existing folder** (`Otos/Views/SyntheticInViews.swift`):
  `CONFLICT (file location)`, staged at `OtosKit/Views/…`. Loud, and the default resolution is
  correct.
- **New file in a new folder** (`Otos/NewFeature/SyntheticNewFolder.swift`): **clean**. The
  file landed at `Otos/NewFeature/`, where the app target compiles it. git infers a directory
  rename only for a folder that existed and moved. `Otos/` itself did not move, because
  `main.swift` stays.

  This is the silent mistarget. Today such a commit is already wrong, because the file would be
  missing its exception line. Even so, nothing in git stops it.
- **A tool without rename detection** (`-X no-renames`) on `3c1002df`: each modified file
  becomes a `modify/delete` conflict, and the added file is staged at `Otos/Views/`. Loud, but a
  careless "keep theirs" resolution puts files in the app target.

### Verdict and what it means for the plan

**Rename detection carries modifications cleanly**: 28 of 30 commits, every modified file.
**An added file conflicts loudly in the common cases:** a new file in an existing folder, and
any add that touches the project file. A guard plus merging when quiet is enough, with two
amendments:

1. **The guard must reject every file under `Otos/` other than `main.swift`, `Assets.xcassets/`
   and `Otos.icon/`, not only `.swift`.** The silent case is a new folder. A resource there,
   like #968's `.tsv`, would be copied into the app bundle instead of the framework, and a
   `.swift`-only guard would pass it.
2. **The move's own PR rewrites every script that names an `Otos/` path, not only the gates.**
   #978 makes a gate with a stale root fail. A tool script such as
   `scene-label-hierarchy.sh` would still quietly write to the old folder. Also, a script
   change in flight when the move lands conflicts in the move's path lines, as #978 did.

**Merging when quiet was measured, not assumed.** `gh pr list --state open` returned no open
PRs on 2026-11-20. 215 commits touched `Otos/` in the week before. In-flight work here lives in
agent worktrees that become PRs within hours, so "no open PR changes `Otos/`" is a state the
repository reaches often.
