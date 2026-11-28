#!/usr/bin/env bash
# The repository's shape, checked the same way by CI and by script/check.sh: every GitHub
# workflow parses as YAML, and every script is executable and starts with a shebang.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

workflows=()
while IFS= read -r -d '' path; do workflows+=("$path"); done \
  < <(find .github -type f \( -name '*.yml' -o -name '*.yaml' \) -print0)
if (( ${#workflows[@]} == 0 )); then
  echo "No GitHub YAML files found." >&2
  exit 1
fi
ruby -e 'require "yaml"; ARGV.each { |path| YAML.safe_load(File.read(path), aliases: true) }' "${workflows[@]}"

scripts=()
while IFS= read -r -d '' path; do scripts+=("$path"); done < <(find script -type f -print0)
if (( ${#scripts[@]} == 0 )); then
  echo "No repo scripts found." >&2
  exit 1
fi
status=0
for script in "${scripts[@]}"; do
  # Settings files beside the scripts that read them (script/process-check.conf) are data.
  [[ "$script" == *.conf ]] && continue
  if [[ ! -x "$script" ]]; then
    echo "Script is not executable: $script" >&2
    status=1
  fi
  if [[ "$(head -n 1 "$script")" != '#!'* ]]; then
    echo "Script is missing a shebang: $script" >&2
    status=1
  fi
done
(( status == 0 )) && echo "op=repo-shape phase=pass workflows=${#workflows[@]} scripts=${#scripts[@]}"
exit "$status"
