#!/usr/bin/env python3
"""The scorecard: what one Otos session felt like, read from the unified log (ADR 0015).

Reads `log show --style ndjson` events of one session and prints the user-felt numbers with
their attribution: launch, every click to paint, store stalls and who held the connections,
background work, memory, resources, the tour's steps and the idle window. Every number is
read from a line the app logged; a number no line carries is listed under "not measured",
never estimated. It is a report, not a gate: it always exits 0 once it has read its input.

Used by script/scorecard.sh; `scorecard_test.py` pins the parser with synthetic lines.
"""

import argparse
import datetime as dt
import json
import re
import sys

WINDOW_READS = {
    "orderedAssetIDs", "filterOptions", "importBatches", "catalogedCount", "visibleCount",
    "mediaTileDetails", "mediaTileDetail", "metadata", "photoInfo",
}

SCOPE_KINDS = [
    ("allMedia", "all media"), ("allImports", "imports"), ("importBatch", "import"),
    ("library", "library"), ("person", "person"), ("people", "people"), ("places", "places"),
    ("mapArea", "map area"), ("mapStack", "map stack"), ("onThisDay", "on this day"),
    ("duplicateGroup", "duplicate group"), ("duplicates", "duplicates"),
]

# A paint during which the process took at least this many page-ins (faults served from disk:
# memory the system pushed out, read back) is marked `pagedIn=<n>`, so a reader can tell the
# machine paging the process back in from a wait of Otos's own. A warm paint takes next to
# none. The mark is a fact beside the number; it never changes a verdict.
PAGED_IN_MIN = 100

HOLDER = re.compile(r"^(?P<conn>[a-z]+\.[a-z]+(?:\.\d+)?):(?:held(?P<held>\d+)ms-endedAgo\d+ms|txn(?P<txn>\d+)ms):(?P<op>[^:]+)")


# ── Parsing ─────────────────────────────────────────────────────────────────────

def parse_fields(message):
    """`op=a phase=b k=v …` as a dict. A value may hold spaces (`String(describing:)` of a
    scope); a token that does not start a new `key=` continues the value before it."""
    fields = {}
    key = None
    for token in message.split(" "):
        match = re.match(r"^([A-Za-z][A-Za-z0-9_.]*)=(.*)$", token)
        if match:
            key = match.group(1)
            fields[key] = match.group(2)
        elif key is not None:
            fields[key] += " " + token
    return fields


def parse_time(stamp):
    # `2026-11-15 21:56:36.040171-0800`
    return dt.datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S.%f%z")


class Event:
    __slots__ = ("time", "op", "phase", "fields", "pid", "image", "message", "level")

    def __init__(self, raw):
        self.message = raw.get("eventMessage", "")
        self.fields = parse_fields(self.message)
        self.op = self.fields.get("op")
        self.phase = self.fields.get("phase")
        self.time = parse_time(raw["timestamp"])
        self.pid = raw.get("processID")
        self.image = raw.get("processImagePath", "")
        # `log show`'s `messageType` (Debug, Info, Default, Error, Fault); the live capture's
        # entries carry none.
        self.level = raw.get("messageType")

    def num(self, key, default=None):
        value = self.fields.get(key)
        try:
            return int(value)
        except (TypeError, ValueError):
            return default


def read_events(lines):
    events = []
    for line in lines:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            raw = json.loads(line)
        except json.JSONDecodeError:
            continue
        if "eventMessage" not in raw or "timestamp" not in raw:
            continue
        events.append(Event(raw))
    events.sort(key=lambda e: e.time)
    return events


# `log stream --style compact`: `2026-11-17 07:43:18.178 Df Otos[86247:232e519] [sub:Cat] message`.
COMPACT_LINE = re.compile(
    r"^(?P<stamp>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+) +\S+ +(?P<process>.+?)\[(?P<pid>\d+):[0-9a-f]+\] +"
    r"(?:\[[^\]]*\] +)?(?P<message>.*)$")
# What `log stream` writes in place of messages it could not deliver in time. It names no
# count: one notice is one or more lost messages.
DROP_NOTICE = "=== Messages dropped during live streaming"


def read_live_capture(lines, image):
    """A tour's live capture (`log stream --style compact`, script/scorecard.sh) as events,
    with the number of drop notices the stream wrote. Every line comes from the one executable
    the script toured (`image`), which compact style does not print. A line that starts no
    entry continues the message before it; the stream's own header lines are skipped. Times
    are this Mac's local time, as `log stream` prints them."""
    raws = []
    drops = 0
    for line in lines:
        line = line.rstrip("\n")
        if line.startswith(DROP_NOTICE):
            drops += 1
            continue
        match = COMPACT_LINE.match(line)
        if not match:
            if raws and line and not line.startswith(("Filtering the log data", "Timestamp ")):
                raws[-1]["eventMessage"] += "\n" + line
            continue
        stamp = dt.datetime.strptime(match.group("stamp"), "%Y-%m-%d %H:%M:%S.%f").astimezone()
        raws.append({
            "timestamp": stamp.strftime("%Y-%m-%d %H:%M:%S.%f%z"),
            "eventMessage": match.group("message"),
            "processID": int(match.group("pid")),
            "processImagePath": image if match.group("process") == image.rsplit("/", 1)[-1] else "",
        })
    events = [Event(raw) for raw in raws]
    events.sort(key=lambda e: e.time)
    return events, drops


def capture_summary(source, session_lines, drops=None, ended=None, log_show_lines=None, log_show_only=None):
    """What the scorecard read and whether it is the whole session: `live` (the tour's live
    capture, with its drop notices, whether its end marker came through, and how many of the
    lines `log show` still held for the session the capture lacks) or `logShow` (the log's
    store, which rotates a busy session's lines out: what it lost cannot be counted)."""
    if source == "live":
        complete = drops == 0 and ended == "seen" and not log_show_only
    else:
        complete = None
    return {"source": source, "lines": session_lines, "dropped": drops, "end": ended,
            "logShowLines": log_show_lines, "logShowOnly": log_show_only, "complete": complete}


def live_comparable(events, pid):
    """The session's `log show` lines a live capture at info level is to hold: its process's
    lines from its `op=sessionStart` on, as the capture's session is read, and not debug, which
    the capture does not ask for."""
    found = [body for start, body in sessions(events) if start.pid == pid]
    body = found[-1] if found else [e for e in events if e.pid == pid]
    return [e for e in body if e.level != "Debug"]


def missing_from_capture(log_show_events, captured):
    """How many of `log show`'s lines the live capture lacks, matched by message (each
    message counted as often as it was logged). Not by time: a stream stamps every entry a
    constant few tens of milliseconds apart from the store's stamp for it. Each one is a line
    the stream lost without a notice."""
    held = {}
    for event in captured:
        held[event.message] = held.get(event.message, 0) + 1
    missing = 0
    for event in log_show_events:
        if held.get(event.message, 0) > 0:
            held[event.message] -= 1
        else:
            missing += 1
    return missing


def is_installed(event):
    return event.image.startswith("/Applications/")


def sessions(events):
    """Each `op=sessionStart` and the events of its process after it."""
    found = []
    for event in events:
        if event.op == "sessionStart":
            found.append(event)
    result = []
    for index, start in enumerate(found):
        later = [s for s in found[index + 1:] if s.pid == start.pid]
        end = later[0].time if later else None
        body = [e for e in events if e.pid == start.pid and e.time >= start.time and (end is None or e.time < end)]
        result.append((start, body))
    return result


def pick_session(events, installed=True, session_id=None):
    candidates = [(s, b) for s, b in sessions(events) if is_installed(s) == installed or not s.image]
    if session_id:
        candidates = [(s, b) for s, b in candidates if s.fields.get("session") == session_id]
    return candidates[-1] if candidates else (None, events)


# ── Analysis ────────────────────────────────────────────────────────────────────

def scope_kind(scope):
    for prefix, kind in SCOPE_KINDS:
        if scope == prefix or scope.startswith(prefix + ":") or scope.startswith(prefix + "("):
            return kind
    return scope.split(":")[0]


def ms_since(start, event):
    return int((event.time - start).total_seconds() * 1000)


def of(events, op, phase=None):
    return [e for e in events if e.op == op and (phase is None or e.phase == phase)]


def first(events, op, phase=None, after=None, where=None):
    for e in events:
        if e.op == op and (phase is None or e.phase == phase) and (after is None or e.time >= after) and (where is None or where(e)):
            return e
    return None


def launch(start, events):
    attached = first(events, "window.attached")
    opened = first(events, "catalog.database.open", "finish")
    started = first(events, "catalog.start", "finish")
    grid = first(events, "launch.firstGrid", "applied")
    # When every background owner first owed nothing, from the launch (`op=owners.quiescent`).
    quiet = first(events, "owners.quiescent", "reached")
    return {
        "windowAttachedMs": ms_since(start.time, attached) if attached else None,
        "databaseOpenMs": opened.num("ms") if opened else None,
        "databaseMigrations": opened.num("migrations") if opened else None,
        "catalogOpenAtMs": ms_since(start.time, started) if started else None,
        "catalogMigrationsMs": started.num("migrationsMs") if started else None,
        "firstGridMs": grid.num("ms") if grid else None,
        "firstGridCatalogMs": grid.num("catalogMs") if grid else None,
        "scope": grid.fields.get("scope") if grid else None,
        "scopeKind": scope_kind(grid.fields.get("scope", "")) if grid else None,
        "items": grid.num("items") if grid else None,
        "ownersQuiescentMs": quiet.num("ms") if quiet else None,
        # When the launch first reached each stage of its settlement (`op=owners.settled`).
        "settledMs": {e.phase: e.num("ms") for e in of(events, "owners.settled")},
        # Which owners were still working their backlog when each stage was reached (`backlog=`:
        # owner names, `none`); a build older than the field reports no entry.
        "settledBacklog": {e.phase: [] if e.fields["backlog"] == "none" else e.fields["backlog"].split(",")
                           for e in of(events, "owners.settled") if "backlog" in e.fields},
    }


