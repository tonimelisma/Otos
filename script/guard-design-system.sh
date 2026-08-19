#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="${GUARD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# DES-001/DES-020: no font-size or color literals anywhere in the app target
# (plan 0095 D16 — the old Otos/Views-only scan left ContentView.swift and
# OtosApp.swift, which sit directly under Otos/, invisible). Otos's own
# values live in exactly one allowlisted file, the DES-021/022 palette. The
# one legitimate non-view use is raw Core Graphics bitmap fill (pixel color,
# not SwiftUI view styling), allowlisted by exact path.
FONT_COLOR_ALLOWLIST=(
  "Otos/Views/DesignPalette.swift"
  "Otos/Services/ThumbnailStore.swift"
)
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
    "$root/Otos" --include='*.swift' || true)
}

# DES-002: exactly seven text styles. A `.font(...)` naming anything else —
# including `.system(...)`, already redundantly caught above — fails. Scoped
# to the whole app target like check_fonts_colors: `.font(...)` is a SwiftUI
# view modifier, so it cannot appear in non-view code by construction.
ALLOWED_FONT_STYLES='^(title2|title3|headline|body|callout|subheadline|footnote)$'
check_font_styles() {
  local root="$1" line abs rel style
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    abs="${line%%:*}"; rel="${abs#"$root/"}"
    is_font_color_allowlisted "$rel" && continue
    style="$(printf '%s\n' "$line" | grep -oE '\.font\(\s*\.[A-Za-z0-9]+' | grep -oE '[A-Za-z0-9]+$' || true)"
    [[ -z "$style" ]] && continue
    if ! printf '%s\n' "$style" | grep -qE "$ALLOWED_FONT_STYLES"; then
      echo "FAIL: DES-002 font style outside the seven: $line" >&2; return 1
    fi
  done < <(grep -RInE '\.font\(\s*\.[A-Za-z0-9]+' "$root/Otos" --include='*.swift' || true)
}

