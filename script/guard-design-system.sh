#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="${GUARD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# DES-001/DES-020: no font-size or color literals in views. Otos's own values
# live in exactly one allowlisted file, the DES-021/022 palette.
FONT_COLOR_ALLOWLIST=("Otos/Views/DesignPalette.swift")
is_font_color_allowlisted() {
  local p="$1" a
  for a in "${FONT_COLOR_ALLOWLIST[@]+"${FONT_COLOR_ALLOWLIST[@]}"}"; do [[ "$p" == "$a" ]] && return 0; done
  return 1
}
check_fonts_colors() {
  local root="$1" line abs rel
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue; abs="${line%%:*}"; rel="${abs#"$root/"}"
    if ! is_font_color_allowlisted "$rel"; then
      echo "FAIL: DES-001/DES-020 font or color literal: $line" >&2; return 1
    fi
  done < <(grep -RInE '\.system\(size:|#[0-9A-Fa-f]{3,8}\b|Color\(red:|NSColor\(red:' \
    "$root/Otos/Views" --include='*.swift' || true)
}

# DES-035/DES-039: user-facing strings never publish internal domain vocabulary.
DOMAIN_NOUNS='\bplan\b|\bdisposition\b|\bcompanion\b|\bpreexisting\b|\bblocked\b|\binventory\b|\breplan\b|\bexecution\b|\bqueued\b'
DOMAIN_NOUN_ALLOWLIST=()
is_domain_noun_allowlisted() {
  local p="$1" a
  for a in "${DOMAIN_NOUN_ALLOWLIST[@]+"${DOMAIN_NOUN_ALLOWLIST[@]}"}"; do [[ "$p" == "$a" ]] && return 0; done
  return 1
}
check_domain_nouns() {
  local root="$1" line abs rel rest content
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    abs="${line%%:*}"; rel="${abs#"$root/"}"
    # Match against the matched string content only, not the whole
    # path:line:content grep record — the repo's own checkout path (e.g. a
    # worktree named after a branch like "fix/some-plan-thing") can otherwise
    # contain one of these words and false-fail on unrelated files.
    rest="${line#*:}"; content="${rest#*:}"
    if ! is_domain_noun_allowlisted "$rel" && printf '%s\n' "$content" | grep -qiE "$DOMAIN_NOUNS"; then
      echo "FAIL: DES-035/DES-039 domain noun in user-facing string: $line" >&2; return 1
    fi
  done < <(grep -RInE "Text\(\"[^\"]*\"" "$root/Otos/Views" --include='*.swift' || true)
}

# D9: the import bar mapper never builds a user-facing number or string from
# a lying `?? 0` / `?? ""` substitution for an unknown value — omit it
# instead (plan 0095 D9, `ImportBarPresentation.swift` specifically, since
# that is the one file every drawn state's strings must pass through).
LYING_DEFAULT_FILE="Otos/Views/ImportBarPresentation.swift"
check_lying_defaults() {
  local root="$1" file="$root/$LYING_DEFAULT_FILE" line
  [[ -f "$file" ]] || return 0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "FAIL: D9 lying default (?? 0 / ?? \"\"): $line" >&2; return 1
  done < <(grep -nE '\?\?\s*(0\b|"")' "$file" || true)
}

check_root() {
  local root="$1"
  check_fonts_colors "$root" && check_domain_nouns "$root" && check_lying_defaults "$root"
}

self_test() {
  local d; d="$(mktemp -d)"; trap 'rm -rf "$d"' RETURN
  mkdir -p "$d/Otos/Views"

  printf 'Text("hi").font(.system(size: 60))\n' > "$d/Otos/Views/Bad.swift"
  if check_root "$d"; then echo "guard-design-system self-test failed (font literal)" >&2; return 1; fi

  printf 'Text("Copy 3 items").foregroundStyle(Color(red: 1, green: 0, blue: 0))\n' > "$d/Otos/Views/Bad.swift"
  if check_root "$d"; then echo "guard-design-system self-test failed (color literal)" >&2; return 1; fi

  printf 'Text("The plan failed")\n' > "$d/Otos/Views/Bad.swift"
  if check_root "$d"; then echo "guard-design-system self-test failed (domain noun)" >&2; return 1; fi
  rm -f "$d/Otos/Views/Bad.swift"

  printf 'let x = presentation.name ?? ""\n' > "$d/Otos/Views/ImportBarPresentation.swift"
  if check_root "$d"; then echo "guard-design-system self-test failed (lying empty-string default)" >&2; return 1; fi

  printf 'let x = count ?? 0\n' > "$d/Otos/Views/ImportBarPresentation.swift"
  if check_root "$d"; then echo "guard-design-system self-test failed (lying zero default)" >&2; return 1; fi

  printf 'let x = count ?? 100\n' > "$d/Otos/Views/ImportBarPresentation.swift"
  check_root "$d" || { echo "guard-design-system self-test failed (false positive on ?? 100)" >&2; return 1; }
  rm -f "$d/Otos/Views/ImportBarPresentation.swift"

  printf 'Text("Import 3 Items").font(.body)\n' > "$d/Otos/Views/Bad.swift"
  check_root "$d"
  echo "guard-design-system self-test: clean oracle"
}

case "${1:-check}" in check) check_root "$ROOT_DIR";; self-test) self_test;; *) exit 2;; esac
