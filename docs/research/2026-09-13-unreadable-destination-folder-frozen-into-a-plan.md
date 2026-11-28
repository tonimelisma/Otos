# Research: an unreadable destination folder, frozen into a plan (2026-09-13)

The user imported 368 items from a card into a OneDrive library at 17:52, saw it
complete, and forty minutes later found the import bar reading `0 new items · 0 KB`,
`⚠ Otos couldn't check 368 names in Camera Roll`, with an enabled `Import 0 Items`
button — on the batch row that held all 368 items, safely in the library.

Evidence is the unified log for that instance (pid 84367,
`script/logs.sh show --last 100m`), read after the fact.

## Timeline

| time | event |
| --- | --- |
| 17:52:26 | run `83B5E84F` starts: 368 files, 43,202,672,420 bytes, 8 workers |
| 17:57:37.064 | `mediaOperation.batch phase=verified expectedPublished=368 storedBatchCount=368 failed=0` |
| 17:57:37.074 | Done drawn: `368 copied just now · 368 items in Camera Roll` |
| 17:57:37.184 | auto-eject fails: `op=catalog.removable.eject phase=error error=… fBsyErr: File is busy (delete)` — logged only |
| 17:57:37.256 | **`Ready · Import 368 Items` drawn** — the held *pre-run* plan, presented while the post-settlement rebuild ran |
| 17:57:37.614 | re-plan lands (`copyCount=0 skipCount=368`), Done again |
| 18:19:38 | `plan.namespace.enumerate … entries=0 folders=0 elapsedMs=1296` — `Camera Roll/2026/09` could not be listed |
| 18:19:41 | `import.plan phase=finish blockedCount=368 copyCount=0 namespaceEntries=0` — every item blocked `filesystemObservationUnavailable` |
| 18:19:41.989 | bar: `needsAttention primaryAction=importItems(count: 0) primaryEnabled=true` |
| 18:27:06 | same again (`entries=0 folders=0` in 20 ms) |
| ~18:40 | the folder lists 883 entries from the shell; the bar still shows the 18:27 plan |

## Findings

1. **The build was correct and the import is intact.** 368 published, 368 stored,
   nothing failed. The bar's later claims were about a plan, not about the batch.
2. **The folder's unreadability was momentary and its cause was swallowed.**
   `FilesystemNamespaceSemantics.enumerateNamespace` wrapped `contentsOfDirectory`
   in `try?`, so the log could not say why a folder that had just received 368
   files answered with an error for 1.3 s. A cloud provider mid-sync is the likely
   reader; the log now records the error domain and code per folder.
3. **A missing observation was promoted to a plan.** ADR 0019 correctly has the
   planner block every candidate in an unread folder — it must never plan an
   overwrite into a namespace it has not seen. But the coordinator then published
   that plan as Ready-with-attention, and ARC-047's hold-the-last-plan rule kept it
   on screen after the folder was readable again, until an unrelated wake. The
   planner's safety net became the presented truth.
4. **The act was a fabrication.** With every item blocked, `copyCount` was 0 and
   the bar drew an enabled `Import 0 Items` — a control whose subject does not
   exist (DES-053).
5. **The stale Ready between Done frames is real.** Observation 7 of the 2026-09-09
   research doc, "found reading, not observed live", was observed live at
   17:57:37.256: the coordinator dropped from `.completed` to `.building` inside
   one actor turn while still holding the pre-run plan.
6. **Auto-eject failed silently.** The card was busy with Otos's own enrichment
   readers when the post-import eject ran. Recorded in the 2026-09-09 research
   doc's closing observations; not fixed here.

## What changed

- `DestinationNamespace.unreadableFolders` records each folder that exists but
  could not be listed, with its error; `op=plan.namespace.enumerate phase=unreadable
  folder=… error=…` says so.
- `MediaOperationCoordinator` defers a build carrying an unreadable folder: phase
  back to `.inventory`, the last proven plan keeps presenting, a bounded backoff
  (1 s, 4 s, 16 s, 60 s) re-plans (`op=import.plan phase=deferred …`), and past
  the last delay the condition is the planning failure `destinationUnavailable`
  that `Try Again` or any planning wake clears. A plan blocked as "couldn't check"
  is never presented.
- A completed run drops the plan it executed from, and the settlement presents
  until the re-plan lands — no stale Ready between Done frames.
- State D offers no act when nothing is importable; suffix exhaustion is its own
  block reason with its own clause.

## Open

- Why OneDrive's File Provider refused the listing for 1.3 s is not established;
  the next occurrence will carry the error domain and code.
- The auto-eject race with Otos's own readers (finding 6).
