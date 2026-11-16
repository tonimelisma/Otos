#!/usr/bin/env python3
"""Summarize one script/survey.sh run directory into summary.json and summary.md.

Usage: survey-summary.py <survey dir>

Reads <dir>/raw (rusage, vmmap, footprint, vm_stat, top, nettop, iostat, sample, heap,
the exported Time Profiler table, the app's unified log and the folder sizes) and writes
one summary per resource, per phase of the session (each snapshot closes a phase).

The summary holds function, thread, process and region names, counts and sizes. It never
copies a log message, a mapped file's path or a file name: Otos's lines are reduced to
their `op=` name and numeric fields, and every string that still looks like a path is
replaced before writing.
"""

import collections
import glob
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

OTOS_BINARIES = {"Otos", "OtosKit", "Otos.debug.dylib"}
OWNER_PREFIXES = re.compile(
    r"^(?:(?:closure #\d+ in |implicit closure #\d+ in |partial apply for |specialized |"
    r"merged |protocol witness for |thunk for |reabstraction thunk helper from |"
    r"\(extension in [^)]*\):|static |@objc |one-time initialization function for |"
    r"generic specialization <[^>]*> of |default argument \d+ of |"
    r"outlined (?:copy|assign with take|assign with copy|destroy|init with take|init with copy|retain|release) of )\s*)+"
)
PATHLIKE = re.compile(r"(/Users/|/Volumes/|/private/var/|~/)[^\s,;)\]]*")


def mb(value):
    return round(value / 1048576, 1) if value is not None else None


def size_to_bytes(text):
    text = text.strip().rstrip("+-")
    match = re.fullmatch(r"([0-9.]+)\s*([BKMGT]?)B?", text)
    if not match:
        return None
    number, unit = float(match.group(1)), match.group(2)
    return int(number * {"": 1, "B": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}[unit])


def redact(value):
    if isinstance(value, str):
        return PATHLIKE.sub("<path>", value)
    if isinstance(value, list):
        return [redact(item) for item in value]
    if isinstance(value, dict):
        return {key: redact(item) for key, item in value.items()}
    return value


def read_ndjson(path):
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path, errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if line.startswith("{"):
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return rows


# ── Snapshots and phases ─────────────────────────────────────────────────────
def snapshots(raw):
    events = []
    with open(os.path.join(raw, "events.tsv")) as handle:
        next(handle)
        for line in handle:
            epoch, kind, label, detail = (line.rstrip("\n").split("\t") + [""] * 4)[:4]
            events.append({"epoch": int(epoch), "kind": kind, "label": label, "detail": detail})
    snaps = [
        {"n": e["detail"].split("=")[1], "label": e["label"], "epoch": e["epoch"]}
        for e in events
        if e["kind"] == "snapshot"
    ]
    return events, snaps


def rusage_by_snapshot(raw, app_pid):
    by_snap = collections.defaultdict(list)
    for row in read_ndjson(os.path.join(raw, "rusage.ndjson")):
        by_snap[row["snapshot"]].append(row)
    result = {}
    readers_last = {}
    for n in sorted(by_snap):
        rows = by_snap[n]
        app = next((r for r in rows if r["pid"] == app_pid), None)
        for row in rows:
            if row["pid"] != app_pid:
                readers_last[row["pid"]] = row
        result[n] = {"app": app, "readers": dict(readers_last)}
    return result


def counters(entry):
    """App plus every text reader seen so far: cumulative CPU, disk and energy."""
    total = collections.Counter()
    rows = ([entry["app"]] if entry["app"] else []) + list(entry["readers"].values())
    for row in rows:
        for key in ("cpu_user_ns", "cpu_system_ns", "diskio_read_bytes", "diskio_written_bytes",
                    "logical_written_bytes", "billed_energy_nj", "pageins"):
            total[key] += row.get(key, 0)
    return total


