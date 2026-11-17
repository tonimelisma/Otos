# Where Move to Trash puts a file: by volume, not by HOME

Date: 2026-11-16. macOS 27 beta, Xcode 27 beta. Question: a tour that runs Move to Trash and
Put Back in a sandbox home (`CFFIXED_USER_HOME` and `HOME` set to a folder of its own) — which
Trash do its files go to, and how can a tour be kept out of the account's own Trash?

## How Otos trashes

Otos has one Trash path: `MediaTrashCoordinator.FileOperations.live`, which calls
`FileManager.trashItem(at:resultingItemURL:)` and stores the resulting URL (ADR 0022). It
does not use `NSWorkspace.recycle`. Put Back is `FileManager.moveItem` from that stored URL.

## What Apple documents

`trashItem(at:resultingItemURL:)`: "Moves an item to the trash", and the resulting URL is
"the item's location in the trash"; the name may change. Nothing says which Trash. The
`FileManager.url(for: .trashDirectory, in: .userDomainMask, appropriateFor:create:)` lookup
takes a URL whose volume chooses the directory.

## Measured

A probe built from the worktree (a Swift executable calling the same APIs), run with
`CFFIXED_USER_HOME` and `HOME` set to a folder inside the worktree:

| Item | `url(for: .trashDirectory, appropriateFor:)` | `trashItem` result |
| --- | --- | --- |
| A file in the sandbox home, on the boot (Data) volume | the account's `~/.Trash` (the user database's home, not `HOME`) | not run: it would be the account's Trash |
| A file on an APFS disk image mounted *inside* the sandbox home (`diskutil image attach --mountOptions nobrowse --mountPoint`) | nil (no Trash on that volume yet, `create: true` included) | `<mount>/.Trashes/501/<name>`; the account's `~/.Trash/<name>` stayed absent |

An earlier tour measured the same from the app: with the sandbox home on the boot volume,
no `.Trash` appeared in the sandbox home, the trashed files went to the account's own Trash
and Put Back brought them out of it.

So `trashItem` keeps an item on its own volume. On the volume holding the account's home it
uses that account's `~/.Trash`, found from the user database, so `HOME` and
`CFFIXED_USER_HOME` do not move it. On any other volume it uses that volume's
`.Trashes/<uid>`, created on first use.

## Conclusion

- A sandbox home on the boot volume cannot keep a tour's Move to Trash out of the account's
  Trash. A tour cut short between Move to Trash and Put Back (the script quits a silent tour,
  or the app crashes) would leave generated files there.
- A library on a volume mounted inside the sandbox home trashes into that volume's own
  `.Trashes`, through exactly the call a user's Move to Trash makes; detaching the volume
  takes every trashed file with it. `script/sandbox-library.sh` makes that volume, and the
  tour runs its act steps only when every source's volume is mounted inside the sandbox home
  (`SmokeTour.trashStays`, which reads `URLResourceKey.volumeURLKey`).
- `url(for: .trashDirectory, appropriateFor:)` cannot be the tour's test: it answers nil on
  a volume whose Trash does not exist yet, where `trashItem` creates one. The volume's mount
  point is the fact that decides.
- Rejected: an injected tour-only Trash folder in `FileOperations` (a `moveItem` into the
  sandbox). It would time a move the user's Move to Trash never makes, against one user
  action, one implementation path.
- `hdiutil` and `diskutil` do not run inside the agent's sandbox; the scripts refuse there and
  no act step runs. Run unsandboxed or as a person.
