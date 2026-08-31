# 0101 — MediaMetadata: upstream brief for transport-independent reading

Upstream brief for `github.com/tonimelisma/MediaMetadata` (Otos pins 0.3.0). **This
document is written for the package, not for Otos.** Every item below states a property a
package consumer needs; the Otos story appears only as motivation. That is deliberate — see
"The rule this brief holds itself to".

Otos's use is one instance of the general case: reading capture metadata from bytes it has
not downloaded. Context and evidence:
`docs/research/removable-volume-and-camera-sources.md` (2026-08-30 section) and
`docs/plans/0100-mtp-import-staging-observability-and-progress.md`.

Measured against the 0.3.0 checkout and a 991-file corpus (Sony ILCE-6700: 464 ARW,
464 HIF, 63 MP4).

## The rule this brief holds itself to

> Every item must be justifiable to a second consumer who has never heard of Otos.

Not "would Otos benefit" — would a CLI `mediadate` tool, a Linux ingest service, or an
unrelated gallery app benefit. Each requirement below names that consumer. Anything whose
only justification is "Otos needs it" is not here; it is in plan 0100, on the Otos side of
the line.

This matters because the package has a real, verifiable independence today: **eight source
files, eight `import Foundation`, nothing else.** No ImageIO, no AVFoundation, no AppKit,
no third-party dependency; it builds on Linux. Every item below preserves that, and the
one item that could have broken it (R11) is shaped specifically so it does not.

## The boundary

`ARCHITECTURE.md` already states it, and these are its words:

> - Generate thumbnails.
> - Decide consumer policy such as which timestamp is trusted for library-path naming.
> - Depend on AppKit, SwiftUI, ImageIO, AVFoundation, or platform APIs in the core target.

Restated for this brief:

**The package owns "what do these bytes say, and what did it cost to find out?"** —
container indexes, where metadata lives, tag semantics, timestamp expression (offset,
precision, floating vs absolute), format identity, byte-range accounting, and the
definitive-vs-transient outcome. All derivable from bytes alone; none of it needs to know
who is asking.

**The consumer owns "which of those claims do I trust, and what did the bytes cost me?"** —
naming precedence, derivations, dedupe keys, transport lifecycle, sessions, retries,
deadlines, concurrency, thread policy, chunk sizing, persistence schema.

The seam is a byte range in, bytes out, plus an honest failure channel. Otos already
respects it — `CaptureWallClock` owns naming precedence (an explicit package non-goal) and
`MediaEnricher.map` owns the projection to Otos's schema — and nothing here changes that.

## Why the package is already close

The hard part is done. `ISOBMFFMetadataParser`, `TIFFMetadataParser`, `RIFFMetadataParser`
and `ID3MetadataParser` already work by *directed* reads against `FileByteSource`, and
`FileByteSource` is already a ranged-read abstraction with read metrics. Measured cost of a
parse:

| Format | read calls | bytes actually read | highest offset touched |
| --- | --- | --- | --- |
| HEIF (HIF) | 138 | 1,533 | 100,893 |
| TIFF (ARW) | 21 | 1,155 | 43,829 |
| ISO-BMFF (MP4) | 168 | 11,526 | end of file |

Roughly 1–12 KB per file. The blocker is that `FileByteSource` is a concrete `final class`
bound to `FileHandle`.

Worth noting how this reads in the package's own history: `ARCHITECTURE.md` describes layer
one as *"`ByteSource`: safe random-access reads over file handles **and in-memory data**"*.
The doc already specifies the abstraction; the code shipped only the file-handle half. R1
is the package finishing a layer it designed, not a consumer asking for a favour.

---

## R1 — Abstract the byte source behind a protocol

*Second consumer: anyone reading from memory, a zip entry, an HTTP range request, S3, a
cloud SDK, or a test harness.*

Every parser takes `source: FileByteSource` concretely. The surface actually used across
the package is `size`, `data(offset:length:)` and `close()` — verified by enumerating every
`source.` reference, not assumed. (`readMetricsSnapshot()` is deliberately absent here; see
R5.)

```swift
public protocol MediaByteSource {
    var size: UInt64 { get }
    func data(offset: UInt64, length: Int) throws -> Data?
    func close()
}
```

`FileByteSource` conforms. Parsers, `isISOBMFF`, `isoBoxProbe`, `jpegEXIFTIFFOffset` and
`extract` take the protocol. No parsing logic changes.

## R2 — Decouple the entry point from `URL`