# ── Memory ───────────────────────────────────────────────────────────────────
def parse_vmmap(path):
    regions, zones, header = [], [], {}
    if not os.path.exists(path):
        return {"regions": regions, "zones": zones, "header": header}
    section = None
    with open(path, errors="replace") as handle:
        for line in handle:
            if line.startswith("Physical footprint:"):
                header["footprint_bytes"] = size_to_bytes(line.split(":", 1)[1])
            elif line.startswith("Physical footprint (peak):"):
                header["footprint_peak_bytes"] = size_to_bytes(line.split(":", 1)[1])
            elif line.startswith("REGION TYPE"):
                section = "region"
            elif line.startswith("MALLOC ZONE"):
                section = "zone"
            elif line.startswith("===") or not line.strip():
                if not line.strip():
                    section = None if section == "zone" else section
                continue
            elif section == "region" and not line.startswith("TOTAL"):
                line = line.split("see MALLOC")[0].rstrip()
                parts = line.split()
                if len(parts) >= 9:
                    name = " ".join(parts[:-8])
                    values = [size_to_bytes(p) for p in parts[-8:-1]]
                    if None not in values:
                        regions.append({"region": name, "virtual": values[0], "resident": values[1],
                                        "dirty": values[2], "swapped": values[3],
                                        "footprint": values[2] + values[3]})
            elif section == "region" and line.startswith("TOTAL"):
                section = None
            elif section == "zone" and not line.startswith("TOTAL"):
                parts = line.split()
                if len(parts) >= 10:
                    name = re.sub(r"_0x[0-9a-f]+$", "", parts[0])
                    dirty, swapped = size_to_bytes(parts[3]), size_to_bytes(parts[4])
                    allocated = size_to_bytes(parts[6])
                    if None not in (dirty, swapped):
                        zones.append({"zone": name, "dirty_plus_swapped": dirty + swapped,
                                      "allocated": allocated, "frag": parts[8]})
    regions.sort(key=lambda r: r["footprint"], reverse=True)
    return {"regions": regions, "zones": zones, "header": header}


def parse_vm(path):
    stats = {}
    if not os.path.exists(path):
        return stats
    page = 16384
    with open(path, errors="replace") as handle:
        for line in handle:
            match = re.search(r"page size of (\d+) bytes", line)
            if match:
                page = int(match.group(1))
            match = re.match(r'^"?([A-Za-z -]+)"?:\s+(\d+)\.', line)
            if match:
                stats[match.group(1).strip().lower().replace(" ", "_")] = int(match.group(2))
            match = re.search(r"used = ([0-9.]+)M", line)
            if match and "swapusage" in line:
                stats["swap_used_bytes"] = int(float(match.group(1)) * 1048576)
            match = re.match(r"kern\.memorystatus_vm_pressure_level: (\d+)", line)
            if match:
                stats["pressure_level"] = int(match.group(1))
            match = re.match(r"kern\.memorystatus_level: (\d+)", line)
            if match:
                stats["memorystatus_free_percent"] = int(match.group(1))
    stats["page_bytes"] = page
    return stats


# ── top / nettop / iostat ────────────────────────────────────────────────────
def parse_top(path, last_block=True):
    if not os.path.exists(path):
        return []
    with open(path, errors="replace") as handle:
        lines = handle.read().splitlines()
    starts = [i for i, line in enumerate(lines) if line.startswith("PID")]
    if not starts:
        return []
    start = starts[-1] if last_block else starts[0]
    columns = lines[start].split()
    rows = []
    for line in lines[start + 1:]:
        if not line.strip() or line.startswith("Processes:"):
            break
        # COMMAND may hold spaces: the fixed-width command column is 16 characters.
        pid = line[:7].strip()
        command = line[7:24].strip()
        rest = line[24:].split()
        row = {"pid": pid, "command": command}
        for name, value in zip(columns[2:], rest):
            row[name.lower()] = value
        rows.append(row)
    return rows


def parse_nettop(path):
    result = {}
    if not os.path.exists(path):
        return result
    with open(path, errors="replace") as handle:
        for line in handle:
            parts = line.strip().split(",")
            if len(parts) >= 3 and parts[1].isdigit() and parts[2].isdigit():
                name, _, pid = parts[0].rpartition(".")
                result[(name, pid)] = (int(parts[1]), int(parts[2]))
    return result


def parse_iostat(path):
    disks, samples = [], collections.defaultdict(list)
    if not os.path.exists(path):
        return {}
    with open(path, errors="replace") as handle:
        lines = handle.read().splitlines()
    for line in lines:
        if "disk" in line and not disks:
            disks = line.split()[:-1] if line.split()[-1] == "cpu" else line.split()
            continue
        parts = line.split()
        if disks and parts and re.fullmatch(r"[0-9.]+", parts[0]):
            for i, disk in enumerate(disks):
                try:
                    samples[disk].append(float(parts[i * 3 + 2]))
                except (IndexError, ValueError):
                    pass
    # The first line is the average since boot, not a session interval.
    return {
        disk: {"intervals": len(values) - 1, "mean_mb_s": round(sum(values[1:]) / max(1, len(values) - 1), 1),
               "max_mb_s": round(max(values[1:] or [0]), 1)}
        for disk, values in samples.items() if len(values) > 1
    }


