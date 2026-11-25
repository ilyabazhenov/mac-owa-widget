#!/usr/bin/env bash
set -euo pipefail

notes_file="${1:-RELEASE_NOTES.md}"

if [[ ! -f "$notes_file" ]]; then
  echo "Missing release notes file: $notes_file"
  exit 1
fi

if [[ ! -s "$notes_file" ]]; then
  echo "Release notes file is empty: $notes_file"
  exit 1
fi

if ! grep -En '^## v[0-9]+\.[0-9]+\.[0-9]+ - [0-9]{4}-[0-9]{2}-[0-9]{2}$' "$notes_file" >/dev/null; then
  echo "Release notes must contain at least one version heading: ## vX.Y.Z - YYYY-MM-DD"
  exit 1
fi

latest_version_line="$(grep -En '^## v[0-9]+\.[0-9]+\.[0-9]+ - [0-9]{4}-[0-9]{2}-[0-9]{2}$' "$notes_file" | head -n1)"
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

if ! printf '%s\n' "$latest_block" | grep -E '^### RU$' >/dev/null; then
  echo "Latest version section must contain a ### RU heading."
  exit 1
fi

if ! printf '%s\n' "$latest_block" | grep -E '^### EN$' >/dev/null; then
  echo "Latest version section must contain a ### EN heading."
  exit 1
fi

if ! printf '%s\n' "$latest_block" | grep -E '^[[:space:]]*#### Установка$' >/dev/null; then
  echo "Latest version section must contain '#### Установка' under RU."
  exit 1
fi

if ! printf '%s\n' "$latest_block" | grep -E "^[[:space:]]*#### Installation$" >/dev/null; then
  echo "Latest version section must contain '#### Installation' under EN."
  exit 1
fi

# Releases are Developer ID signed and notarized, so Gatekeeper opens a fresh download without
# help. Sections are usually written by copying the previous one, and every section before the
# switch tells users to strip the quarantine flag; refuse that stale step instead of shipping it.
if printf '%s\n' "$latest_block" | grep -Eq 'xattr|com\.apple\.quarantine'; then
  echo "Latest version section still tells users to remove the quarantine flag (xattr)."
  echo "Releases are notarized; drop that step from both installation sections."
  exit 1
fi

echo "✓ Release notes validation passed for latest version section."
