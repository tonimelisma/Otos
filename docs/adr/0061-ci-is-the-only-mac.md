# ADR 0061: CI is the only Mac

- Status: Accepted
- Date: 2026-11-27

## Context

The owner (2026-11-26): "releases need to happen even from cloud. CI needs to be enough.
cloud dev might be the only way we do dev for months. we can't be gated on a local env."
A cloud session runs in an Ubuntu VM with no Xcode, macOS or display, and never reaches the
owner's Mac. Every fact that only a session on his Mac used to supply had to come from
somewhere else, or not be needed
(`docs/research/2026-11-26-ci-only-macos-development.md`).

## MECE Decision Scope

Owns: which Mac builds, tests, looks at and releases Otos, and what a session on the owner's
Mac adds. Defers: how CI's verification is built and held to its budget (ADR 0044); how a
release is published and installed (ADR 0059); what the installed app hands over (ADR 0060);
the weekly measurement (ADR 0043); the read-only rule for the owner's data (ADR 0020).

## Decision

1. **GitHub's `xcode-27` runner is the Mac.** Each fact a session on the Mac supplied is a
   CI job whose evidence a cloud session reads: `op=` lines in the job log, JSON, and PNG
   artifacts made from generated media. Merging, releasing and the Definition Of Done need
   nothing else.
2. **The look is a capture walk.** Shard 3 of every full-tier run launches the dev build it
   tested, once per appearance, on a generated library whose photos fill every view, and
   captures the window in the library's grid, Places, On This Day, Duplicates and the Edit
   pane, light and dark (`script/app-capture.sh`, ADR 0044 item 20). People is not captured: generated photos
   hold no faces (owner, 2026-11-27: "leave out faces").
3. **The release launches what it ships** and publishes nothing that does not reach its
   first window (ADR 0059 item 9).
4. **A suite can run many times on CI** (the workflow Repeat A Suite, ADR 0044 item 19), the
   cloud session's way to reproduce a failure that shows only sometimes.
5. **A session on the Mac is optional, and nothing waits for it.** Started from Claude Code
   on the Mac itself, never reached from a cloud session, it adds read-only looks at the
   owner's own data and app: his library, the installed app's logs, the felt targets, the
   evaluations on his data, profiling and lldb, and the weekly counts (ADR 0043). It
   verifies through the same CI run, and it never installs: Sparkle is the only installer,
   so the installed app is always a build CI published.
6. **What the owner's Mac experiences reaches a session only when he hands it over** (Help ▸
   Export Diagnostics…, ADR 0060). Nothing about his data goes to CI, a public artifact or
   a third-party service.

## Rejected alternatives

- **Reaching the owner's Mac from a cloud session** (a remote shell into it). The owner
  ruled it out (2026-11-26): a session on the Mac is one he starts there.
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
- **Self-hosted Mac runners.** They need a Mac the owner keeps running and patched, which is
  the dependency this decision removes.

## Consequences

- A cloud session ships an app change end to end: CI verifies it, the session reads the
  captures, CI publishes the release, and the installed app updates itself.
- What needs the owner's own data (the look at his library, the felt targets, the
  evaluations, Core ML conversions from his research repositories) is a non-blocking owner
  note in the final report, never a condition of done.
- A surface the walk cannot fill with generated media (People) is looked at only on the Mac.
