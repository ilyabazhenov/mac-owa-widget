## v1.0.45 - 2026-06-30

### RU

#### Что изменилось

- Настройки: добавлен выбор часового пояса отображения календаря. Можно оставить «Системный» (как в macOS) либо выбрать пояс из списка РФ (UTC+2…+12). По умолчанию — Москва, поведение текущих пользователей не меняется. Смена пояса применяется без перезапуска.
- Синхронизация: больше нет ложного «Неверный пароль», когда сервер OWA недоступен (например, выключен VPN). Теперь приложение отличает настоящую страницу входа OWA от ответов 404/5xx и показывает понятное сообщение «Не удалось подключиться к серверу».
- Синхронизация: авто-восстановление после ошибки аутентификации. Блокировка ставится не с первой ошибки, а после двух подряд (переживает кратковременные сбои сессии), снимается авто-пробой раз в 30 минут, а в футере появилась кнопка «Повторить» — можно разблокировать вручную без повторного ввода пароля.
- Меню-бар: при проблемах (ошибка входа, сертификат, сбой синхронизации) иконка показывает значок-предупреждение, а во всплывающей подсказке — текст ошибки.

#### Установка

1. Переместите `OWAWidget.app` в `/Applications`.
2. Снимите quarantine-атрибуты (нужно только при первой установке):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. Все последующие обновления устанавливаются автоматически через кнопку «Установить» внутри приложения.

### EN

#### What's Changed

- Settings: added a calendar display time zone picker. Keep “System” (follows macOS) or choose a zone from the Russia list (UTC+2…+12). Default is Moscow, so current behavior is unchanged. Changing the zone applies without a restart.
- Sync: no more false “Invalid password” when the OWA server is unreachable (e.g. VPN is off). The app now distinguishes a real OWA logon page from 404/5xx responses and shows a clear “Could not connect to the server” message.
- Sync: auto-recovery after an authentication error. The block is no longer triggered by a single failure but after two in a row (survives transient session blips), clears itself via an auto-probe every 30 minutes, and a “Retry” button in the footer lets you unblock manually without re-entering the password.
- Menu bar: on problems (auth error, certificate, sync failure) the icon shows a warning badge and the tooltip shows the error text.

#### Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes (only needed on the first install):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. All subsequent updates install automatically via the “Install” button inside the app.

## v1.0.44 - 2026-06-16

### RU

#### Что изменилось

- Создание встреч: выбор длительности — пресеты 30 мин / 1 ч / 1.5 ч / 2 ч. Поиск свободных слотов и грид занятости теперь учитывают выбранную длительность: клик по ячейке выделяет окно нужной длины в пределах непрерывного свободного промежутка (не захватывая занятые соседние ячейки и не вылезая за конец дня); слишком короткие свободные «дырки» приглушаются; после смены длительности показывается предупреждение, если выбранный слот стал занят.
- Создание встреч: исправлена подсветка выбранного предложенного слота — радио-кнопка в списках «Лучшие варианты» и доступных слотов теперь корректно отмечает выбор.
- Настройки: окно настроек отображается в Доке, пока открыто (иконка остаётся, если параллельно открыто окно создания встречи).
- Настройки: окно редактирования аккаунта больше не открывается повторно пустым после закрытия; после системного запроса доступа к Keychain окно настроек возвращается на передний план.

#### Установка

1. Переместите `OWAWidget.app` в `/Applications`.
2. Снимите quarantine-атрибуты (нужно только при первой установке):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. Все последующие обновления устанавливаются автоматически через кнопку «Установить» внутри приложения.

### EN

#### What's Changed

- Create meeting: meeting duration picker — presets 30 min / 1 h / 1.5 h / 2 h. Free-slot search and the availability grid now honor the selected duration: clicking a cell selects a window of the chosen length within a continuous free gap (without grabbing busy neighbors or spilling past the end of day); free gaps too short to fit are dimmed; a warning appears if the selected slot becomes busy after changing the duration.
- Create meeting: fixed highlighting of the selected suggested slot — the radio button in the “Best options” and available-slots lists now marks the selection correctly.
- Settings: the settings window now appears in the Dock while open (the icon stays if the create-meeting window is also open).
- Settings: the account edit sheet no longer reopens empty after closing; the settings window returns to the foreground after the system Keychain access prompt.

#### Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes (required only for the first install):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. All subsequent updates are installed automatically via the in-app **Install** button.

## v1.0.43 - 2026-06-16

### RU

#### Что изменилось

- Popover: настраиваемый размер окна — три пресета (компактный/средний/большой). Быстрое переключение из футера (применяется сразу) и из настроек (по кнопке «Сохранить»). Выбор запоминается между запусками.
- Окно деталей встречи: список участников.
- Автообновление: окна Sparkle теперь поднимаются на передний план.

#### Установка

1. Переместите `OWAWidget.app` в `/Applications`.
2. Снимите quarantine-атрибуты (нужно только при первой установке):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. Все последующие обновления устанавливаются автоматически через кнопку «Установить» внутри приложения.

### EN

#### What's Changed

- Popover: adjustable window size — three presets (compact/medium/large). Switch quickly from the footer (applied immediately) or from Settings (on Save). The choice persists across launches.
- Meeting detail window: attendee list.
- Auto-update: Sparkle windows are now brought to the foreground.

#### Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes (required only for the first install):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. All subsequent updates are installed automatically via the in-app **Install** button.

## v1.0.42 - 2026-06-05

### RU

#### Что изменилось

- Popover: поиск встреч по названию, организатору, участникам, локации и описанию среди уже загруженных событий (окно синхронизации −7…+30 дней); результаты сгруппированы по дням, компактная кнопка подключения.
- Безопасность: строгая проверка TLS-сертификатов с per-host pinning; недоверенный сертификат — явный промпт «доверять серверу» вместо молчаливого сбоя; только HTTPS; миграция legacy `http://` аккаунтов на `https://`; защита join-ссылок от небезопасных схем; усиленное хранение паролей в Keychain.
- Настройки: удаление аккаунта через кнопку корзины и контекстное меню с подтверждением.
- Создание встреч: исправлено зависание в плейсхолдере «Подбираем свободные слоты…» при открытии окна без участников.
- OWA/EWS: автоматический повтор запроса при обрыве устаревшего HTTP keep-alive при создании встречи и RSVP (Accept/Decline/Tentative).
- Статус синхронизации: относительные подписи («только что», «N минут назад», «N часов назад»).

#### Установка

1. Переместите `OWAWidget.app` в `/Applications`.
2. Снимите quarantine-атрибуты (нужно только при первой установке):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. Все последующие обновления устанавливаются автоматически через кнопку «Установить» внутри приложения.

### EN

#### What's Changed

- Popover: search meetings by title, organizer, attendees, location, and description among already loaded events (sync window −7…+30 days); results grouped by day with a compact join button.
- Security: strict TLS certificate validation with per-host pinning; untrusted certificates show an explicit “trust this server” prompt instead of failing silently; HTTPS only; legacy `http://` accounts migrated to `https://`; join URLs blocked from unsafe schemes; hardened Keychain credential storage.
- Settings: delete accounts via trash button and context menu with confirmation.
- Create meeting: fixed hanging on the “Finding free slots…” placeholder when opening the window without attendees.
- OWA/EWS: automatic retry when a stale HTTP keep-alive drops the connection during meeting creation and RSVP (Accept/Decline/Tentative).
- Sync status: relative time labels (just now, N minutes ago, N hours ago).

#### Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes (required only for the first install):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. All subsequent updates are installed automatically via the in-app **Install** button.

## v1.0.41 - 2026-06-01

### RU

#### Что изменилось

- Popover: события на весь день вынесены в закреплённую шапку над таймлайном — они больше не занимают колонки пересечений и не вытесняют короткие встречи; при четырёх и более all-day доступен горизонтальный скролл.
- Глобальный хоткей **Ctrl+Option+J** для подключения к текущей или начинающейся в ближайшие 2 минуты встрече из любого приложения; при нескольких подходящих встречах показывается компактный выбор; переключатель в настройках.
- Релизная сборка — universal binary (**Apple Silicon и Intel**); локальная dev-сборка по-прежнему нативная для скорости.

#### Установка

1. Переместите `OWAWidget.app` в `/Applications`.
2. Снимите quarantine-атрибуты (нужно только при первой установке):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. Все последующие обновления устанавливаются автоматически через кнопку «Установить» внутри приложения.

