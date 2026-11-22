# The first RAW9 development after an install

2026-11-22. macOS 27.0 (26A434), Xcode 27.2 (MacOSX27.2 SDK), MacBookPro18,3. Installed Otos
at 4eb13c44, read-only, on the owner's library. Command-line probes read one local ARW.
System logs were read with `log show` for `aned`, `ANECompilerService` and the processes
named below. Evidence tags: [M] measured here, [V] verified in logs, files or headers.

## Question

In the first session after `script/install.sh`, the first RAW9 development on the
background lane logged `op=render.still decoder=raw9 developMs=62208`. The developments
after it took 0.8–1.0 s. `op=render.rawResources phase=ready elapsedMs=0` came right
before it, so fetching Apple's resources was not the cost. Why did it take 62 s, and can
Otos remove it?

## Findings

1. **RAW9 runs a network on the Neural Engine, and a process needs it compiled.**
   - Core Image compiles RAW9's network into the developing process's Core ML cache
     (`~/Library/Caches/<process>/com.apple.e5rt.e5bundlecache/…/main_ane`). A probe that
     only develops a RAW9 wrote the same bundle (`4CAECC91…5AEFE.bundle`) that Otos wrote [M].
   - In a fresh process the first image costs about 0.85 s (`outputImage`), and 0.09 s once
     compiled [M].
   - Otos's entry for it dates from 2026-11-14. Its compiled files were rewritten at
     10:35:46 in the first session after the install, and not in the next session [V].
2. **macOS compiles one Neural Engine network at a time, for every app.**
   - At 10:34:48.35 Otos (pid 28654) asked `aned` for the RAW9 compile, and
     `ANECompilerService` took the request at QoS 17 [V].
   - The service was already compiling another network. That compile started at
     10:33:09.8 for `mediaanalysisd` (pid 68649, the system's photo-analysis daemon). It
     had mapped a 69 MB model at 10:32:53 and ran its text-processing tasks at QoS 17. The
     compile ended at 10:35:45.873, when `mediaanalysisd` dropped its connection [V].
   - Otos's compile started 236 ms later and took 0.83 s (10:35:46.109–10:35:46.941) [V].
     So the render waited 57 s in the queue and spent under a second compiling.
   - A probe reproduced the queue at 10:50: its request at QoS 25 waited 39 s behind a
     QoS 17 compile already running (10:50:23–10:51:04) [V].
3. **Inside Otos, Core ML started no other model while that compile waited.**
   - The search encoder's load was admitted at 10:35:04. Otos's Core ML logged nothing
     until 10:35:46.963, 22 ms after the RAW9 compile ended. Then it mapped the text model:
     126 KB, then 86 MB at 10:35:47.133 [V]. `op=search.encoder phase=loaded ms=43394`
     followed at 10:35:47.596.
   - The face model loaded after it (`op=face.model phase=loaded` at 10:35:49) [V].
   - With the system's compiler free, a probe compiled three cold models beside a RAW9
     development with no visible wait [M]: whatever holds Otos's other loads behind the
     RAW9 compile lasts only as long as that compile, under a second when the queue is free.
4. **Otos's own models also compile again after every install.** Their cached copies are
   keyed by the model file's identity, which `script/install.sh` replaces (research
   `2026-11-12-core-ml-compile-cache-in-test-runs.md`). They compile on the CPU (BNNS),
   not on the Neural Engine, in about 0.5 s each with memory free [M].
5. **The SDK offers no way around the queue.** `CIRAWFilter` has no compute-unit or
   priority option. The 27.2 SDK adds only
   `downloadAllResources(timeout:completionHandler:)`, which fetches "every on-demand
   demosaic/denoise model" [V]. `CIContextOption.priorityRequestLow` concerns GPU rendering
   [V].

## Conclusion

The minute is macOS's: RAW9's Neural Engine network needs compiling once per process
cache, and macOS's single Neural Engine compiler was busy for 2.5 minutes with the
photo-analysis daemon. Otos's own compile took 0.83 s. While it waited, Core ML in Otos
held the search and face models too.

Otos has no lever that removes this:
- it cannot reorder or preempt another app's compile;
- it cannot move RAW9 off the Neural Engine;
- a warm-up RAW9 development at launch would join the same queue.

Holding the first RAW9 development until Otos's own models load was rejected. It would
delay every first RAW to save a model load that is already fast whenever the system's
compiler is free, and it guesses at the queue's state rather than reading it. No Otos change.

The render was on the background lane; the photo kept its thumbnail. A RAW the user
opens in such a minute would wait on the same queue (`op=render.still lane=interactive`).
