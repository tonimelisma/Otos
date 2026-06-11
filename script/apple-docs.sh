#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  script/apple-docs.sh DOC
  DOC=/documentation/swiftui/view script/apple-docs.sh
  script/apple-docs.sh doctor

DOC may be an Apple Developer URL, Sosumi URL, /documentation path, /design
path, /videos/play path, or external HTTPS Swift-DocC URL.
EOF
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 127
  fi
}

normalize_doc_url() {
  local input="$1"

  case "$input" in
    https://sosumi.ai/*)
      printf '%s\n' "$input"
      ;;
    https://developer.apple.com/*)
      printf '%s\n' "${input/https:\/\/developer.apple.com/https://sosumi.ai}"
      ;;
    /documentation/*|/design/*|/videos/play/*)
      printf 'https://sosumi.ai%s\n' "$input"
      ;;
    https://*)
      printf 'https://sosumi.ai/external/%s\n' "$input"
      ;;
    *)
      echo "Unsupported DOC value: $input" >&2
      usage >&2
      exit 2
      ;;
  esac
}

doctor() {
  require_command curl
  echo "curl: $(command -v curl)"
  echo "sosumi: https://sosumi.ai"
}

main() {
  local action_or_doc="${1:-}"

  if [[ "$action_or_doc" == "doctor" ]]; then
    doctor
    return
  fi

  local doc_input="${DOC:-$action_or_doc}"
  if [[ -z "$doc_input" ]]; then
    usage
    exit 2
  fi

  require_command curl

  local normalized_url
  normalized_url="$(normalize_doc_url "$doc_input")"
  curl -fsSL "$normalized_url"
}

main "$@"