### EN

#### What's Changed

- Popover: all-day events moved to a sticky header above the timeline — they no longer participate in overlap columns or crowd out short meetings; horizontal scroll when there are four or more all-day events.
- Global hotkey **Ctrl+Option+J** to join the current meeting or one starting within the next 2 minutes from any app; compact picker when multiple meetings qualify; toggle in Settings.
- Release builds ship as a universal binary (**Apple Silicon and Intel**); local dev builds remain native for speed.

#### Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes (required only for the first install):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. All subsequent updates are installed automatically via the in-app **Install** button.

## v1.0.40 - 2026-05-25

### RU

#### Что изменилось

- Исправлена позиция баннера-напоминания на мультимониторных конфигурациях: уведомление теперь корректно появляется на экране, ближайшем к курсору, даже если мониторы разного разрешения или высоты.
- Fallback-логика «ближайшего экрана» для случаев, когда курсор оказывается на стыке мониторов или ровно на границе frame.
- Исправлена анимация появления панели: fade-in вместо slide-in при первом показе, чтобы macOS не перетаскивал окно на соседний монитор.
- Тесты: покрытие `nearestScreenIndex`, `distanceSquared` и edge-кейсов мультимониторных конфигураций.

#### Установка

1. Переместите `OWAWidget.app` в `/Applications`.
2. Снимите quarantine-атрибуты (нужно только при первой установке):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. Все последующие обновления устанавливаются автоматически через кнопку «Установить» внутри приложения.

### EN

#### What's Changed

- Fixed notification banner positioning on multi-monitor setups: the banner now correctly appears on the screen nearest to the cursor, even when monitors have different resolutions or heights.
- Added nearest-screen fallback for cases when the cursor lands in the gap between monitors or exactly on a frame boundary.
- Fixed panel animation: fade-in instead of slide-in on first appearance to prevent macOS from moving the panel to a wrong monitor.
- Tests: coverage for `nearestScreenIndex`, `distanceSquared`, and multi-monitor edge cases.

#### Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes (required only for the first install):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. All subsequent updates are installed automatically via the in-app **Install** button.

## v1.0.39 - 2026-05-22

### RU

#### Что изменилось

- Popover: навигация по дням расширена до 30 дней вперёд — доступны все дни, которые уже синхронизированы (-7…+30), а не только ближайшая неделя.
- Создание встреч: можно забронировать своё время без участников (self-only); грид занятости и кликабельные слоты работают только по вашему календарю.
- Создание встреч: исправлен тултип с устаревшей занятостью необязательных участников при переключении недели; hover показывает все перекрывающиеся события в ячейке.
- Тесты: регрессии для self-only грида, навигации по неделям и SOAP CreateItem (SendToNone, без пустого RequiredAttendees).

#### Установка

1. Переместите `OWAWidget.app` в `/Applications`.
2. Снимите quarantine-атрибуты (нужно только при первой установке):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. Все последующие обновления устанавливаются автоматически через кнопку «Установить» внутри приложения.

### EN

#### What's Changed

- Popover: day navigation extended to 30 days ahead — all days already synced (-7…+30) are browsable, not just the nearest week.
- Create meeting: book your own time without attendees (self-only); availability grid and clickable slots use only your calendar.
- Create meeting: fixed tooltip showing stale optional-attendee busy state after week navigation; hover lists all overlapping events in a cell.
- Tests: regressions for self-only grid, week navigation, and SOAP CreateItem (SendToNone, omit empty RequiredAttendees).

#### Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes (required only for the first install):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. All subsequent updates are installed automatically via the in-app **Install** button.

## v1.0.38 - 2026-05-22

### RU

#### Что изменилось

- Исправлен краш при открытии настроек на macOS Sequoia: поднятие окон при Cmd+Tab ограничено только окном создания встречи; UI переназначения горячих клавиш в настройках временно отключён (шорткат Ctrl+Opt+N по-прежнему работает).
- Создание встреч: в тултипе ячейки сетки показывается занятость опциональных участников отдельной секцией; исправлено позиционирование выпадающего списка участников.
- Диагностика: always-on лог жизненного цикла в Application Support, пункт «Скопировать диагностику» в контекстном меню иконки; инструкции в README и INSTALL.
- Тесты: покрытие `shouldRaiseWindow` и инвариантов optional-статусов в cell matrix.

