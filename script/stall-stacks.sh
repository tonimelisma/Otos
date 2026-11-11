#!/usr/bin/env bash
set -euo pipefail

# Prints each main-thread stall with the stacks the stall watcher sampled while it lasted
# (ADR 0015): the `op=mainThreadStall` fault, then each distinct stack, most sampled
# first, its parts joined and its Swift symbols demangled. An Otos frame the image does
# not name keeps `image+0xoffset`, which `atos -o <binary> -l 0` resolves.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  script/stall-stacks.sh --last <duration> [--pid <pid>] [--process <name>]
  script/stall-stacks.sh --file <ndjson>

--last     Read the unified log through `script/logs.sh show` (e.g. 10m, 1h).
--file     Read a capture `script/logs.sh show` already wrote.
--pid, --process   Passed to `script/logs.sh` to pick one instance.
EOF
}

last=""
file=""
log_args=()
while (($# > 0)); do
  case "$1" in
    --last) last="$2"; shift 2 ;;
    --file) file="$2"; shift 2 ;;
    --pid|--process) log_args+=("$1" "$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if [[ -z "$last" && -z "$file" ]] || [[ -n "$last" && -n "$file" ]]; then
  usage >&2
  exit 2
fi

capture="$(mktemp -t otos-stall-stacks)"
trap 'rm -f "$capture"' EXIT
if [[ -n "$file" ]]; then
  cp "$file" "$capture"
else
  "$ROOT_DIR/script/logs.sh" show --last "$last" Performance ${log_args[@]+"${log_args[@]}"} >"$capture"
fi

python3 -I - "$capture" <<'PY'
import json
import re
import subprocess
import sys

COUNTED = {
    "heaviest": "heaviest frames, by the samples each appears in",
    "own": "Otos's own frames, by the samples each appears in",
    "leaf": "innermost frames, by the samples each tops",
}
stalls = {}
stacks = {}
order = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    message = event.get("eventMessage", "")
    pid = event.get("processID")
    fields = dict(re.findall(r"(\w+)=(\S+)", message))
    if message.startswith("op=mainThreadStall.stack "):
        key = (pid, fields.get("stallID"))
        kind = fields.get("kind")
        name = kind if kind in COUNTED else f"stack {fields.get('stack')}"
        stack = stacks.setdefault(key, {}).setdefault(name, {"fields": fields, "parts": {}})
        stack["parts"][int(fields.get("part", "1"))] = fields.get("frames", "")
    elif message.startswith("op=mainThreadStall "):
        key = (pid, fields.get("stallID"))
        stalls[key] = (event.get("timestamp", "")[:23], message)
        order.append(key)

symbols = set()
for stack_set in stacks.values():
    for stack in stack_set.values():
        for part in stack["parts"].values():
            for frame in part.split("|"):
                frame = frame.split("*", 1)[-1]
                if ":" in frame:
                    symbols.add(frame.split(":", 1)[1])
demangled = {}
if symbols:
    names = sorted(symbols)
    result = subprocess.run(
        ["xcrun", "swift-demangle", "--simplified"],
        input="\n".join(names), capture_output=True, text=True, check=False,
    )
    lines = result.stdout.splitlines()
    if result.returncode == 0 and len(lines) == len(names):
        demangled = dict(zip(names, lines))

for key in order:
    timestamp, message = stalls[key]
    print(f"{timestamp} pid={key[0]} {message}")
    ranks = {name: index for index, name in enumerate(COUNTED)}
    for name in sorted(stacks.get(key, {}), key=lambda value: (ranks.get(value, len(ranks)), value)):
        stack = stacks[key][name]
        fields = stack["fields"]
        frames = "|".join(stack["parts"][index] for index in sorted(stack["parts"]))
        if name in COUNTED:
            print(f"  {COUNTED[name]} (of {fields.get('ofSamples')}):")
        else:
            print(f"  {name}: {fields.get('samples')} of {fields.get('ofSamples')} samples, innermost first")
        for depth, frame in enumerate(frames.split("|")):
            count, _, rest = frame.partition("*") if name in COUNTED else ("", "", frame)
            location, _, symbol = rest.partition(":")
            label = f"{count:>4}" if name in COUNTED else f"{depth:4d}"
            print(f"    {label} {location} {demangled.get(symbol, symbol)}")
PY
