#!/usr/bin/env bash
#
# Generate an Ed25519 keypair for Sparkle update signing.
#
# Usage:
#   bash scripts/generate_sparkle_keys.sh
#
# Behavior:
#   1. Resolves SwiftPM dependencies so Sparkle artifacts are downloaded.
#   2. Locates Sparkle's `generate_keys` tool inside the SwiftPM artifact cache.
#   3. Stores the keypair in your login Keychain (Sparkle's default behavior).
#      The private key never touches the repo or any build artifact.
#   4. Prints the PUBLIC key (base64) -- paste it into Info.plist as SUPublicEDKey.
#   5. Prints the PRIVATE key (base64) ONCE in a loud banner so you can copy it
#      into a GitHub Actions Secret named SPARKLE_ED_PRIVATE_KEY and into your
#      password manager / cold backup.
#
# IMPORTANT:
#   - Run this script in a TRUSTED interactive Terminal only.
#   - Output contains the private key in plaintext. Do NOT redirect to files
#     in the repo or commit any of it.
#   - The private key remains in Keychain after this run; it can be re-exported
#     via `security find-generic-password -s "https://sparkle-project.org" \
#         -a ed25519 -w` for as long as that Keychain is intact.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if ! command -v swift >/dev/null 2>&1; then
  echo "swift toolchain not found in PATH" >&2
  exit 1
fi

echo "Resolving SwiftPM dependencies (downloads Sparkle if missing)..."
swift package resolve >/dev/null

ARTIFACTS_DIR="${ROOT_DIR}/.build/artifacts"
if [[ ! -d "${ARTIFACTS_DIR}" ]]; then
  echo "Artifacts directory not found at ${ARTIFACTS_DIR}." >&2
  echo "Try running 'swift build' first to materialize the artifact cache." >&2
  exit 1
fi

GENERATE_KEYS_BIN="$(find "${ARTIFACTS_DIR}" -type f -name 'generate_keys' -perm +111 2>/dev/null | head -n 1 || true)"
if [[ -z "${GENERATE_KEYS_BIN}" ]]; then
  echo "generate_keys tool not found inside ${ARTIFACTS_DIR}." >&2
  echo "Sparkle artifacts may not be downloaded yet. Run 'swift build' once and retry." >&2
  exit 1
fi

echo "Using generate_keys at: ${GENERATE_KEYS_BIN}"

# `generate_keys` will create or read an Ed25519 keypair from the login Keychain
# under the entry `https://sparkle-project.org` / account `ed25519`.
GENERATE_OUTPUT="$("${GENERATE_KEYS_BIN}")"

# The tool prints the public key on stdout. Extract the first base64-looking line.
# Use `grep -E` here to avoid awk delimiter escaping pitfalls with '/'.
PUBLIC_KEY="$(printf '%s\n' "${GENERATE_OUTPUT}" | grep -E '^[A-Za-z0-9+/=]{40,}$' | head -n 1 || true)"

if [[ -z "${PUBLIC_KEY}" ]]; then
  # Fallback: try `-p` flag (newer Sparkle CLI)
  PUBLIC_KEY="$("${GENERATE_KEYS_BIN}" -p 2>/dev/null || true)"
fi

if [[ -z "${PUBLIC_KEY}" ]]; then
  echo "Could not parse public key from generate_keys output:" >&2
  printf '%s\n' "${GENERATE_OUTPUT}" >&2
  exit 1
fi

# Export the private key from Keychain. Sparkle's `generate_keys` stores the
# private key as a generic password under that service / account pair.
PRIVATE_KEY="$(security find-generic-password \
  -s "https://sparkle-project.org" \
  -a ed25519 \
  -w 2>/dev/null || true)"

if [[ -z "${PRIVATE_KEY}" ]]; then
  echo "Failed to read the private key back from the login Keychain." >&2
  echo "Open Keychain Access.app and check entry: 'https://sparkle-project.org'." >&2
  exit 1
fi

cat <<EOF

==================================================================
  SPARKLE Ed25519 KEYPAIR GENERATED
==================================================================

PUBLIC KEY (paste into OWAWidget/Info.plist -> SUPublicEDKey):
------------------------------------------------------------------
${PUBLIC_KEY}
------------------------------------------------------------------

EOF

cat <<'EOF'
##################################################################
#  PRIVATE KEY -- BACK UP NOW. THIS WILL NOT BE SHOWN AGAIN.     #
#  Copy this value to ALL of the following:                      #
#                                                                 #
#    1. GitHub Actions Secret named: SPARKLE_ED_PRIVATE_KEY       #
#       Repo Settings -> Secrets and variables -> Actions         #
#                                                                 #
#    2. Your password manager (1Password / Bitwarden / iCloud     #
#       Keychain) under name:                                     #
#       "OWAWidget Sparkle EdDSA private key"                     #
#                                                                 #
#    3. (Optional) Encrypted external storage / hardware token.   #
#                                                                 #
#  Losing this key means you cannot ship updates that already     #
#  installed clients will accept. Their public key is baked into  #
#  Info.plist of the version they installed.                      #
##################################################################
EOF

cat <<EOF

PRIVATE KEY (base64):
------------------------------------------------------------------
${PRIVATE_KEY}
------------------------------------------------------------------

The private key remains in your login Keychain. To re-export later:

    security find-generic-password -s "https://sparkle-project.org" \\
        -a ed25519 -w

Next steps:
  1. Paste the PUBLIC key into OWAWidget/Info.plist -> SUPublicEDKey
  2. Paste the PRIVATE key into GitHub Actions Secret SPARKLE_ED_PRIVATE_KEY
  3. Save a backup copy of the PRIVATE key in your password manager.

EOF
