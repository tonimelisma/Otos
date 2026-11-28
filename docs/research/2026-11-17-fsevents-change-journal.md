# A library's change journal: FSEvents history at launch (2026-11-17)

Supports ADR 0002, "Change Journal" and "Scan Update Cadence", and ARC-025/ARC-038 (plan 0116).

## Question

Every launch walked both fixed libraries in full: on the reference library 16,924 files in a
cloud-synced (File Provider) folder and 788 in a second, six batches that changed nothing and
still held the writer about 1.9 s, finished eight seconds after launch. Can a launch know,
without walking, that nothing under a root changed since the catalog last reflected it? And is
the walk what kept the provider's File Provider extension busy at launch?

## Sources

All statements below were read in the SDK header this repo builds against
(`MacOSX.sdk/…/FSEvents.framework/Headers/FSEvents.h`, Xcode 27.2), not from memory.

- `FSEventStreamGetLatestEventId`: "Clients can store this value persistently as long as they
  also store the UUID for the device (obtained via `FSEventsCopyUUIDForDevice()`) … This works
  because the FSEvents service stores events in a persistent, per-volume database."
- `FSEventsCopyUUIDForDevice`: a non-NULL UUID "uniquely identifies a given stream of FSEvents";
  a different one than stored means the stream is different "(for example, because FSEvents were
  purged, because the disk was erased, or because the event ID counter wrapped around back to
  zero)". NULL means historical events are not available, and only `SinceNow` may be passed. The
  UUID is stored on the device and travels with it.
- `FSEventStreamStart`: with a `sinceWhen`, historical events are sent first, then a
  `HistoryDone` event, then contemporary events.
- `kFSEventStreamEventFlagHistoryDone`: sentinel ending the historical events; its path is to be
  ignored. Not sent for `SinceNow`.
- `kFSEventStreamEventFlagMustScanSubDirs`: rescan the directory and all its children;
  `UserDropped`/`KernelDropped` accompany it when buffering failed and the whole watched tree
  must be rescanned.
- `kFSEventStreamEventFlagEventIdsWrapped`: previously issued IDs are no longer valid `sinceWhen`
  values.
- `kFSEventStreamEventFlagRootChanged` (with `WatchRoot`): a directory on the path to a watched
  root changed; the event ID is zero.
- `kFSEventStreamEventFlagMount` / `Unmount`: a volume mounted or unmounted under a watched path.
- `kFSEventStreamCreateFlagFullHistory`: delivers every event of the first historical chunk
  holding `sinceWhen`, so none near an unclean exit is skipped.
- `FSEventsGetCurrentEventId`: the most recent event ID system-wide.

## What the walk asks of the filesystem

`CatalogScanner` uses `FileManager.enumerator(at:includingPropertiesForKeys:options:)` with
`skipsHiddenFiles` and `skipsPackageDescendants`, prefetching eleven keys: regular file,
directory, symbolic link, package, hidden, name, creation date, content modification date, file
size, content type, file identifier. Each directory is listed once with its attributes; each
entry's values come from that listing (the content type from the name's extension). No
ubiquitous-item key (download status, downloading, uploaded), no tag, no extended attribute, no
byte is read. Each media file then ran four statements inside the writer's transaction (spelling
lookup, move-witness lookup, put-back update, upsert), which wrote no row when nothing changed:
the cost PR #891 removed.

## Is the walk what keeps the provider busy?

Observed on the test Mac: the provider's extension process starts with Otos (its elapsed
time equals Otos's on three launches) and runs at 80–90 % CPU for minutes; a sample shows it
serving XPC requests against its own SQLite store; Spotlight's indexer is busy at the same time.

What is proven: the walk lists every directory under the root at launch, through the same
kernel calls Finder's listing uses. What is not: that those listings are what the extension
serves. A listing of a directory the provider has already materialized is answered by the local
filesystem; one of a directory still dataless makes the system ask the provider to enumerate it.
Otos's other launch work also reaches the provider: enrichment's deliberate downloads and every
locality check before a byte read. This session could not drive a File Provider domain.

The test that separates them follows from this change: a launch whose journal vouches reads no
directory (`op=catalog.scan phase=skip reason=noChanges directoriesRead=0`). If the extension
still runs at that CPU on such a launch (`script/survey.sh` during the first minutes), the walk
was not its cause.

## Does FSEvents see a provider's changes?

The provider's daemon writes the domain's folder on the local volume like any process, and
FSEvents journals per volume from the kernel. The 2026-07-11 materialization
capture in this folder saw the provider's hydrations as file events
from another process; it also saw one hydration with no event in its window. What the catalog
needs from the journal is membership and the stored facts (name, size, dates). A download or an
eviction changes only `SF_DATALESS` and extended attributes, none of which the catalog stores;
locality is read on demand by `MaterializationCoordinator`, so neither needs a walk. Unproven: that
every remote create, rename and delete the provider applies reaches FSEvents' history. One that
did not would stay out of the catalog until the root's next walk.

## `FullHistory` delivers events before the start ID

Measured on this Mac (macOS 27): a folder with a subfolder and 50 files was written, and three
seconds later a stream was started at `FSEventsGetCurrentEventId()` on it. With
`kFSEventStreamCreateFlagFullHistory` it delivered 103 events, every one with an ID below the
start, the folder's own creation (`ItemCreated | ItemIsDir` at the watched path) first, then
`HistoryDone`; without the flag it delivered none. This is the header's "all the events in the
first chunk of historical events that contains the sinceWhen id".

So a stream started from an ID re-delivers part of what came before it. Seen on a 160,002-file
sandbox library added a minute after it was written: the first walk (76–79 s) was followed by a
second full walk with `reason=events` (20–22.5 s, no row written), made by the root folder's own
creation event from that chunk. Events at or before the start ID are therefore dropped by ID:
the catalog already reflects them (the stored position, or the walk that started after the
probe).

## Conclusions

- Store per fixed root `{volume event-database UUID, last applied event ID, root inode}`; replay
  since it at launch; walk only when the UUID, the inode or the ID's place in the stream says the
  journal cannot vouch, or when a replayed event says it lost track.
- Start a walking root's stream at the ID probed before the walk, so the walk and the stream
  together miss nothing, and drop what the stream delivers at or before its start ID.
- Store a newer position only after every delivered event is applied and no walk is owed.
- A network or read-only volume without a UUID keeps today's walk at every launch.
