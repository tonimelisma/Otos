# The Trash question, read when the targets change (2026-11-15)

Follows `2026-11-15-immediate-feedback-for-every-act.md` (#778/#781).

## Question

With `Ask before downloading more than 100 MB to move items to the Trash` on (the default),
#778 left Move to Trash waiting for one hop before anything is hidden: the window holds no
locality fact, so the command asked `MediaTrashCoordinator.downloadBytes` — one `lstat` per
target off the main actor, and a catalog read only for a target whose own file is cloud-only —
and hid the items when it answered. The hop is short when the cooperative pool is free and
unbounded when it is not (#765, #773). The question (APP-045, DES-090) must still be asked
before anything is hidden when it applies. What is the smallest correct way for the common
command — every target local, or the download under the threshold — to hide in the step that
applies it?

## Method

The code of `CatalogWindowViewModelTrash`, `MediaTrashCoordinator`, `FileMaterialization`,
`MaterializationCoordinator.locality(of:)`, the grid's tile-detail read and the Info pane's
locality read; ADR 0008; and tests that deliver each interleaving at its exact suspension.
Nothing was run on the installed app or the owner's data.

## What answers the question

The question applies when the catalog sizes of the dataless members of the targets whose own
file is dataless add up to more than 100 MB (`LargeTrashDownloadPrompt.asks`). Two facts:
which own files are dataless (a filesystem flag, `SF_DATALESS`, read by `lstat`), and the
members' catalog sizes. Neither is held by the window:

- The grid's tile details carry no locality; only the Info pane reads one, for one item
  (`MaterializationCoordinator.locality(of:)`), when it is shown.
- ADR 0008 forbids storing dataless status: it is a point-in-time fact a provider can change at
  any moment (eviction under disk pressure, a download), and every byte read checks it again
  immediately before it reads.

## Options

### (a) Read the question's answer when the targets change

A lane (ADR 0032: a revision pair, one doorbell loop) sizes the command the current targets
would make — the same `downloadBytes` the command used — whenever a target writer changes them
(`refreshOpenWithMenu`, which selection, focus, mode and Compare already call), and keeps the
result with exactly the files it read. A command whose files equal the reading's answers from
it in the step that applies it: asks, or hides. A command whose targets have not been read yet
(it came in the same step as the change, or it is Duplicates' Move All, which is not the
current targets) reads for itself as before, and nothing is hidden until that read answers.

- **What can change in between.** The locality of a target's file, between the reading and the
  command: seconds when the user acts at once, as long as the selection sits. Evicted since
  (local → cloud-only): the question is not asked although it would have applied. Downloaded
  since (cloud-only → local): it is asked although it no longer applies, and the answer moves
  the items as before. A catalog size that changed since: the prompt states the old figure.
- **Consequence at worst.** An unasked download: the queue downloads the file before it moves
  it, under the 5 GB free-space floor, which stops and asks (`.diskFloor`); a download the
  provider refuses stops and asks (`.downloadFailed`); the items wait hidden with the status
  bar's `to download` and Cancel. Nothing is deleted and nothing is lost: the question guards a
  download's cost, not the move.
- **Cost.** One `lstat` per target file at each target change, off the main actor, and a
  catalog read of the cloud-only targets' members — what each command cost before, now paid when
  the targets change, once per distinct target set. A select-all of a cloud-only library reads
  every item's members once, in the background.
- **ADR 0008.** Nothing is stored: the reading lives in the window's memory, for one target set,
  and is replaced when the targets change. No byte is read on it; the queue checks every
  member's status again under its lease before it moves it, as before.

### (b) Hide the targets known local, ask only about the rest

Splits one command in two: what is hidden, what the undo entry covers and what the question
names stop being the command the user gave. It still needs a locality fact before the hide,
which is (a)'s or (c)'s. Rejected: the question is about the command, and half a command hidden
under a question is neither DES-119's result nor DES-090's.

### (c) Keep the hop and prove it sub-frame

The hop is one actor enqueue and N `lstat`s. It is sub-frame on a free pool and has no bound on
a starved one: #765 and #773 measured pool waits of seconds under enrichment. Proving it
schedule-independent would need the hop off the cooperative pool altogether, a dedicated thread
for one `lstat` per command — and the command would still wait on it. Rejected.

## Decision

(a), the one a blank-slate build would have: the question is a property of the targets, read
when they change, as the Open With menu and the Info pane already are; the command decides in
its own step from what was read; a command with nothing read for it waits as before. Listed as
an owner decision: the question is answered from the targets' locality as read when the
targets last changed, not at the keypress.

## Verification

`CatalogWindowViewModelTrashTests`: a command whose targets were read hides in its own step; a
command made in the same step as a target change waits for its own read; cloud-only targets over
the threshold are asked about in the command's step with nothing hidden; a file evicted since
the reading moves without the question; a file downloaded since is still asked about.

## Not established

- The lane's read time at owner scale (a select-all of 166,000 items) was not measured.
- Nothing was verified on the installed app.
