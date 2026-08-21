# 2026-08-21 — Unicode normalization is not a per-volume capability

## Question

`VolumeNamespaceCapabilities.prefersDecomposedUnicode` was modelled as a per-volume
fact and used by `FilesystemNamespaceSemantics.nameKey` to choose whether a
comparison key is decomposed or precomposed. It was never probed: every production
construction passed `true`. Plan 0098 asked whether to probe it for real or to
remove it.

## Method

`script/synthetic-card.sh create && attach` produced two image-backed volumes —
case-insensitive ExFAT at `/Volumes/OTOSPROBE` and case-sensitive APFS at
`/Volumes/OTOSPROBECS` — alongside the machine's own case-insensitive encrypted
APFS home. A Swift probe read `URLResourceValues` on each, wrote a file whose name
carried a **precomposed** `é` (NFC), read the directory back, and checked whether
the file could also be opened by the opposite normalization.

## Results

```
root=/Volumes/OTOSPROBE     caseSensitive=false casePreserved=true format=ExFAT
root=/Volumes/OTOSPROBECS   caseSensitive=true  casePreserved=true format=APFS (Case-sensitive)
root=/Users/<user>          caseSensitive=false casePreserved=true format=APFS (Encrypted)

root=/Volumes/OTOSPROBE     wroteNFC  readBackBytes=[101, 204, 129, 120]  opensByOppositeNormalization=true
root=/Volumes/OTOSPROBECS   wroteNFC  readBackBytes=[101, 204, 129, 120]  opensByOppositeNormalization=true
```

`[101, 204, 129, 120]` is `e` + `U+0301` + `x`: **decomposed**, on both volumes,
for a name written precomposed. Both volumes also opened the file by either
spelling.

(Both `storedIsNFD` and `storedIsNFC` reported `true` in the raw probe output.
That is not a contradiction and not evidence: Swift's `String ==` is canonical-
equivalence based, so a decomposed string compares equal to its precomposed form.
The UTF-8 bytes are the only ground truth here, which is why the probe printed
them. This is the same property that `FilesystemNameKey`'s byte-exact `==` exists
to defeat.)

## Conclusions

1. **Case sensitivity is a real per-volume fact.** The probe distinguishes ExFAT
   (false) from case-sensitive APFS (true) from case-insensitive APFS (false).
   `volumeSupportsCaseSensitiveNames` is kept.

2. **Normalization is not.** Through the Foundation APIs Otos uses, a
   non-normalizing filesystem (ExFAT) and APFS both hand back NFD and both resolve
   either spelling to the same file. There is no observable per-volume variation
   to probe.

3. **Modelling it per-volume was actively harmful, independent of (2).** A
   comparison key only has to satisfy one property: both sides of a comparison
   normalize the same way. *Which* form is arbitrary; consistency is everything.
   Making the form a per-volume variable introduced the possibility of two
   different keys for one path — and that possibility shipped. Plan 0097 left two
   disagreeing "unknown" values:

   | source | `prefersDecomposedUnicode` |
   |---|---|
   | `VolumeNamespaceCapabilities.unknown` | `true` |
   | a `library_root` row with NULL capability columns | `false` (read as `== 1`) |

   The same relative path therefore produced different `FilesystemNameKey`s
   depending on which value a caller happened to hold — invisible on ASCII paths,
   live on every accented filename.

## Decision

Remove `prefersDecomposedUnicode` from `VolumeNamespaceCapabilities` and drop its
persisted column. `nameKey` always decomposes, which is what every production
caller already asked for and what the v17 `relative_path_key` backfill wrote, so no
persisted key changes. `isCaseSensitive` remains the one probed capability, and
`isKnown` now derives from the one column that carries it.

Recorded in ADR 0025 (volume-aware path equality), which this supersedes in part.
