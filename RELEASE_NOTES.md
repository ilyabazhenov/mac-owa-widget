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
