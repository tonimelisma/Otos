---
paths:
  - "OtosKit/**/*.swift"
  - "OtosTests/**/*.swift"
---

# Reading media bytes, and MediaMetadata

## Byte reads never accidentally download

Most media lives in cloud-synced folders as possibly-dataless placeholders, whose name,
size, dates and type read without downloading. Reading the bytes downloads the file, so
byte-reading work must never *accidentally* materialize a file:
- A reader asks `MaterializationCoordinator` where the original is (`locality(of:)`:
  local, fetchable or unreachable).
- It fetches through `ensureLocal`.
- It re-checks the `FileMaterialization` detector immediately before reading.

The scanner reads only filesystem facts. `EnrichmentCoordinator` owns deliberate
background materialization, which may go as far as the whole library. Otos frees nothing
it downloads, and downloads never take a volume below the 5 GB floor (`FreeSpaceFloor`,
ADR 0027). See ADR 0008 and ADR 0009.

## MediaMetadata is ours

[MediaMetadata](https://github.com/tonimelisma/MediaMetadata) is Otos's own byte-parsing
library, with the same owner; Otos can change it in any way it needs (ADR 0039).

- **The library owns** every fact read from a file's bytes, and every rule about what that
  fact means:
  - format family and kind;
  - orientation and display geometry;
  - timestamp roles, and which one names or orders a file;
  - location sources;
  - codec identity;
  - `extractionRevision`.
- **Otos owns:**
  - persistence;
  - when to pay for bytes (never downloading for a parser fix);
  - the catalog's projections;
  - product policy such as no audio;
  - the platform decode facts it renders with.
- **Never build into Otos what belongs in the library.** That means no re-derived parsing
  rule, no copy of a library enum, and no per-fix migration. When Otos needs a fact the
  library lacks, the change goes into the library, is released, and Otos takes it by
  version bump. When the library is not changed in the same session, write the request
  for it.
- **Store what the library reports, as reported,** with its family's
  `extractionRevision(for:)` at the read. `MetadataRefresher` re-reads older records from
  local bytes only.
