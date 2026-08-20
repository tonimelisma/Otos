# Volume Path Equality Research

Date: 2026-08-20. Plan 0096, increments 1–3.

The implementation uses the volumeSupportsCaseSensitiveNames resource fact and
the existing FilesystemNamespaceSemantics.nameKey owner. The local internal
volume reports case-insensitive, case-preserved names. The removable card, SMB,
DMG, and exFAT qualification fixtures were not mounted during this pass;
docs/research/2026-08-19-removable-volume-qualification.md records the same
hardware limitation. Unknown roots use the documented conservative
case-insensitive/precomposed fallback until a live probe is available.

The targeted path probe also confirmed that resolvingSymlinksInPath() is not a
case-folding operation and can rewrite /private/... to /.... Catalog relative
paths therefore use standardizedFileURL after the root has already been
normalized at registration.

Decision: FilesystemNameKey is the only equality owner. Catalog identity remains
the display spelling in relative_path; the folded key is an equality index and
never a durable identity or content fingerprint.
