#!/usr/bin/env bash
#
# Build OWAWidget.app signed with Developer ID, notarize and staple it, package
# it as a versioned zip, EdDSA-sign the archive with Sparkle's `sign_update`, and
# emit `dist/appcast.xml` with the resulting signature/length so Sparkle clients
# can verify and install the update.
#
# Outputs (printed at the end, parsed by the caller):
#   VERSION=<x.y.z>
#   ARCHIVE_PATH=<path/to/zip>
#   APPCAST_PATH=<path/to/appcast.xml>
#
# Signing key resolution order:
#   1. Login Keychain entry written by `generate_keys`. This is the normal path:
#      releases are built and published locally.
#   2. SPARKLE_ED_PRIVATE_KEY env var, as an escape hatch for signing from a
#      machine where the key is not in the Keychain (restored from the password
#      manager backup). Read via `sign_update --ed-key-file -` so the secret
#      never lands on disk. See docs/sparkle-key-backup.md.
#
# When neither source produces a valid signature, the script aborts so we
# never publish a release that existing clients cannot install.
#
# Notarization uses a notarytool Keychain profile (default `owawidget-notary`,
# override with NOTARY_PROFILE), created once per machine:
#   xcrun notarytool store-credentials owawidget-notary \
#     --key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER-UUID>
# A release that is not notarized is rejected by Gatekeeper on first launch, so
# there is no flag to skip it.
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

NOTARY_PROFILE="${NOTARY_PROFILE:-owawidget-notary}"

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

# The build compiles whatever is in the working tree, and the build number comes from
# `git rev-list --count HEAD`: an uncommitted change would ship in a release that no commit
# describes. The release commit (VERSION, RELEASE_NOTES.md) comes first, see AGENTS.md.
DIRTY="$(git -C "${ROOT_DIR}" status --porcelain)"
if [[ -n "${DIRTY}" ]]; then
  echo "The working tree has uncommitted changes; commit them before packaging:" >&2
  echo "${DIRTY}" >&2
  exit 1
fi

# Fail before the build, not after it: both checks are cheap, the build is not.
if ! security find-identity -v -p codesigning | grep -q '"Developer ID Application: '; then
  echo "No valid 'Developer ID Application' certificate in the login Keychain." >&2
  echo "Releases must be Developer ID signed; see AGENTS.md, release process." >&2
  exit 1
fi
if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
  echo "notarytool profile '${NOTARY_PROFILE}' is missing or its credentials are rejected." >&2
  echo "Create it once: xcrun notarytool store-credentials ${NOTARY_PROFILE} --key <AuthKey.p8> --key-id <KEYID> --issuer <ISSUER>" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "Building universal bundle (arm64 + x86_64) for version ${VERSION}" >&2
make -C "${ROOT_DIR}" release-bundle >&2

if [[ ! -d "${APP_PATH}" ]]; then
  echo "App bundle not found at ${APP_PATH}" >&2
  exit 1
fi

# Entitlements that loosen hardened runtime belong to local ad-hoc builds only
# (OWAWidget-dev.entitlements). sign_app.sh picks them by identity; this checks the result,
# so a change there cannot ship them silently.
FORBIDDEN_ENTITLEMENTS=(
  com.apple.security.cs.disable-library-validation
  com.apple.security.get-task-allow
  com.apple.security.cs.allow-dyld-environment-variables
  com.apple.security.cs.allow-unsigned-executable-memory
  com.apple.security.cs.allow-jit
)
for binary in "${APP_PATH}" "${APP_PATH}/Contents/Helpers/owawidget-mcp"; do
  ENTITLEMENTS="$(codesign -d --entitlements - --xml "${binary}" 2>/dev/null || true)"
  for key in "${FORBIDDEN_ENTITLEMENTS[@]}"; do
    if [[ "${ENTITLEMENTS}" == *"${key}"* ]]; then
      echo "Release signature of ${binary} carries ${key}." >&2
      exit 1
    fi
  done
done
echo "✓ Entitlements: no hardened-runtime exceptions" >&2

