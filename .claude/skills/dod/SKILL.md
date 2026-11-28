---
name: dod
description: Write Otos's one final Definition Of Done report for an increment — its required contents, the look at what shipped, and where it is posted. Use after the merge and cleanup, never before.
---

# The final report

There is one report per increment, written after the merge and cleanup, never before.

**Where it goes:** posted in full as one PR comment, in the order of CLAUDE.md's "Final
increment report", with the Definition of Done checklist. The chat gets a short summary and
the PR link.

**Format:** green and red status emoji, with plain-language text.

`script/dod-report.sh` generates the mechanical checklist. The report answers:

- what was done, and what was not;
- design decisions;
- requirement, ADR and doc changes;
- the requester's guidance this increment captured, restated so the requester can correct it;
- verification:
  - the Xcode version;
  - the CI run on the final commit;
  - the cloud or Mac `script/check.sh` result;
  - the measured durations against the budget (five minutes; six to nine for a Swift change);
  - the `op=perf.status` line;
- remote CI status, with exact waiver evidence if a job could not run;
- instrumentation and profiling evidence;
- code smells observed, addressed or accepted;
- the media-originals and diagnostics review;
- outstanding review comments claimed, and how each was fixed;
- risks and follow-ups, each filed as an issue, and non-blocking notes for the requester;
- the merge and cleanup steps completed;
- for an app change, the release `v<x.y.z>` that publishes it.

## The look

Tests prove the code; only a look proves what a user sees. On 2026-11-19 every check
was green while half of All Media's tiles were blank.

- **Before taking a capture, name what it should show.** Anything else is a finding:
  - a blank or placeholder tile, or a duplicate;
  - a wrong label, badge or count;
  - text clipped or overlapping;
  - a state that never settles;
  - a status that contradicts the logs.
- **A finding the increment caused** is fixed in this increment. One it did not cause is
  diagnosed from logs and catalog, then fixed.
- **From a cloud session:** read CI's captures of each view (the library's grid, Places, On This
  Day, Duplicates, the Edit pane), light and dark, on generated media, from the PR's final
  run (`ci` skill).
- **From a session on a Mac:** also build and look at the dev app on a generated library, and,
  read-only, at the installed app, as the `mac-session` skill says; name the release it shows.
- **The report says** which surfaces were looked at and what each showed.