# ── Threads (sample) and heap ────────────────────────────────────────────────
def parse_sample(path):
    threads = []
    if not os.path.exists(path):
        return threads
    with open(path, errors="replace") as handle:
        lines = handle.read().splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if line.startswith("Call graph:"))
    except StopIteration:
        return threads
    current = None
    for line in lines[start + 1:]:
        if not line.strip():
            if current:
                threads.append(current)
            break
        match = re.match(r"^    (\d+) (Thread_\d+.*)$", line)
        if match:
            if current:
                threads.append(current)
            name = re.sub(r"Thread_\d+\s*", "", match.group(2)).strip(" :") or "thread"
            current = {"thread": name, "samples": int(match.group(1)), "frames": []}
            continue
        frame = re.match(r"^(\s*[+!:| ]*)(\d+) (.*?)(?:\s+\(in ([^)]+)\))?(?:\s+\+.*)?$", line)
        if frame and current is not None:
            current["frames"].append((len(frame.group(1)), int(frame.group(2)), frame.group(3).strip(),
                                      frame.group(4) or ""))
    out = []
    for thread in threads:
        frames = thread["frames"]
        best = None
        for i, (depth, count, symbol, image) in enumerate(frames):
            nxt = frames[i + 1][0] if i + 1 < len(frames) else -1
            if nxt <= depth and (best is None or count > best[1]):
                best = (depth, count, symbol, image)
        out.append({"thread": thread["thread"], "samples": thread["samples"],
                    "heaviest_leaf": best[2] if best else None, "leaf_image": best[3] if best else None,
                    "leaf_samples": best[1] if best else 0})
    out.sort(key=lambda t: t["samples"], reverse=True)
    return out


def parse_heap(path):
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path, errors="replace") as handle:
        for line in handle:
            match = re.match(r"^\s*(\d+)\s+(\d+)\s+([0-9.]+)\s+(\S.*?)\s*$", line)
            if match:
                # CLASS_NAME, TYPE and BINARY are separated by runs of spaces; a
                # non-object row has neither type nor binary.
                rest = re.split(r"\s{2,}", match.group(4))
                rows.append({"count": int(match.group(1)), "bytes": int(match.group(2)), "class": rest[0],
                             "type": rest[1] if len(rest) > 1 else "",
                             "binary": rest[2] if len(rest) > 2 else ""})
    rows.sort(key=lambda r: r["bytes"], reverse=True)
    return rows[:20]


# ── Time Profiler ────────────────────────────────────────────────────────────
def owner_of(symbol):
    name = OWNER_PREFIXES.sub("", symbol)
    name = re.sub(r"^(OtosKit|Otos)\.", "", name)
    match = re.match(r"([A-Z][A-Za-z0-9_]*)", name)
    return match.group(1) if match else name.split("(")[0][:40]