*Second consumer: anything whose bytes have no file URL — a network stream has a MIME type,
a zip member has a name, an in-memory buffer has neither.*

`read(url:)` is the only public entry, and the `url` passed into parsers is used **solely**
for `url.pathExtension.lowercased()` (format identity hint and diagnostics) — it never opens
the file. Add:

```swift
public static func read(source: MediaByteSource, filenameHint: String? = nil) -> MediaMetadataResult
```

An earlier draft asked for `filename: String`. `filenameHint: String?` is the honest name:
it says the value is advisory (the package detects format from magic bytes anyway) and it
lets a consumer with no filename at all call the API without inventing one. `read(url:)`
keeps working and becomes a thin wrapper.

## R3 — Ship a caching byte source; let the consumer size it

*Second consumer: every remote consumer, without exception.*

An earlier draft of this brief asked the package for a caching decorator, then withdrew it
on the grounds that cache sizing is a transport property the package cannot see. That
withdrawal was half right and is **partly reversed here.**

The *number* is the consumer's: a useful chunk size differs per transport and only the
consumer knows the latency. But the *mechanism* — align the offset down to a chunk
boundary, fetch one chunk, serve slices from it — is completely generic and needs nothing
the package does not have. Splitting it the other way makes every remote consumer reinvent
the same decorator.

More to the point: **the need is manufactured by the package's own read pattern.** HEIF
costs 138 reads for 1,533 bytes inside a single 100 KB region; TIFF costs 21 reads for
1,155 bytes inside 44 KB. Those are ~11-byte scattered reads. A library that issues 138
tiny reads and tells remote consumers "your problem" is exporting an implementation detail
as a consumer burden. Two fixes, both package-side, and both are wanted:

1. **Coalesce reads inside the parsers** (an internal buffer over the current region). No
   API change, no consumer action, and it helps local-file consumers too.
2. **Ship the decorator:**

   ```swift
   public struct CachingByteSource: MediaByteSource {
       public init(wrapping source: MediaByteSource, chunkSize: Int)
   }
   ```

   Package owns the mechanism; consumer picks the number.

Measured read regions per parse, handed over as sizing guidance:

| Format | read calls | bytes read | distinct regions |
| --- | --- | --- | --- |
| HEIF | 138 | 1,533 | 1 — `0 … 100,893` |
| TIFF/ARW | 21 | 1,155 | 1 — `0 … 43,829` |
| ISO-BMFF/MP4 | 168 | 11,526 | 3 — `0 … 223`, `131,056 … 131,072`, `201,457,664 … EOF` |

For scale, on a transport with 42.6 ms median read latency the uncached HEIF pattern costs
~5.9 s per file; served from one cached chunk the same parse costs 91 ms.

## R4 — State the execution contract

*Second consumer: any consumer in a Swift 6 strict-concurrency codebase, which is
increasingly all of them.*

The package is entirely synchronous; a remote source's read is not. An earlier draft framed
this as a choice between making the API async (invasive, and it taxes every local-file
consumer to serve remote ones) and documenting that reads may block. The second is right,
but the important half was missing. State all three sentences in the README and on the
protocol:

> The parsing core is synchronous. A source may block the calling thread for the duration
> of a read; callers must run parses off the main actor and off any actor whose progress
> the read depends on. **A source is confined to a single `read(source:)` call: it must not
> escape that call, be stored, or be used concurrently.**

The third sentence is the load-bearing one and it costs nothing to write. It tells a strict-
concurrency consumer that the source never crosses an isolation boundary and therefore needs
no `Sendable` conformance — which is what lets such a consumer implement one without an
`@unchecked Sendable` escape. (Otos bans those outright via
`script/check-no-unchecked-sendable.sh`, ARC-042, but the question is general: today a
caller cannot tell from the API whether `read` may block or whether the source must be
`Sendable`, and both answers matter.)

Whether the package should eventually go async is a separate judgement for its owner. It is
the cleaner contract for remote transports and would remove the need for a consumer-side
blocking thread; it is also a large change that every local-file consumer pays for. Not
required here.

## R5 — Make read metrics public, and measure them in the package

*Second consumer: anyone paying per byte or per round trip — cloud egress, metered
connections, a vendor whose files unexpectedly need ten times the reads.*

`MediaMetadataReadMetrics` and `SourceReadMetrics` are internal, so a consumer cannot see
`readOperationCount`, `byteReadCount`, `uniqueByteReadCount` or `elapsedMilliseconds`.
Expose them on `MediaMetadataResult`.

