# Immich sync reset and new sessions (2026-11-13)

Research for ADR 0046 §5: what a sync stream lists after a reset, after a dropped resync, and
for a session that never synced. All facts are **source**, read on 2026-11-13 from Immich
`main` (`server/src/services/sync.service.ts`, `server/src/repositories/session.repository.ts`,
`server/src/schema/tables/session.table.ts`). Nothing here was measured against a live server.

## What the server does

- `POST /api/sync/stream` with `reset: true` calls `resetSyncProgress(session)` first: one
  transaction that sets the session's `isPendingSyncReset` to false and deletes every
  `session_sync_checkpoint` row of the session. The stream then continues as for any request.
- After that, the stream checks `isPendingSyncReset` and then `needsFullSync(checkpoints)`.
  Either one true sends a single `SyncResetV1` line and ends the response. After a
  `reset: true` both are false: the flag was just cleared, and with no checkpoints
  `needsFullSync` returns false. So a `reset: true` stream sends no `SyncResetV1`; it lists
  every entity from the start, as a stream with no cursor does.
- `needsFullSync` reads only the `SyncCompleteV1` checkpoint: none means false; otherwise true
  when the time encoded in its `updateId` is older than 30 days (`MAX_DAYS`).
- Acknowledging `SyncResetV1` (`POST /api/sync/ack`) calls the same `resetSyncProgress` and
  returns early, so other acks sent with it in that request are not stored.
- Every other ack stores the newest checkpoint per type, and the next stream without `reset`
  resumes after it.
- `session.isPendingSyncReset` is a boolean column, default `false`.

## Conclusions

1. A resync that drops after some of its batches were acknowledged resumes, on the next
   plain stream, after those batches. Only `reset: true` (or a fresh `SyncResetV1` that is
   then acknowledged) makes the next stream list from zero again. A client that treats a
   resumed stream as a full listing purges every row the acknowledged batches carried.
2. While a full resync is owed, every pass should send `reset: true`; such a stream answering
   `SyncResetV1` would be a server fault, not a reset Otos asked for.
3. A new session (a login) has no checkpoints and `isPendingSyncReset = false`, so it gets no
   `SyncResetV1`: its first stream lists from zero but nothing tells the client it is a full
   listing. Assets deleted while the client had no session are not reported to it as
   deletions unless their audit rows are still within retention, which this source does not
   show either way. A client that already holds rows has to treat a new session's first
   pass as a full resync itself.

## Sources

- https://github.com/immich-app/immich/blob/main/server/src/services/sync.service.ts
- https://github.com/immich-app/immich/blob/main/server/src/repositories/session.repository.ts
- https://github.com/immich-app/immich/blob/main/server/src/schema/tables/session.table.ts
