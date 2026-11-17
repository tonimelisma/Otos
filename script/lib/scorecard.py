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
    __slots__ = ("time", "op", "phase", "fields", "pid", "image", "message")

    def __init__(self, raw):
        self.message = raw.get("eventMessage", "")
        self.fields = parse_fields(self.message)
        self.op = self.fields.get("op")
        self.phase = self.fields.get("phase")
        self.time = parse_time(raw["timestamp"])
        self.pid = raw.get("processID")
        self.image = raw.get("processImagePath", "")

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
    """Every act timed from its intent to its result on the grid (`op=ui.actToResult`), and,
    for an act whose file work follows, from its intent to that work's end (`completedMs`)."""
    result = []
    for line in of(events, "ui.actToResult"):
        if line.phase in ("finish", "abandoned"):
            act = line.fields.get("act")
            entry = {"act": act, "outcome": "shown" if line.phase == "finish" else "abandoned",
                     "ms": line.num("ms"), "surface": line.fields.get("surface"),
                     "supersededBy": line.fields.get("supersededBy")}
            if act in FILE_WORK and line.phase == "finish":
                entry["completedMs"] = act_completion(events, act, line)
            result.append(entry)
    return result


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


def tour_silence_limit(idle_seconds, deadline_seconds):
    """How long a tour may go without a line before the script calls it stuck, in seconds.
    The longest stretch a working tour is silent is its idle step (`idle_seconds`, one sleep)
    or one step's wait for its fact (at most `deadline_seconds`, then the step reports
    `outcome=deadline`), whichever is longer; the margin covers the untimed reads between a
    step's waits and the launch before the first line. time: deadline"""
    return max(int(idle_seconds), int(deadline_seconds)) + TOUR_SILENCE_MARGIN_SECONDS


TOUR_SILENCE_MARGIN_SECONDS = 60

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
    if uses:
        total = store_use(uses[-1])
        result["connections"] = total["busyMs"]
        result["topHolds"] = sorted(([k, *v] for k, v in total["holds"].items()), key=lambda row: -row[1])[:12]
        result["writer"] = [row for row in result["topHolds"] if row[0].startswith("main.writer:")]
        result["changes"] = total["changes"]
        result["changeFacts"] = total["changeFacts"]
    return result


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
        "steps": steps,
        "idle": idle,
    }


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
        "memory": memory(start, events, toured["steps"], click_list),
        "resources": resources(events),
        "tour": toured,
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
            searches += 1
            name = f"search {'first' if searches == 1 else 'again'} {step.get('label')}"
            add("search.firstResultsMs", f"{name} first results", int_or_none(step.get("firstMs")))
            add("search.completeMs", f"{name} complete", step_ms(step))
        elif step.get("kind") in QUERY_STEPS:
            add("query.resultMs", f"{step['kind']} {step.get('label')}", step_ms(step))
        elif step.get("kind") in PHOTO_STEPS:
            add("photo.stepMs", f"{step['kind']} {step.get('label')}", step_ms(step))
    for act in report["acts"]:
        if act["outcome"] == "shown":
            add("act.resultMs", f"act {act['act']}", act["ms"])
            if act["act"] in FILE_WORK:
                add("act.completedMs", f"act {act['act']} file work done", act.get("completedMs"))
    add("stalls.count", "store stall lines", report["stalls"]["count"])
    add("stalls.per10Min", "store stall lines per 10 minutes", report["stalls"]["per10Min"])
    add("mainThreadStalls.count", "main-thread stalls", report["stalls"]["mainThread"]["count"])
    add("mainThreadStalls.worstMs", "worst main-thread stall ms", report["stalls"]["mainThread"]["worstMs"] or 0)
    add("memory.peakFootprintMB", "peak footprint MB", report["memory"]["peakFootprintMB"])
    add("disk.derivedFolderMB", "derived folder MB", (report.get("disk") or {}).get("folderMB"))
    return rows


# ── Output ──────────────────────────────────────────────────────────────────────

def fmt(value):
    return "-" if value is None else str(value)