**Change the plumbing while doing it.** An earlier draft kept `readMetricsSnapshot()` on the
source, which meant every custom conformance had to reimplement byte accounting — and any
consumer that skipped it got no metrics, defeating the purpose. The package already knows
every offset and length it requested, so it should do the counting: **wrap whatever source
it is given in an internal counting decorator.** That removes the awkward protocol member,
and makes metrics work identically for a file, a network range reader, or a test double.

## R6 — Three read outcomes, not two

*Second consumer: anyone whose transport can fail — which is everyone R1 is for.*

`FileByteSource.data(offset:length:)` returns `nil` when `length > size - offset`, and `nil`
on a short read. `ICCameraFile.requestReadDataAtOffset:length:` was measured behaving the
same way for a range crossing EOF, starting at EOF, and beyond EOF.

An earlier draft concluded from this that the contract could simply be documented: *"a fully
in-bounds range returns exactly `length` bytes; anything else returns nil."* **That is not
sufficient, and R6 and R7 collide if it stands.** `nil` is one channel carrying two facts —
"the file ends here" and "the bytes did not arrive" — and no parser above it can separate
them. The distinction is exactly what R7 needs.

So the contract needs three outcomes, and the honest shape uses the `throws` the signature
already has:

| Situation | Result |
| --- | --- |
| Fully in-bounds range, all bytes delivered | `Data` of exactly `length` |
| Range extends past `size` | `nil` — a structural fact about the file |
| Fully in-bounds range that did **not** deliver `length` bytes, for any reason | `throw` |

The third row is the new one, and it is not hypothetical. FB7663947 documents
`ICCameraFile.requestReadData` returning **empty `Data` with a nil error** — a failure
wearing the shape of a success. A source implementer who has only `nil` available has no
way to report it, and the consumer silently learns "this file has no metadata".

Document all three rows on the protocol so implementers do not each invent an answer.

## R7 — A failure must never be reported as definitive

*Second consumer: any consumer that caches the result. Recording "this file has no capture
date" when the truth is "the disk was unplugged" is corruption, and it is durable.*

State it as a package invariant:

> A read that could not be satisfied for reasons outside the file's own structure must
> never be reported as a definitive outcome.

**The mechanism does not exist today, and this is the item most likely to be mistaken for
already-done.** Verified against 0.3.0:

- Every one of the **19** `source.data(...)` call sites in the package uses `try?`
  (`ID3MetadataParser` ×3, `ISOBMFFMetadataParser` ×1, `RIFFMetadataParser` ×9,
  `TIFFMetadataParser` ×1, `MediaMetadata.swift` ×5). A thrown transport error is therefore
  discarded and becomes indistinguishable from `nil`.
- `ReadOutcome` is `.readFailure` **only** when some `ParserProvenance.status == .failed`
  (`MediaMetadataResult.swift:72-82`), and the only place that is set today is the
  `FileByteSource(url:)` init catch in `extract`.

So a mid-parse transport failure yields `.parsed` with empty timestamps — a definitive
"this file has no capture date". Two ways to fix it; the first is far smaller:

1. **Latch it on the source wrapper.** The counting decorator from R5 is already wrapping
   every source; have it record that a read threw, and have `extract` consult the latch
   before constructing the outcome. No parser logic changes.
2. Propagate throws through all 19 call sites. Correct, much larger, and it changes every
   parser's control flow.

*Motivation, for the issue body:* Otos keys retry on `ReadOutcome.shouldRetry` and treats a
definitive outcome as proof that no capture date exists, then names the file from its
filesystem mtime. That name is also the dedupe key, so a misclassified failure produces a
different name on the next plan, finds nothing at that path, and copies the file again —
the duplicate-import defect Otos already fixed once.

## R8 — Prove parser independence from read granularity

*Second consumer: everyone, indirectly — this is what makes R1 and R2 safe to rely on.*

Add tests that run the existing corpus through sources which deliberately satisfy reads in
different patterns from `FileByteSource` — byte-at-a-time, oversized chunks, chunk-aligned
via `CachingByteSource` — and assert byte-identical `MediaMetadataResult`s. Parsing must
depend on the bytes, never on how they arrived.

Add one more, for R6/R7: a source that throws at read *N* must yield `.readFailure` for
every parser family, at every *N*.

## R9 — Size comes from the source

*Second consumer: any source with no filesystem entry to stat.*

`FileByteSource` derives `size` from `URL.resourceValues(.fileSizeKey)`. The protocol takes
`size` as a property of the source. Follows directly from R1.

