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
#      фида и ATS; подпись — ad-hoc с entitlements и флагами самого архива.
#   2. «Новая» сторона — текущая сборка из .build, подписанная scripts/sign_app.sh тем же
#      сертификатом, что и релиз (Developer ID). Для проверки без сертификата: --identity -
#   3. Архив, appcast с подписью и локальный HTTP-сервер.
#   4. Запуск «старой» версии, которая проверяет обновления на localhost.
#
# Ничего не уходит на GitHub: фид, архив и подпись живут только на localhost, а тестовая версия
# никогда не публикуется. Подписывает стенд одноразовым EdDSA-ключом, а не боевым: обе стороны
# получают его публичную половину в SUPublicEDKey. С боевым ключом архив «версии 99.0.0» был бы
# настоящим обновлением для всех пользователей, и попади он в фид — они остались бы на нём
# навсегда, ведь Sparkle не откатывает версию назад. Отдельный bundle id означает отдельные UserDefaults и отдельный каталог
# в Application Support, поэтому аккаунты и кэш рабочей копии недоступны тестовой.
#
# Использование:
#   bash scripts/test_update_locally.sh                 # собрать, поднять сервер, запустить
#   bash scripts/test_update_locally.sh --prepare-only  # только собрать и проверить, без запуска
#   bash scripts/test_update_locally.sh --clean         # убрать за собой и выйти
#   bash scripts/test_update_locally.sh --identity -    # новая сторона ad-hoc вместо Developer ID
#
# Ctrl-C останавливает сервер и убирает следы.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${ROOT_DIR}/.build/artifacts/sparkle/Sparkle/bin"
# Переопределяется, чтобы проверить релизную сборку, не трогая рабочую копию:
#   BUILT_APP=.build/release-check/OWAWidget.app (после make release-bundle APP_PATH=…).
BUILT_APP="${BUILT_APP:-${ROOT_DIR}/.build/OWAWidget.app}"
WORK_DIR="${ROOT_DIR}/.build/update-test"
TEST_BUNDLE_ID="com.owawidget.MacOwaWidget.updatetest"
PORT="${PORT:-8899}"
NEW_VERSION="${NEW_VERSION:-99.0.0}"
NEW_BUILD="${NEW_BUILD:-99000}"
OLD_ARCHIVE=""
MODE="run"
# По умолчанию — как в релизе (RELEASE_SIGN_IDENTITY в Makefile).
NEW_IDENTITY="${NEW_IDENTITY:-Developer ID Application}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prepare-only) MODE="prepare"; shift ;;
    --clean)        MODE="clean"; shift ;;
    --old)          OLD_ARCHIVE="$2"; shift 2 ;;
    --port)         PORT="$2"; shift 2 ;;
    --identity)     NEW_IDENTITY="$2"; shift 2 ;;
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

# Одноразовая пара ключей стенда. Приватная половина — в WORK_DIR (0600), которую стенд удаляет
# за собой; формат тот же, что принимает `--ed-key-file`: base64 32-байтного seed.
STAND_KEY_FILE="${WORK_DIR}/stand-ed25519.key"
STAND_KEYS="$(swift - <<'SWIFT'
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
)"
( umask 077 && printf '%s' "$(sed -n 1p <<<"${STAND_KEYS}")" > "${STAND_KEY_FILE}" )
STAND_PUBLIC_KEY="$(sed -n 2p <<<"${STAND_KEYS}")"
unset STAND_KEYS
[[ -s "${STAND_KEY_FILE}" && -n "${STAND_PUBLIC_KEY}" ]] || { echo "Не удалось создать ключ стенда" >&2; exit 1; }

set_str() { # plist key value
  /usr/libexec/PlistBuddy -c "Set :$2 $3" "$1" >/dev/null 2>&1 || \
  /usr/libexec/PlistBuddy -c "Add :$2 string $3" "$1"
}

