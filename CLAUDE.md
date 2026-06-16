# OWA Widget

Этот файл содержит краткий контекст. Полные агентские правила находятся в `AGENTS.md`.

## Где смотреть правила

- Основной source of truth для агентов: `AGENTS.md`.
- При расхождении между этим файлом и `AGENTS.md` следуй `AGENTS.md`.

## Краткий контекст проекта

OWAWidget — macOS menu bar приложение на Swift 6 и SwiftUI для показа ближайших встреч Exchange / OWA и быстрого перехода в звонок.

Ключевые директории:

- `OWAWidget/Services/` — сервисы состояния, синхронизации, уведомлений и keychain.
- `OWAWidget/Providers/` — календарные провайдеры (OWA и будущие интеграции).
- `OWAWidget/Views/` — SwiftUI интерфейс popover и настроек.

## Базовые команды

```bash
make build
make run
swift build
```

Если нужен Xcode-проект, генерируй его через `xcodegen generate` из `project.yml`.

## Ограничения агентов

- Никогда не используй `isolation: "worktree"` при вызове Agent tool. Worktree изоляция запрещена.
- Релиз собирается и публикуется **только локально** (`make release-package` + `gh release create`). Не запускай GitHub Actions workflow `release.yml` — раннер с Xcode 16.4 несовместим с зависимостью `KeyboardShortcuts`. Подробности — в `AGENTS.md`, раздел «Релизный процесс».
