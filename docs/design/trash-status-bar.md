# Trash status bar

The surface that reports the Move to Trash queue (DES-089). Items the user moved to
the Trash disappear from Otos at once; this bar is how Otos says the work behind them
is still happening, typically while cloud-only files download so they can go to the
system Trash and stay recoverable.

## L1 primary fact

How many items are on their way to the Trash, or what they are waiting for.

## Placement

Bottom of the content pane, below the selected source's own status surface (the import
bar), in every sidebar scope. It belongs to no selection (DES-040's exception). It is
drawn only while at least one item is pending, and removed when the queue drains.

## Zones and height

Two zones at one fixed height across every state (DES-018, DES-053):

| Zone | Content |
| --- | --- |
| What | L1 (`title3`, semibold) over L3 (`subheadline`); an orange attention badge before L1 when the queue needs attention |
| Progress | Working only: a small determinate linear indicator with `M of N` beside it; blank space otherwise |

No buttons. The queue's questions arrive as alerts (`Delete … Immediately?`), and
withdrawing a Move to Trash is ⌘Z.

## States

| State (DES-030) | L1 | L3 | Progress |
| --- | --- | --- | --- |
| Working | `Moving 14 items to the Trash` | `340 MB to download`, or nothing when all are local | `3 of 14` |
| Needs attention: floor | `Waiting for free space` | `14 items waiting to move to the Trash` | none |
| Needs attention: provider | `Waiting to download` | `14 items waiting to move to the Trash` | none |

Counts restart when the queue drains: `N` is the items moved since the bar appeared
plus those still pending. Bytes are the catalog sizes of members still cloud-only,
formatted like the import bar (`ImportBarByteFormat`). No percentage is synthesized.

## Prompts

| Trigger | Title | Message | Buttons |
| --- | --- | --- | --- |
| A download is definitively refused | `Delete 2 Items Immediately?` / `Delete “IMG_1.MOV” Immediately?` | `They couldn’t be downloaded, so they can’t be moved to the Trash. You can’t undo this.` | `Delete` (destructive), `Cancel` (default) |
| A download would leave less than 5 GB free | same | `There isn’t enough free space to download them so they can be moved to the Trash. You can’t undo this.` | same |

`Delete` is destructive-styled because the user never chose permanent deletion; it is
not the default, so Return cannot trigger it. Questions of the same kind merge while
one is waiting.

## Accessibility

L1 is a header; the progress zone reads as one element with its value. The bar adds no
Tab stop. With Reduce Motion the indicator's value change uses a 0.1 s linear step.
