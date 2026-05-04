#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${ROOT_DIR}/VERSION"
APP_NAME="OWAWidget"
APP_PATH="${ROOT_DIR}/.build/${APP_NAME}.app"
DIST_DIR="${ROOT_DIR}/dist"

if [[ ! -f "${VERSION_FILE}" ]]; then
  echo "VERSION file not found at ${VERSION_FILE}" >&2
  exit 1
fi

VERSION="$(tr -d '[:space:]' < "${VERSION_FILE}")"
if [[ -z "${VERSION}" ]]; then
  echo "VERSION file is empty" >&2
  exit 1
fi

echo "Building bundle for version ${VERSION}"
make -C "${ROOT_DIR}" bundle

if [[ ! -d "${APP_PATH}" ]]; then
  echo "App bundle not found at ${APP_PATH}" >&2
  exit 1
fi

mkdir -p "${DIST_DIR}"
ARCHIVE_PATH="${DIST_DIR}/${APP_NAME}-v${VERSION}-macos.zip"
rm -f "${ARCHIVE_PATH}"

ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ARCHIVE_PATH}"

echo "VERSION=${VERSION}"
echo "ARCHIVE_PATH=${ARCHIVE_PATH}"
