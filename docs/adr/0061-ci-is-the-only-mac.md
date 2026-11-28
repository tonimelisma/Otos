# ADR 0061: CI is the only Mac

- Status: Accepted
- Date: 2026-11-27

## Context

Releases happen from the cloud too, and CI is enough: development may run only in cloud
sessions for months, and nothing may be gated on a local environment (2026-11-26).
A cloud session runs in an Ubuntu VM with no Xcode, macOS or display, and never reaches a
Mac. Every fact that only a session on a Mac used to supply had to come from
somewhere else, or not be needed
(`docs/research/2026-11-26-ci-only-macos-development.md`).

## MECE Decision Scope

Owns: which Mac builds, tests, looks at and releases Otos, and what a local session on a
Mac adds. Defers: how CI's verification is built and held to its budget (ADR 0044); how a
release is published and installed (ADR 0059); what the installed app hands over (ADR 0060);
the weekly measurement (ADR 0043); the read-only rule for a user's data (ADR 0020).

## Decision

1. **GitHub's `xcode-27` runner is the Mac.** Each fact a session on the Mac supplied is a
   CI job whose evidence a cloud session reads: `op=` lines in the job log, JSON, and PNG
   artifacts made from generated media. Merging, releasing and the Definition Of Done need
   nothing else.
2. **The look is a capture walk.** Shard 3 of every full-tier run launches the dev build it
   tested, once per appearance, on a generated library whose photos fill every view, and
   captures the window in the library's grid, Places, On This Day, Duplicates and the Edit
   pane, light and dark (`script/app-capture.sh`, ADR 0044 item 20). People is not captured: generated photos
   hold no faces (2026-11-27).
3. **The release launches what it ships** and publishes nothing that does not reach its
   first window (ADR 0059 item 9).
4. **A suite can run many times on CI** (the workflow Repeat A Suite, ADR 0044 item 19), the
   cloud session's way to reproduce a failure that shows only sometimes.
5. **A local session on a Mac is optional, and nothing waits for it.** Started on the Mac
   itself, never reached from a cloud session, it may inspect the installed app read-only:
   its logs, the felt targets, profiling and lldb, and the weekly counts (ADR 0043). Otos
   tooling never writes to a user's library, catalog or installed-app settings; experiments
   that write use generated catalogs, and live checks on real data run only when the person
   running the session asks for them. It verifies through the same CI run, and it never
   installs: Sparkle is the only installer, so the installed app is always a build CI
   published.
6. **What a user's Mac experiences reaches a session only when the user hands it over**
   (Help ▸ Export Diagnostics…, ADR 0060). Nothing about the user's data goes to CI, a
   public artifact or a third-party service.

## Rejected alternatives

- **Reaching a Mac from a cloud session** (a remote shell into it). Ruled out
  (2026-11-26): a session on a Mac is one started there.
- **The weekly instruction counts on CI.** The runner's virtual Mac (`VirtualMac2,1`) reads
  zero instructions retired (run 45870604355); deterministic twin tests stay CI's
  performance gate.
- **One launch per captured view.** Ten launches would add an estimated minute to the shard
  that finishes last (two launches took 54 s, run 45922482801), and each exit is a
  chance for the VM's video driver to hold a process that cannot end
  (`docs/research/2026-11-27-a-capture-launch-stuck-in-the-vms-video-driver.md`).
- **One launch for both appearances.** Switching the appearance mid-launch left the
  toolbar's glass still animating when the next capture was taken (run 45947165362), and
  nothing reports that animation's end.
- **Self-hosted Mac runners.** They need a Mac someone keeps running and patched, which is
  the dependency this decision removes.

## Consequences

- A cloud session ships an app change end to end: CI verifies it, the session reads the
  captures, CI publishes the release, and the installed app updates itself.
- What needs real data (a look at a real library, the felt targets, the evaluations on
  private labelled sets, Core ML conversions from research repositories) is a non-blocking
  note in the final report, never a condition of done.
- A surface the walk cannot fill with generated media (People) is looked at only on the Mac.
