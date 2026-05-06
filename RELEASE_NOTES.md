## v1.0.27 - 2026-05-06

### RU

#### Что изменилось

- Обновлена иконка приложения во всех размерах macOS-бандла; мастер-исходник переведен на PNG.
- Улучшена логика напоминаний и агрегации уведомлений для встреч, включая обновления в `MeetingReminderShared` и `NotificationService`.
- Обновлены тесты расписания напоминаний и агрегации уведомлений для проверки нового поведения.

#### Установка

1. Переместите `OWAWidget.app` в `/Applications`.
2. Снимите quarantine-атрибуты:

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

### EN

#### What's Changed

- Updated the app icon across all macOS bundle sizes; the master source was switched to PNG.
- Improved meeting reminder and notification aggregation logic, including updates in `MeetingReminderShared` and `NotificationService`.
- Updated reminder scheduling and notification aggregation tests to validate the new behavior.

#### Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes:

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

## v1.0.26 - 2026-05-06

### RU

#### Что изменилось

- Технический релиз: обновлены версия и релизные метаданные для публикации нового дистрибутива.
- Функциональные изменения приложения отсутствуют по сравнению с `v1.0.25`.

#### Установка

1. Переместите `OWAWidget.app` в `/Applications`.
2. Снимите quarantine-атрибуты:

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

### EN

#### What's Changed

- Technical release: version and release metadata were updated to publish a new distribution package.
- No functional app changes are included compared to `v1.0.25`.

#### Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes:

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

## v1.0.25 - 2026-05-06

### RU

#### Что изменилось

- Добавлен индикатор доступной новой версии в popover с проверкой релизов GitHub каждые 6 часов.
- В плашке обновления доступны действия «Открыть релиз» и «Пропустить эту версию».
- В Preferences добавлен раздел обновлений: автопроверка и ручная кнопка «Проверить сейчас».

#### Установка

1. Переместите `OWAWidget.app` в `/Applications`.
2. Снимите quarantine-атрибуты:

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

### EN

#### What's Changed

- Added a new-version indicator in the popover with GitHub release checks every 6 hours.
- Added “View release” and “Skip this version” actions in the update banner.
- Added an Updates section in Preferences with automatic checks and a manual “Check now” action.

#### Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes:

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

## v1.0.24 - 2026-05-06

### RU

#### Что изменилось

- Добавлен пассивный индикатор обновлений: приложение проверяет GitHub Releases раз в 6 часов и показывает плашку о доступной новой версии в popover.
- В плашке доступны действия: открыть страницу релиза и пропустить конкретную версию до выхода следующей.
- В Preferences добавлен раздел обновлений: переключатель автопроверки и кнопка «Проверить сейчас».
- Добавлены локализации RU/EN для нового UI обновлений и тесты сравнения версий для проверки логики определения «новее/старее».

#### Установка

1. Переместите `OWAWidget.app` в `/Applications`.
2. Снимите quarantine-атрибуты:

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

### EN

#### What's Changed

- Added a passive update indicator: the app checks GitHub Releases every 6 hours and shows a banner in the popover when a newer version is available.
- The banner now supports opening the release page and skipping a specific version until a newer one is published.
- Added an Updates section in Preferences with an automatic-check toggle and a “Check now” action.
- Added RU/EN localization strings for the new update UI and version-comparison tests to validate newer/older detection logic.

#### Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes:

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

## v1.0.23 - 2026-05-06

### RU

#### Что изменилось

- Добавлен двуязычный формат release notes с обязательными секциями `RU` и `EN` для каждой версии.
- Обновлены правила релизного процесса: структура заметок и install-инструкция теперь обязательны на двух языках.
- Добавлена автоматическая валидация `RELEASE_NOTES.md` перед упаковкой релиза, чтобы отлавливать ошибки формата до публикации.

#### Установка

1. Переместите `OWAWidget.app` в `/Applications`.
2. Снимите quarantine-атрибуты:

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

### EN

#### What's Changed

- Added a bilingual release notes format with mandatory `RU` and `EN` sections for each version.
- Updated release workflow rules to require note structure and installation instructions in both languages.
- Added automatic `RELEASE_NOTES.md` validation before packaging so formatting issues are caught before publishing.

#### Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes:

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```
