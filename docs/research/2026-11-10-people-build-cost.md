# People build cost (2026-11-10)

**Question.** People rebuilds after every catalog change while enrichment reads faces
(ADR 0047, `PeopleProjection`). Is that build expensive enough to matter, and which part
of it costs?

## Evidence

**The installed app on the test Mac, two hours of logs** (`script/logs.sh show --last 2h Catalog`,
`op=people.state phase=built`), 21:44–23:39 on 2026-11-10, while about 1,600 stills were
read for faces (807 → 1,482 faces; 14,027 → 12,446 stills unchecked):

| | builds | median | max |
| --- | --- | --- | --- |
| `readMs` (the snapshot read) | 1,453 | 469 ms | 4,144 ms |
| `groupMs` (`PeopleStateBuilder`) | 1,453 | 29 ms | 55 ms |

About one build every five seconds; 731 s of build time in the two hours, almost all of it
the read. 163 builds had the same counts as the build before.

**The read's SQL alone** on a read-only copy of that catalog (`sqlite3 .backup`, 19,447
assets, 1,484 faces), `.timer on`: the face join 6 ms, the unchecked count 27 ms, people
and rejections under 1 ms. So the read's cost was not SQLite.

**The benchmark** (`people.snapshot.10k`, `people.build.10k`; ADR 0043): the generated
15,000-still catalog with 10,000 faces, 1,000 named across 20 people, Debug build.

| case | before | after |
| --- | --- | --- |
| `people.snapshot.10k` | 60,543 M instructions, 3.6 s | 2,790 M instructions, 0.18 s |
| `people.build.10k` | 65,609 M instructions, 3.8 s | 7,882 M instructions, 0.57 s |
| `people.suggestions.10k` (grouping alone) | 9,654 M instructions, 0.64 s | unchanged |

## Cause

`FaceStorage.floats(from:)` decoded each embedding value by slicing the row's `Data`,
enumerating the four bytes and folding them with `reduce`: four allocating steps for
each of 512 values on each face, 5.1 million values at 10,000 faces, on every build.
`SearchEmbeddingStorage` read the same byte form with one `loadUnaligned` per value.

A temporary probe (decoding 10,000 stored embeddings alone) split the read after a first
fix that moved faces onto that `loadUnaligned` loop: the snapshot fell to 13,406 M
instructions, of which decoding was still 10,698 M, about 2,000 instructions per value in
the Debug build Otos installs. With one copy of the bytes, decoding is 73 M.

## Conclusion

Both now go through one `Float32Storage`. On a little-endian host, every Mac Otos runs
on, the stored form is the array's own memory, so encoding and decoding are one copy; a
big-endian host would swap each value. The build stays as it is: rebuilding only when
faces or people changed would save the 163 of 1,453 builds that repeated their counts,
while the read was the cost of every build. Grouping (`people.suggestions.10k`) is the larger remaining part, and is
measured on its own.