# DES-035/DES-039: user-facing strings never publish internal domain
# vocabulary. Matches a literal in any position — not only inside
# `Text("…")` — since a pure mapper (`ImportBarPresentation.swift`) returns
# bare `String` values from switch expressions with no enclosing call syntax
# at all (plan 0095 D16). Comment lines (`//…`) are skipped: they are prose,
# not user-facing strings, and doc comments legitimately reference the
# forbidden words when explaining why they're forbidden.
#
# Scope is Otos/Views (recursive) plus the top-level Otos/*.swift composition
# roots (ContentView.swift, OtosApp.swift) — not the whole Otos/ tree.
# Services/Stores/ViewModels/Models legitimately use this exact vocabulary in
# OSLog calls, doc comments, and internal reason/path constants that are
# never rendered; scanning them produced two dozen false positives with zero
# real UI defects (verified empirically before choosing this scope, plan
# 0095 increment 11). check_fonts_colors/check_font_styles don't have this
# problem — their patterns are syntactically SwiftUI-only — so only this
# check and check_lying_defaults stay scoped narrower than the full tree.
DOMAIN_NOUNS='\bplan\b|\bdisposition\b|\bcompanion\b|\bpreexisting\b|\bblocked\b|\binventory\b|\breplan\b|\bexecution\b|\bqueued\b'
DOMAIN_NOUN_ALLOWLIST=()
is_domain_noun_allowlisted() {
  local p="$1" a
  for a in "${DOMAIN_NOUN_ALLOWLIST[@]+"${DOMAIN_NOUN_ALLOWLIST[@]}"}"; do [[ "$p" == "$a" ]] && return 0; done
  return 1
}
user_facing_string_roots() {
  local root="$1"
  find "$root/Otos/Views" -name '*.swift' 2>/dev/null
  find "$root/Otos" -maxdepth 1 -name '*.swift' 2>/dev/null
}
check_domain_nouns() {
  local root="$1" file line trimmed content
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    local rel="${file#"$root/"}"
    is_domain_noun_allowlisted "$rel" && continue
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      content="${line#*:}"
      trimmed="${content#"${content%%[![:space:]]*}"}"
      [[ "$trimmed" == //* ]] && continue
      if printf '%s\n' "$content" | grep -qE '"[^"]*"' && printf '%s\n' "$content" | grep -qiE "$DOMAIN_NOUNS"; then
        echo "FAIL: DES-035/DES-039 domain noun in user-facing string: $rel:$line" >&2; return 1
      fi
    done < <(grep -n '.' "$file" || true)
  done < <(user_facing_string_roots "$root")
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
  check_fonts_colors "$root" && check_font_styles "$root" && check_domain_nouns "$root" && check_lying_defaults "$root"
}

self_test() {
  local d; d="$(mktemp -d)"; trap 'rm -rf "$d"' RETURN
  mkdir -p "$d/Otos/Views" "$d/Otos/Services"

  printf 'Text("hi").font(.system(size: 60))\n' > "$d/Otos/Views/Bad.swift"
  if check_root "$d"; then echo "guard-design-system self-test failed (font literal)" >&2; return 1; fi

  printf 'Text("Copy 3 items").foregroundStyle(Color(red: 1, green: 0, blue: 0))\n' > "$d/Otos/Views/Bad.swift"
  if check_root "$d"; then echo "guard-design-system self-test failed (color literal)" >&2; return 1; fi
  rm -f "$d/Otos/Views/Bad.swift"

  # DES-001/DES-020 widened root: a color literal outside Otos/Views must now fail too.
  printf 'let fill = NSColor(red: 1, green: 1, blue: 1, alpha: 1)\n' > "$d/Otos/Services/Bad.swift"
  if check_root "$d"; then echo "guard-design-system self-test failed (widened font/color root)" >&2; return 1; fi
  rm -f "$d/Otos/Services/Bad.swift"

  # The one allowlisted non-view exception still passes.
  mkdir -p "$d/Otos/Services"
  printf 'context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))\n' > "$d/Otos/Services/ThumbnailStore.swift"
  check_root "$d" || { echo "guard-design-system self-test failed (ThumbnailStore false positive)" >&2; return 1; }
  rm -f "$d/Otos/Services/ThumbnailStore.swift"

  # DES-002: a disallowed named style fails; the seven allowed ones, including
  # a chained weight modifier, pass.
  printf 'Text("hi").font(.caption)\n' > "$d/Otos/Views/Bad.swift"
  if check_root "$d"; then echo "guard-design-system self-test failed (disallowed font style)" >&2; return 1; fi
  printf 'Text("hi").font(.largeTitle)\n' > "$d/Otos/Views/Bad.swift"
  if check_root "$d"; then echo "guard-design-system self-test failed (disallowed font style 2)" >&2; return 1; fi
  printf 'Text("hi").font(.title3.weight(.semibold))\n' > "$d/Otos/Views/Bad.swift"
  check_root "$d" || { echo "guard-design-system self-test failed (allowed font style false positive)" >&2; return 1; }
  rm -f "$d/Otos/Views/Bad.swift"

  printf 'Text("The plan failed")\n' > "$d/Otos/Views/Bad.swift"
  if check_root "$d"; then echo "guard-design-system self-test failed (domain noun)" >&2; return 1; fi
  rm -f "$d/Otos/Views/Bad.swift"

  # DES-035/DES-039 "any position" broadening: a bare literal with no
  # enclosing Text(...) call — exactly ImportBarPresentation.swift's shape —
  # must fail too, not just Text("...") literals.
  printf 'case .sourceRemoved:\n    "The plan failed"\n' > "$d/Otos/Views/Bad.swift"
  if check_root "$d"; then echo "guard-design-system self-test failed (bare literal, no Text wrapper)" >&2; return 1; fi
  rm -f "$d/Otos/Views/Bad.swift"

  # A comment mentioning a forbidden word is prose, not a user-facing string.
  printf '// explains why "the plan" is forbidden wording\nlet x = 1\n' > "$d/Otos/Views/Bad.swift"
  check_root "$d" || { echo "guard-design-system self-test failed (comment false positive)" >&2; return 1; }
  rm -f "$d/Otos/Views/Bad.swift"

  # Widened UI-root scan: a top-level Otos/*.swift file (ContentView.swift's
  # shape) is now checked even though it isn't under Otos/Views.
  printf 'Text("The plan failed")\n' > "$d/Otos/Bad.swift"
  if check_root "$d"; then echo "guard-design-system self-test failed (top-level Otos/*.swift not scanned)" >&2; return 1; fi
  rm -f "$d/Otos/Bad.swift"

  # Deliberately NOT widened for domain nouns: Services/Stores/etc. carry
  # internal vocabulary in logs and doc comments that must stay unchecked.
  printf 'OtosLog.catalog.notice("plan.rebuild phase=schedule")\n' > "$d/Otos/Services/Bad.swift"
  check_root "$d" || { echo "guard-design-system self-test failed (non-view directory false positive)" >&2; return 1; }
  rm -f "$d/Otos/Services/Bad.swift"

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