patch_plist() { # app_path [version] [build]
  local plist="$1/Contents/Info.plist"
  set_str "${plist}" CFBundleIdentifier "${TEST_BUNDLE_ID}"
  set_str "${plist}" SUFeedURL "http://localhost:${PORT}/appcast.xml"
  set_str "${plist}" SUPublicEDKey "${STAND_PUBLIC_KEY}"
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
# Начиная с v1.0.54 релизы подписаны Developer ID, и library validation в них включена: ad-hoc
# подпись без Team ID под ней не загрузит Sparkle.framework (dyld: «different Team IDs»).
# Такую старую сторону переподписываем сертификатом новой стороны; более ранние — ad-hoc.
OLD_IDENTITY="-"
# Через переменную, не `codesign | grep -q`: при pipefail ранний выход grep обрывает codesign
# SIGPIPE-ом, и проверка молча ложна.
OLD_SIGNATURE="$(codesign -dvv "${OLD_APP}" 2>&1 || true)"
if [[ "${OLD_SIGNATURE}" == *$'\nAuthority=Developer ID Application:'* ]]; then
  [[ "${NEW_IDENTITY}" != "-" ]] || {
    echo "Старая сторона подписана Developer ID: нужен сертификат, --identity - не подойдёт." >&2
    exit 1
  }
  OLD_IDENTITY="${NEW_IDENTITY}"
fi
patch_plist "${OLD_APP}"
# Правка Info.plist ломает подпись, поэтому переподписываем — но с entitlements и флагами
# (hardened runtime) самого архива, у каждого вложенного компонента свои: так старая сторона
# остаётся тем, что стоит у людей, а не тем, как мы подписываем сейчас.
codesign --sign "${OLD_IDENTITY}" --force --deep --timestamp=none \
  --preserve-metadata=entitlements,flags "${OLD_APP}" >/dev/null 2>&1
codesign --verify --strict --deep "${OLD_APP}"
echo "   подпись: $(codesign -dvv "${OLD_APP}" 2>&1 | grep -m1 -E '^(Authority|Signature)=') $(codesign -dv "${OLD_APP}" 2>&1 | grep -o 'flags=[^ ]*')"

echo "== Новая сторона: текущая сборка =="
ditto "${BUILT_APP}" "${WORK_DIR}/new/OWAWidget.app"
NEW_APP="${WORK_DIR}/new/OWAWidget.app"
patch_plist "${NEW_APP}" "${NEW_VERSION}" "${NEW_BUILD}"
# Тот же скрипт, что и в Makefile: стенд проверяет ровно ту подпись, что получат пользователи.
bash "${ROOT_DIR}/scripts/sign_app.sh" "${NEW_APP}" "${NEW_IDENTITY}" >/dev/null 2>&1
echo "   подпись: $(codesign -dvv "${NEW_APP}" 2>&1 | grep -m1 -E '^(Authority|Signature)=') $(codesign -dv "${NEW_APP}" 2>&1 | grep -o 'flags=[^ ]*')"

echo "== Архив и appcast =="
ditto -c -k --sequesterRsrc --keepParent "${NEW_APP}" \
  "${WORK_DIR}/serve/OWAWidget-v${NEW_VERSION}-macos.zip"
"${BIN_DIR}/generate_appcast" --download-url-prefix "http://localhost:${PORT}/" \
  --ed-key-file "${STAND_KEY_FILE}" "${WORK_DIR}/serve" >/dev/null
rm -f "${STAND_KEY_FILE}"
if ! grep -q 'sparkle:edSignature="[^"]' "${WORK_DIR}/serve/appcast.xml"; then
  echo "appcast без подписи — стенд бессмыслен, клиент такое обновление отвергнет." >&2
  echo "Ключ стенда одноразовый; проверьте вывод generate_appcast выше." >&2
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
  codesign -dvv "${OLD_APP}" 2>&1 | grep -m1 -E '^(Authority|Signature)='   # ждём подпись новой стороны

Ctrl-C — остановить сервер и убрать следы.
EOF

wait