#### Установка

1. Переместите `OWAWidget.app` в `/Applications`.
2. Снимите quarantine-атрибуты (нужно только при первой установке):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. Все последующие обновления устанавливаются автоматически через кнопку «Установить» внутри приложения.

### EN

#### What's Changed

- Fixed Settings crash on macOS Sequoia: window raise on Cmd+Tab is scoped to the create-meeting window only; keyboard shortcut rebinding UI in Settings is temporarily disabled (default Ctrl+Opt+N still works).
- Create meeting: cell tooltip shows optional attendee busy status in a separate section; attendee dropdown positioning and hit-testing fixed.
- Diagnostics: always-on lifecycle log in Application Support, **Copy diagnostics** in the menu bar icon context menu; docs in README and INSTALL.
- Tests: coverage for `shouldRaiseWindow` and optional-status invariants in the cell matrix.

#### Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes (required only for the first install):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. All subsequent updates are installed automatically via the in-app **Install** button.

## v1.0.37 - 2026-05-21

### RU

#### Что изменилось

- Создание встреч: новое окно с поиском участников (FindPeople), сеткой занятости, подсказками свободных слотов и созданием через OWA/EWS.
- Форма встречи: обязательные и необязательные участники, поле «Расположение» с историей, выбор даты/времени, изменяемый размер окна, overlay после успешного создания.
- Сетка занятости: цветовая легенда, объединение многочасовых свободных слотов, занятость организатора, навигация по неделям.
- Popover: просмотр календаря до 7 дней назад.
- Настройки: выбор темы приложения (светлая/тёмная/системная), позиция баннера уведомлений на экране.
- OWA: защита от рекурсии при 401, обработка блокировки AD, фильтрация прошедших слотов; RSVP и синхронизация стабильнее при смене пароля.
- Исправления UI: смещение выбора слота на +30 мин, таймзона overlay, наезд легенды на грид, поднятие окон на передний план при Cmd+Tab.
- DEBUG-логи перенесены из `/tmp` в Application Support.

#### Установка

1. Переместите `OWAWidget.app` в `/Applications`.
2. Снимите quarantine-атрибуты (нужно только при первой установке):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. Все последующие обновления устанавливаются автоматически через кнопку «Установить» внутри приложения.

### EN

#### What's Changed

- Create meeting: new window with attendee search (FindPeople), availability grid, free-slot suggestions, and meeting creation via OWA/EWS.
- Meeting form: required/optional attendees, location field with history, date/time pickers, resizable window, success overlay with countdown.
- Availability grid: color legend, merged multi-hour free slots, organizer busy state, week navigation.
- Popover: browse calendar up to 7 days in the past.
- Settings: app theme (light/dark/system), on-screen notification banner position.
- OWA: 401 recursion guard, AD lockout handling, past-slot filtering; more stable sync and notifications after password changes.
- UI fixes: +30 min slot selection offset, timezone overlay, legend/grid overlap, bring windows to front on Cmd+Tab activation.
- DEBUG logs moved from `/tmp` to Application Support.

#### Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes (required only for the first install):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. All subsequent updates are installed automatically via the in-app **Install** button.

## v1.0.36 - 2026-05-13

### RU

#### Что изменилось

- Меню-бар: режимы отображения и форматирование статуса/обратного отсчёта до ближайшей встречи (настраивается в настройках).
- OWA: ответы на приглашения (RSVP) и отображение вашего ответа в карточке и деталях встречи.
- Напоминания: исправлено появление дублирующих панелей; RSVP выполняется через EWS SOAP для большей совместимости с Exchange.
- Таймлайн: опция приглушения прошедших встреч и правки вёрстки карточек.

#### Установка

1. Переместите `OWAWidget.app` в `/Applications`.
2. Снимите quarantine-атрибуты (нужно только при первой установке):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. Все последующие обновления устанавливаются автоматически через кнопку «Установить» внутри приложения.

### EN

#### What's Changed