def checkpoint(samples, index, scope):
    """The `index`-th usage sample of a paint checkpoint, when it names the same scope. The
    app writes one `paintStart` per intent's start line and one `paint` per finish line, from
    one serial queue, so the n-th sample is the n-th line's; a sample naming another scope
    (a capture that began mid-session) is not that line's."""
    if index >= len(samples):
        return None
    sample = samples[index]
    named = sample.fields.get("scope")
    return sample if named is None or named == scope else None


def clicks(events, launch_scope, idle_end=None):
    """Every sidebarSelectionToPaint start, with its end and what happened between. A return
    that starts after the tour's idle window (its restore of the launch scope) is a
    `returnAfterIdle`, never a warm `return`: the idle window may have let the system page
    the process out."""
    seen = {launch_scope} if launch_scope else set()
    result = []
    starts = of(events, "ui.sidebarSelectionToPaint", "start")
    finishes = of(events, "ui.sidebarSelectionToPaint", "finish")
    usages = of(events, "process.usage")
    start_samples = [e for e in usages if e.fields.get("event") == "paintStart"]
    paint_samples = [e for e in usages if e.fields.get("event") == "paint"]
    for index, start in enumerate(starts):
        scope = start.fields.get("scope", "")
        end = first(events, "ui.sidebarSelectionToPaint", after=start.time,
                    where=lambda e, s=scope: e.phase in ("finish", "abandoned") and e.fields.get("scope") == s)
        if scope not in seen:
            visit = "first"
        elif idle_end is not None and start.time >= idle_end.time:
            visit = "returnAfterIdle"
        else:
            visit = "return"
        click = {
            "at": start.time.isoformat(),
            "scope": scope,
            "kind": scope_kind(scope),
            "first": visit == "first",
            "visit": visit,
            "outcome": "pending" if end is None else ("painted" if end.phase == "finish" else "abandoned"),
            "ms": end.num("ms") if end else None,
        }
        seen.add(scope)
        if end is not None and end.phase == "abandoned":
            click["supersededBy"] = end.fields.get("supersededBy")
        # What the process paid from the intent to its paint: the checkpoints at both ends.
        usage = None
        if end is not None and end.phase == "finish":
            usage = usage_delta(checkpoint(start_samples, index, scope),
                                checkpoint(paint_samples, finishes.index(end), scope))
        click["usage"] = usage
        page_ins = (usage or {}).get("pageIns")
        if page_ins is not None and page_ins >= PAGED_IN_MIN:
            click["pagedIn"] = page_ins
        window = [e for e in events if e.time >= start.time and (end is None or e.time <= end.time)]
        publish = first(window, "projection.publish", "start", where=lambda e: scope_matches(e.fields.get("scope", ""), scope))
        if publish:
            click["beforeBuildMs"] = ms_since(start.time, publish)
        orders = [e for e in window if e.op == "catalog.store.query.order" and e.phase == "finish"
                  and ("scope=" + scope) in e.message]
        if orders:
            order = orders[-1]
            click["order"] = {k: order.num(k) for k in ("queryMs", "waitMs", "execMs", "lockMs", "stackReadMs",
                                                        "stackRuleMs", "orderSqlMs", "mapMs", "count")
                              if order.num(k) is not None}
            click["order"]["stacks"] = order.fields.get("stacks")
        stalls = [e for e in window if e.op == "catalog.store.stall"]
        waits = [e.num("connectionMs", 0) for e in stalls if e.fields.get("operation") in WINDOW_READS]
        click["windowReadStalls"] = len(waits)
        if waits:
            click["worstWindowReadConnectionMs"] = max(waits)
        options = first(events, "catalog.store.query.filterOptions", "finish", after=start.time,
                        where=lambda e: e.fields.get("row") == scope)
        if options:
            click["filterOptions"] = {"waitMs": options.num("waitMs"), "execMs": options.num("execMs"),
                                      "afterPaint": end is not None and options.time > end.time}
        built = first(window, "catalog.projection.window", "finish",
                      where=lambda e: e.fields.get("resolvedSidebarSelection") == scope)
        if built:
            click["publish"] = {k: built.num(k) for k in ("totalMs", "assetOrderQueryMs", "collapseMs", "equalityUs", "filterOptionsMs")}
            applied = first(window, "ui.state.apply", "finish", after=built.time)
            if applied:
                click["stateApplyMs"] = applied.num("applyMs")
        until = end.time + dt.timedelta(seconds=1) if end else None
        grid = first(events, "ui.mediaGrid.structuralApply", "finish", after=start.time,
                     where=lambda e: e.fields.get("scope") == scope and (until is None or e.time <= until))
        if grid:
            click["gridApply"] = {k: grid.num(k) for k in ("commitMs", "totalMs")}
        result.append(click)
    return result


def scope_matches(described, scope):
    """`projection.publish` names the scope with `String(describing:)`; a click names it
    with its diagnostic description. Equal when the kinds and any id agree."""
    if described == scope:
        return True
    kind = scope.split(":")[0]
    ident = scope.split(":", 1)[1] if ":" in scope else ""
    return described.startswith(kind) and (ident == "" or ident in described)


def holders_of(events):
    """Every holder a stall line names: its own `running`/`endedDuringWait` values, or the
    `op=catalog.store.stall.holders` parts."""
    found = []
    for event in events:
        texts = []
        if event.op == "catalog.store.stall.holders":
            texts.append(event.fields.get("holders", ""))
        elif event.op == "catalog.store.stall":
            for key in ("running", "endedDuringWait"):
                value = event.fields.get(key, "")
                if ":" in value:
                    texts.append(value)
        for text in texts:
            for token in text.split(","):
                match = HOLDER.match(token)
                # A holder the log cut short ends in `<…>`: its name is not whole, so it is not counted.
                if match and "<" not in match.group("op"):
                    found.append((match.group("op"), int(match.group("held") or match.group("txn")), match.group("conn")))
    return found


def stalls(start, events):
    lines = of(events, "catalog.store.stall")
    per_minute = {}
    for line in lines:
        minute = ms_since(start.time, line) // 60000
        per_minute[minute] = per_minute.get(minute, 0) + 1
    holders = {}
    for operation, held, _ in holders_of(events):
        longest, count = holders.get(operation, (0, 0))
        holders[operation] = (max(longest, held), count + 1)
    window = [e for e in lines if e.fields.get("operation") in WINDOW_READS]
    main = of(events, "mainThreadStall")
    by_op = {}
    for stall in main:
        op = stall.fields.get("bracketedOp", "unattributed")
        worst, count = by_op.get(op, (0, 0))
        by_op[op] = (max(worst, stall.num("stallMs", 0)), count + 1)
    writes = of(events, "catalog.store.writeWait")
    write_ops = {}
    for line in writes:
        op = line.fields.get("operation", "unnamed")
        worst, count = write_ops.get(op, (0, 0))
        write_ops[op] = (max(worst, line.num("waitMs", 0)), count + 1)
    return {
        "count": len(lines),
        "perMinute": {str(k): v for k, v in sorted(per_minute.items())},
        "worstConnectionMs": max((e.num("connectionMs", 0) for e in lines), default=None),
        "windowReadStalls": len(window),
        "worstWindowReadConnectionMs": max((e.num("connectionMs", 0) for e in window), default=None),
        "holders": dict(sorted(holders.items(), key=lambda kv: -kv[1][0])),
        "mainThread": {"count": len(main), "worstMs": max((e.num("stallMs", 0) for e in main), default=None),
                       "byOp": dict(sorted(by_op.items(), key=lambda kv: -kv[1][0]))},
        "writeWaits": {"count": len(writes), "worstMs": max((e.num("waitMs", 0) for e in writes), default=None),
                       "byOp": dict(sorted(write_ops.items(), key=lambda kv: -kv[1][0]))},
    }


def store_use(line):
    """`op=catalog.store.use` fields as numbers."""
    def pairs(value, width):
        out = {}
        if not value or value == "none":
            return out
        for item in value.split(","):
            parts = item.rsplit(":", width)
            if len(parts) == width + 1:
                try:
                    out[parts[0]] = [int(p) for p in parts[1:]]
                except ValueError:
                    continue
        return out
    return {
        "busyMs": {k: v[0] for k, v in pairs(line.fields.get("busyMs"), 1).items()},
        "holds": pairs(line.fields.get("holds"), 3),
        "changes": line.num("changes", 0),
        "changeFacts": {k: v[0] for k, v in pairs(line.fields.get("changeFacts"), 1).items()},
        "transactions": line.num("transactions", 0),
    }


def difference(later, earlier):
    def sub(a, b):
        return {k: a.get(k, 0) - b.get(k, 0) for k in a if a.get(k, 0) - b.get(k, 0)}
    return {
        "busyMs": sub(later["busyMs"], earlier["busyMs"]),
        "holds": {k: [v[0] - earlier["holds"].get(k, [0, 0, 0])[0], v[1] - earlier["holds"].get(k, [0, 0, 0])[1], v[2]]
                  for k, v in later["holds"].items() if v[0] - earlier["holds"].get(k, [0, 0, 0])[0] > 0},
        "changes": later["changes"] - earlier["changes"],
        "changeFacts": sub(later["changeFacts"], earlier["changeFacts"]),
        "transactions": later["transactions"] - earlier["transactions"],
    }


# An act whose file work follows its visible result (DES-119): the line that starts the work
# (it names the batch) and the line that ends it for that batch.
FILE_WORK = {
    "moveToTrash": ((("trash.move", "start"), ("trash.redo", "start")), ("mediaTrash.queue", "trashed")),
    "putBack": ((("trash.undo", "start"),), ("mediaTrash.undo", "finish")),
}


def act_completion(events, act, finished):
    """Milliseconds from the act's start to the end of its file work: the newest start line
    of its kind at or before the visible result, and the last end line of that batch."""
    starts, (end_op, end_phase) = FILE_WORK[act]
    begun = [e for e in events if (e.op, e.phase) in starts and e.time <= finished.time and e.fields.get("batch")]
    if not begun:
        return None
    start = begun[-1]
    ends = [e for e in events if e.op == end_op and e.phase == end_phase
            and e.fields.get("batch") == start.fields.get("batch") and e.time >= start.time]
    return ms_since(start.time, ends[-1]) if ends else None


