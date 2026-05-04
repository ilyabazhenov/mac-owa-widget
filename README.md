# OWAWidget

OWAWidget - macOS menu bar приложение для быстрого просмотра ближайших встреч и перехода в онлайн-звонки из календаря Microsoft Exchange / OWA.

Проект написан на Swift 6 и SwiftUI. Основной сценарий: приложение живет в строке меню, показывает ближайшие встречи, находит ссылки на Teams, Zoom, Webex, Google Meet и другие платформы, а также отправляет локальные уведомления перед началом встречи.

## Возможности

- Подключение Exchange / OWA аккаунта.
- Хранение пароля в macOS Keychain.
- Синхронизация календаря по расписанию.
- Отображение ближайшей встречи в menu bar popover.
- Группировка нескольких встреч, начинающихся примерно одновременно.
- Поиск join-ссылок в отдельном поле встречи, location и body.
- Локальные уведомления с действием Join.
- Заготовка под будущий Google Calendar провайдер.

## Требования

- macOS 13 или новее.
- Xcode или Xcode Command Line Tools.
- Swift 6 toolchain.
- Для `make watch`: `fswatch`.
- Опционально для генерации Xcode project: XcodeGen.

## Сборка

Быстрая проверка компиляции:

```bash
swift build
```

Сборка через Makefile:

```bash
make build
```

Сборка `.app` bundle и запуск:

```bash
make run
```

Автопересборка при изменении Swift-файлов:

```bash
make watch
```

Очистка:

```bash
make clean
```

## Xcode

`OWAWidget.xcodeproj` не хранится в проекте. Он считается генерируемым артефактом и игнорируется через `.gitignore`.

Если нужен Xcode-проект, сгенерируй его из `project.yml`:

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
    |       +-- GoogleCalendarProvider (stub)
    |
    +-- SyncScheduler
    +-- NotificationService
```

Ключевые файлы:

| Файл | Назначение |
| --- | --- |
| `OWAWidget/OWAWidgetApp.swift` | Точка входа приложения, menu bar extra, окно настроек, обработчик уведомлений. |
| `OWAWidget/Services/CalendarService.swift` | Главный источник состояния: аккаунты, события, статус синхронизации. |
| `OWAWidget/Providers/CalendarProvider.swift` | Протокол календарного провайдера. |
| `OWAWidget/Providers/OWA/OWAClient.swift` | OWA авторизация, cookies, CANARY token и запрос календаря. |
| `OWAWidget/Providers/OWA/OWACalendarProvider.swift` | Маппинг OWA-событий в `CalendarEvent`. |
| `OWAWidget/Services/MeetingURLDetector.swift` | Поиск ссылок на платформы встреч. |
| `OWAWidget/Services/NotificationService.swift` | Планирование локальных уведомлений. |
| `OWAWidget/Views/` | SwiftUI интерфейс popover и настроек. |

## Хранение данных

- Метаданные аккаунтов хранятся в `UserDefaults` по ключу `calendarAccounts`.
- Пароли хранятся в Keychain, service: `com.owawidget.OWAWidget`.
- Настройки синхронизации и уведомлений хранятся в `UserDefaults`.

## Добавление календарного провайдера

1. Создай папку `OWAWidget/Providers/<ProviderName>/`.
2. Реализуй `actor <ProviderName>CalendarProvider: CalendarProvider`.
3. Реализуй `fetchEvents(from:to:)` и `validateCredentials()`.
4. Добавь новый case в `AccountType`.
5. Подключи провайдер в `CalendarService.rebuildProviders()`.
6. Добавь UI для настройки аккаунта, если провайдер требует другой способ авторизации.

## Безопасность

Пароли не должны попадать в `UserDefaults`, логи или документацию. Для OWA on-premise сценариев может потребоваться работа с нестандартными TLS-сертификатами, но ослабление проверки TLS должно быть явной настройкой пользователя, а не поведением по умолчанию.

