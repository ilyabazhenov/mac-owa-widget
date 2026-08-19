#!/usr/bin/env bash
#
# Прогон обновления Sparkle целиком на localhost, без публикации чего-либо.
#
# Зачем: `make release-package` проверяет, что архив и appcast подписаны, но не то, что
# установленная у пользователя версия сумеет это обновление применить. Установку выполняет не
# само приложение, а `Autoupdate` и XPC-сервисы внутри Sparkle.framework, поэтому всё, что
# меняет подпись или упаковку — hardened runtime, entitlements, состав бандла — способно сломать
# обновление, не сломав сборку. Узнать об этом по жалобам пользователей дорого: сломанный
# апдейтер означает, что они молча перестают получать версии.
#
# Что делает скрипт:
#   1. «Старая» сторона — распакованный ранее опубликованный архив, то есть ровно то, что стоит
#      у людей. Меняются только bundle id (чтобы не задеть рабочую копию и её данные), адрес
#      фида и ATS; подпись воспроизводится ad-hoc БЕЗ hardened runtime.
#   2. «Новая» сторона — текущая сборка из .build, подписанная как сейчас подписывает Makefile.
#   3. Архив, appcast с подписью и локальный HTTP-сервер.
#   4. Запуск «старой» версии, которая проверяет обновления на localhost.
#
# Ничего не уходит на GitHub: фид, архив и подпись живут только на localhost, а тестовая версия
# никогда не публикуется. Отдельный bundle id означает отдельные UserDefaults и отдельный каталог
# в Application Support, поэтому аккаунты и кэш рабочей копии недоступны тестовой.
#
# Использование:
#   bash scripts/test_update_locally.sh                 # собрать, поднять сервер, запустить
#   bash scripts/test_update_locally.sh --prepare-only  # только собрать и проверить, без запуска
#   bash scripts/test_update_locally.sh --clean         # убрать за собой и выйти
#
# Ctrl-C останавливает сервер и убирает следы.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${ROOT_DIR}/.build/artifacts/sparkle/Sparkle/bin"
BUILT_APP="${ROOT_DIR}/.build/OWAWidget.app"
WORK_DIR="${ROOT_DIR}/.build/update-test"
TEST_BUNDLE_ID="com.owawidget.MacOwaWidget.updatetest"
PORT="${PORT:-8899}"
NEW_VERSION="${NEW_VERSION:-99.0.0}"
NEW_BUILD="${NEW_BUILD:-99000}"
OLD_ARCHIVE=""
MODE="run"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prepare-only) MODE="prepare"; shift ;;
    --clean)        MODE="clean"; shift ;;
    --old)          OLD_ARCHIVE="$2"; shift 2 ;;
    --port)         PORT="$2"; shift 2 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

cleanup_traces() {
  # Тестовое приложение убиваем по пути, а не через `pkill -x OWAWidget`: рабочая копия
  # называется так же, и общий pkill остановил бы её вместе с тестовой.
  pkill -f "${WORK_DIR}/old/OWAWidget.app" 2>/dev/null || true
  defaults delete "${TEST_BUNDLE_ID}" 2>/dev/null || true
  rm -rf "${HOME}/Library/Caches/${TEST_BUNDLE_ID}"
  rm -rf "${HOME}/Library/Application Support/OWAWidget/${TEST_BUNDLE_ID}"
  rm -rf "${WORK_DIR}"
}

if [[ "${MODE}" == "clean" ]]; then
  cleanup_traces
  echo "Следы стенда убраны."
  exit 0
fi

if [[ -z "${OLD_ARCHIVE}" ]]; then
  OLD_ARCHIVE="$(ls -t "${ROOT_DIR}"/dist/OWAWidget-v*-macos.zip 2>/dev/null | head -1 || true)"
fi
if [[ -z "${OLD_ARCHIVE}" || ! -f "${OLD_ARCHIVE}" ]]; then
  echo "Не найден архив предыдущей версии." >&2
  echo "Укажите его через --old, либо скачайте опубликованный релиз в dist/:" >&2
  echo "  gh release download --pattern '*.zip' --dir dist" >&2
  exit 1
fi
if [[ ! -d "${BUILT_APP}" ]]; then
  echo "Нет ${BUILT_APP}. Сначала соберите: make bundle" >&2
  exit 1
fi
if [[ ! -x "${BIN_DIR}/generate_appcast" ]]; then
  echo "Нет инструментов Sparkle. Выполните: swift package resolve" >&2
  exit 1
fi

cleanup_traces
mkdir -p "${WORK_DIR}/old" "${WORK_DIR}/new" "${WORK_DIR}/serve"

set_str() { # plist key value
  /usr/libexec/PlistBuddy -c "Set :$2 $3" "$1" >/dev/null 2>&1 || \
  /usr/libexec/PlistBuddy -c "Add :$2 string $3" "$1"
}

