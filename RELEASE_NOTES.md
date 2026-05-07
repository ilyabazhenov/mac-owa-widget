## v1.0.31 - 2026-05-07

### RU

#### Что изменилось

- Улучшен countdown в menubar: минуты до ближайшей встречи теперь округляются вверх (например, `1:01` → `2m`) и корректно обрабатываются граничные значения.
- Добавлены unit-тесты на форматирование countdown для защиты от регрессий.

#### Установка

1. Переместите `OWAWidget.app` в `/Applications`.
2. Снимите quarantine-атрибуты (нужно только при первой установке):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. Все последующие обновления устанавливаются автоматически через кнопку «Установить» внутри приложения.

### EN

#### What's Changed

- Improved the menu bar countdown: minutes until the next meeting now round up (e.g. `1:01` → `2m`) and edge cases are handled correctly.
- Added unit tests for countdown formatting to prevent regressions.

#### Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes (required only for the first install):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. All subsequent updates are installed automatically via the in-app **Install** button.

## v1.0.30 - 2026-05-07

### RU

#### Что изменилось

- Обновлена документация проекта: добавлен `DEVELOPMENT.md` с рабочими процессами разработки и поддержкой агентов.
- Улучшен `README.md`: актуализировано описание приложения и добавлены новые визуальные материалы для GitHub-страницы проекта.
- Добавлены графические ассеты для репозитория (`readme-hero` и social preview), чтобы упростить онбординг и навигацию по проекту.

#### Установка

1. Переместите `OWAWidget.app` в `/Applications`.
2. Снимите quarantine-атрибуты (нужно только при первой установке):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. Все последующие обновления устанавливаются автоматически через кнопку «Установить» внутри приложения.

### EN

#### What's Changed

- Updated project docs: added `DEVELOPMENT.md` with day-to-day development workflows and agent guidance.
- Improved `README.md` with refreshed app description and new visual assets for the GitHub project page.
- Added repository image assets (`readme-hero` and social preview) to make onboarding and project navigation clearer.

#### Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes (required only for the first install):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. All subsequent updates are installed automatically via the in-app **Install** button.

## v1.0.29 - 2026-05-06

### RU

#### Что изменилось

- Исправлен релизный сценарий Sparkle: appcast теперь генерируется официальным `generate_appcast`, что устраняет ошибки чтения обновления в клиенте.
- Подготовлен корректный повторный релиз после `v1.0.28`, чтобы у обновления был новый build number и оно гарантированно определялось из `v1.0.27`.
- Актуализированы агентские и пользовательские инструкции по установке/обновлению под новый auto-update flow.

#### Установка

1. Переместите `OWAWidget.app` в `/Applications`.
2. Снимите quarantine-атрибуты (нужно только при первой установке):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. Все последующие обновления устанавливаются автоматически через кнопку «Установить» внутри приложения.

### EN

#### What's Changed

- Fixed Sparkle release packaging: appcast is now generated via the official `generate_appcast` tool, which resolves update metadata parsing failures in clients.
- Prepared a correct follow-up release after `v1.0.28` so the update has a new build number and is reliably detected from `v1.0.27`.
- Updated agent/user installation and update instructions for the new auto-update flow.

#### Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes (required only for the first install):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. All subsequent updates are installed automatically via the in-app **Install** button.

## v1.0.28 - 2026-05-06

### RU

#### Что изменилось

- Добавлен in-app автоапдейтер на базе Sparkle 2 с подписью релизных артефактов EdDSA.
- Обновлен релизный пайплайн: теперь `make release-package` формирует подписанный `OWAWidget-v<version>-macos.zip` и `appcast.xml` для автообновлений.
- Обновлены интерфейс и локализация раздела обновлений: кнопка «Установить» запускает установку новой версии в один клик.

#### Установка

1. Переместите `OWAWidget.app` в `/Applications`.
2. Снимите quarantine-атрибуты (нужно только при первой установке):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. Все последующие обновления устанавливаются автоматически через кнопку «Установить» внутри приложения.

### EN

#### What's Changed

- Added Sparkle 2 based in-app auto-updater with EdDSA-signed release artifacts.
- Updated the release pipeline: `make release-package` now produces a signed `OWAWidget-v<version>-macos.zip` and `appcast.xml` for automatic updates.
- Updated update UI and localization: the new **Install** action applies the latest version in one click.

#### Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes (required only for the first install):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. All subsequent updates are installed automatically via the in-app **Install** button.

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