## R10 — Expose cheap format identification

*Second consumer: any tool triaging a directory of unknown files, or validating that a
stream is what its name claims before spending a full parse on it.*

```swift
public static func identify(source: MediaByteSource, filenameHint: String? = nil) -> MediaFormat
```

`isTIFF`, `isJPEG`, `isRIFF` and `isISOBMFF` already exist internally and the entry point
already reads 12 bytes to dispatch. This exposes that step without committing to a parse.

*Motivation:* Otos uses it as a transport capability gate — one 12-byte ranged read whose
returned family must be consistent with the item's extension, otherwise the device is
treated as not supporting ranged reads at all. Any consumer over an unreliable transport
wants the same cheap validation.

## R11 — Report embedded preview *locations* (never pixels)

*Second consumer: every RAW viewer, gallery, and DAM in existence. Extracting the embedded
JPEG from a RAW file is one of the most common things anyone does with these containers, and
today every one of them re-implements the IFD walk.*

The container declares where its previews are, and finding them is exactly the format
knowledge this package exists to own — the same argument that puts the TIFF walk here rather
than in a consumer. Measured on the corpus: Sony ARW IFD0 carries `PreviewOffset` 196,770 /
`PreviewLength` 292,799, extracting as a valid 1616×1080 JPEG, and IFD1 a 160×120 thumbnail;
HEIF yields a 256×170 embedded thumbnail from within the first 128 KB — the same bytes the
capture-wall read already fetches.

**Return a descriptor, not an image.** This is what keeps both stated non-goals intact
("generate thumbnails", "decode pixels") *and* keeps the Foundation-only dependency:

```swift
public struct EmbeddedPreview: Equatable, Sendable {
    public enum Encoding: Equatable, Sendable { case jpeg, heic, other(String) }
    public let byteOffset: UInt64
    public let byteLength: Int
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let encoding: Encoding
}
// on MediaMetadataResult:
public let previews: [EmbeddedPreview]   // largest first
```

The consumer reads that range through its own transport and decodes with whatever it likes —
ImageIO on Apple platforms, something else on Linux. The package never decodes, never
allocates a pixel buffer, and never links a graphics framework.

Note the reads a parse already performs usually cover the descriptor itself, so for most
containers this costs nothing beyond the parse.

## Non-requirements

- **No new parsers.** HEIF, TIFF/RAW, ISO-BMFF and RIFF are covered; the corpus parsed
  991/991 with the existing code.
- **No change to what is extracted.** `VideoInfo.durationSeconds` and
  `CaptureTimestamps.quickTimeCreation` already supply what is needed, including the
  `localWithOffset` / `localFloating` / `absolute` distinction.
- **No hashing, thumbnail generation, or pixel decoding.**
- **No naming, retry, deadline, concurrency, session, or caching *policy*.** R3 ships a
  cache *mechanism*; the number, and when to use it, stay with the consumer.
- **No new dependency.** The core target imports `Foundation` and nothing else, and this
  brief is shaped to keep that true.

## Acceptance

1. `read(source:filenameHint:)` produces results identical to `read(url:)` for the same file.
2. Read metrics are publicly readable from `MediaMetadataResult`, and are produced by the
   package for *any* source, including one that implements no accounting of its own (R5).
3. R8's granularity tests pass over the existing corpus, for every source pattern.
4. A source that throws mid-parse yields `.readFailure`, for every parser family, at every
   read index (R7). **This is the acceptance criterion the previous draft was missing**, and
   the one that makes R7 real rather than aspirational.
5. A fully in-bounds short read is distinguishable from an out-of-bounds range at the
   protocol level (R6).
6. `identify(source:)` returns the same `MediaFormat` a full parse would (R10).
7. `previews` are byte-exact: reading the declared range yields a decodable image of the
   declared dimensions, for every fixture that has one (R11).
8. `FileByteSource` and `read(url:)` behaviour is unchanged for existing consumers.

## How this is filed

These become issues in the package repository, phrased as above — the general property
first, the Otos story as motivation. Pre-1.0 the package's own `AGENTS.md` says a breaking
public-API change bumps the minor, so R1/R2/R5/R6 land as `0.4.0` and Otos moves its pin
deliberately.

Dependency direction is one-way and stays that way: the package never learns Otos exists.
No vendoring, no fork, no local path dependency — not even temporarily during integration.
Otos's integration work is plan 0100 (D1), which plans against a released tag rather than
against a promise.
