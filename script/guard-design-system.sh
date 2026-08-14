#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="${GUARD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# DES-001/DES-020: no font-size or color literals in views. Otos's own values
# live in exactly one allowlisted file, the DES-021/022 palette.
FONT_COLOR_ALLOWLIST=()
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
  local root="$1" line abs rel
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue; abs="${line%%:*}"; rel="${abs#"$root/"}"
    if ! is_domain_noun_allowlisted "$rel"; then
      echo "FAIL: DES-035/DES-039 domain noun in user-facing string: $line" >&2; return 1
    fi
  done < <(grep -RInE "Text\(\"[^\"]*\"" "$root/Otos/Views" --include='*.swift' \
    | grep -iE "$DOMAIN_NOUNS" || true)
}

check_root() {
  local root="$1"
  check_fonts_colors "$root" && check_domain_nouns "$root"
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

  printf 'Text("Import 3 Items").font(.body)\n' > "$d/Otos/Views/Bad.swift"
  check_root "$d"
  echo "guard-design-system self-test: clean oracle"
}

case "${1:-check}" in check) check_root "$ROOT_DIR";; self-test) self_test;; *) exit 2;; esac
