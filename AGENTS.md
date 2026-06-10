# AGENTS.md

## Язык

Отвечай пользователю всегда на русском языке.

Код и комментарии в коде пиши на английском языке.

## Source of truth

Этот файл является основным источником агентских инструкций в репозитории.
Если аналогичные правила встречаются в других файлах, при расхождении следуй этому файлу.

## Приоритет инструкций

Применяй инструкции в таком порядке:

1. Прямой запрос пользователя в текущем чате.
2. Ограничения безопасности и целостности проекта.
3. Процедурные workflow-правила этого файла (сборка, проверка, релиз).

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
- `OWAWidget/Services/UpdateCheckService.swift` - обертка над Sparkle (`SPUStandardUpdaterController`) для авто-обновлений по EdDSA-подписанному appcast.xml.
- `OWAWidget/Views/` - SwiftUI интерфейс меню и настроек.
- `OWAWidget/Views/MeetingListView.swift` - таймлайн-список встреч в popover (тайм-сетка + overlay карточек).
- `OWAWidget/Views/TimelineMeetingLayout.swift` - алгоритмы раскладки пересекающихся встреч (slotting, clusters, lanes, frame math).
- `OWAWidget/Views/TimelineMeetingBlockView.swift` - визуальная карточка встречи в таймлайне, включая compact-режим.
- `OWAWidget/Views/CreateMeeting/` - окно создания встречи: поиск участников через FindPeople, занятость через GetUserAvailabilityInternal, создание через CreateCalendarEvent (OWA JSON API). Ключевые файлы: `CreateMeetingView.swift`, `CreateMeetingViewModel.swift`, `AttendeeSearchField.swift`, `SlotSuggestionsView.swift`.
- `OWAWidget/Services/MeetingFreeSlotCalculator.swift` - алгоритм поиска свободных 30-мин слотов по MergedFreeBusy строке OWA.
- `OWAWidget/Services/AppearanceService.swift` - тема приложения (light/dark/system).
- `OWAWidget/Services/RecentAttendeesStore.swift` / `RecentLocationsStore.swift` - история участников и локаций для быстрого ввода в форме создания встречи.

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
- `CustomMeetingReminderController` использует архитектуру **live-update single panel**: в любой момент времени отображается не более одного `NSPanel`. Если при срабатывании нового напоминания панель уже открыта, вызывается `updateCurrentPanel(merging:)`, который мёрджит новые встречи в `currentDisplayedItems`, пересчитывает title/subtitle и заменяет `currentHostingView.rootView` (SwiftUI делает diff in-place). Очереди (`queue: [Payload]`) не существует — не добавляй её. `finishPresentation()` очищает `currentPanel`, `currentHostingView`, `currentDisplayedItems`, `currentAnchorStartDate`, `currentDismissDeadline` без вызова какого-либо «следующего» элемента. Автозакрытие по таймеру и ручное закрытие оба вызывают `finishPresentation()` / `closeCurrentPanelAndFinish()` без дополнительных флагов.
- Reminder-панель показывается через `panel.orderFrontRegardless()` + `panel.makeKey()`. `orderFrontRegardless()` обязателен, потому что OWA Widget — фоновое menu-bar приложение: `makeKeyAndOrderFront(nil)` в таком случае молча не работает. `makeKey()` после `orderFrontRegardless()` даёт панели статус key window, и SwiftUI-кнопки срабатывают с первого клика. Без `makeKey()` первый клик «активирует» окно, а второй уже нажимает кнопку.
- Не обновляй версию вручную в `OWAWidget/Info.plist`: `make bundle`/`make release-package` автоматически ставят `CFBundleShortVersionString` из `VERSION` и `CFBundleVersion` из git-счётчика коммитов.
- RSVP (Accept/Decline/Tentative) реализован через **EWS SOAP** (`OWAClient.respondToMeeting`, строка ~511), а не через OWA JSON API. При расширении RSVP-функциональности сохраняй это разделение: EWS SOAP для мутирующих операций с письмами/ответами на встречи.

## Debug-логирование в файл

`make run` и `make watch` собирают **debug**-конфигурацию (`swift build` без `--configuration release`), поэтому блоки `#if DEBUG` активны именно в этих режимах. Используй это для инструментирования нового кода.

### Правило

При разработке новой фичи или диагностике бага **добавляй файловый лог** в компонент, который меняешь. Это позволяет агенту после запуска `make run` прочитать лог через `Read`-инструмент и увидеть точный поток выполнения без вмешательства пользователя.

### Канонический паттерн

```swift
import os.log

// В теле класса/актора — os.log для production:
private let log = Logger(subsystem: "com.owawidget", category: "MyComponent")

#if DEBUG
// Путь: /tmp/owawidget_<компонент>.log
private static let debugLogURL = URL(fileURLWithPath: "/tmp/owawidget_mycomponent.log")

// Вызывать в init() — сбрасывает файл при каждом запуске приложения:
private func setupDebugLog() {
    let header = "=== MyComponent Log started \(Date()) ===\n"
    try? header.write(to: Self.debugLogURL, atomically: true, encoding: .utf8)
}

// Вызывать вместо / вместе с log.info:
private func dlog(_ message: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    let line = "[\(f.string(from: Date()))] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: Self.debugLogURL) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: Self.debugLogURL, options: .atomic)
    }
}
#endif
```

