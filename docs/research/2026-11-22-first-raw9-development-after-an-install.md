# The first RAW9 development after an install

2026-11-22. macOS 27.0 (26A434), Xcode 27.2, MacBookPro18,3. Installed Otos at 4eb13c44,
read-only, on the owner's library. Command-line probes read one local ARW. Evidence tags:
[M] measured here, [V] verified in logs or files.

## Question

In the first session after `script/install.sh`, the first RAW9 development on the
background lane logged `op=render.still decoder=raw9 developMs=62208`. The developments
after it took 0.8–1.0 s. `op=render.rawResources phase=ready elapsedMs=0` came right
before it, so fetching Apple's camera support was not the cost. Why did it take 62 s?

## Findings

1. **It happens on the first launch after an install, not on every launch.**
   - First session after the install (pid 28654): the RAW's support was ready at 10:34:48,
     and its development finished at 10:35:47.922 [V].
   - Next session, same build (pid 30461): the first RAW9 development took 1,081 ms, and
     `search.encoder` loaded in 30 ms [V].
2. **It ended with the search encoder's Core ML compile.**
   - `op=search.encoder phase=loaded ms=43394` logged at 10:35:47.596, 0.33 s before the
     RAW's finish [V].
   - Between 10:35:46 and 10:35:51 the installed app's
     `~/Library/Caches/net.melisma.Otos/com.apple.e5rt.e5bundlecache/26A434/` gained three
     BNNS programs (343, 370 and 261 MB) and two ANE bundles [V].
   - One ANE bundle is RAW9's own Core ML program: a probe that only develops a RAW9 wrote
     the same bundle (`4CAECC91…5AEFE.bundle`) into its own cache [M]. Core Image compiles
     RAW9's network into the cache of the process that develops it, as Otos's own models are.
3. **An install makes every model compile again.**
   - The compiled copy is keyed by the model file's identity (research
     `2026-11-12-core-ml-compile-cache-in-test-runs.md`). Today's probe confirmed it again:
     the same bytes deleted and copied back to the same path made a new entry, while a
     touch or a relinked binary did not [M].
   - `script/install.sh` replaces the bundle, so the first launch recompiles everything.
   - The cache keeps one install's programs: 226 entries, one set per install since
     2026-11-12, all empty but today's 928 MB [V].
4. **The compile is fast with memory free and was slow at 10:35, under memory pressure.**
   - In a fresh probe, a cold compile of `SigLIP2Text` took 0.5–0.6 s, and a RAW9
     development beside it took 0.66–0.78 s [M].
   - In the app at 10:34–10:35: `freeMB` was 95–137, the compressor held 4.3–5.1 GB and swap
     4.6 GB, page-ins rose from 7,229 to 98,431 (about 1.4 GB), and Otos used 6.8 s of CPU
     in 45 s [V]. The process was mostly waiting, not computing.

## Unknown

Whether RAW9's ANE compile waited on the search model's compile (one compile at a time in
the process), or both were only starved by the memory pressure. The probes ran with memory
free and showed no wait. Recreating the pressure would mean filling the owner's memory, so
it was not tried.

## Conclusion

A first RAW9 development pays its Core ML compile once per install, beside every model
Otos loads. On a Mac with memory free that costs under a second; under memory pressure, on
2026-11-22, it cost a minute. An installed user pays it once per update; the owner pays it
on the first launch after each `script/install.sh`. Nothing in Otos holds the cache's key:
the compiled programs are Core ML's own, in the process's Caches (2026-11-16 research
`first-search-while-the-encoder-loads`). So there is no Otos change to make, and the
background lane's minute is not a user-facing wait. A RAW the user opens goes through the
interactive lane. If one waits like this, that is a new finding, measured with
`op=render.still lane=interactive`.