# The archive is signed with the key in the Keychain; clients check it against the
# SUPublicEDKey of the version they run. A mismatch would publish an update nobody can install.
if [[ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  KEYCHAIN_PUBLIC_KEY="$("${SPARKLE_ARTIFACTS_DIR}/bin/generate_keys" -p 2>/dev/null | tail -1 | tr -d '[:space:]')"
  BUNDLE_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "${APP_PATH}/Contents/Info.plist")"
  if [[ "${KEYCHAIN_PUBLIC_KEY}" != "${BUNDLE_PUBLIC_KEY}" ]]; then
    echo "The EdDSA key in the Keychain does not match SUPublicEDKey in the bundle." >&2
    echo "See docs/sparkle-key-backup.md before going any further." >&2
    exit 1
  fi
  echo "✓ EdDSA key in the Keychain matches SUPublicEDKey" >&2
fi

# Notarize, then staple the ticket into the bundle so Gatekeeper accepts the app
# offline on first launch. Stapling must happen before the release zip is made:
# the ticket travels inside the .app.
echo "Notarizing ${APP_PATH} (profile ${NOTARY_PROFILE}); this takes a few minutes..." >&2
NOTARY_ZIP="${WORK_DIR}/notarize.zip"
NOTARY_RESULT="${WORK_DIR}/notary.json"
ditto -c -k --keepParent "${APP_PATH}" "${NOTARY_ZIP}"
xcrun notarytool submit "${NOTARY_ZIP}" --keychain-profile "${NOTARY_PROFILE}" \
  --wait --output-format json > "${NOTARY_RESULT}" || true
NOTARY_STATUS="$(plutil -extract status raw -o - "${NOTARY_RESULT}" 2>/dev/null || echo unknown)"
NOTARY_ID="$(plutil -extract id raw -o - "${NOTARY_RESULT}" 2>/dev/null || true)"
if [[ "${NOTARY_STATUS}" != "Accepted" ]]; then
  echo "Notarization failed: status=${NOTARY_STATUS}" >&2
  cat "${NOTARY_RESULT}" >&2 || true
  if [[ -n "${NOTARY_ID}" ]]; then
    echo "Notary log:" >&2
    xcrun notarytool log "${NOTARY_ID}" --keychain-profile "${NOTARY_PROFILE}" >&2 || true
  fi
  exit 1
fi
echo "✓ Notarized (submission ${NOTARY_ID})" >&2

xcrun stapler staple "${APP_PATH}" >&2
GATEKEEPER="$(spctl --assess --type execute -vv "${APP_PATH}" 2>&1 || true)"
if ! grep -q 'source=Notarized Developer ID' <<<"${GATEKEEPER}"; then
  echo "Gatekeeper does not accept the stapled app:" >&2
  echo "${GATEKEEPER}" >&2
  exit 1
fi
echo "✓ Gatekeeper: accepted, Notarized Developer ID" >&2

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

APPCAST_PATH="${DIST_DIR}/appcast.xml"

if [[ ! -x "${GENERATE_APPCAST_BIN}" ]]; then
  echo "generate_appcast not found at ${GENERATE_APPCAST_BIN}." >&2
  echo "Run 'swift package resolve' once to download Sparkle's binary artifact." >&2
  exit 1
fi

TMP_APPCAST_DIR="${WORK_DIR}/appcast"
mkdir -p "${TMP_APPCAST_DIR}"
cp "${ARCHIVE_PATH}" "${TMP_APPCAST_DIR}/"

# Drop a release-notes file next to the archive with a matching base name so
# generate_appcast embeds it as the item's "What's New" (<description> CDATA).
# We strip the "#### Установка"/"#### Installation" subsections: those manual
# install steps are irrelevant to in-app auto-updates and only add noise to
# the Sparkle popover. The full section (with install steps) still ships to the
# GitHub Release via NOTES_PATH.
ARCHIVE_BASENAME="$(basename "${ARCHIVE_PATH}" .zip)"
SPARKLE_NOTES_PATH="${TMP_APPCAST_DIR}/${ARCHIVE_BASENAME}.md"
awk '
  /^#### (Установка|Installation)/ { skip = 1; next }
  /^#{2,4} / { skip = 0 }
  !skip { print }
' "${NOTES_PATH}" > "${SPARKLE_NOTES_PATH}"

# Let Sparkle generate the appcast in its canonical format.
# This avoids subtle parsing incompatibilities in handcrafted XML.
# --embed-release-notes forces the .md notes to be embedded as
# <description sparkle:format="markdown"> CDATA. Without it, generate_appcast
# emits a relative <sparkle:releaseNotesLink> to a file we never upload.
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  printf '%s' "${SPARKLE_ED_PRIVATE_KEY}" | "${GENERATE_APPCAST_BIN}" --embed-release-notes --ed-key-file - "${TMP_APPCAST_DIR}" >/dev/null
else
  "${GENERATE_APPCAST_BIN}" --embed-release-notes "${TMP_APPCAST_DIR}" >/dev/null
fi

cp "${TMP_APPCAST_DIR}/appcast.xml" "${APPCAST_PATH}"

# `generate_appcast` exits 0 even when it cannot reach the signing key, silently
# writing an appcast with no signature. Sparkle clients reject unsigned updates,
# so a successful exit code is not evidence that the release is installable —
# check the artifact itself.
# The `[^"]` matters: an empty `sparkle:edSignature=""` would satisfy a bare
# prefix match and let an unsigned release through the very check meant to stop it.
if ! grep -q 'sparkle:edSignature="[^"]' "${APPCAST_PATH}"; then
  echo "appcast.xml carries no sparkle:edSignature — the EdDSA key was unavailable." >&2
  echo "Clients would reject this update. Check the login Keychain entry" >&2
  echo "https://sparkle-project.org / ed25519, or set SPARKLE_ED_PRIVATE_KEY." >&2
  echo "Recovery procedure: docs/sparkle-key-backup.md" >&2
  exit 1
fi

echo "✓ Release package ready: ${ARCHIVE_PATH}" >&2
echo "✓ Appcast generated:    ${APPCAST_PATH}" >&2

echo "VERSION=${VERSION}"
echo "ARCHIVE_PATH=${ARCHIVE_PATH}"
echo "APPCAST_PATH=${APPCAST_PATH}"
echo "NOTES_PATH=${NOTES_PATH}"
