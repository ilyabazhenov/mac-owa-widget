# OWA Widget

macOS-приложение для строки меню, которое показывает ближайшие встречи из календаря Microsoft Exchange / OWA и помогает быстро перейти в онлайн-звонок. Проект написан на Swift 6 и SwiftUI.

## Сборка и запуск

```bash
make build    # скомпилировать Swift-код
make run      # собрать .app-пакет и запустить приложение
make watch    # автоматически пересобирать при изменении .swift файлов, требуется fswatch
make clean    # удалить артефакты сборки
```

Быстрая проверка компиляции:

```bash
swift build
```

`OWAWidget.xcodeproj` не хранится в репозитории. Если нужен Xcode-проект, сгенерируй его из `project.yml` через XcodeGen:

```bash
xcodegen generate
```

После генерации можно открыть `OWAWidget.xcodeproj` в Xcode и настроить `Development Team` для подписи приложения.

## Архитектура

```text
SwiftUI Views
    |
    v
CalendarService (@MainActor, ObservableObject)
    |
    +-- CalendarProvider actors
    |       |
    |       +-- OWACalendarProvider
    |       |       |
    |       |       +-- OWAClient
    |       |
    |       +-- GoogleCalendarProvider (заглушка)
    |
    +-- SyncScheduler
    +-- NotificationService
```

В проекте включена строгая конкурентность Swift 6 (`SWIFT_STRICT_CONCURRENCY = complete`). Провайдеры календарей и фоновые сервисы реализованы через акторы. `CalendarEvent` и `CalendarAccount` являются `Sendable` value types.

## Ключевые файлы

| Файл | Назначение |
| --- | --- |
| `OWAWidget/OWAWidgetApp.swift` | Точка входа приложения, `MenuBarExtra`, окно настроек и обработчик уведомлений. |
| `OWAWidget/Services/CalendarService.swift` | Главный `@MainActor` источник состояния: аккаунты, события, статус синхронизации. |
| `OWAWidget/Providers/CalendarProvider.swift` | Общий протокол календарных провайдеров. |
| `OWAWidget/Providers/OWA/OWAClient.swift` | OWA-авторизация, cookies, CANARY token и запрос календаря. |
| `OWAWidget/Providers/OWA/OWACalendarProvider.swift` | Маппинг OWA-событий в `CalendarEvent`. |
| `OWAWidget/Providers/OWA/OWAModels.swift` | Модели ответа OWA-сервиса и ошибки OWA. |
| `OWAWidget/Providers/GoogleCalendar/GoogleCalendarProvider.swift` | Заглушка будущей интеграции с Google Calendar. |
| `OWAWidget/Services/MeetingURLDetector.swift` | Поиск ссылок на Teams, Zoom, Webex, Google Meet и другие платформы в данных события. |
| `OWAWidget/Services/NotificationService.swift` | Локальные уведомления перед встречами. |
| `OWAWidget/Services/KeychainService.swift` | Хранение паролей аккаунтов в macOS Keychain. |
| `OWAWidget/Services/LaunchAtLoginService.swift` | Автозапуск при входе в систему через `SMAppService.mainApp` (`ServiceManagement`). |
| `OWAWidget/Views/PopoverView.swift` | Главное окно popover: ближайшие встречи, секции событий и состояния ошибки/пустого списка. |
| `OWAWidget/Views/NextMeetingBannerView.swift` | Баннер ближайшей встречи или стопка встреч, начинающихся почти одновременно. |
| `OWAWidget/Views/MeetingListView.swift` | Основной список встреч в popover: тайм-сетка и overlay карточек встреч. |
| `OWAWidget/Views/TimelineMeetingLayout.swift` | Чистая логика таймлайн-раскладки: слоты, кластеры пересечений, lane assignment и frame-калькуляции. |
| `OWAWidget/Views/TimelineMeetingBlockView.swift` | Карточка встречи в таймлайне; в compact-режиме сохраняет заголовок, интервал времени и join action. |
| `project.yml` | Конфигурация XcodeGen. Правки Xcode-проекта вноси здесь, затем генерируй `.xcodeproj`. |

## Добавление нового календарного провайдера

1. Создай папку `OWAWidget/Providers/<ProviderName>/`.
2. Реализуй `actor <ProviderName>CalendarProvider: CalendarProvider`.
3. Реализуй `fetchEvents(from:to:)` и `validateCredentials()`.
4. Добавь новый case в `AccountType` в `OWAWidget/Models/CalendarAccount.swift`.
5. Подключи провайдер в `CalendarService.rebuildProviders()`.
6. Добавь интерфейс настройки аккаунта, если провайдер требует другой способ авторизации.

## Заметки по OWA

### Авторизация

Поток: `GET /owa/` → редирект на `logon.aspx` → парсинг HTML-формы → `POST /owa/auth.owa`.

**Критично:** `OWAClient.fetchLoginForm()` скачивает HTML страницы логина и парсит реальные поля формы. Поле пароля называется `password` (не `passwd`!). Поле `passwordText` обязательно и всегда пустое. Параметр `destination` должен быть `https://<host>/owa/?bFS=1`.