- Menu bar: display modes and status/countdown formatting for the next meeting (configurable in Settings).
- OWA: meeting RSVP and showing your response in the row and meeting details.
- Reminders: fixed duplicate reminder panels; RSVP uses EWS SOAP for better Exchange compatibility.
- Timeline: optional dimming of past meetings and layout fixes for meeting cards.

#### Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes (required only for the first install):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. All subsequent updates are installed automatically via the in-app **Install** button.

## v1.0.35 - 2026-05-07

### RU

#### Что изменилось

- Повторно выпущен релиз с новым build-number для Sparkle, чтобы обновление корректно предлагалось пользователям на `v1.0.33`.
- Сохранено поведение `v1.0.34`: при скрытии/закрытии popover открытые детали встречи сбрасываются и не восстанавливаются при следующем открытии.

#### Установка

1. Переместите `OWAWidget.app` в `/Applications`.
2. Снимите quarantine-атрибуты (нужно только при первой установке):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. Все последующие обновления устанавливаются автоматически через кнопку «Установить» внутри приложения.

### EN

#### What's Changed

- Re-released with a new Sparkle build number so the update is correctly offered to users on `v1.0.33`.
- Keeps the `v1.0.34` behavior: opened meeting details are reset when the popover/app is hidden or closed and do not reopen automatically.

#### Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes (required only for the first install):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. All subsequent updates are installed automatically via the in-app **Install** button.

## v1.0.34 - 2026-05-07

### RU

#### Что изменилось

- Исправлено поведение popover: при скрытии/закрытии приложения теперь сбрасывается открытая панель деталей встречи и при следующем открытии она не восстанавливается.
- Добавлены регрессионные тесты для логики сброса деталей встречи при скрытии popover.

#### Установка

1. Переместите `OWAWidget.app` в `/Applications`.
2. Снимите quarantine-атрибуты (нужно только при первой установке):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. Все последующие обновления устанавливаются автоматически через кнопку «Установить» внутри приложения.

### EN

#### What's Changed

- Fixed popover behavior: when the app/popover is hidden or closed, the opened meeting details panel is now reset and does not reappear on the next open.
- Added regression tests for the meeting-detail reset behavior on popover hide.

#### Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes (required only for the first install):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. All subsequent updates are installed automatically via the in-app **Install** button.

## v1.0.33 - 2026-05-07

### RU

#### Что изменилось

- Технический релиз для публикации новой подписанной сборки и обновления канала Sparkle.
- Функциональные изменения приложения отсутствуют по сравнению с `v1.0.32`.

#### Установка

1. Переместите `OWAWidget.app` в `/Applications`.
2. Снимите quarantine-атрибуты (нужно только при первой установке):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. Все последующие обновления устанавливаются автоматически через кнопку «Установить» внутри приложения.

### EN

#### What's Changed

- Technical release to publish a new signed build and refresh the Sparkle update channel metadata.
- No functional app changes are included compared to `v1.0.32`.

#### Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes (required only for the first install):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. All subsequent updates are installed automatically via the in-app **Install** button.

## v1.0.32 - 2026-05-07

### RU

#### Что изменилось

- Стабилизирована логика напоминаний: улучшены пересчет и пересоздание локальных уведомлений при изменениях встреч и повторных синках.
- Улучшена локализация напоминаний и связанных системных сообщений, чтобы текст уведомлений корректнее соответствовал выбранному языку.
- Обновлены тесты офлайн-синхронизации календаря для защиты сценариев с задержкой сети и перестроением расписания напоминаний.

#### Установка

1. Переместите `OWAWidget.app` в `/Applications`.
2. Снимите quarantine-атрибуты (нужно только при первой установке):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. Все последующие обновления устанавливаются автоматически через кнопку «Установить» внутри приложения.

### EN

#### What's Changed

- Stabilized reminder logic by improving local notification recalculation and rescheduling after meeting changes and follow-up syncs.
- Improved reminder localization and related system-facing messages so notification text better matches the selected app language.
- Updated offline calendar sync tests to protect delayed-network and reminder-rescheduling scenarios from regressions.

#### Installation

1. Move `OWAWidget.app` to `/Applications`.
2. Remove quarantine attributes (required only for the first install):

```bash
xattr -dr com.apple.quarantine /Applications/OWAWidget.app
```

3. All subsequent updates are installed automatically via the in-app **Install** button.

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
