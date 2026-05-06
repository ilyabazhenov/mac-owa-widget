## v1.0.16 - 2026-05-06

### RU

#### Что изменилось

- Добавлено более явное быстрое действие возврата к Today в заголовке навигации по дням.
- Обновлен UX навигации по датам: `Today` теперь воспринимается как отдельное действие, а не часть текстовой метки даты.
- Добавлены регрессионные тесты для граничных условий навигации по дням и правил видимости действия `Today`.

#### Установка

1. Переместите `OWAWidget.app` в `/Applications`.
2. Снимите quarantine-атрибуты:

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

### EN

#### What's Changed

- Added a clearer quick return action to Today in the day navigation header.
- Updated the date navigation UX so `Today` is recognized as an action, not part of the date label.
- Added regression tests for day navigation bounds and visibility rules of the `Today` action.

#### Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes:

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```