def acts(events):
    """Every act timed from its intent to its result committed on the grid on the main actor
    (`op=ui.actToResult phase=finish`), with whether its window could present it (`window`:
    visible, occluded, noWindow; unknown in a build older than the field) and, in a visible
    window, the first frame presented after it (`presentedMs`, the line `phase=presented` of
    the same `report`); and, for an act whose file work follows, from its intent to that work's
    end (`completedMs`)."""
    presented = {line.fields.get("report"): line.num("ms")
                 for line in of(events, "ui.actToResult") if line.phase == "presented"}
    result = []
    for line in of(events, "ui.actToResult"):
        if line.phase in ("finish", "abandoned"):
            act = line.fields.get("act")
            entry = {"act": act, "outcome": "shown" if line.phase == "finish" else "abandoned",
                     "ms": line.num("ms"), "surface": line.fields.get("surface"),
                     "supersededBy": line.fields.get("supersededBy")}
            if line.phase == "finish":
                entry["window"] = line.fields.get("window")
                report = line.fields.get("report")
                entry["presentedMs"] = presented.get(report) if report is not None else None
            if act in FILE_WORK and line.phase == "finish":
                entry["completedMs"] = act_completion(events, act, line)
            result.append(entry)
    return result


# A window that presents no frame (`window=` on `op=ui.actToResult phase=finish`), and the
# verdict its act's presented-frame row carries instead of a number.
UNPRESENTED_WINDOWS = {"occluded": "OCCLUDED", "noWindow": "NO-WINDOW"}

QUERY_STEPS = ("search", "sort", "filter")
PHOTO_STEPS = ("photo", "compare", "info")