def print_report(report, rows, out):
    w = out.write
    w(f"op=scorecard session={report.get('session')} build={report.get('build')} pid={report.get('pid')} "
      f"durationS={report.get('durationS')} clicks={len(report['clicks'])} stalls={report['stalls']['count']} "
      f"peakFootprintMB={fmt(report['memory']['peakFootprintMB'])} "
      f"fails={sum(1 for r in rows if r['verdict'] == 'FAIL')}\n")
    for row in rows:
        if row["metric"] == "tour.deadline":
            w(f"FAIL: tour {row['label']} after {fmt(row['value'])} ms: the fact it waits on never came\n")
    w("\n")
    w("USER-FELT NUMBERS\n")
    w(f"  {'number':44} {'value':>9} {'target':>8}  verdict\n")
    for row in rows:
        w(f"  {row['label'][:44]:44} {fmt(row['value']):>9} {row['target']:>8}  {row['verdict']}"
          + (f"  pagedIn={row['pagedIn']}" if row.get("pagedIn") is not None else "") + "\n")
    launched = report.get("launch")
    if launched:
        w("\nLAUNCH (ms from session start)\n")
        w(f"  window attached {fmt(launched['windowAttachedMs'])}, database open took {fmt(launched['databaseOpenMs'])} "
          f"(migrations {fmt(launched['databaseMigrations'])}), catalog open at {fmt(launched['catalogOpenAtMs'])} "
          f"(migrations {fmt(launched['catalogMigrationsMs'])} ms), first grid {fmt(launched['firstGridMs'])} "
          f"(catalog {fmt(launched['firstGridCatalogMs'])}) in {launched['scopeKind']}, {fmt(launched['items'])} items, "
          f"owners quiescent {fmt(launched['ownersQuiescentMs'])}\n")
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
              + (f" fileWorkDoneMs={fmt(act.get('completedMs'))}" if act['act'] in FILE_WORK else "")
              + (f" supersededBy={act['supersededBy']}" if act.get("supersededBy") else "") + "\n")
    w("\nBACKGROUND PASSES (phase=start lines)\n")
    for op, count in list(report["background"].items())[:15]:
        w(f"  {op:44} {count:>5}\n")
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
    before = {r["label"]: r for r in saved.get("verdicts", [])}
    out.write("\nCOMPARED WITH " + str(saved.get("report", {}).get("session")) + "\n")
    for row in rows:
        # A label or field the saved scorecard lacks (an older one) reads as unknown, never 0.
        old_row = before.get(row["label"]) or {}
        old = old_row.get("value")
        if old is None or row["value"] is None:
            delta = "-"
        else:
            delta = f"{row['value'] - old:+d}"
        paged = ""
        if old_row.get("pagedIn") is not None or row.get("pagedIn") is not None:
            paged = f"  pagedIn {fmt(old_row.get('pagedIn'))} → {fmt(row.get('pagedIn'))}"
        out.write(f"  {row['label'][:44]:44} {fmt(old):>9} → {fmt(row['value']):>9}  {delta}{paged}\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--input", help="ndjson from log show, or - for stdin")
    parser.add_argument("--targets")
    parser.add_argument("--dev", action="store_true", help="the dev build's newest session, not the installed app's")
    parser.add_argument("--session", help="a session id from op=sessionStart")
    parser.add_argument("--pid", type=int, help="the session of this process, whichever build it is")
    parser.add_argument("--window", action="store_true", help="the whole input, not one session")
    parser.add_argument("--json", help="write the scorecard as JSON here")
    parser.add_argument("--compare", help="a saved scorecard JSON to print deltas against")
    parser.add_argument("--matrix", nargs="+", help="saved tour scorecards to print as one ablation table")
    parser.add_argument("--labels", help="the matrix rows' names, |-separated")
    parser.add_argument("--tour-silence-limit", nargs=2, type=int, metavar=("IDLE", "DEADLINE"),
                        help="print the seconds without a tour line after which a tour with this idle and step deadline is stuck")
    args = parser.parse_args(argv)
    if args.tour_silence_limit:
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
