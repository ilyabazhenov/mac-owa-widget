# AGENTS.md

## Язык

Отвечай пользователю всегда на русском языке.

## Контекст проекта

OWAWidget - macOS menu bar приложение на Swift 6 и SwiftUI для просмотра ближайших встреч и быстрого перехода в онлайн-звонки из календаря Microsoft Exchange / OWA.

Основной код находится в `OWAWidget/`.

Ключевые части:

- `OWAWidget/OWAWidgetApp.swift` - точка входа приложения, `MenuBarExtra`, окно настроек, обработка уведомлений.
- `OWAWidget/Services/CalendarService.swift` - главный `@MainActor` источник состояния, аккаунтов, событий и синхронизации.
- `OWAWidget/Providers/CalendarProvider.swift` - общий протокол календарных провайдеров.
- `OWAWidget/Providers/OWA/` - интеграция с OWA: авторизация, CANARY token, запрос календаря и маппинг событий.
- `OWAWidget/Providers/GoogleCalendar/` - заглушка будущего Google Calendar провайдера.
- `OWAWidget/Services/MeetingURLDetector.swift` - поиск ссылок на Teams, Zoom, Webex, Google Meet и другие платформы.
- `OWAWidget/Services/NotificationService.swift` - локальные уведомления о встречах.
- `OWAWidget/Services/KeychainService.swift` - хранение паролей в Keychain.
- `OWAWidget/Services/LaunchAtLoginService.swift` - автозапуск при входе (`SMAppService.mainApp`).
- `OWAWidget/Views/` - SwiftUI интерфейс меню и настроек.
- `OWAWidget/Views/MeetingListView.swift` - таймлайн-список встреч в popover (тайм-сетка + overlay карточек).
- `OWAWidget/Views/TimelineMeetingLayout.swift` - алгоритмы раскладки пересекающихся встреч (slotting, clusters, lanes, frame math).
- `OWAWidget/Views/TimelineMeetingBlockView.swift` - визуальная карточка встречи в таймлайне, включая compact-режим.

## Сборка и запуск

Используй актуальные команды из `Makefile`:

```bash
make build
make run
make watch
make clean
```

Для быстрой проверки компиляции достаточно:

```bash
swift build
```

`make watch` требует установленный `fswatch`.

## Xcode-проект

`OWAWidget.xcodeproj` считается генерируемым артефактом и не должен храниться в репозитории. Если нужен Xcode-проект, генерируй его из `project.yml` через XcodeGen.

Не редактируй сгенерированный `.xcodeproj` вручную как источник истины. Изменения настроек проекта вноси в `project.yml`, а настройки SwiftPM - в `Package.swift`.

## Правила изменений

- Не добавляй секреты, пароли, токены, cookies или реальные серверные адреса в репозиторий.
- Пароли аккаунтов должны оставаться только в Keychain.
- Не ослабляй TLS-проверки без явной настройки пользователя. Текущий OWA-клиент поддерживает локальные корпоративные Exchange-сценарии, но безопасность TLS нужно улучшать осторожно.
- Учитывай строгую конкурентность Swift 6. Сохраняй границы акторов у сервисов и провайдеров.
- Не включай `OWAWidget.xcodeproj/`, `.build/`, `DerivedData/` и другие артефакты сборки в изменения.
- При добавлении нового календарного провайдера реализуй `CalendarProvider`, добавь тип аккаунта в `CalendarAccount`, затем подключи провайдер в `CalendarService.rebuildProviders()`.
- Для UI параллельных встреч придерживайся инварианта: даже в compact-карточке нужно показывать собственный интервал времени события.
- Для проверки логики пересечений используй критерий полуинтервалов: `lhs.startDate < rhs.endDate && rhs.startDate < lhs.endDate`.
- Не обновляй версию вручную в `OWAWidget/Info.plist`: `make bundle`/`make release-package` автоматически ставят `CFBundleShortVersionString` из `VERSION` и `CFBundleVersion` из git-счётчика коммитов.

## Проверка

Минимальная проверка перед завершением изменения:

```bash
swift build
```

Если менялась упаковка приложения или entitlement-файлы, дополнительно проверь:

```bash
make run
```

## Релизный процесс по запросу пользователя

- Если пользователь пишет: **"выпусти новый релиз"** (или эквивалентную формулировку), агент должен выполнить полный цикл, а не только локальную сборку.
- Полный цикл включает:
  1. Обновление `VERSION` (новая версия).
  2. Обновление `RELEASE_NOTES.md` под эту версию.
     - В `RELEASE_NOTES.md` обязательно добавлять инструкцию по установке.
     - В инструкции по установке обязательно упоминать и приводить команду: `xattr -dr com.apple.quarantine /Applications/OWAWidget.app`.
  3. Сборку релизного архива через `make release-package`.
  4. Публикацию релиза на GitHub (через `gh release create`, с приложением zip-артефакта из `dist/`).
- После публикации агент должен вернуть пользователю ссылку на релиз GitHub.
