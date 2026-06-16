#!/usr/bin/env bash
#
# Build OWAWidget.app, package it as a versioned zip, EdDSA-sign the archive
# with Sparkle's `sign_update`, and emit `dist/appcast.xml` with the resulting
# signature/length so Sparkle clients can verify and install the update.
#
# Outputs (printed at the end, parsed by the GitHub Actions workflow):
#   VERSION=<x.y.z>
#   ARCHIVE_PATH=<path/to/zip>
#   APPCAST_PATH=<path/to/appcast.xml>
#
# Signing key resolution order:
#   1. SPARKLE_ED_PRIVATE_KEY env var (preferred for CI). Read via
#      `sign_update --ed-key-file -` so the secret never lands on disk.
#   2. Login Keychain entry written by `generate_keys` (default for local dev).
#
# When neither source produces a valid signature, the script aborts so we
# never publish a release that existing clients cannot install.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${ROOT_DIR}/VERSION"
RELEASE_NOTES_FILE="${ROOT_DIR}/RELEASE_NOTES.md"
APP_NAME="OWAWidget"
APP_PATH="${ROOT_DIR}/.build/${APP_NAME}.app"
DIST_DIR="${ROOT_DIR}/dist"

SPARKLE_ARTIFACTS_DIR="${ROOT_DIR}/.build/artifacts/sparkle/Sparkle"
SIGN_UPDATE_BIN="${SPARKLE_ARTIFACTS_DIR}/bin/sign_update"
GENERATE_APPCAST_BIN="${SPARKLE_ARTIFACTS_DIR}/bin/generate_appcast"

REPO_OWNER="ilyabazhenov"
REPO_NAME="mac-owa-widget"
RELEASE_DOWNLOAD_BASE="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download"

if [[ ! -f "${VERSION_FILE}" ]]; then
  echo "VERSION file not found at ${VERSION_FILE}" >&2
  exit 1
fi

VERSION="$(tr -d '[:space:]' < "${VERSION_FILE}")"
if [[ -z "${VERSION}" ]]; then
  echo "VERSION file is empty" >&2
  exit 1
fi

if [[ ! -f "${RELEASE_NOTES_FILE}" ]]; then
  echo "RELEASE_NOTES.md not found at ${RELEASE_NOTES_FILE}" >&2
  exit 1
fi

echo "Building universal bundle (arm64 + x86_64) for version ${VERSION}" >&2
make -C "${ROOT_DIR}" release-bundle >&2

if [[ ! -d "${APP_PATH}" ]]; then
  echo "App bundle not found at ${APP_PATH}" >&2
  exit 1
fi

mkdir -p "${DIST_DIR}"
ARCHIVE_PATH="${DIST_DIR}/${APP_NAME}-v${VERSION}-macos.zip"
rm -f "${ARCHIVE_PATH}"

ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ARCHIVE_PATH}"

if [[ ! -x "${SIGN_UPDATE_BIN}" ]]; then
  echo "sign_update not found at ${SIGN_UPDATE_BIN}." >&2
  echo "Run 'swift package resolve' once to download Sparkle's binary artifact." >&2
  exit 1
fi

echo "Signing ${ARCHIVE_PATH} with Sparkle EdDSA key..." >&2

# `sign_update` prints attributes like:
#   sparkle:edSignature="ABC...=" length="12345678"
SIGN_OUTPUT=""
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  SIGN_OUTPUT="$(printf '%s' "${SPARKLE_ED_PRIVATE_KEY}" | "${SIGN_UPDATE_BIN}" --ed-key-file - "${ARCHIVE_PATH}")"
else
  SIGN_OUTPUT="$("${SIGN_UPDATE_BIN}" "${ARCHIVE_PATH}" 2>/dev/null || true)"
fi

if [[ -z "${SIGN_OUTPUT}" ]] || ! grep -q 'sparkle:edSignature=' <<<"${SIGN_OUTPUT}"; then
  echo "Failed to sign ${ARCHIVE_PATH}." >&2
  echo "Make sure SPARKLE_ED_PRIVATE_KEY is set, or that the EdDSA private key is in the login Keychain." >&2
  exit 1
fi

if ! grep -q 'length="' <<<"${SIGN_OUTPUT}"; then
  echo "Failed to parse sign_update output:" >&2
  echo "${SIGN_OUTPUT}" >&2
  exit 1
fi

APPCAST_PATH="${DIST_DIR}/appcast.xml"

if [[ ! -x "${GENERATE_APPCAST_BIN}" ]]; then
  echo "generate_appcast not found at ${GENERATE_APPCAST_BIN}." >&2
  echo "Run 'swift package resolve' once to download Sparkle's binary artifact." >&2
  exit 1
fi

TMP_APPCAST_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_APPCAST_DIR}"' EXIT
cp "${ARCHIVE_PATH}" "${TMP_APPCAST_DIR}/"

# Let Sparkle generate the appcast in its canonical format.
# This avoids subtle parsing incompatibilities in handcrafted XML.
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  printf '%s' "${SPARKLE_ED_PRIVATE_KEY}" | "${GENERATE_APPCAST_BIN}" --ed-key-file - "${TMP_APPCAST_DIR}" >/dev/null
else
  "${GENERATE_APPCAST_BIN}" "${TMP_APPCAST_DIR}" >/dev/null
fi

cp "${TMP_APPCAST_DIR}/appcast.xml" "${APPCAST_PATH}"

echo "✓ Release package ready: ${ARCHIVE_PATH}" >&2
echo "✓ Appcast generated:    ${APPCAST_PATH}" >&2

# Extract ONLY the current version's section from the full changelog. RELEASE_NOTES.md
# accumulates every version; passing the whole file to `gh release --notes-file` would
# list all past versions in the GitHub release body. Publishers must use NOTES_PATH.
NOTES_PATH="${DIST_DIR}/release-notes-v${VERSION}.md"
VERSION_RE="$(printf '%s' "${VERSION}" | sed 's/\./\\./g')"
awk -v re="^## v${VERSION_RE} " '
  $0 ~ re { f = 1 }
  f && /^## v/ && $0 !~ re { exit }
  f { print }
' "${RELEASE_NOTES_FILE}" > "${NOTES_PATH}"

if ! grep -qE "^## v${VERSION_RE} " "${NOTES_PATH}"; then
  echo "Failed to extract release notes for v${VERSION}: no '## v${VERSION} - YYYY-MM-DD' heading found in ${RELEASE_NOTES_FILE}." >&2
  exit 1
fi

NOTES_SECTION_COUNT="$(grep -cE '^## v[0-9]' "${NOTES_PATH}")"
if [[ "${NOTES_SECTION_COUNT}" -ne 1 ]]; then
  echo "Extracted notes for v${VERSION} contain ${NOTES_SECTION_COUNT} version sections, expected exactly 1." >&2
  exit 1
fi

echo "✓ Release notes section: ${NOTES_PATH}" >&2

echo "VERSION=${VERSION}"
echo "ARCHIVE_PATH=${ARCHIVE_PATH}"
echo "APPCAST_PATH=${APPCAST_PATH}"
echo "NOTES_PATH=${NOTES_PATH}"
