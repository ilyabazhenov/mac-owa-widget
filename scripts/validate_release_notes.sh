#!/usr/bin/env bash
set -euo pipefail

notes_file="${1:-RELEASE_NOTES.md}"
required_quarantine_command="xattr -dr com.apple.quarantine /Applications/OWAWidget.app"

if [[ ! -f "$notes_file" ]]; then
  echo "Missing release notes file: $notes_file"
  exit 1
fi

if [[ ! -s "$notes_file" ]]; then
  echo "Release notes file is empty: $notes_file"
  exit 1
fi

if ! rg -n '^## v[0-9]+\.[0-9]+\.[0-9]+ - [0-9]{4}-[0-9]{2}-[0-9]{2}$' "$notes_file" >/dev/null; then
  echo "Release notes must contain at least one version heading: ## vX.Y.Z - YYYY-MM-DD"
  exit 1
fi

latest_version_line="$(rg -n '^## v[0-9]+\.[0-9]+\.[0-9]+ - [0-9]{4}-[0-9]{2}-[0-9]{2}$' "$notes_file" | head -n1)"
latest_version_number="${latest_version_line%%:*}"

latest_block="$(
  awk -v start="$latest_version_number" '
    NR < start { next }
    NR > start && /^## / { exit }
    { print }
  ' "$notes_file"
)"

if [[ -z "$latest_block" ]]; then
  echo "Failed to read the latest release notes section."
  exit 1
fi

if ! printf '%s\n' "$latest_block" | rg '^### RU$' >/dev/null; then
  echo "Latest version section must contain a ### RU heading."
  exit 1
fi

if ! printf '%s\n' "$latest_block" | rg '^### EN$' >/dev/null; then
  echo "Latest version section must contain a ### EN heading."
  exit 1
fi

if ! printf '%s\n' "$latest_block" | rg '^\s*#### Установка$' >/dev/null; then
  echo "Latest version section must contain '#### Установка' under RU."
  exit 1
fi

if ! printf '%s\n' "$latest_block" | rg "^\s*#### Installation$" >/dev/null; then
  echo "Latest version section must contain '#### Installation' under EN."
  exit 1
fi

quarantine_count="$(printf '%s\n' "$latest_block" | rg -F "$required_quarantine_command" -c)"
if [[ "$quarantine_count" -lt 2 ]]; then
  echo "Latest version section must include '$required_quarantine_command' in both RU and EN installation sections."
  exit 1
fi

echo "✓ Release notes validation passed for latest version section."