def parse_time_profile(path, start_epoch, boundaries):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return None
    frames, binaries, threads, backtraces, weights, times = {}, {}, {}, {}, {}, {}
    self_all, self_main, self_other = collections.Counter(), collections.Counter(), collections.Counter()
    owners, owners_main, by_thread = collections.Counter(), collections.Counter(), collections.Counter()
    by_phase = collections.Counter()
    owners_by_phase = collections.defaultdict(collections.Counter)
    total = main = 0

    def ref(elem, table):
        key = elem.get("ref") or elem.get("id")
        return table.get(key)

    for _, elem in ET.iterparse(path, events=("end",)):
        tag = elem.tag
        if tag == "binary" and elem.get("id"):
            binaries[elem.get("id")] = elem.get("name")
        elif tag == "frame" and elem.get("id"):
            binary = elem.find("binary")
            frames[elem.get("id")] = (elem.get("name") or "?", ref(binary, binaries) if binary is not None else "")
        elif tag == "thread" and elem.get("id"):
            threads[elem.get("id")] = elem.get("fmt") or ""
        elif tag in ("backtrace", "tagged-backtrace") and elem.get("id"):
            backtraces[elem.get("id")] = [f.get("ref") or f.get("id") for f in elem.iter("frame")]
        elif tag == "weight" and elem.get("id"):
            weights[elem.get("id")] = int(elem.text or 0)
        elif tag == "sample-time" and elem.get("id"):
            times[elem.get("id")] = int(elem.text or 0)
        elif tag == "row":
            thread_elem = elem.find("thread")
            weight_elem = elem.find("weight")
            time_elem = elem.find("sample-time")
            bt_elem = elem.find("tagged-backtrace")
            if bt_elem is None:
                bt_elem = elem.find("backtrace")
            thread = ref(thread_elem, threads) if thread_elem is not None else ""
            weight = ref(weight_elem, weights) if weight_elem is not None else 0
            sample_ns = ref(time_elem, times) if time_elem is not None else 0
            stack = [frames.get(fid, ("?", "")) for fid in (ref(bt_elem, backtraces) or [])] if bt_elem is not None else []
            weight = weight or 0
            is_main = thread.startswith("Main Thread")
            thread_name = re.sub(r"\s*\(0x[0-9a-f]+\)", "", thread)
            thread_name = re.sub(r"\s*\([^()]*pid: \d+\)\s*$", "", thread_name).strip() or "thread"
            leaf = stack[0][0] if stack else "?"
            if re.fullmatch(r"0x[0-9a-f]+", leaf):
                leaf = "(unsymbolicated in %s)" % (stack[0][1] or "?")
            owner = next((owner_of(name) for name, binary in stack if binary in OTOS_BINARIES),
                         "(system: %s)" % (stack[0][1] if stack else "?"))
            if owner.startswith("__debug_main_executable") or owner == "main":
                # The only Otos frame is the entry point: framework work on the run loop
                # (SwiftUI, AppKit, Core Animation) that no Otos type is on the stack for.
                owner = "(frameworks under the run loop: %s)" % (stack[0][1] if stack else "?")
            total += weight
            self_all[leaf] += weight
            owners[owner] += weight
            by_thread[thread_name] += weight
            if is_main:
                main += weight
                self_main[leaf] += weight
                owners_main[owner] += weight
            else:
                self_other[leaf] += weight
            epoch = start_epoch + sample_ns / 1e9
            phase = next((label for label, end in boundaries if epoch <= end), boundaries[-1][0] if boundaries else "session")
            by_phase[phase] += weight
            owners_by_phase[phase][owner] += weight
            elem.clear()

    def top(counter, n=15):
        return [{"name": name, "ms": round(w / 1e6, 1)} for name, w in counter.most_common(n)]

    return {
        "on_cpu_ms": round(total / 1e6, 1),
        "main_thread_on_cpu_ms": round(main / 1e6, 1),
        "top_self_functions": top(self_all),
        "top_self_main_thread": top(self_main, 10),
        "top_self_other_threads": top(self_other, 10),
        "top_owners": top(owners),
        "top_owners_main_thread": top(owners_main, 10),
        "top_threads": top(by_thread, 12),
        "by_phase_ms": {k: round(v / 1e6, 1) for k, v in by_phase.items()},
        "owners_by_phase": {k: top(v, 5) for k, v in owners_by_phase.items()},
    }


def trace_duration(raw):
    path = os.path.join(raw, "cpu-toc.xml")
    if not os.path.exists(path):
        return None
    match = re.search(r"<duration>([0-9.]+)</duration>", open(path, errors="replace").read())
    return float(match.group(1)) if match else None


def trace_start_epoch(raw):
    path = os.path.join(raw, "cpu-toc.xml")
    if not os.path.exists(path):
        return None
    text = open(path, errors="replace").read()
    match = re.search(r"<start-date>([^<]+)</start-date>", text)
    if not match:
        return None
    from datetime import datetime
    stamp = match.group(1)
    stamp = re.sub(r"(\.\d+)?([+-]\d\d):(\d\d)$", lambda m: (m.group(1) or "") + m.group(2) + m.group(3), stamp)
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            return datetime.strptime(stamp, fmt).timestamp()
        except ValueError:
            pass
    return None


# ── The app's log, reduced to names and numbers ──────────────────────────────
def parse_log(raw):
    ops = collections.Counter()
    stalls = {"mainThreadStall": [], "catalogStoreStall": []}
    store_ops = collections.Counter()
    descriptions = 0
    first_description_epoch = None
    for row in read_ndjson(os.path.join(raw, "log.ndjson")):
        message = row.get("eventMessage", "")
        match = re.match(r"op=([A-Za-z0-9_.]+)", message)
        if not match:
            continue
        op = match.group(1)
        phase = re.search(r"\bphase=([A-Za-z0-9_]+)", message)
        ops[op + (" " + phase.group(1) if phase else "")] += 1
        if op == "mainThreadStall":
            value = re.search(r"\bstallMs=(\d+)", message)
            if value:
                stalls["mainThreadStall"].append(int(value.group(1)))
        elif op == "catalog.store.stall":
            value = re.search(r"\bwaitMs=(\d+)", message)
            operation = re.search(r"\boperation=([A-Za-z0-9_.]+)", message)
            if value:
                stalls["catalogStoreStall"].append(int(value.group(1)))
            if operation:
                store_ops[operation.group(1)] += 1
        elif op == "description":
            descriptions += 1
    def stats(values):
        return {"count": len(values), "max_ms": max(values) if values else None,
                "total_ms": sum(values) if values else 0}
    return {
        "op_counts": [{"op": k, "count": v} for k, v in ops.most_common(30)],
        "main_thread_stalls": stats(stalls["mainThreadStall"]),
        "store_stalls": stats(stalls["catalogStoreStall"]),
        "store_stall_operations": [{"operation": k, "count": v} for k, v in store_ops.most_common(10)],
        "description_lines": descriptions,
    }


