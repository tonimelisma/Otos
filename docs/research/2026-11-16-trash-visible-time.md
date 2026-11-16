# What Move to Trash's 515 ms held (2026-11-16)

## Question

The first sandbox tour that timed acts (#813) measured Like, Dislike and Not Rated at 22 to
23 ms from intent to the grid, and Move to Trash at 515 ms, against the 100 ms target for
"every act's result visible" (plan 0116). DES-119 says the tile leaves at once and the file
operation follows. Is the 515 ms the visible part or the file operation, and what holds it?

## Method

The dev build's own unified log for that session (a sandbox home, a generated library of 28
JPEGs, the screen locked), read line by line from the act's intent to its result. No other
data was read.

## Findings

| Time (ms after the intent) | Line | What it is |
| --- | --- | --- |
| 0 | `op=trash.move phase=start`, `op=ui.actToResult phase=start` | the intent; `hide` yielded on the Projection intent stream |
| 72 | `op=catalog.pendingTrash phase=mark` | the Store's mark, from the trash intent stream |
| 160 | `op=trash.queue phase=hidden` | the trash queue took the item |
| 187 | `op=mediaTrash.queue phase=trashed` | **the file is in the Trash** |
| 366 | `op=projection.hold phase=held hold=trash:…` | **Projection applies the hide** |
| 366 | `op=ui.state.apply … delta=-1` | the window's state without the item |
| 389 | `Media grid state received … actions=apply` | the grid has it |
| 515 | `Media grid structural apply started`, `op=ui.actToResult phase=finish` | the grid commits the removal |

- **The file operation finished first**, at 187 ms. The visible part is the slow one.
- **The hide waited 366 ms to reach Projection.** It was the sixth intent on the stream. Before it came two choice holds, two choice landings and their passes from the choice acts just before. Each intent was applied at the moment a main-thread state apply finished: 48.790, 48.864, 49.073, 49.213 and 49.282 s. They were spaced about 70 ms apart.
  - The consumer that forwards intents to Projection was a `Task {}` started in a `@MainActor` method, so it ran on the main actor.
  - Each `await projection.apply(intent)` returned to the main actor, and the next intent waited for the main thread's next turn.
  - In this Debug build a turn was about 70 ms of SwiftUI and grid work.
- **Then 149 ms from state to commit.** The grid's apply waited for a main-thread turn too: another state apply ran at +440 ms before the structural apply started.

## Change

- **Forwarder off the main actor.** The forwarder now runs off the main actor (`CatalogWindowViewModel.forwardProjectionIntents`, `@concurrent`), so an intent reaches Projection as soon as Projection is free.
  - `ProjectionIntentForwardingTests` holds the main thread after yielding a hide. It waits for Projection to publish the window without the item, which a main-bound consumer can never do.
- **Put Back is timed** (`op=ui.actToResult act=putBack`), from Undo to the grid showing the item again.
- **The scorecard reports both ends.** For Move to Trash and Put Back it now reports the visible result and the file work's end (`fileWorkDoneMs`) apart. The file work is matched by batch: `op=mediaTrash.queue phase=trashed batch=` and `op=mediaTrash.undo phase=finish batch=`.
- **The tour times each act on its own.** It waits for the previous choice to be written (`hasSettledMediaChoices`) before the next act.

Put Back's visible result follows the Store: Undo asks the queue to put the file back, and the items return when the withdrawal is read (APP-085). In the same session the Put Back's file work took 4 ms (`op=trash.undo phase=start` to `op=mediaTrash.undo phase=finish`), and the window's state with the item back was applied 6 ms after Undo. The grid commit was not timed: that build had no line for it.

## After the change (same sandbox, dev build, screen locked)

| Act | Before | After | File work done |
| --- | --- | --- | --- |
| Dislike / Like / Not Rated | 22 to 23 ms | 23 to 26 ms | – |
| Move to Trash | 515 ms | **225 ms** | 234 ms |
| Put Back (Undo) | not timed | **355 ms** | 86 ms |

- **The hold is no longer behind the main thread.** It now reaches Projection in the step of the intent (`op=projection.hold phase=held` in the same millisecond as `op=ui.actToResult phase=start`), and Projection publishes at once.
- **What remains is main-thread turns.** The window applied that state 82 ms later (`op=ui.state.apply … delta=-1`), and the grid committed the removal about 120 ms after that.
  - Both waited for the main thread's earlier turns, about 70 to 80 ms each in this Debug build, with the Info pane open.
  - What fills a turn is not in these lines; a Time Profiler trace of a sandbox tour names it. That is the next step for the 100 ms target.
- **Put Back's visible time waits on its file work first.** It reads the Store's withdrawal (APP-085), which landed after 86 ms. Then come the same main-thread turns.

## Not measured here

- **The main-thread turn itself.** It was about 70 ms in a Debug build, with the Info pane open. A Time Profiler trace of a sandbox tour would name it. This note does not.
- **The new timings.** The tour after this change measures them.
