# Freed memory stays in the footprint (macOS 27, 2026-11-16)

## Question

The owner's 200 s no-click survey on ece1ffe1 (with #837's `malloc_zone_pressure_relief` on
every `LoadAdmission` release) showed "Malloc Small (empty)" growing from 47 MB at +30 s to
566 MB at +60 s and 701 MB at the end, while live small and large malloc stayed at 409–470 MB
and 265–290 MB. Does `malloc_zone_pressure_relief` return freed pages on this OS at all, and
which frees leave memory in `phys_footprint`?

## Method

A C program (no Otos code) on the owner's Mac, macOS 27 beta, default allocator. For each
size it allocates 400 MB in blocks of that size, touches every byte, frees them (all, or all
but one in N), calls `malloc_zone_pressure_relief(NULL, 0)` — and, in a second build, on every
zone `malloc_get_all_zones` lists — and reads `phys_footprint` from `TASK_VM_INFO` after each
step. A last run maps 25 × 16 MB with `mmap`, touches and unmaps them, then does the same with
`malloc`/`free`. Also run with `MallocNanoZone=0` and `MallocXzone=0`.

## Results (MB of `phys_footprint`)

| Block size | Peak | After `free` | Relief returned | After relief |
| --- | --- | --- | --- | --- |
| 64 B | 452 | 213 | 0 | 213 |
| 200 B | 680 | 374 | 0 | 374 |
| 1,000 B | 789 | 261 | 0 | 261 |
| 4,000 B | 673 | 674 | 0 | 674 |
| 40,000 B | 1,167 | 1,167 | 0 | 1,167 |
| 128 KB | 402 | 402 | 0 | 402 |
| 1 MB | 604 | 604 | 0 | 604 |
| 16 MB | 1,005 | 1,005 | 0 | 1,005 |
| 200 B, one in 64 kept | 1,631 | 1,631 | 0 | 1,631 |

- `malloc_zone_pressure_relief` returned 0 bytes in every case, on the default zone and on
  every listed zone, and with either environment switch.
- Freed blocks of 4 KB and up stayed in the footprint entirely, 16 MB blocks included; the
  smallest sizes gave back about half. A later allocation reuses them (the 1 MB run after the
  128 KB run grew the footprint by 202 MB for 400 MB allocated).
- `mmap` then `munmap` of the same 400 MB: 401 MB touched, 1 MB after unmapping.

## Conclusion

On macOS 27 what a pass allocates with `malloc` and frees stays in the process's footprint
until the allocator reuses it; asking the allocator to give it back does nothing. So the rule
for People's transient work is not to free it but not to put it in the malloc heap:

- scratch matrices and buffers a pass needs only while it runs live in their own mapped
  regions, unmapped when the pass ends (`ScratchBuffer`, `Otos/Support/ScratchBuffer.swift`, whose
  guide states the rule for the whole app: a transient buffer of 4 KB or more that is freed
  before the process ends goes there);
- what a pass builds per face is a few flat arrays, not a small allocation per face
  (`PeopleFaces`, `Bests`), so the heap's peak, which the footprint keeps, stays small;
- `malloc_zone_pressure_relief` on `LoadAdmission` release (#837) is removed: it returns
  nothing.