# ── Files ────────────────────────────────────────────────────────────────────
def parse_files(path):
    rows = {}
    if not os.path.exists(path):
        return rows
    with open(path) as handle:
        next(handle)
        for line in handle:
            kind, sub, size, files = line.rstrip("\n").split("\t")
            key = (kind, sub)
            prev = rows.get(key, (0, 0))
            rows[key] = (prev[0] + int(size), prev[1] + int(files))
    return rows


# ── Everything ───────────────────────────────────────────────────────────────
def summarize(out_dir):
    raw = os.path.join(out_dir, "raw")
    session = json.load(open(os.path.join(raw, "session.json")))
    app_pid = session["pid"]
    events, snaps = snapshots(raw)
    start = session["session_start"]
    usage = rusage_by_snapshot(raw, app_pid)
    boundaries = [(s["label"], s["epoch"]) for s in snaps]

    # Per phase: what Otos (app + text readers) spent between two snapshots.
    phases = []
    previous = collections.Counter()
    previous_vm = None
    vm_first = None
    for snap in snaps:
        n = snap["n"]
        entry = usage.get(n)
        vm = parse_vm(os.path.join(raw, "vm-%s.txt" % n))
        vmmap = parse_vmmap(os.path.join(raw, "vmmap-%s.txt" % n))
        row = {"phase": snap["label"], "at_s": snap["epoch"] - start}
        if entry and entry["app"]:
            now = counters(entry)
            delta = now - previous
            previous = now
            app = entry["app"]
            row.update({
                "otos_phys_footprint_mb": mb(app["phys_footprint_bytes"]),
                "otos_lifetime_max_footprint_mb": mb(app["lifetime_max_phys_footprint_bytes"]),
                "otos_resident_mb": mb(app["resident_bytes"]),
                "readers": len(entry["readers"]),
                "readers_footprint_mb": mb(sum(r["phys_footprint_bytes"] for r in entry["readers"].values())),
                "cpu_s": round((delta["cpu_user_ns"] + delta["cpu_system_ns"]) / 1e9, 2),
                "disk_read_mb": mb(delta["diskio_read_bytes"]),
                "disk_written_mb": mb(delta["diskio_written_bytes"]),
                "energy_j": round(delta["billed_energy_nj"] / 1e9, 2),
            })
        row["top_regions_mb"] = [{"region": r["region"], "footprint_mb": mb(r["footprint"]),
                                  "resident_mb": mb(r["resident"])} for r in vmmap["regions"][:8]]
        row["malloc_zones_mb"] = [{"zone": z["zone"], "dirty_plus_swapped_mb": mb(z["dirty_plus_swapped"]),
                                   "allocated_mb": mb(z["allocated"]), "frag": z["frag"]} for z in vmmap["zones"][:4]]
        if vm:
            page = vm["page_bytes"]
            row["system"] = {
                "free_mb": mb(vm.get("pages_free", 0) * page),
                "compressor_mb": mb(vm.get("pages_occupied_by_compressor", 0) * page),
                "swap_used_mb": mb(vm.get("swap_used_bytes")),
                "pressure_level": vm.get("pressure_level"),
                "memorystatus_free_percent": vm.get("memorystatus_free_percent"),
            }
            if previous_vm:
                row["system"]["pageouts_since_previous"] = vm.get("pageouts", 0) - previous_vm.get("pageouts", 0)
                row["system"]["swapouts_since_previous"] = vm.get("swapouts", 0) - previous_vm.get("swapouts", 0)
                row["system"]["swap_growth_mb"] = mb((vm.get("swap_used_bytes") or 0) - (previous_vm.get("swap_used_bytes") or 0))
            previous_vm = vm
            vm_first = vm_first or vm
        neighbours = parse_top(os.path.join(raw, "neighbours-%s.txt" % n))
        grouped = collections.defaultdict(lambda: {"processes": 0, "mem_mb": 0.0, "cpu": 0.0})
        for proc in neighbours:
            group = grouped[proc["command"]]
            group["processes"] += 1
            group["mem_mb"] += mb(size_to_bytes(proc.get("mem", "0")) or 0)
            try:
                group["cpu"] += float(proc.get("%cpu", 0))
            except ValueError:
                pass
        row["neighbours"] = sorted(({"command": k, **{kk: round(vv, 1) for kk, vv in v.items()}}
                                    for k, v in grouped.items()), key=lambda g: g["mem_mb"], reverse=True)
        topmem = parse_top(os.path.join(raw, "top-mem-%s.txt" % n), last_block=False)
        row["top_memory_processes"] = [{"command": p["command"], "mem": p.get("mem")} for p in topmem[:10]]
        topcpu = parse_top(os.path.join(raw, "top-cpu-%s.txt" % n))
        row["top_cpu_processes"] = [{"command": p["command"], "cpu": p.get("%cpu"), "power": p.get("power")}
                                    for p in topcpu[:10]]
        phases.append(row)

    # Whole session, other processes: rusage deltas between the first and last snapshot.
    all_files = sorted(glob.glob(os.path.join(raw, "all-*.ndjson")))
    others = []
    unreadable = None
    if len(all_files) >= 2:
        first = {(r["pid"], r["command"]): r for r in read_ndjson(all_files[0]) if "pid" in r}
        last_rows = read_ndjson(all_files[-1])
        unreadable = next((r["unreadable"] for r in last_rows if "unreadable" in r), None)
        for row in last_rows:
            if "pid" not in row or row["pid"] == app_pid:
                continue
            base = first.get((row["pid"], row["command"]))
            if not base:
                continue
            others.append({
                "command": row["command"],
                "cpu_s": round((row["cpu_user_ns"] + row["cpu_system_ns"] - base["cpu_user_ns"] - base["cpu_system_ns"]) / 1e9, 2),
                "disk_read_mb": mb(row["diskio_read_bytes"] - base["diskio_read_bytes"]),
                "disk_written_mb": mb(row["diskio_written_bytes"] - base["diskio_written_bytes"]),
                "energy_j": round((row["billed_energy_nj"] - base["billed_energy_nj"]) / 1e9, 2),
                "footprint_mb": mb(row["phys_footprint_bytes"]),
            })

    def top_others(key, n=10):
        return sorted(others, key=lambda r: r[key], reverse=True)[:n]

    nettops = sorted(glob.glob(os.path.join(raw, "nettop-*.csv")))
    network = {}
    if len(nettops) >= 2:
        first, last = parse_nettop(nettops[0]), parse_nettop(nettops[-1])
        deltas = []
        for key, (bytes_in, bytes_out) in last.items():
            base = first.get(key, (0, 0))
            deltas.append({"command": key[0], "pid": key[1], "in_mb": mb(bytes_in - base[0]), "out_mb": mb(bytes_out - base[1])})
        otos = [d for d in deltas if d["pid"] == str(app_pid)]
        network = {
            "otos": otos[0] if otos else {"in_mb": 0.0, "out_mb": 0.0, "note": "no socket seen"},
            "top_processes": sorted(deltas, key=lambda d: d["in_mb"] + d["out_mb"], reverse=True)[:10],
        }
        for item in network["top_processes"]:
            item.pop("pid", None)
        network["otos"].pop("pid", None)

    before, after = parse_files(os.path.join(raw, "files-before.tsv")), parse_files(os.path.join(raw, "files-after.tsv"))
    files = []
    for key in sorted(set(before) | set(after)):
        b, a = before.get(key, (0, 0)), after.get(key, (0, 0))
        files.append({"location": key[0], "subfolder": key[1], "before_mb": mb(b[0]), "after_mb": mb(a[0]),
                      "delta_mb": mb(a[0] - b[0]), "files_before": b[1], "files_after": a[1]})

    start_epoch = trace_start_epoch(raw)
    cpu = parse_time_profile(os.path.join(raw, "time-profile.xml"), start_epoch or start, boundaries) \
        if os.path.exists(os.path.join(raw, "time-profile.xml")) else None
    session_s = session["session_end"] - start
    if cpu:
        traced_s = trace_duration(raw) or session_s
        cpu["traced_wall_ms"] = round(traced_s * 1000)
        cpu["main_thread_idle_or_waiting_ms"] = round(traced_s * 1000 - cpu["main_thread_on_cpu_ms"], 1)

    threads = {os.path.basename(p): parse_sample(p)[:12] for p in sorted(glob.glob(os.path.join(raw, "sample-*.txt")))}
    heaps = {os.path.basename(p): parse_heap(p) for p in sorted(glob.glob(os.path.join(raw, "heap-*.txt")))}
    heap_seconds = [e["detail"] for e in events if e["kind"] == "heap"]

    language_model = []
    for row in phases:
        model = [g for g in row["neighbours"] if g["command"].startswith("TGOnDevice")]
        language_model.append({"phase": row["phase"], "mem_mb": model[0]["mem_mb"] if model else None,
                               "processes": model[0]["processes"] if model else 0})

    errors = open(os.path.join(raw, "errors.log"), errors="replace").read().splitlines()
    not_captured = [
        "Energy by subsystem (CPU/GPU/ANE package power): powermetrics needs root; per-process billed energy from rusage and top's POWER column stand in.",
        "Per-file and per-call disk I/O (fs_usage, iosnoop, dtrace): need root; per-process byte counters from rusage stand in.",
        "Disk, CPU and energy counters of processes run by other users (root daemons, _modelmanagerd, _mds_stores, WindowServer): proc_pid_rusage needs root for them; top's MEM/CPU/POWER columns are the only reading (%s processes unreadable at the last snapshot)." % unreadable,
        "footprint(1), vmmap and heap of other users' processes (the system language model): need root; top's MEM column stands in.",
        "memory_pressure(1) status: the tool applies pressure rather than reporting it; kern.memorystatus_vm_pressure_level and kern.memorystatus_level are read instead.",
        "Allocation history: an Allocations trace was %s." % ("recorded (raw/allocations.trace, not summarized)" if session.get("allocations") else "not recorded (pass --allocations; it slows the app)"),
        "Time Profiler records on-CPU samples only: main-thread time blocked or idle is the session time minus its on-CPU time, not a measured split.",
    ]
    if not session.get("tour_seen"):
        not_captured.append("Tour steps: no op=tour line arrived, so phases are the fixed +15/+30/+60/+180 s plan.")
    if not heaps and session.get("heap"):
        not_captured.append("Heap by class: the footprint never passed %s MB, so heap(1) never ran." % session.get("peak_floor_mb", 200))
    for line in errors:
        not_captured.append("Capture failed: " + line.split(" ", 1)[-1])

    return redact({
        "session": {
            "mode": session["mode"], "bundle_id": session["bundle_id"], "repo_revision": session["repo_revision"],
            "seconds": session_s, "tour_steps": session["tour_steps"], "sandbox_home": session["sandbox_home"],
            "end": next((e["detail"] for e in events if e["kind"] == "session" and e["label"] == "end"), None),
        },
        "phases": phases,
        "cpu": cpu,
        "threads": threads,
        "heap": heaps,
        "heap_capture": heap_seconds,
        "log": parse_log(raw),
        "language_model": language_model,
        "disk_io": {"iostat": parse_iostat(os.path.join(raw, "iostat.txt"))},
        "other_processes": {
            "by_cpu": top_others("cpu_s"), "by_disk_read": top_others("disk_read_mb"),
            "by_disk_written": top_others("disk_written_mb"), "by_energy": top_others("energy_j"),
            "unreadable_without_root": unreadable,
        },
        "network": network,
        "files": files,
        "not_captured": not_captured,
    })


