# The first search after the tower's warm-up (2026-11-17)

## Question

On the owner's library (installed 160a1997, launch tour), the first search took 1,466 ms to
its first results with the text tower already prepared. Was that the tower's first-inference
cost, its pages being read back in after an idle, or something else?

## Evidence

The session's own log, from the unified log, read only:

| time | line |
| --- | --- |
| 02:58:42.024 | `search.encoder phase=loaded ms=35` |
| 02:58:43.279 | `search.encoder phase=prepared ms=1290` (load plus the warm-up prediction) |
| 03:00:43.878 | `search.prepare phase=done admitted=false ms=158` (the intent to search) |
| 03:00:45.024 | `search.encode depth=asTyped first=true ms=1200 spellMs=68 parseMs=15` |
| 03:00:45.281 | the next query, `depth=asTyped ms=26` |

There is no `search.encoder phase=released` line, so the model was not let go under memory
pressure. The tower had already made its warm-up prediction two minutes earlier, so the 1.1 s
was spent in the **second** prediction of that loaded model. It was not first-inference cost.
The query came after an idle because the Duplicates step before it ran into its deadline. The
Mac had 91 MB free and 5.8 GB of swap in use. Vision's text reader (a child process) and
enrichment's hashing were running beside it.

A hosted probe (a test run once and not committed: CPU-only tower, this Mac, 530 MB free,
5.7 GB of swap in use) measured:

- prepare (load plus one warm-up): 823 ms
- the next three queries: 24, 18 and 18 ms
- after a 120 s idle: 44 ms
- the one after that: 22 ms

## Conclusion

- Preparing already ran one warm-up prediction (`SearchTextTower.prepare`). `op=search.encoder
  phase=prepared` now reports the load and the warm-up apart (`loadMs`, `warmUpMs`).
- An idle of two minutes alone does not reproduce the cost, even with comparable swap. What made
  the owner's second prediction take 1.1 s is **not established**. Candidates are page-out of
  the tower's pages under that session's pressure, or CPU contention with the text reader and
  hashing. The tour does not mark page-ins for a search step, so the session cannot tell them
  apart.
- So no rule that asks "is the tower prepared?" can say whether it will be quick. The reader now
  races the words reading with the tower's (ADR 0048). The first results wait on the words
  reading (about 20–160 ms), and on the tower only when the tower lands first.

## Sources

- `logs/tour-160a1997.log`, and the unified log of pid 87381, 02:58:30–03:01:10.
- The probe's `op=test.failure … PROBE …` line from `script/check.sh --only` (not committed).