def int_or_none(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def step_ms(step):
    """A step's own time: its `resultMs` (timed from the intent) when it carries one."""
    for key in ("resultMs", "ms"):
        try:
            return int(step[key])
        except (KeyError, TypeError, ValueError):
            continue
    return None


def disk(events):
    """The derived folder by kind (`op=derived.folder phase=counted`: the stored counters, or
    the census of a reconciliation that ran) and, when one ran, why and what it removed
    (`op=derived.reconcile phase=finish`): the session's disk, for `--compare` to show growth
    between sessions."""
    counted = first(events, "derived.folder", "counted")
    reconciled = first(events, "derived.reconcile", "finish")
    if counted is None and reconciled is None:
        return None
    kinds = ("thumbnail", "preview", "faceFrames", "other")
    return {
        "folderMB": counted.num("bytes", 0) // 1_048_576 if counted else None,
        "files": {k: counted.num(f"{k}Files", 0) for k in kinds} if counted else None,
        "mb": {k: counted.num(f"{k}Bytes", 0) // 1_048_576 for k in kinds} if counted else None,
        "source": counted.fields.get("source") if counted else None,
        "reconciled": reconciled.fields.get("reason") if reconciled else None,
        "reconcileMs": reconciled.num("ms") if reconciled else None,
        "removedFiles": reconciled.num("removedFiles") if reconciled else None,
        "removedMB": reconciled.num("removedBytes", 0) // 1_048_576 if reconciled else None,
    }


def background(events):
    """Passes each background owner began, by `op=… phase=start` lines that are not the window's."""
    window_ops = {"ui.sidebarSelectionToPaint", "projection.publish", "catalog.start", "tour", "smoke.select"}
    passes = {}
    for event in events:
        if event.phase == "start" and event.op not in window_ops:
            passes[event.op] = passes.get(event.op, 0) + 1
    return dict(sorted(passes.items(), key=lambda kv: -kv[1]))


def root_scans(events):
    """Each library pass and each launch that walked nothing, and why (`op=catalog.scan`):
    a walk's finish line, or a replay's `skip` (nothing changed) or `replayed` (events
    named what to reconcile)."""
    passes = []
    for event in events:
        if event.op == "catalog.scan" and event.phase in ("finish", "skip", "replayed"):
            passes.append({
                "root": event.fields.get("rootPath"),
                "phase": event.phase,
                "reason": event.fields.get("reason"),
                "directoriesRead": event.num("directoriesRead"),
                "filesStatted": event.num("filesStatted"),
                "rowsWritten": event.num("rowsWritten"),
                "events": event.num("events"),
            })
    return passes


def memory(start, events, tour_steps, click_list):
    samples = of(events, "process.memory")
    milestones = {}
    pressure = []
    for sample in samples:
        event = sample.fields.get("event")
        if event in ("sessionStart", "windowAttached", "catalogOpen", "firstGrid", "searchIndexLoaded", "peopleBuilt") and event not in milestones:
            milestones[event] = {"atMs": ms_since(start.time, sample), "footprintMB": sample.num("footprintMB")}
        if event == "memoryPressure":
            running = [c["scope"] for c in click_list if c["at"] <= sample.time.isoformat() and c["outcome"] != "pending"][-1:]
            step = [s for s in tour_steps if s["at"] <= sample.time.isoformat()][-1:]
            pressure.append({"atMs": ms_since(start.time, sample), "level": sample.fields.get("level"),
                             "footprintMB": sample.num("footprintMB"), "freeMB": sample.num("freeMB"),
                             "lastClick": running[0] if running else None,
                             "tourStep": step[0]["label"] if step else None})
    search = first(events, "search.index", "loaded")
    people = first(events, "people.state", "applied")
    return {
        "samples": len(samples),
        "peakFootprintMB": max((s.num("peakFootprintMB", 0) for s in samples), default=None),
        "peak": peak_moment(start, samples, tour_steps),
        "lastFootprintMB": samples[-1].num("footprintMB") if samples else None,
        "minFreeMB": min((s.num("freeMB") for s in samples if s.num("freeMB") is not None), default=None),
        "maxSwapUsedMB": max((s.num("swapUsedMB") for s in samples if s.num("swapUsedMB") is not None), default=None),
        "milestones": milestones,
        "pressure": pressure,
        "tileCacheMaxMB": max((s.num("tileCacheMB") for s in samples if s.num("tileCacheMB") is not None), default=None),
        "sqliteMaxMB": max((s.num("sqliteMB") for s in samples if s.num("sqliteMB") is not None), default=None),
        "searchIndexLoadedAtMs": ms_since(start.time, search) if search else None,
        "searchMappedMB": search.num("mappedMB") if search else None,
        "searchLoadedFrom": search.fields.get("from") if search else None,
        "searchOpenMs": search.num("openMs") if search else None,
        "peopleAppliedAtMs": ms_since(start.time, people) if people else None,
    }


PRESSURE_LEVELS = ("normal", "warning", "critical")


def overlap_seconds(span, spans):
    """Seconds of `span` that the non-overlapping `spans` cover."""
    start, stop = span
    return sum(max(0.0, (min(stop, b) - max(start, a)).total_seconds()) for a, b in spans)


def description_spans(events, end):
    """Each description request from its grant to its end (`op=load.admission load=description`:
    the grant's time plus the release's `ms`; one still running at the session's end runs to
    it). Requests run one at a time, so the spans never overlap."""
    released = {e.fields.get("request"): e for e in of(events, "load.admission", "released")
                if e.fields.get("load") == "description"}
    spans = []
    for grant in of(events, "load.admission", "granted"):
        if grant.fields.get("load") != "description":
            continue
        release = released.get(grant.fields.get("request"))
        ms = release.num("ms") if release is not None else None
        stop = grant.time + dt.timedelta(milliseconds=ms) if ms is not None else end
        if stop is not None:
            spans.append((grant.time, max(grant.time, stop)))
    return spans


def pressure_attribution(launch_line, changes, events, end):
    """The seconds above normal that description requests account for, and the rest.

    The owner accepts the pressure description writing causes (2026-11-18: "Descriptions should
    run when the app is foregrounded. OS will swap running apps"; ADR 0015, ADR 0057). An
    episode above normal — from a read that left normal to the read that found it again — is
    the descriptions' whole when the room's memory hold began with a description request
    running (`op=load.admission phase=memoryHold held=true running=…description…`, logged in
    the step of that read): the level then stays up until the kernel lowers it, which it does
    only after its own smoothing. Any other episode is theirs only for the seconds a request
    ran in it; the rest is not."""
    episodes = []
    level, since = launch_line.fields.get("level"), launch_line.time
    for change in (c for c in changes if c.time >= launch_line.time):
        if level in PRESSURE_LEVELS[1:]:
            if episodes and episodes[-1][1] == since:
                episodes[-1] = (episodes[-1][0], change.time)
            else:
                episodes.append((since, change.time))
        level, since = change.fields.get("level"), change.time
    if level in PRESSURE_LEVELS[1:] and end is not None:
        stop = max(since, end)
        if episodes and episodes[-1][1] == since:
            episodes[-1] = (episodes[-1][0], stop)
        else:
            episodes.append((since, stop))
    requests = description_spans(events, end)
    holds = [e for e in of(events, "load.admission", "memoryHold") if e.fields.get("held") == "true"]
    attributed = 0.0
    for start, stop in episodes:
        began = next((h for h in holds if start <= h.time <= stop), None)
        if began is not None and "description" in began.fields.get("running", "").split(","):
            attributed += (stop - start).total_seconds()
        else:
            attributed += overlap_seconds((start, stop), requests)
    total = sum((stop - start).total_seconds() for start, stop in episodes)
    return round(attributed, 1), round(max(0.0, total - attributed), 1), len(requests)


def machine(start, events):
    """The machine's memory-pressure level over the session, and the load of Otos's own
    process tree (the app and its text-reading helpers).

    The level comes from `op=system.pressure` lines, each the kernel's level
    (`kern.memorystatus_vm_pressure_level`) as the background room read it (ADR 0057):
    `phase=launch` is its first read, and each `phase=changed` a later read whose level
    differs from the last logged, at a decision, a report of the memory-pressure source or a
    re-read while held, so a level the source never announced is counted.
    `phase=sourceReport` lines (the source's own reports) are not levels. Seconds at each level run from the launch line
    to the session's last event. The judgement (`pressureCaused`) holds only when the machine
    was at `normal` at launch: then a level that stayed is `normal`; one that left `normal`
    came while Otos was the new workload, and is `descriptions` when description writing
    accounts for every second of it (`pressure_attribution`: pressure the owner accepts),
    else `caused`; a launch at another level is `notJudged`, since the machine was not quiet
    before Otos. Whether another workload started during the session is not in the app's log,
    so a caused level is Otos's or a neighbour's started after it; a quiet machine (nothing
    else started) makes it Otos's.

    A helper's line (`op=process.usage phase=helper`) is its last sample before it ended:
    CPU and peak footprint at least those, never more."""
    lines = of(events, "system.pressure")
    launch_line = next((e for e in lines if e.phase == "launch"), None)
    changes = [e for e in lines if e.phase == "changed"]
    end = events[-1].time if events else None
    result = {"atLaunch": None, "systemLevelAtLaunch": None, "availablePercentAtLaunch": None,
              "thermalAtLaunch": None, "lowPowerAtLaunch": None, "changes": [], "seconds": None,
              "worst": None, "pressureCaused": None, "secondsOutsideNormal": None,
              "secondsFromDescriptions": None, "secondsNotFromDescriptions": None, "descriptionRequests": None}
    if launch_line is not None:
        result.update({
            "atLaunch": launch_line.fields.get("level"),
            "systemLevelAtLaunch": launch_line.num("systemLevel"),
            "availablePercentAtLaunch": launch_line.num("availablePercent"),
            "thermalAtLaunch": launch_line.fields.get("thermal"),
            "lowPowerAtLaunch": launch_line.fields.get("lowPower"),
        })
        seconds = {level: 0.0 for level in PRESSURE_LEVELS}
        level, since = launch_line.fields.get("level"), launch_line.time
        for change in (c for c in changes if c.time >= launch_line.time):
            if level in seconds:
                seconds[level] += (change.time - since).total_seconds()
            level, since = change.fields.get("level"), change.time
        if level in seconds and end is not None:
            seconds[level] += max(0.0, (end - since).total_seconds())
        result["seconds"] = {k: round(v, 1) for k, v in seconds.items()}
        seen = [result["atLaunch"]] + [c.fields.get("level") for c in changes]
        ranked = [PRESSURE_LEVELS.index(s) for s in seen if s in PRESSURE_LEVELS]
        result["worst"] = PRESSURE_LEVELS[max(ranked)] if ranked else None
        result["secondsOutsideNormal"] = round(seconds["warning"] + seconds["critical"], 1)
        described, other, requests = pressure_attribution(launch_line, changes, events, end)
        result.update({"secondsFromDescriptions": described, "secondsNotFromDescriptions": other,
                       "descriptionRequests": requests})
        if result["atLaunch"] != "normal":
            result["pressureCaused"] = "notJudged"
        elif result["worst"] == "normal":
            result["pressureCaused"] = "normal"
        else:
            result["pressureCaused"] = "caused" if other > 0 else "descriptions"
    result["changes"] = [{"atMs": ms_since(start.time, c), "level": c.fields.get("level"),
                          "systemLevel": c.num("systemLevel"), "availablePercent": c.num("availablePercent")}
                         for c in changes]
    # A helper's lines are cumulative (one after each page, one as it ends): its last counts.
    last_by_helper = {}
    for line in of(events, "process.usage", "helper"):
        last_by_helper[line.fields.get("helperPid") or id(line)] = line
    helpers = list(last_by_helper.values())
    usages = [e for e in of(events, "process.usage") if e.phase != "helper"]
    app_cpu = usages[-1].num("cpuMs") if usages else None
    helper_cpu = sum(h.num("cpuMs", 0) for h in helpers)
    result["tree"] = {
        "appCpuMs": app_cpu,
        "appPeakFootprintMB": max((s.num("peakFootprintMB", 0) for s in of(events, "process.memory")), default=None),
        "helpers": len(helpers),
        "helperCpuMs": helper_cpu if helpers else 0,
        "helperPeakFootprintMB": max((h.num("peakFootprintMB", 0) for h in helpers), default=None),
        "cpuMs": None if app_cpu is None else app_cpu + helper_cpu,
        "byRole": {},
    }
    for helper in helpers:
        role = helper.fields.get("role", "unknown")
        entry = result["tree"]["byRole"].setdefault(role, {"count": 0, "cpuMs": 0, "peakFootprintMB": 0})
        entry["count"] += 1
        entry["cpuMs"] += helper.num("cpuMs", 0)
        entry["peakFootprintMB"] = max(entry["peakFootprintMB"], helper.num("peakFootprintMB", 0))
    return result


def step_name(step):
    return f"{step.get('index')}:{step.get('kind')}/{step.get('label')}"


def peak_moment(start, samples, tour_steps):
    """When the session's peak footprint was reached. Each sample carries the process's peak
    so far, so the peak was reached after the sample before the first one that reports it
    (`afterMs`) and by that one (`atMs`). A tour step's line is written when the step ends:
    the last step line at or before `afterMs` is the step finished before the peak
    (`afterStep`), and the first one after it is the step that was running when the peak was
    reached (`duringStep`), or None when the peak came after the last step."""
    peaks = [(s, s.num("peakFootprintMB")) for s in samples if s.num("peakFootprintMB") is not None]
    if not peaks:
        return None
    top = max(value for _, value in peaks)
    index = next(i for i, (_, value) in enumerate(peaks) if value == top)
    sample = peaks[index][0]
    previous = peaks[index - 1][0] if index > 0 else None
    bound = (previous or sample).time.isoformat()
    finished = [s for s in tour_steps if s["at"] <= bound][-1:]
    running = [s for s in tour_steps if s["at"] > bound][:1]
    return {
        "footprintMB": top,
        "atMs": ms_since(start.time, sample),
        "afterMs": ms_since(start.time, previous) if previous else None,
        "sample": sample.fields.get("event"),
        "afterStep": step_name(finished[0]) if finished else None,
        "duringStep": step_name(running[0]) if running else None,
    }


def tour_silence_limit(idle_seconds, deadline_seconds, settle_seconds=0, library_seconds=0):
    """How long a tour may go without a line before the script calls it stuck, in seconds.
    The longest stretch a working tour is silent is its idle step (`idle_seconds`, one sleep),
    one step's wait for its fact (at most `deadline_seconds`, then the step reports
    `outcome=deadline`), a settled tour's wait for the launch to settle (at most
    `settle_seconds`, then `op=tour phase=settled by=deadline`) or the wait for a sandbox
    library's first walk (at most `library_seconds`, then `sandboxLibraryNeverScanned`),
    whichever is longest; the margin covers the untimed reads between a step's waits and the
    launch before the first line. time: deadline"""
    longest = max(int(idle_seconds), int(deadline_seconds), int(settle_seconds), int(library_seconds))
    return longest + TOUR_SILENCE_MARGIN_SECONDS


TOUR_SILENCE_MARGIN_SECONDS = 60


# ── A sandbox library's files in the account's Trash ────────────────────────────

def trash_presence(name, trash_dir, lstat=None):
    """Whether a generated file named `name` is in `trash_dir`: "absent", "present", or
    "unknown" when the path cannot be tested (no permission, a name that is not a plain file
    name). Tested by path, never by listing the Trash. Unknown is never read as absent."""
    import os
    lstat = lstat or os.lstat
    if not name or "/" in name or name in (".", ".."):
        return "unknown"
    try:
        lstat(os.path.join(trash_dir, name))
        return "present"
    except FileNotFoundError:
        return "absent"
    except OSError:
        return "unknown"


def trash_leftovers(names, trash_dir, lstat=None, remove=None):
    """Every generated name found in the account's Trash, removed, and every name that could
    not be tested: `(removed, unknown)`. A sandbox library's files are its own (each name
    carries its run's prefix), so one found there is the tour's and is removed. A name whose
    removal fails stays in `unknown`, so it is reported, not counted as cleaned."""
    import os
    remove = remove or os.remove
    removed, unknown = [], []
    for name in names:
        state = trash_presence(name, trash_dir, lstat)
        if state == "present":
            try:
                remove(os.path.join(trash_dir, name))
                removed.append(name)
            except OSError:
                unknown.append(name)
        elif state == "unknown":
            unknown.append(name)
    return removed, unknown


def report_trash_leftovers(names_file, trash_dir, out):
    """`--trash-leftovers`: 0 when no generated file is in the Trash, 1 when one was (it is
    removed and named) or could not be tested."""
    with open(names_file, encoding="utf-8") as handle:
        names = [line.strip() for line in handle if line.strip()]
    removed, unknown = trash_leftovers(names, trash_dir)
    for name in removed:
        out.write(f"op=sandboxLibrary.trash phase=leftover name={name} removed=true\n")
    for name in unknown:
        out.write(f"op=sandboxLibrary.trash phase=unknown name={name} — could not test or remove it\n")
    clean = not removed and not unknown
    out.write(f"op=sandboxLibrary.trash phase={'clean' if clean else 'FAILED'} tested={len(names)} "
              f"leftovers={len(removed)} unknown={len(unknown)}\n")
    return 0 if clean else 1

USAGE_KEYS = ("cpuMs", "diskReadMB", "diskWrittenMB", "pageIns")


def usage_delta(first_line, last_line):
    """The usage counters' growth between two samples; a counter either line lacks (a build
    older than it) is None, never 0."""
    if not first_line or not last_line:
        return None
    delta = {}
    for key in USAGE_KEYS:
        before, after = first_line.num(key), last_line.num(key)
        delta[key] = None if before is None or after is None else after - before
    return delta


def resources(events):
    usages = of(events, "process.usage")
    uses = of(events, "catalog.store.use")
    result = {"session": usage_delta(usages[0], usages[-1]) if len(usages) > 1 else None}
    idle_start, idle_end = idle_window(events)
    result["diskByOwner"] = {
        "session": disk_by_owner(events, usages[0], usages[-1]) if len(usages) > 1 else None,
        "idle": disk_by_owner(events, idle_start, idle_end),
    }
    if uses:
        total = store_use(uses[-1])
        result["connections"] = total["busyMs"]
        result["topHolds"] = sorted(([k, *v] for k, v in total["holds"].items()), key=lambda row: -row[1])[:12]
        result["writer"] = [row for row in result["topHolds"] if row[0].startswith("main.writer:")]
        result["changes"] = total["changes"]
        result["changeFacts"] = total["changeFacts"]
    return result


# The page a page-in reads, on Apple silicon: `ri_pageins` counts pages, not bytes.
PAGE_BYTES = 16384
MIB = 1048576


def store_reads(line):
    """`op=catalog.store.reads` as KiB: by role, and by `role:operation` with transactions."""
    def pairs(value, width):
        out = {}
        if not value or value == "none":
            return out
        for item in value.split(","):
            parts = item.rsplit(":", width)
            try:
                out[parts[0]] = [int(p) for p in parts[1:]] if len(parts) == width + 1 else None
            except ValueError:
                continue
        return {k: v for k, v in out.items() if v is not None}
    return {
        "byRole": {k: v[0] for k, v in pairs(line.fields.get("readKB"), 1).items()},
        "byOperation": pairs(line.fields.get("top"), 2),
    }


def disk_by_owner(events, first_usage, last_usage):
    """Who read the disk between two `op=process.usage` samples, in MiB: the originals each
    owner hashed whole (`op=contentHash` bytes), the catalog pages each connection role read
    into SQLite's cache (`op=catalog.store.reads` at the same events), and the pages the
    process faulted in from mapped files (page-ins); the rest of the process's disk read is
    named as not attributed. Each owner's figure is what it asked of the disk; the system may
    have served part of it from memory, so the parts can exceed the total."""
    if not first_usage or not last_usage:
        return None
    total = usage_delta(first_usage, last_usage)
    if total is None or total["diskReadMB"] is None:
        return None
    rows = []
    hashed = {}
    for line in of(events, "contentHash", "finish"):
        if first_usage.time <= line.time <= last_usage.time:
            owner = line.fields.get("owner", "unknown")
            hashed[owner] = hashed.get(owner, 0) + (line.num("bytes", 0) or 0)
    for owner, size in sorted(hashed.items(), key=lambda item: -item[1]):
        rows.append({"owner": f"originals hashed: {owner}", "mb": round(size / MIB), "source": "op=contentHash bytes"})
    event_of = lambda line: line.fields.get("event")  # noqa: E731
    reads = {event_of(line): line for line in of(events, "catalog.store.reads")}
    first_reads, last_reads = reads.get(event_of(first_usage)), reads.get(event_of(last_usage))
    top = []
    if last_reads:
        later = store_reads(last_reads)
        earlier = store_reads(first_reads) if first_reads else {"byRole": {}, "byOperation": {}}
        for role, kb in sorted(later["byRole"].items()):
            grown = kb - earlier["byRole"].get(role, 0)
            if grown > 0:
                rows.append({"owner": f"catalog pages: {role}", "mb": round(grown / 1024), "source": "SQLite cache misses"})
        for key, (kb, count) in later["byOperation"].items():
            before = earlier["byOperation"].get(key, [0, 0])
            if kb - before[0] > 0:
                top.append([key, round((kb - before[0]) / 1024), count - before[1]])
        top.sort(key=lambda row: -row[1])
    if total["pageIns"] is not None:
        rows.append({"owner": "page-ins: mapped files, models, frameworks", "mb": round(total["pageIns"] * PAGE_BYTES / MIB),
                     "source": "op=process.usage pageIns"})
    named = sum(row["mb"] for row in rows)
    return {
        "totalMB": total["diskReadMB"],
        "cpuMs": total["cpuMs"],
        "rows": rows,
        "notAttributedMB": max(0, total["diskReadMB"] - named),
        "catalogTop": top[:8],
        "catalogMeasured": last_reads is not None,
    }


def idle_window(events):
    """The tour's idle window: its `idleStart` and `idleEnd` usage checkpoints."""
    return (first(events, "process.usage", where=lambda e: e.fields.get("event") == "idleStart"),
            first(events, "process.usage", where=lambda e: e.fields.get("event") == "idleEnd"))


def tour(start, events):
    steps = []
    for line in of(events, "tour", "step"):
        step = {k: v for k, v in line.fields.items() if k not in ("op", "phase")}
        step["at"] = line.time.isoformat()
        step["atMs"] = ms_since(start.time, line)
        steps.append(step)
    config = first(events, "tour", "config")
    finish = first(events, "tour", "finish")
    settled_line = first(events, "tour", "settled")
    idle = None
    idle_start, idle_end = idle_window(events)
    if idle_start and idle_end:
        seconds = max(0.001, (idle_end.time - idle_start.time).total_seconds())
        idle = {"seconds": round(seconds, 1), **usage_delta(idle_start, idle_end)}
        use_start = first(events, "catalog.store.use", where=lambda e: e.fields.get("event") == "idleStart")
        use_end = first(events, "catalog.store.use", where=lambda e: e.fields.get("event") == "idleEnd")
        if use_start and use_end:
            delta = difference(store_use(use_end), store_use(use_start))
            idle["changesPerMinute"] = round(delta["changes"] * 60 / seconds, 1)
            idle["changeFacts"] = delta["changeFacts"]
            idle["transactions"] = delta["transactions"]
            idle["busyMs"] = delta["busyMs"]
            idle["topHolds"] = sorted(([k, *v] for k, v in delta["holds"].items()), key=lambda row: -row[1])[:8]
            idle["quiet"] = delta["changes"] == 0 and delta["transactions"] == 0
        idle["stalls"] = len([e for e in of(events, "catalog.store.stall") if idle_start.time <= e.time <= idle_end.time])
    return {
        "config": {k: v for k, v in config.fields.items() if k not in ("op", "phase")} if config else None,
        "finished": finish.fields.get("outcome") if finish else None,
        # A build older than the start field toured at launch: that was the only kind.
        "start": (config.fields.get("start") or "launch") if config else None,
        "settled": {"by": settled_line.fields.get("by"), "waitMs": settled_line.num("waitMs"),
                    "backlog": settled_line.fields.get("backlog")} if settled_line else None,
        "steps": steps,
        "idle": idle,
    }


def session_kind(toured):
    """What kind of session a scorecard measured: `launch` (a tour from the first grid, under
    the launch's own load), `settled` (a tour that first waited for the launch to settle, or,
    when it registered its library, for the work that library's first walk raised:
    `libraryWork`; one whose wait reached its deadline is `settled(deadline)`, still under
    load), or `untoured`."""
    if toured["start"] is None:
        return "untoured"
    if toured["start"] != "settled":
        return "launch"
    by = (toured["settled"] or {}).get("by")
    return "settled" if by in ("launchWork", "ownersQuiescent", "libraryWork") else "settled(deadline)"


def owners_at_end(events):
    """The last `op=owners.status` and the `op=owners.pending` lines of the same moment: which
    owners were not quiescent when the session ended, and what each owed, ran or held. None
    when the session logged no status (a build older than these lines, or a session that did
    not end through a tour's finish)."""
    status = None
    for event in of(events, "owners.status"):
        status = event
    if status is None:
        return None
    pending = [{k: v for k, v in e.fields.items() if k not in ("op", "phase")}
               for e in of(events, "owners.pending", status.phase) if e.time >= status.time]
    # Rows an owner holds for a fact outside it, quiescent or not (`op=owners.held`): a count,
    # or None where the build logged `unknown`.
    held = [{"owner": e.fields.get("owner"), "waitingFor": e.fields.get("waitingFor"), "count": e.num("count")}
            for e in of(events, "owners.held", status.phase) if e.time >= status.time]
    return {
        "moment": status.phase,
        "owners": status.num("owners"),
        "quiescent": status.num("quiescent"),
        "pending": pending,
        "held": held,
    }


HELD_LABELS = {"digestAwaitsLocalBytes": "digest waits for local bytes", "pacing": "paced, claim held until the pacing passes"}


def describe_pending(owner):
    """One owner that was not quiescent, in a few words: what it ran and owed."""
    parts = []
    if owner.get("runningPasses") not in (None, "0"):
        parts.append(f"running {owner['runningPasses']} pass (written {owner.get('written', '-')} so far)")
    if owner.get("owedRequests") not in (None, "0"):
        parts.append(f"owed {owner['owedRequests']} requests")
    if owner.get("unactedChanges") not in (None, "0"):
        parts.append(f"{owner['unactedChanges']} store changes not acted on")
    if owner.get("holdsWork") == "true":
        parts.append("holding work in flight")
    if owner.get("backlog") == "true":
        parts.append("all of it its backlog")
    if owner.get("wake") not in (None, "none"):
        parts.append(f"wake {owner['wake']}")
    if owner.get("heldBy") not in (None, "none"):
        # The background room held its next unit (ADR 0057).
        parts.append(f"held by {owner['heldBy']}")
    return f"{owner.get('owner')}: " + ", ".join(parts or ["not quiescent"])


NOT_MEASURED_ALWAYS = [
    "rows visited or returned by background reads (no line carries them)",
    "which owner's write caused each store change (changes carry kinds of fact, not their writer)",
    "writer waits of writes outside CatalogStore.timedWrite (writeWait covers named writes only; "
    "the writer's busy time in catalog.store.use covers all)",
    "People snapshot bytes, thumbnail decode caches outside the grid's tile store, SQLite page cache per connection",
]


def analyse(events, session_start):
    start = session_start or (events[0] if events else None)
    if start is None:
        return {"error": "no events"}
    launched = launch(start, events) if session_start else None
    click_list = clicks(events, launched["scope"] if launched else None, idle_window(events)[1])
    toured = tour(start, events)
    report = {
        "session": start.fields.get("session"),
        "pid": start.pid,
        "build": "installed" if is_installed(start) else "dev",
        "start": start.time.isoformat(),
        "durationS": round((events[-1].time - start.time).total_seconds(), 1) if events else 0,
        "launch": launched,
        "clicks": click_list,
        "stalls": stalls(start, events),
        "background": background(events),
        "rootScans": root_scans(events),
        "memory": memory(start, events, toured["steps"], click_list),
        "machine": machine(start, events),
        "resources": resources(events),
        "tour": toured,
        "sessionKind": session_kind(toured),
        "ownersAtEnd": owners_at_end(events),
        "acts": acts(events),
        "disk": disk(events),
    }
    duration = report["durationS"]
    report["stalls"]["per10Min"] = round(report["stalls"]["count"] * 600 / duration, 1) if duration else None
    missing = list(NOT_MEASURED_ALWAYS)
    if not report["acts"]:
        missing.append("act to result for choices and Move to Trash (no op=ui.actToResult line: no act ran, "
                       "and a tour acts only in a sandbox home)")
    if not of(events, "process.memory"):
        missing.append("memory (no op=process.memory lines: a build older than the resource checkpoints)")
    if any(c["outcome"] == "painted" for c in click_list) and not any(c["usage"] for c in click_list):
        missing.append("what each paint cost the process, page-ins included (no op=process.usage event=paintStart "
                       "lines: a build older than the paint's start checkpoint)")
    if not of(events, "catalog.store.use"):
        missing.append("connection busy time and store changes by kind (no op=catalog.store.use lines)")
    if not of(events, "system.pressure"):
        missing.append("the machine's memory-pressure level over the session (no op=system.pressure lines: "
                       "a build older than the pressure line)")
    if of(events, "catalog.store.stall") and not of(events, "catalog.store.stall.holders"):
        missing.append("the waiting read of each stall and its full holder list (stall lines cut at about "
                       "1,017 characters; this build logs holders inside the line)")
    report["notMeasured"] = missing
    return report


# ── Targets ─────────────────────────────────────────────────────────────────────

VISIT_LABELS = {"first": "first", "return": "return", "returnAfterIdle": "return after idle"}


def verdicts(report, targets):
    """One row per user-felt number: value, target, PASS/FAIL/NO-TARGET."""
    rows = []

    def add(metric, label, value, paged_in=None):
        target = targets.get(metric)
        if value is None:
            verdict = "NO-DATA"
        elif target is None or target.get("maxMs") is None and target.get("max") is None:
            verdict = "NO-TARGET"
        else:
            limit = target.get("maxMs", target.get("max"))
            verdict = "PASS" if value <= limit else "FAIL"
        shown = "none" if not target or (target.get("maxMs") is None and target.get("max") is None) else str(target.get("maxMs", target.get("max")))
        row = {"metric": metric, "label": label, "value": value, "target": shown, "verdict": verdict}
        if paged_in is not None:
            row["pagedIn"] = paged_in
        rows.append(row)

    launched = report.get("launch") or {}
    add("launch.firstGridMs", "launch → first grid (" + str(launched.get("scopeKind")) + ")", launched.get("firstGridMs"))
    for click in report["clicks"]:
        if click["outcome"] != "painted":
            continue
        if click["visit"] == "returnAfterIdle":
            metric = "click.returnAfterIdleMs"
        elif click["visit"] == "return":
            metric = "click.returnMs"
        elif click["kind"] == "all media":
            metric = "click.allMedia.firstMs"
        else:
            metric = "click.smallScopeMs"
        add(metric, VISIT_LABELS[click["visit"]] + " " + click["kind"], click["ms"], click.get("pagedIn"))
    searches = 0
    for step in report["tour"]["steps"]:
        if step.get("outcome") == "deadline":
            # A step whose fact never came is a failure of its own, whatever it measures.
            rows.append({"metric": "tour.deadline", "label": f"step {step.get('index')} {step.get('kind')} {step.get('label')} deadline",
                         "value": step_ms(step), "target": "fact", "verdict": "FAIL"})
            continue
        if step.get("outcome") != "reported":
            continue
        if step.get("kind") == "scroll":
            add("scroll.withoutThumbnail", f"scroll {step.get('label')} {step.get('position')} tiles without thumbnail",
                int_or_none(step.get("withoutThumbnail")))
        elif step.get("kind") == "search":
            # The session's first search pays the cold start (the encoder's load, the vectors'
            # first read); every later one does not, so they are reported apart.
            # Each is reported twice: when its first results were on screen (its first matches
            # while still searching, or its answer), held to the target, and when it was
            # complete, a number. A build older than `firstMs` has no first-results number.
            # A tour run with --search-after-warm types each query once the focus's readying of
            # the text tower has ended (`submit=afterWarm`), as a person who types does; its
            # numbers say so (`after warm`), so they are never read as the immediate ones. Both
            # are timed from the query; `focus to query` is how long after the focus it came.
            searches += 1
            name = f"search {'first' if searches == 1 else 'again'} {step.get('label')}"
            if step.get("submit") == "afterWarm":
                name += " after warm"
            add("search.firstResultsMs", f"{name} first results", int_or_none(step.get("firstMs")))
            add("search.completeMs", f"{name} complete", step_ms(step))
            if step.get("focusMs") is not None:
                add("search.focusToQueryMs", f"{name} focus to query", int_or_none(step.get("focusMs")))
        elif step.get("kind") in QUERY_STEPS:
            add("query.resultMs", f"{step['kind']} {step.get('label')}", step_ms(step))
        elif step.get("kind") in PHOTO_STEPS:
            add("photo.stepMs", f"{step['kind']} {step.get('label')}", step_ms(step))
        elif step.get("label") == "duplicates":
            # The groups the launch built when the step reached Duplicates (`row=absent`: none,
            # so the sidebar had no row to click), and how long the step waited for them.
            add("duplicates.groups", "duplicates groups the launch built", int_or_none(step.get("groups")))
            add("duplicates.buildWaitMs", "duplicates wait for the launch's build", int_or_none(step.get("buildWaitMs")))
    for act in report["acts"]:
        if act["outcome"] == "shown":
            add("act.resultMs", f"act {act['act']}", act["ms"])
            # The frame that composited the commit, a number beside the held one: only a
            # visible window presents one, so an occluded window's act prints `occluded`.
            add("act.presentedMs", f"act {act['act']} presented", act.get("presentedMs"))
            if act.get("window") in UNPRESENTED_WINDOWS:
                rows[-1]["state"] = act["window"]
                rows[-1]["verdict"] = UNPRESENTED_WINDOWS[act["window"]]
            if act["act"] in FILE_WORK:
                add("act.completedMs", f"act {act['act']} file work done", act.get("completedMs"))
    add("stalls.count", "store stall lines", report["stalls"]["count"])
    add("stalls.per10Min", "store stall lines per 10 minutes", report["stalls"]["per10Min"])
    add("mainThreadStalls.count", "main-thread stalls", report["stalls"]["mainThread"]["count"])
    add("mainThreadStalls.worstMs", "worst main-thread stall ms", report["stalls"]["mainThread"]["worstMs"] or 0)
    add("memory.peakFootprintMB", "peak footprint MB", report["memory"]["peakFootprintMB"])
    add("disk.derivedFolderMB", "derived folder MB", (report.get("disk") or {}).get("folderMB"))
    caused = (report.get("machine") or {}).get("pressureCaused")
    # Not a number against a limit: the level is judged only from a quiet start (`machine`).
    # Pressure description writing accounts for is the owner's to accept (2026-11-18), not a fail.
    verdict = {"normal": "PASS", "descriptions": "ACCEPTED", "caused": "FAIL",
               "notJudged": "NOT-JUDGED"}.get(caused, "NO-DATA")
    # The value is the seconds above `normal` that descriptions do not account for; the state
    # names the judgement.
    rows.append({"metric": "machine.pressureCaused", "label": "memory pressure caused: s above normal",
                 "value": (report.get("machine") or {}).get("secondsNotFromDescriptions"), "target": "normal",
                 "state": caused, "verdict": verdict})
    tree = (report.get("machine") or {}).get("tree") or {}
    add("machine.treeCpuMs", "CPU ms of Otos and its helpers", tree.get("cpuMs"))
    return rows


# ── Output ──────────────────────────────────────────────────────────────────────

def fmt(value):
    return "-" if value is None else str(value)


def describe_capture(captured):
    """The `capture=` line: which source the numbers come from, how many of the session's lines
    each source held, and whether the session is whole. A partial capture is said to be one."""
    line = (f"capture={captured['source']} lines={captured['lines']} dropped={fmt(captured['dropped'])}"
            f" logShowLines={fmt(captured['logShowLines'])}")
    if captured["source"] == "live":
        line += (f" logShowOnly={fmt(captured.get('logShowOnly'))} end={captured['end']}"
                 f" complete={'yes' if captured['complete'] else 'no'}")
        if captured.get("logShowOnly"):
            line += (f"\nPARTIAL: `log show` still held {captured['logShowOnly']} of the session's lines the live capture"
                     " lacks: the stream lost them without a notice")
        if captured["dropped"]:
            line += (f"\nPARTIAL: the live capture dropped messages {captured['dropped']} times (each notice is one or"
                     " more lines): a number below may miss a fact the session logged")
        if captured["end"] != "seen":
            line += "\nPARTIAL: the capture's end marker never came through: the session's last lines may be missing"
    else:
        line += " complete=unknown (the log's store rotates a busy session's lines out; what it lost cannot be counted)"
    return line


def print_report(report, rows, out):
    w = out.write
    w(f"op=scorecard session={report.get('session')} kind={report.get('sessionKind', 'launch')} "
      f"build={report.get('build')} pid={report.get('pid')} "
      f"durationS={report.get('durationS')} clicks={len(report['clicks'])} stalls={report['stalls']['count']} "
      f"peakFootprintMB={fmt(report['memory']['peakFootprintMB'])} "
      f"fails={sum(1 for r in rows if r['verdict'] == 'FAIL')}\n")
    captured = report.get("capture")
    if captured:
        w(describe_capture(captured) + "\n")
    for row in rows:
        if row["metric"] == "tour.deadline":
            w(f"FAIL: tour {row['label']} after {fmt(row['value'])} ms: the fact it waits on never came\n")
    w("\n")
    w("USER-FELT NUMBERS\n")
    w(f"  {'number':44} {'value':>9} {'target':>8}  verdict\n")
    for row in rows:
        w(f"  {row['label'][:44]:44} {row.get('state') or fmt(row['value']):>9} {row['target']:>8}  {row['verdict']}"
          + (f"  pagedIn={row['pagedIn']}" if row.get("pagedIn") is not None else "") + "\n")
    launched = report.get("launch")
    if launched:
        w("\nLAUNCH (ms from session start)\n")
        w(f"  window attached {fmt(launched['windowAttachedMs'])}, database open took {fmt(launched['databaseOpenMs'])} "
          f"(migrations {fmt(launched['databaseMigrations'])}), catalog open at {fmt(launched['catalogOpenAtMs'])} "
          f"(migrations {fmt(launched['catalogMigrationsMs'])} ms), first grid {fmt(launched['firstGridMs'])} "
          f"(catalog {fmt(launched['firstGridCatalogMs'])}) in {launched['scopeKind']}, {fmt(launched['items'])} items, "
          f"owners quiescent {fmt(launched['ownersQuiescentMs'])}\n")
        stages = launched.get("settledMs") or {}
        backlogs = launched.get("settledBacklog") or {}

        def reached(stage, ms):
            if stage not in backlogs:
                return f"{stage} at {fmt(ms)} ms"
            return f"{stage} at {fmt(ms)} ms (working a backlog: {', '.join(backlogs[stage]) or 'none'})"

        if stages:
            w("  settled " + ", ".join(reached(stage, ms) for stage, ms in stages.items()) + "\n")
        else:
            w("  settled: no stage reached\n")
        at_end = report.get("ownersAtEnd")
        if launched["ownersQuiescentMs"] is None:
            if at_end is None:
                w("  owners never quiescent; which and why not measured (no op=owners.status line)\n")
            else:
                w(f"  owners never quiescent: at {at_end['moment']} {fmt(at_end['quiescent'])} of {fmt(at_end['owners'])} were; "
                  f"the rest were busy:\n")
                for owner in at_end["pending"]:
                    w(f"    {describe_pending(owner)}\n")
    settled = report["tour"].get("settled")
    if settled:
        what = "its library's work" if settled["by"] == "libraryWork" else "the launch"
        w(f"  the tour waited {fmt(settled['waitMs'])} ms for {what} to settle: by {fmt(settled['by'])}"
          + (f" backlog={settled['backlog']}" if settled.get("backlog") else "") + "\n")
    w("\nCLICK TO PAINT\n")
    for click in report["clicks"]:
        order = click.get("order", {})
        usage = click.get("usage") or {}
        w(f"  {click['kind']:16} {VISIT_LABELS[click['visit']]:17} {click['outcome']:9} {fmt(click['ms']):>7} ms"
          + (f"  pagedIn={click['pagedIn']}" if click.get("pagedIn") is not None else "")
          + f"  process[cpu={fmt(usage.get('cpuMs'))} diskRead={fmt(usage.get('diskReadMB'))}MB pageIns={fmt(usage.get('pageIns'))}]"
          + f"  beforeBuild={fmt(click.get('beforeBuildMs'))}"
          f" order[query={fmt(order.get('queryMs'))} wait={fmt(order.get('waitMs'))} exec={fmt(order.get('execMs'))}"
          f" sql={fmt(order.get('orderSqlMs'))} map={fmt(order.get('mapMs'))} lock={fmt(order.get('lockMs'))}"
          f" stacks={fmt(order.get('stacks'))}:{fmt(order.get('stackReadMs'))}]"
          f" windowStalls={click['windowReadStalls']}/{fmt(click.get('worstWindowReadConnectionMs'))}"
          f" publish={fmt((click.get('publish') or {}).get('totalMs'))} apply={fmt(click.get('stateApplyMs'))}"
          f" grid={fmt((click.get('gridApply') or {}).get('commitMs'))}/{fmt((click.get('gridApply') or {}).get('totalMs'))}"
          f" filterOptions={fmt((click.get('filterOptions') or {}).get('waitMs'))}+{fmt((click.get('filterOptions') or {}).get('execMs'))}"
          + (f" supersededBy={click['supersededBy']}" if click.get("supersededBy") else "") + "\n")
    s = report["stalls"]
    w("\nSTALLS\n")
    w(f"  store stall lines {s['count']} ({fmt(s.get('per10Min'))} per 10 minutes) per minute {s['perMinute']}; worst connectionMs {fmt(s['worstConnectionMs'])}; "
      f"window reads waited {s['windowReadStalls']} (worst {fmt(s['worstWindowReadConnectionMs'])})\n")
    w("  holders (operation: longest hold ms, times named)\n")
    for op, (longest, count) in list(s["holders"].items())[:15]:
        w(f"    {op:40} {longest:>8} {count:>5}\n")
    m = s["mainThread"]
    w(f"  main-thread stalls {m['count']} worst {fmt(m['worstMs'])} ms by op {dict(list(m['byOp'].items())[:6])}\n")
    ww = s["writeWaits"]
    w(f"  writer waits {ww['count']} worst {fmt(ww['worstMs'])} ms by op {dict(list(ww['byOp'].items())[:6])}\n")
    if report["acts"]:
        w("\nACT TO RESULT (ms)\n")
        for act in report["acts"]:
            w(f"  {fmt(act['act']):14} {act['outcome']:9} {fmt(act['ms']):>7} ms  surface={fmt(act['surface'])}"
              + (f" window={fmt(act.get('window'))} presentedMs="
                 f"{act.get('window') if act.get('window') in UNPRESENTED_WINDOWS else fmt(act.get('presentedMs'))}"
                 if act["outcome"] == "shown" else "")
              + (f" fileWorkDoneMs={fmt(act.get('completedMs'))}" if act['act'] in FILE_WORK else "")
              + (f" supersededBy={act['supersededBy']}" if act.get("supersededBy") else "") + "\n")
    w("\nBACKGROUND PASSES (phase=start lines)\n")
    for op, count in list(report["background"].items())[:15]:
        w(f"  {op:44} {count:>5}\n")
    w("  library passes (phase, reason, directories read, files statted, rows written, events)\n")
    for scan in report.get("rootScans", []):
        w(f"    {fmt(scan['root'])}: {scan['phase']} reason={fmt(scan['reason'])} directoriesRead={fmt(scan['directoriesRead'])} "
          f"filesStatted={fmt(scan['filesStatted'])} rowsWritten={fmt(scan['rowsWritten'])} events={fmt(scan['events'])}\n")
    mem = report["memory"]
    w("\nMEMORY\n")
    w(f"  peak footprint {fmt(mem['peakFootprintMB'])} MB, last {fmt(mem['lastFootprintMB'])} MB, system free min "
      f"{fmt(mem['minFreeMB'])} MB, swap used max {fmt(mem['maxSwapUsedMB'])} MB; search index loaded at "
      f"{fmt(mem['searchIndexLoadedAtMs'])} ms (from {fmt(mem['searchLoadedFrom'])}, opened in {fmt(mem['searchOpenMs'])} ms, "
      f"{fmt(mem['searchMappedMB'])} MB mapped); People applied at {fmt(mem['peopleAppliedAtMs'])} ms\n")
    w(f"  known holders: search vectors {fmt(mem['searchMappedMB'])} MB mapped (clean, not footprint), grid tile images max {fmt(mem['tileCacheMaxMB'])} MB, "
      f"SQLite heap max {fmt(mem['sqliteMaxMB'])} MB\n")
    peak = mem.get("peak")
    if peak:
        w(f"    peak {fmt(peak['footprintMB'])} MB reached by {peak['atMs']} ms (sample {fmt(peak['sample'])}), after "
          f"{fmt(peak['afterMs'])} ms; tour step finished before it {fmt(peak['afterStep'])}, running {fmt(peak['duringStep'])}\n")
    for name, value in mem["milestones"].items():
        w(f"    {name:20} at {value['atMs']:>7} ms  {fmt(value['footprintMB'])} MB\n")
    for event in mem["pressure"]:
        w(f"    memory pressure {event['level']} at {event['atMs']} ms: footprint {fmt(event['footprintMB'])} MB, free "
          f"{fmt(event['freeMB'])} MB, last click {event['lastClick']}, tour step {event['tourStep']}\n")
    print_machine(report.get("machine"), w)
    res = report["resources"]
    d = report.get("disk")
    w("\nDISK (derived folder, from its counters or a reconciliation's census)\n")
    if d:
        w(f"  {fmt(d['folderMB'])} MB from {fmt(d['source'])}; files {d['files']}; MB {d['mb']}\n")
        if d["reconciled"]:
            w(f"  reconciled ({d['reconciled']}) in {fmt(d['reconcileMs'])} ms: removed {fmt(d['removedFiles'])} files, "
              f"{fmt(d['removedMB'])} MB\n")
        else:
            w("  no reconciliation was owed\n")
    else:
        w("  - (no op=derived.folder line)\n")
    w("\nRESOURCES (who held what)\n")
    w(f"  process {res.get('session')}\n")
    if "connections" in res:
        w(f"  connection busy ms by role {res['connections']}\n")
        w("  longest total holds (role:operation, total ms, transactions, longest ms)\n")
        for row in res["topHolds"]:
            w(f"    {row[0]:52} {row[1]:>9} {row[2]:>7} {row[3]:>8}\n")
        w(f"  store changes {res['changes']} by kind {res['changeFacts']}\n")
    print_disk_by_owner(res.get("diskByOwner") or {}, w, report.get("ownersAtEnd"))
    t = report["tour"]
    if t["steps"] or t["config"]:
        w(f"\nTOUR config={t['config']} finished={t['finished']}\n")
        for step in t["steps"]:
            extra = {k: v for k, v in step.items() if k not in ("index", "kind", "label", "outcome", "ms", "at", "atMs")}
            w(f"  {fmt(step.get('index')):>3} {step.get('kind', ''):8} {step.get('label', ''):12} {step.get('outcome', ''):9} "
              f"{fmt(step.get('ms')):>7} ms {extra}\n")
        if t["idle"]:
            w(f"  idle {t['idle']}\n")
    w("\nNOT MEASURED\n")
    for item in report["notMeasured"]:
        w(f"  - {item}\n")


def print_machine(m, w):
    w("\nMACHINE (memory pressure over the session; Otos's process tree)\n")
    if not m or m.get("atLaunch") is None:
        w("  - (no op=system.pressure phase=launch line)\n")
    else:
        w(f"  pressure at launch {m['atLaunch']} (kernel level {fmt(m['systemLevelAtLaunch'])}, "
          f"{fmt(m['availablePercentAtLaunch'])} % available, thermal {fmt(m['thermalAtLaunch'])}, "
          f"low power {fmt(m['lowPowerAtLaunch'])}); worst {m['worst']}; caused {m['pressureCaused']}\n")
        seconds = m["seconds"] or {}
        w("  seconds at each level " + ", ".join(f"{k} {fmt(seconds.get(k))}" for k in PRESSURE_LEVELS) + "\n")
        w(f"  above normal {fmt(m['secondsOutsideNormal'])} s: {fmt(m['secondsFromDescriptions'])} s from description "
          f"writing (accepted; {fmt(m['descriptionRequests'])} requests), {fmt(m['secondsNotFromDescriptions'])} s not\n")
        for change in m["changes"]:
            w(f"    {change['level']} at {change['atMs']} ms (kernel level {fmt(change['systemLevel'])}, "
              f"{fmt(change['availablePercent'])} % available)\n")
    tree = (m or {}).get("tree") or {}
    w(f"  process tree CPU {fmt(tree.get('cpuMs'))} ms: app {fmt(tree.get('appCpuMs'))} ms, helpers "
      f"{fmt(tree.get('helperCpuMs'))} ms over {fmt(tree.get('helpers'))} helper processes; peak footprint app "
      f"{fmt(tree.get('appPeakFootprintMB'))} MB, largest helper {fmt(tree.get('helperPeakFootprintMB'))} MB\n")
    for role, entry in (tree.get("byRole") or {}).items():
        w(f"    {role}: {entry['count']} processes, {entry['cpuMs']} ms CPU, largest {entry['peakFootprintMB']} MB\n")


def print_disk_by_owner(windows, w, at_end=None):
    w("\nDISK READ BY OWNER (MiB; each owner's figure is what it asked of the disk)\n")
    held = (at_end or {}).get("held")
    if at_end is None or held is None:
        w("  held rows: - (no op=owners.status line)\n")
    elif not held:
        w(f"  held rows at {at_end['moment']}: - (no op=owners.held line: a build older than it)\n")
    for row in held or []:
        label = HELD_LABELS.get(row["waitingFor"], row["waitingFor"])
        w(f"  held at {at_end['moment']}: {label}: {fmt(row['count'])} ({row['owner']}, op=owners.held)\n")
    for name in ("session", "idle"):
        window = windows.get(name)
        if not window:
            w(f"  {name}: - (no op=process.usage samples bound it)\n")
            continue
        w(f"  {name}: {window['totalMB']} MiB read, {fmt(window['cpuMs'])} ms CPU\n")
        for row in window["rows"]:
            w(f"    {row['owner']:48} {row['mb']:>8}  ({row['source']})\n")
        w(f"    {'not attributed':48} {window['notAttributedMB']:>8}  (originals read for metadata and renders, "
          f"previews decoded, everything else)\n")
        if not window["catalogMeasured"]:
            w("    catalog pages: - (no op=catalog.store.reads line: a build older than it)\n")
        for key, mb, count in window["catalogTop"]:
            w(f"      {key:46} {mb:>8}  in {count} transactions\n")


def print_matrix(saved, labels, out):
    """One row per tour configuration: launch, each sidebar step's paint, stalls, memory."""
    columns = []
    for scorecard in saved:
        for step in scorecard["report"]["tour"]["steps"]:
            if step.get("kind") == "scope":
                name = f"{step.get('label')}#{step.get('index')}"
                if name not in columns:
                    columns.append(name)
    header = ["configuration", "firstGrid"] + columns + ["stalls", "worstWait", "peakMB"]
    widths = [max(18, max((len(l) for l in labels), default=0))] + [max(9, len(c)) for c in header[1:]]
    out.write("  ".join(h.ljust(w) if i == 0 else h.rjust(w) for i, (h, w) in enumerate(zip(header, widths))) + "\n")
    for label, scorecard in zip(labels, saved):
        report = scorecard["report"]
        paints = {}
        for step in report["tour"]["steps"]:
            if step.get("kind") == "scope":
                value = step.get("paintMs") if step.get("outcome") == "reported" else step.get("outcome")
                paints[f"{step.get('label')}#{step.get('index')}"] = value
        cells = [label, fmt((report.get("launch") or {}).get("firstGridMs"))]
        cells += [fmt(paints.get(c)) for c in columns]
        cells += [fmt(report["stalls"]["count"]), fmt(report["stalls"]["worstConnectionMs"]), fmt(report["memory"]["peakFootprintMB"])]
        out.write("  ".join(c.ljust(w) if i == 0 else c.rjust(w) for i, (c, w) in enumerate(zip(cells, widths))) + "\n")


def compare(report, rows, saved, out):
    """Deltas against a saved scorecard of the same kind of session. A launch session's numbers
    are under the launch's load and a settled one's are not, so two kinds are never compared:
    the mismatch is printed instead. A saved scorecard older than the kind field predates
    settled tours: it is compared with a launch or untoured session, never a settled one."""
    saved_report = saved.get("report", {})
    kind = report.get("sessionKind", "launch")
    saved_kind = saved_report.get("sessionKind")
    if saved_kind is None and not kind.startswith("settled"):
        saved_kind = kind
    if kind != saved_kind:
        out.write(f"\nNOT COMPARED WITH {saved_report.get('session')}: this session is {kind}, that one "
                  f"{saved_kind or 'older than settled tours (a launch tour)'}; "
                  f"compare a {kind} session with a {kind} one\n")
        return False
    before = {r["label"]: r for r in saved.get("verdicts", [])}
    out.write(f"\nCOMPARED WITH {saved_report.get('session')} (both {kind})\n")
    for row in rows:
        # A label or field the saved scorecard lacks (an older one) reads as unknown, never 0.
        old_row = before.get(row["label"]) or {}
        old = old_row.get("value")
        if old is None or row["value"] is None:
            delta = "-"
        else:
            # A rate (stalls per 10 minutes) is a float; every other value is whole.
            change = row["value"] - old
            delta = f"{change:+d}" if isinstance(change, int) else f"{change:+.1f}"
        paged = ""
        if old_row.get("pagedIn") is not None or row.get("pagedIn") is not None:
            paged = f"  pagedIn {fmt(old_row.get('pagedIn'))} → {fmt(row.get('pagedIn'))}"
        out.write(f"  {row['label'][:44]:44} {old_row.get('state') or fmt(old):>9} → "
                  f"{row.get('state') or fmt(row['value']):>9}  {delta}{paged}\n")
    return True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--input", help="ndjson from log show, or - for stdin")
    parser.add_argument("--live", help="a tour's live capture (log stream --style compact); --input is then the "
                                       "log show read of the same window, only counted")
    parser.add_argument("--live-end", choices=("seen", "missing"), default="missing",
                        help="whether the capture's end marker came through")
    parser.add_argument("--image", help="the executable a --live capture was taken of")
    parser.add_argument("--targets")
    parser.add_argument("--dev", action="store_true", help="the dev build's newest session, not the installed app's")
    parser.add_argument("--session", help="a session id from op=sessionStart")
    parser.add_argument("--pid", type=int, help="the session of this process, whichever build it is")
    parser.add_argument("--window", action="store_true", help="the whole input, not one session")
    parser.add_argument("--json", help="write the scorecard as JSON here")
    parser.add_argument("--compare", help="a saved scorecard JSON to print deltas against")
    parser.add_argument("--matrix", nargs="+", help="saved tour scorecards to print as one ablation table")
    parser.add_argument("--labels", help="the matrix rows' names, |-separated")
    parser.add_argument("--tour-silence-limit", nargs="+", type=int, metavar="SECONDS",
                        help="IDLE DEADLINE [SETTLE]: print the seconds without a tour line after which a tour with this "
                             "idle, step deadline and settle deadline is stuck")
    parser.add_argument("--trash-leftovers", nargs=2, metavar=("NAMES", "TRASH"),
                        help="test the Trash for each generated file name in NAMES; remove and report any found")
    args = parser.parse_args(argv)
    if args.trash_leftovers:
        return report_trash_leftovers(*args.trash_leftovers, sys.stdout)
    if args.tour_silence_limit:
        if len(args.tour_silence_limit) not in (2, 3, 4):
            parser.error("--tour-silence-limit takes IDLE DEADLINE [SETTLE [LIBRARY]]")
        print(tour_silence_limit(*args.tour_silence_limit))
        return 0
    if args.matrix:
        saved = []
        for path in args.matrix:
            with open(path, encoding="utf-8") as handle:
                saved.append(json.load(handle))
        labels = args.labels.split("|") if args.labels else args.matrix
        print_matrix(saved, labels, sys.stdout)
        return 0
    if not args.input or not args.targets:
        parser.error("--input and --targets are required")
    if args.input == "-":
        events = read_events(sys.stdin)
    else:
        with open(args.input, encoding="utf-8") as stream:
            events = read_events(stream)
    log_show_events, drops = None, None
    if args.live:
        if not args.image:
            parser.error("--live needs --image")
        log_show_events = events
        with open(args.live, encoding="utf-8", errors="replace") as stream:
            events, drops = read_live_capture(stream, args.image)
    with open(args.targets, encoding="utf-8") as handle:
        targets = {t["metric"]: t for t in json.load(handle)["targets"]}
    if args.window:
        session_start, body = None, events
    elif args.pid:
        found = [(s, b) for s, b in sessions(events) if s.pid == args.pid]
        session_start, body = found[-1] if found else (None, events)
    else:
        session_start, body = pick_session(events, installed=not args.dev, session_id=args.session)
        if session_start is None:
            print("op=scorecard phase=failed reason=noSession hint=no op=sessionStart for that build in the window")
            return 0
    report = analyse(body, session_start)
    pid = session_start.pid if session_start else args.pid
    if args.live:
        comparable = live_comparable(log_show_events, pid)
        report["capture"] = capture_summary("live", len(body), drops, args.live_end, len(comparable),
                                            missing_from_capture(comparable, body))
    else:
        report["capture"] = capture_summary("logShow", len(body))
    rows = verdicts(report, targets)
    print_report(report, rows, sys.stdout)
    if args.compare:
        with open(args.compare, encoding="utf-8") as handle:
            compare(report, rows, json.load(handle), sys.stdout)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump({"report": report, "verdicts": rows}, handle, indent=1, default=str)
        print(f"\nop=scorecard phase=saved json={args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