def table(rows, columns):
    if not rows:
        return "_none_\n"
    out = ["| " + " | ".join(columns) + " |", "|" + "---|" * len(columns)]
    for row in rows:
        out.append("| " + " | ".join("" if row.get(c) is None else str(row.get(c)) for c in columns) + " |")
    return "\n".join(out) + "\n"


def markdown(s):
    lines = ["# Survey %s (%s, %s s)\n" % (s["session"]["repo_revision"], s["session"]["mode"], s["session"]["seconds"])]
    lines.append("Bundle `%s`; tour steps %s; sandbox home %s; session end: %s.\n" % (
        s["session"]["bundle_id"], s["session"]["tour_steps"], s["session"]["sandbox_home"], s["session"]["end"]))
    lines.append("## Otos by phase (app + text readers)\n")
    lines.append(table(s["phases"], ["phase", "at_s", "otos_phys_footprint_mb", "otos_lifetime_max_footprint_mb",
                                     "otos_resident_mb", "readers", "readers_footprint_mb", "cpu_s",
                                     "disk_read_mb", "disk_written_mb", "energy_j"]))
    lines.append("## System memory by phase\n")
    lines.append(table([{"phase": p["phase"], **p.get("system", {})} for p in s["phases"]],
                       ["phase", "free_mb", "compressor_mb", "swap_used_mb", "swap_growth_mb",
                        "pageouts_since_previous", "swapouts_since_previous", "pressure_level",
                        "memorystatus_free_percent"]))
    lines.append("## Otos memory by region (dirty + swapped), each phase\n")
    for p in s["phases"]:
        lines.append("**%s**: " % p["phase"] + ", ".join("%s %s MB" % (r["region"], r["footprint_mb"]) for r in p["top_regions_mb"]) + "\n")
        if p["malloc_zones_mb"]:
            lines.append("  malloc zones: " + ", ".join("%s %s MB (allocated %s, frag %s)" % (
                z["zone"], z["dirty_plus_swapped_mb"], z["allocated_mb"], z["frag"]) for z in p["malloc_zones_mb"]) + "\n")
    lines.append("\n## System language model (TGOnDeviceInferenceProviderService, top MEM)\n")
    lines.append(table(s["language_model"], ["phase", "processes", "mem_mb"]))
    lines.append("## Neighbours at the last phase (top MEM/CPU)\n")
    lines.append(table(s["phases"][-1]["neighbours"] if s["phases"] else [], ["command", "processes", "mem_mb", "cpu"]))
    lines.append("## CPU inside Otos (Time Profiler)\n")
    cpu = s["cpu"]
    if cpu:
        lines.append("On-CPU %s ms over %s ms traced; main thread on-CPU %s ms, idle or blocked %s ms.\n\n" % (
            cpu["on_cpu_ms"], cpu["traced_wall_ms"], cpu["main_thread_on_cpu_ms"], cpu["main_thread_idle_or_waiting_ms"]))
        lines.append("By phase (ms): " + ", ".join("%s %s" % kv for kv in cpu["by_phase_ms"].items()) + "\n\n")
        for title, key in (("Owners (first Otos frame)", "top_owners"), ("Owners, main thread", "top_owners_main_thread"),
                           ("Self time, all threads", "top_self_functions"), ("Self time, main thread", "top_self_main_thread"),
                           ("Self time, other threads", "top_self_other_threads"), ("Threads", "top_threads")):
            lines.append("**%s**\n\n" % title + table(cpu[key], ["name", "ms"]))
        lines.append("**Owners by phase**\n\n")
        for phase, owners in cpu["owners_by_phase"].items():
            lines.append("- %s: %s\n" % (phase, ", ".join("%s %s ms" % (o["name"], o["ms"]) for o in owners)))
    else:
        lines.append("_no trace_\n")
    lines.append("\n## Threads (sample, heaviest leaf per thread)\n")
    for name, threads in s["threads"].items():
        lines.append("**%s**\n\n" % name + table(threads, ["thread", "samples", "heaviest_leaf", "leaf_image", "leaf_samples"]))
    lines.append("## Heap at the footprint peak\n")
    for name, rows in s["heap"].items():
        lines.append("**%s**\n\n" % name + table(rows, ["class", "count", "bytes", "type", "binary"]))
    if s["heap_capture"]:
        lines.append("heap(1) pause: %s\n" % ", ".join(s["heap_capture"]))
    log = s["log"]
    lines.append("\n## Stalls and log (op names and numbers only)\n")
    lines.append("- main-thread stalls: %(count)s, longest %(max_ms)s ms, total %(total_ms)s ms\n" % log["main_thread_stalls"])
    lines.append("- store connection waits: %(count)s, longest %(max_ms)s ms, total %(total_ms)s ms\n" % log["store_stalls"])
    lines.append("- description lines: %s\n\n" % log["description_lines"])
    lines.append(table(log["store_stall_operations"], ["operation", "count"]))
    lines.append(table(log["op_counts"], ["op", "count"]))
    lines.append("## Disk I/O, system (iostat)\n")
    lines.append(table([{"disk": k, **v} for k, v in s["disk_io"]["iostat"].items()], ["disk", "intervals", "mean_mb_s", "max_mb_s"]))
    others = s["other_processes"]
    for title, key, cols in (("Other processes by CPU", "by_cpu", ["command", "cpu_s", "footprint_mb"]),
                             ("Other processes by disk read", "by_disk_read", ["command", "disk_read_mb"]),
                             ("Other processes by disk written", "by_disk_written", ["command", "disk_written_mb"]),
                             ("Other processes by energy", "by_energy", ["command", "energy_j"])):
        lines.append("## %s (this user's processes, session delta)\n" % title + table(others[key], cols))
    lines.append("## Network (nettop, session delta)\n")
    if s["network"]:
        lines.append("Otos: in %s MB, out %s MB\n\n" % (s["network"]["otos"].get("in_mb"), s["network"]["otos"].get("out_mb")))
        lines.append(table(s["network"]["top_processes"], ["command", "in_mb", "out_mb"]))
    lines.append("## Disk growth: folders Otos owns\n")
    lines.append(table(s["files"], ["location", "subfolder", "before_mb", "after_mb", "delta_mb", "files_before", "files_after"]))
    lines.append("## Not captured, and why\n")
    lines.extend("- %s\n" % item for item in s["not_captured"])
    return "\n".join(line.rstrip("\n") for line in lines) + "\n"


def main(argv):
    if len(argv) != 1:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    out_dir = argv[0]
    summary = summarize(out_dir)
    with open(os.path.join(out_dir, "summary.json"), "w") as handle:
        json.dump(summary, handle, indent=1)
    with open(os.path.join(out_dir, "summary.md"), "w") as handle:
        handle.write(markdown(summary))
    print("op=survey.summary phase=written out=%s" % out_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