patch_plist() { # app_path [version] [build]
  local plist="$1/Contents/Info.plist"
  set_str "${plist}" CFBundleIdentifier "${TEST_BUNDLE_ID}"
  set_str "${plist}" SUFeedURL "http://localhost:${PORT}/appcast.xml"
  [[ -n "${2:-}" ]] && set_str "${plist}" CFBundleShortVersionString "$2"
  [[ -n "${3:-}" ]] && set_str "${plist}" CFBundleVersion "$3"
  # Фид отдаётся по http с localhost, поэтому только для стенда снимаем ATS.
  /usr/libexec/PlistBuddy -c "Delete :NSAppTransportSecurity" "${plist}" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "${plist}"
  /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true" "${plist}"
}

echo "== Старая сторона: $(basename "${OLD_ARCHIVE}") =="
ditto -x -k "${OLD_ARCHIVE}" "${WORK_DIR}/old"
OLD_APP="${WORK_DIR}/old/OWAWidget.app"
[[ -d "${OLD_APP}" ]] || { echo "В архиве нет OWAWidget.app" >&2; exit 1; }
patch_plist "${OLD_APP}"
cat > "${WORK_DIR}/old.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.network.client</key><true/>
</dict></plist>
EOF
# Намеренно без --options runtime: воспроизводим подпись уже установленной версии.
codesign --sign - --force --deep "${OLD_APP}/Contents/Frameworks/Sparkle.framework" >/dev/null 2>&1
codesign --sign - --force --deep --entitlements "${WORK_DIR}/old.entitlements" "${OLD_APP}" >/dev/null 2>&1
echo "   подпись: $(codesign -dv "${OLD_APP}" 2>&1 | grep -o 'flags=[^ ]*')"

echo "== Новая сторона: текущая сборка =="
ditto "${BUILT_APP}" "${WORK_DIR}/new/OWAWidget.app"
NEW_APP="${WORK_DIR}/new/OWAWidget.app"
patch_plist "${NEW_APP}" "${NEW_VERSION}" "${NEW_BUILD}"
codesign --sign - --force --deep --options runtime \
  "${NEW_APP}/Contents/Frameworks/Sparkle.framework" >/dev/null 2>&1
codesign --sign - --force --deep --options runtime \
  --entitlements "${ROOT_DIR}/OWAWidget/OWAWidget-dev.entitlements" "${NEW_APP}" >/dev/null 2>&1
echo "   подпись: $(codesign -dv "${NEW_APP}" 2>&1 | grep -o 'flags=[^ ]*')"

echo "== Архив и appcast =="
ditto -c -k --sequesterRsrc --keepParent "${NEW_APP}" \
  "${WORK_DIR}/serve/OWAWidget-v${NEW_VERSION}-macos.zip"
"${BIN_DIR}/generate_appcast" --download-url-prefix "http://localhost:${PORT}/" \
  "${WORK_DIR}/serve" >/dev/null
if ! grep -q 'sparkle:edSignature="[^"]' "${WORK_DIR}/serve/appcast.xml"; then
  echo "appcast без подписи — стенд бессмыслен, клиент такое обновление отвергнет." >&2
  echo "Проверьте ключ: см. docs/sparkle-key-backup.md" >&2
  exit 1
fi
echo "   версия в фиде: $(grep -o '<sparkle:shortVersionString>[^<]*' "${WORK_DIR}/serve/appcast.xml" | head -1 | sed 's/.*>//')"

if [[ "${MODE}" == "prepare" ]]; then
  echo
  echo "Стенд собран, сервер не поднимался (--prepare-only)."
  echo "  ${WORK_DIR}"
  exit 0
fi

trap 'echo; echo "Останавливаю стенд…"; cleanup_traces; echo "Готово."' EXIT

( cd "${WORK_DIR}/serve" && python3 -m http.server "${PORT}" --bind 127.0.0.1 ) \
  >"${WORK_DIR}/server.log" 2>&1 &

# Sparkle сам проверяет обновления вскоре после запуска, если это разрешено; без
# SUHasLaunchedBefore первый запуск потратит время на вопрос о разрешении.
defaults write "${TEST_BUNDLE_ID}" SUHasLaunchedBefore -bool true
defaults write "${TEST_BUNDLE_ID}" SUEnableAutomaticChecks -bool true
defaults write "${TEST_BUNDLE_ID}" SUAutomaticallyUpdate -bool true
defaults write "${TEST_BUNDLE_ID}" SUScheduledCheckInterval -int 3600

open "${OLD_APP}"

cat <<EOF

Стенд поднят. В меню-баре появился второй значок — это старая версия.

Что должно произойти:
  1. Sparkle заберёт http://localhost:${PORT}/appcast.xml и скачает архив
     (видно в ${WORK_DIR}/server.log).
  2. При выходе из приложения обновление установится.

Как проверить результат:
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \\
    "${OLD_APP}/Contents/Info.plist"        # ждём ${NEW_VERSION}
  codesign -dv "${OLD_APP}" 2>&1 | grep -o 'flags=[^ ]*'   # ждём adhoc,runtime

Ctrl-C — остановить сервер и убрать следы.
EOF

wait