После успешного POST сервер возвращает 302 и устанавливает куку `X-OWA-CANARY`. Если кука не найдена в редиректах, `OWAClient` делает `GET /owa/` и ищет CANARY в HTML страницы.

`OWAClient` — actor с ephemeral `URLSession`. Delegate `OWASessionDelegate` перехватывает заголовки `Set-Cookie` из 302-ответов (через `willPerformHTTPRedirection`), т.к. `session.configuration.httpCookieStorage` у ephemeral-сессии недоступен для чтения. **Не добавляй Cookie-заголовок вручную** — это вызывает дублирование и HTTP 400 от сервера.

### Запрос календаря

`POST /owa/service.svc?action=GetCalendarView`

Данные передаются в заголовке `X-OWA-UrlPostData` (URL-encoded JSON), тело запроса — пустое.

Ключевые параметры запроса:
- `__type`: `"GetCalendarViewJsonRequest:#Exchange"` (с `Json` в середине!)
- `RequestServerVersion`: `"V2017_08_18"`
- Поля дат: `RangeStart` / `RangeEnd` (не `StartDate`/`EndDate`)
- `CalendarId` → `TargetFolderId` → `BaseFolderId` → `DistinguishedFolderId` с `Id: "calendar"`

### Структура ответа

`Body.Items[]` — массив `CalendarItem`. Поля: `Subject`, `Start`, `End`, `FreeBusyType`, `Organizer.Mailbox.Name`. `OWACalendarProvider` ищет join-ссылку: `JoinOnlineMeetingUrl` → `Location.DisplayName` → `TextBody.Value`.

### TLS и сертификаты

`TLSBypassDelegate` принимает самоподписанные сертификаты для on-premise Exchange. Не ослабляй TLS-поведение дальше без явной настройки пользователя.

## Уведомления

Категория уведомлений: `MEETING_JOIN`.

Действие: `JOIN_MEETING`.

Уведомление создается за `notificationLeadMinutes` минут до начала встречи. При нажатии открывается `joinURL` через `NSWorkspace.shared.open` на main thread.

## Одновременные встречи

Если несколько встреч начинаются в пределах 5 минут от ближайшей предстоящей встречи, `PopoverView.nextEvents` группирует их. `NextMeetingBannerView` показывает такую группу как стопку. События со ссылкой на звонок сортируются выше событий без ссылки.

Основной список встреч в `MeetingListView` построен как тайм-сетка с overlay карточек. Пересечения определяются через полуинтервальный критерий (`lhs.startDate < rhs.endDate && rhs.startDate < lhs.endDate`) и раскладываются по lane-колонкам внутри overlap-кластеров.

Для компактных карточек (`TimelineMeetingBlockView`, режим `compact`) обязательно сохраняй отображение собственного интервала времени события; это ключевой UX-инвариант для параллельных встреч.

## Хранение настроек

- Метаданные аккаунтов: `UserDefaults`, ключ `calendarAccounts`, JSON-кодированный массив `[CalendarAccount]`.
- Пароли: macOS Keychain, service `com.owawidget.OWAWidget`, account `accountID.uuidString`.
- Настройки синхронизации: `UserDefaults`, ключ `syncInterval`.
- Настройки уведомлений: `UserDefaults`, ключ `notificationLeadMinutes`.
- Автозапуск при входе: состояние хранит macOS (Login Items), не `UserDefaults`; переключатель в настройках вызывает `SMAppService.mainApp` через `LaunchAtLoginService`.

## Правила для агентов

- Отвечай пользователю на русском языке.
- Не добавляй секреты, пароли, токены, cookies или реальные серверные адреса в репозиторий.
- Не коммить и не восстанавливай `OWAWidget.xcodeproj/`; это генерируемый артефакт.
- Для проверки после изменений запускай `swift build`.
- Если менялись упаковка приложения, entitlement-файлы или запуск `.app`, дополнительно проверяй `make run`.
- Не обновляй версию вручную в `OWAWidget/Info.plist`: `make bundle`/`make release-package` автоматически ставят `CFBundleShortVersionString` из `VERSION` и `CFBundleVersion` из git-счётчика коммитов.

## Релиз по команде пользователя

Если пользователь просит "выпустить новый релиз" (или формулирует это эквивалентно), агент должен:

1. Подготовить новую версию (`VERSION`) и обновить `RELEASE_NOTES.md`.
   - В `RELEASE_NOTES.md` обязательно добавлять инструкцию по установке.
   - В инструкции по установке обязательно упоминать и приводить команду: `xattr -dr com.apple.quarantine /Applications/OWAWidget.app`.
2. Собрать релизный архив (`make release-package`).
3. Опубликовать релиз на GitHub через `gh` (создать tag/release и прикрепить zip из `dist/`).
4. Сообщить пользователю URL опубликованного GitHub release.

Не ограничиваться только локальной сборкой архива, если пользователь явно запросил выпуск релиза.
