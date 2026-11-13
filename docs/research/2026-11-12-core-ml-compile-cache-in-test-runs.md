# Core ML's compile cache in parallel test runs

Date: 2026-11-12. macOS 27.0.1 (26A434), Xcode 27.2, MacBookPro18,3. Load averages 55–145
from several parallel `script/check.sh` runs. Measured with small command-line probes that
load a model or run Vision's text request, and with `check.sh --only SearchReadingTests`.

## Question

Why did `SearchReadingTests/textInAPictureIsRead` take 10–220 s and sometimes fail with
`e5rtError("e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options
call failed", 13)`, when the same read takes well under a second warm? And why did the test
runner's cache folder hold 37 GB?

## Findings

1. **Core ML compiles a model on first load into the process's Caches**
   (`~/Library/Caches/<process>/com.apple.e5rt.e5bundlecache/<OS build>/…`). Every test
   process shares the test runner's folder, `com.apple.dt.xctest.tool`.
2. **The compiled copy is keyed by the model's path exactly as given and by the file's
   identity.**
   - FocalNet loaded from one path: 222 ms and one entry, then 8 ms with no new entry.
   - The same bytes copied to a second path: 253 ms and a second entry.
   - A symlink to the first path: 152 ms and a third entry.
   - Touching the files made no new entry.
   - At one path, the same bytes deleted and copied back made a new entry (193 ms). Bytes
     changed in place made none (8 ms).

   So a model that stays put compiles once, and one that is copied anew compiles again
   even at the same path. The installed app is copied anew by every `script/install.sh`, and
   its own Caches gained a 248 MB or 352 MB SigLIP 2 copy on most installs: 91 entries, about
   3.7 GB, by 2026-11-12.
3. **A hit does not touch the entry.** A warm read left every entry's modification time as
   it was.
4. **The folder is pruned:**
   - every entry older than 2026-11-09 was an empty directory;
   - the folder shrank from 37 GB to 31 GB within hours;
   - it held 40 copies of one 352 MB model and 20 each of two others.

   Each checkout's build puts the models at its own path, so each added about 1.3 GB.
   `PhotoSearchIndexTests` also loaded SigLIP through a fresh temporary symlink on every run.
5. **Vision's text request compiles three models the same way.**
   - Cold, at load average 120–130: 82–121 s, on the CPU and on the default device alike.
   - Warm, in each later process: 0.2–0.4 s.

   In the test runner's folder these entries were rewritten on most runs, so most runs
   compiled them again. On a warm, untouched folder two back-to-back runs read in 0.38 s
   and 0.41 s with the entries unchanged.
6. **Moving the cache does not help.**
   - `CFFIXED_USER_HOME` moves where entries are written, but a later process did not find
     them (70 s, then 68 s).
   - A symlinked or cloned cache folder missed the same way.
   - `HOME` and `TMPDIR` do not move it.

## Conclusion

The failures follow from the folder's churn:

1. Per-checkout model copies fill the shared folder.
2. Pruning removes entries.
3. Vision's entries look old because hits never touch them, so they go too.
4. Each parallel check then compiles Vision's models at once, under load, for minutes, and
   some compiles fail.

Giving every checkout one path per model version stops the per-checkout copies, as long as
that copy is never replaced: it is published once and read-only. The installed app is left
to the platform. Each update compiles each model once more, and macOS prunes the folder.
Avoiding that would mean the app copying its models out of its bundle at run time, which no
measured user cost asks for; most of the 3.7 GB comes from development installs. Whether
pruning ever reaches Vision's entries again is not measured; with the copies gone, the
folder holds one compiled copy per model version.