### Соглашения по именованию файлов

| Компонент | Путь |
|---|---|
| `CustomMeetingReminderController` | `/tmp/owawidget_reminder.log` |
| `CalendarService` | `/tmp/owawidget_calendar.log` |
| Новый компонент `FooService` | `/tmp/owawidget_foo.log` |

### Как агент читает логи

После того как пользователь сообщил о воспроизведении бага:

```bash
# Посмотреть последние N строк:
tail -100 /tmp/owawidget_reminder.log

# Найти ключевые события:
grep -n "present\|enqueue\|SUPPRESSED\|WARNING" /tmp/owawidget_reminder.log
```

Или использовать `Read`-инструмент напрямую с `offset`/`limit` для больших файлов.

### Что логировать

Логируй на ключевых точках потока выполнения:
- вход в публичные методы с аргументами;
- изменение центрального состояния (`currentPanel`, `scheduleGeneration`, etc.);
- ветки, где происходит принятие решения (suppressed / present / merge);
- предупреждения о неожиданных состояниях.

Не логируй в tight loops и не добавляй `sleep` для «дать время» логам записаться — файловая запись синхронная.

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

- Если пользователь просит **"выпустить новый релиз"** (или эквивалентно), выполняй полный цикл публикации:
 1. Обновление `VERSION`.
 2. Обновление `RELEASE_NOTES.md`.
 - Обязательный формат секции версии:
 - `## vX.Y.Z - YYYY-MM-DD`
 - `### RU` и `### EN`
 - В обеих секциях обязательны подразделы про изменения и установку.
 - В обоих языках в инструкции по установке давай прямую ссылку на `https://github.com/ilyabazhenov/mac-owa-widget/releases/latest/download/OWAWidget-macos.zip`, затем распаковку в `/Applications`.
 - В обоих языках в инструкции по установке обязательно указывай, что `xattr -dr com.apple.quarantine /Applications/OWAWidget.app` нужен ТОЛЬКО при первой установке; последующие обновления ставит Sparkle автоматически.
 3. Перед упаковкой обязательно зафиксируй релизные изменения (`VERSION`, `RELEASE_NOTES.md` и связанные файлы) в git commit, чтобы `CFBundleVersion`/`sparkle:version` гарантированно выросли относительно предыдущего релиза (build номер берется из `git rev-list --count HEAD`).
 4. Сборка архива и appcast: `make release-package` (создает `dist/OWAWidget-v<ver>-macos.zip`, `dist/OWAWidget-macos.zip` и `dist/appcast.xml`).
 - Требуется доступ к EdDSA-приватнику (логин-Keychain или env `SPARKLE_ED_PRIVATE_KEY`). Если ключа нет — скрипт упадет; не пытайся выпустить релиз без подписи.
 5. Перед публикацией проверь `dist/appcast.xml`: `sparkle:version` нового релиза должен быть строго больше `sparkle:version` предыдущего опубликованного релиза.
 6. Публикация на GitHub через `gh release create` с тремя ассетами: versioned zip, `OWAWidget-macos.zip` (стабильная ссылка для установки) и `appcast.xml`.
 7. Возврат пользователю URL релиза.

- Если пользователь просит **"подготовить релиз"** (без явного требования публикации):
 1. Обнови `VERSION` и `RELEASE_NOTES.md`.
 2. Перед упаковкой обязательно зафиксируй релизные изменения в git commit, чтобы build номер в appcast вырос.
 3. Собери архив и appcast `make release-package` (zip + `dist/appcast.xml`).
 4. Убедись, что `sparkle:version` в `dist/appcast.xml` строго больше предыдущего релиза.
 5. Не публикуй релиз в GitHub, пока пользователь не попросит явно.

- По умолчанию не изменяй релизные артефакты и метаданные без релизного запроса.

## Guardrails для релизных файлов

Без явного релизного запроса пользователя не изменяй:

- `VERSION`
- `RELEASE_NOTES.md`
- `dist/` (включая zip-артефакты и `appcast.xml`)
- теги/релизы GitHub
- `OWAWidget/Info.plist` ключ `SUPublicEDKey` (трогать только при ротации EdDSA-ключа Sparkle, что ломает обновления у установленных клиентов)

## Definition of Done для агента

Перед завершением ответа:

1. Проверь минимально `swift build`, если менялся код/логика.
2. Если менялись упаковка, entitlement-файлы или запуск `.app`, дополнительно запусти `make run`.
3. В финальном ответе кратко укажи:
   - какие файлы изменены;
   - какие проверки запускались;
   - результат проверок (успешно/ошибка и что сделано).
