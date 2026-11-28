# Source-file disposition: prior art in gomediaimport

Date: 2026-08-19. Plan 0096, the erase-set decisions.

## Question

Otos's "Erase the card" deletes only plan entries whose disposition is
`.skipPreexisting` (`Otos/Services/MediaImportExecutor.swift:384`). That is a
*copy-side* fact — "this file is already in the library" — used as if it were a
*card-side* fact. Everything else on the card survives an erase, including
sidecar originals Otos just copied.

What should the erase set be? `github.com/tonimelisma/gomediaimport` (checked out
at `../gomediaimport`, 7,083 lines of Go) solves the same problem for the same
user with the same cards, and CLAUDE.md already cites its ignore set as the
source of Otos's own. What model does it use?

## Measured: gomediaimport's model

### Sidecars carry a three-way action

`cmd/gomediaimport/media_types.go:57-74`:

```go
type SidecarAction string
const ( SidecarIgnore SidecarAction = "ignore"
        SidecarCopy   SidecarAction = "copy"
        SidecarDelete SidecarAction = "delete" )

var sidecarDefaults = map[string]SidecarAction{
    "thm": SidecarDelete, "ctg": SidecarDelete, "xmp": SidecarCopy,
    "aae": SidecarDelete, "lrf": SidecarDelete, "srt": SidecarCopy,
    "mpl": SidecarDelete, "cpi": SidecarDelete,
}
```

`SidecarDelete` is the disposition Otos lacks: **not copied, but still removed
from the source.** A `.thm` is real card clutter with no value in a library, and
leaving it behind means the card is never actually clean.

Resolution order is override → built-in default → global default
(`getSidecarAction`), with `sidecar_default: delete` shipped in `config.yaml`.

### Deletion is keyed on status, and covers three of them

`cmd/gomediaimport/import.go:558`:

```go
if file.Status == StatusCopied || file.Status == StatusPreExisting || file.Status == StatusSidecarDeleted {
    os.Remove(sourcePath)
}
```

`StatusUnnamable` is deliberately excluded — a file the tool could not name is
never deleted. Unknown non-media, non-sidecar files are never even enumerated
(`file_operations.go:138`, "Skip non-media, non-sidecar files").

### Card debris is a separate, typed concept

`cmd/gomediaimport/file_operations.go:18-35` defines `sourceArtifactKind` with
four members, each carried on a `sourceCleanupTarget` so the summary can name
what it removed rather than reporting an opaque count:

| Kind | Matcher |
| --- | --- |
| `system trash` | top-level `.Trashes`, `.Trash`, `$RECYCLE.BIN`, `.Trash-*` (`isTopLevelTrashDir`) |
| `Sony thumbnail directory` | `M4ROOT/THMBNL`, `PRIVATE/M4ROOT/THMBNL` (`isSonyThumbnailDir`) |
| `Sony XML companion` | `M4ROOT/CLIP/*.xml`, `PRIVATE/M4ROOT/CLIP/*.xml` (`isSonyClipXML`) |
| `AppleDouble file` | `._*` |

`cleanupSourceArtifacts` (`import.go:587`) removes them only when
`--delete-originals` is set, and only after
`validateSourceCleanupTarget(sourceDir, target.Path)` proves the path is inside
the source tree.

### Four properties worth carrying over

1. **Deletion is path-validated before it happens.** Nothing outside the source
   root can be removed, even if a matcher misfires.
2. **Everything deleted is reported** — per file when verbose, plus a count and
   total bytes freed. Otos's equivalent path logs **only on failure**, so a
   successful erase of 265 files produces no log line at all.
3. **Conservative on the unknown.** Unknown non-media files and unnamable media
   are never touched.
4. **Path components are matched case-insensitively.** `isSonyThumbnailDir` and
   `isSonyClipXML` use `equalFoldComponents` / `strings.EqualFold`, and both
   spell out `M4ROOT/…` *and* `PRIVATE/M4ROOT/…`. gomediaimport already handles
   the exact `PRIVATE` ↔ `private` instability that produced plan 0096's D1 —
   independent corroboration, from prior art on the same hardware, that
   increment 2's fix is addressing a real filesystem property and not an
   Otos-only accounting error.

## Where Otos stands against it

| gomediaimport | Otos today |
| --- | --- |
| copied → delete source | ✅ `.copy` |
| pre-existing → delete source | ✅ `.skipPreexisting` |
| sidecar `copy` → delete source | ⚠️ copied, **source left on the card** (`deleteSourceIfRequested` deletes only `entry.source.sourceURL`, never `entry.companionDestinations`) |
| sidecar `delete` → delete, never copy | ❌ no such disposition; `MediaOperationDisposition` has only `copy`, `skipPreexisting`, `relocate`, `noOp`, `blocked` |
| source artifacts → delete | ❌ ARC-045 already names this exact set — Sony `M4ROOT/THMBNL`, `M4ROOT/CLIP/*.xml`, trash roots, `._*` — but as **ignore paths**, never as an erase set |
| unknown → leave | ✅ |
| path-validated deletion | ❓ unverified for Otos's `removeItem` path |
| deletion reported | ❌ error-only logging |

## Decisions, 2026-08-19

Recorded from a live decision session, and **simpler than gomediaimport's
model** — the per-extension action table collapses to one preference:

| Class on the card | Copied to library | Deleted on Erase |
| --- | --- | --- |
| Media | yes | yes |
| Media already in the library | no | yes |
| Zero-byte media (new `excluded` disposition) | no | yes |
| Useful sidecars `.xmp` / `.srt` | **only if "Copy sidecars" is on** | yes, either way |
| Cruft sidecars `.thm .ctg .aae .lrf .mpl .cpi` | no | yes |
| Source artifacts (`THMBNL`, `CLIP/*.xml`, `._*`, card trash) | no | yes |
| Unknown non-media | no | **no** |

- **Exactly one setting**, "Copy sidecars into the library". It governs
  *copying* only. There is no per-extension override table: gomediaimport is a
  CLI where a config file is the only surface, and Otos can change a default in
  a release.
- **Cruft deletion is never configurable** and happens only as part of an
  explicit Erase. If the sidecar setting is off, `.xmp`/`.srt` are simply
  reclassified as cruft — not copied, still deleted.
- **Erase stays permanent** (`removeItem`, not `trashItem`). The recoverability
  guarantee is the verified library copy that `eraseConfirmationProvenClean`
  already proves, not a `.Trashes` folder — and a Trash on the card would not
  free the space the user is erasing to reclaim. Note the one exception this
  leaves: a zero-byte file is *not* in the library, so its deletion is
  unrecoverable — of zero bytes, so nothing is lost, but the ADR must say so
  rather than leave the exception unstated.

**Assumption stated, not decided:** an orphan `.xmp` with no matching media file
on the card follows the same rule as a parented one — copied when the setting is
on, deleted on erase either way. This matches gomediaimport, which assigns
orphan sidecars a destination and copies them (`import.go:203-215`). If orphans
should instead be left alone, that is a one-line change to the classifier and
this assumption is where to revisit it.

## Sources

- `../gomediaimport` — `cmd/gomediaimport/media_types.go`, `file_operations.go`,
  `import.go`, `config.yaml`, `README.md`
- [github.com/tonimelisma/gomediaimport](https://github.com/tonimelisma/gomediaimport)
