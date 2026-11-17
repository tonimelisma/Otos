# ADR 0056: Transient and owner-scale buffers live in mapped memory, and a failed mapping traps

- Status: Accepted
- Date: 2026-11-16

## Context

On macOS 27 what `malloc` frees stays in the process's footprint until `malloc` reuses it:
freed blocks of 4 KB to 16 MB were all still counted after `free`, and
`malloc_zone_pressure_relief` returned nothing for any zone
(`docs/research/2026-11-16-freed-memory-stays-in-the-footprint.md`). A People pass that built a
few hundred megabytes of scratch and freed it, an order read whose array doubled as it grew,
and an intern table of path strings each left their freed blocks in the footprint
(`docs/research/2026-11-16-people-pass-heap.md`,
`docs/research/2026-11-16-shared-path-strings.md`).

Three owners keep memory outside the heap: `ScratchBuffer` (a pass's matrices and per-row
tables of a size known at the start), `MappedArrayBuilder` (an owner-scale result whose length
is learned while it is read) and `MediaAssetIdentityTable` (the process's asset identities,
never freed). Each mapped with its own `mmap` call and its own failure handling.

## MECE Decision Scope

This ADR owns where those buffers live, the one type that maps them, and what a failed mapping
does. It defers what each buffer holds to its owner's ADR (0005 the identity table and the
window's reads, 0047 People's scratch) and the memory a process reports to ADR 0015.

## Decision

- A transient buffer of 4 KB or more that is freed before the process ends, an owner-scale
  result whose length is learned while it is read, and the identity table's storage are mapped
  memory of their own. A region is unmapped when its owner lets it go, so the footprint goes
  back down when the work ends.
- `MappedMemory` is the one place that maps and unmaps anonymous memory. `ScratchBuffer`,
  `MappedArrayBuilder` and `MediaAssetIdentityTable` map through it.
- **A mapping that fails traps** (`op=mappedMemory.map phase=failed bytes= errno=`). `mmap` of
  private anonymous memory reserves address space only (`man 2 mmap`): pages are zero-filled
  on first touch and backed by the compressor and swap, so memory pressure never fails the
  call; there is no commit charge to run out of. It fails with `ENOMEM` when the address space
  or the process's map entries are exhausted, which is when `malloc` fails too, and Swift traps
  on every failed allocation of an array, a string or an object. A read that threw on a failed
  mapping would end at its next allocation, so it would add a path that cannot run.

## Rejected

- A throwing builder for the reads (the read fails, publishes nothing and stays owed, ADR
  0032 rule 4): it treats as transient a condition no allocation in the process survives, and
  makes every owner-scale read carry an error that is never recoverable.
- Each type mapping for itself: three copies of one rule, which drifted in their messages and
  rounding.

## Consequences

- A new owner of transient or owner-scale memory maps through `MappedMemory` and inherits the
  policy; a file mapping (`SearchVectorFile`, People's vector file) is a read of a file, not
  scratch, and keeps its own failure handling.
- The trap's line names the size asked for, so a crash report says which owner asked.
