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
- `OWAWidget/Providers/CalendarProviderFactory.swift` - единственное место, где аккаунт превращается в провайдер. Два места конструирования расходились бы: проверка соединения собирала бы провайдер иначе, чем цикл синхронизации.
- `OWAWidget/Providers/EAS/` - провайдер Exchange ActiveSync: тот же ящик, что у OWA, но через единственный опубликованный наружу путь `/Microsoft-Server-ActiveSync`, поэтому работает без VPN. Протокол, инварианты и ограничения расписаны в `docs/eas-provider.md` - **читай этот документ перед правками в этой папке**: там объяснено, почему сессия живёт в реестре, почему `SyncKey` и элементы пишутся атомарно и почему первый `401` латчит клиента намертво.
- `OWAWidget/Providers/GoogleCalendar/` - заглушка будущего Google Calendar провайдера через прямой API (OAuth). Не используется: календари Google приезжают через EventKit.
- `OWAWidget/Providers/EventKit/` - чтение календарей, которые macOS уже синхронизирует (Google, iCloud, локальные). Провайдер read-only: мутирующие методы `CalendarProvider` остаются `notSupported`.

> **Доступ к календарям требует entitlement.** `scripts/sign_app.sh` подписывает с `--options runtime`, а hardened runtime закрывает TCC-ресурсы без явного разрешения - даже вне песочницы. Без `com.apple.security.personal-information.calendars` в файле entitlements (их два, ключ нужен в обоих - см. раздел «Xcode») вызов `requestFullAccessToEvents` возвращает `false` за миллисекунды, статус остаётся `notDetermined`, и системный диалог не показывается вообще. Отладка такого молчания легко уходит в ложные версии - проверено на зонде 2026-08-22. `Info.plist` при этом обязан содержать обе строки: `NSCalendarsUsageDescription` (macOS 13) и `NSCalendarsFullAccessUsageDescription` (macOS 14+); отсутствие строки - это крэш в момент запроса, а не отказ.
>
> **Выданный доступ не переживает смену ad-hoc подписи.** TCC привязывает разрешение к designated requirement бандла. У ad-hoc подписи это `cdhash`, поэтому на локальных сборках статус возвращается в `notDetermined`, а синхронизация EventKit падает с "Calendar access has not been granted yet". Сбрасывает разрешение любое изменение подписанного содержимого - не только новый код: `make bundle` берёт `CFBundleVersion` из `git rev-list --count HEAD`, так что достаточно одного коммита, чтобы `Info.plist` изменился и подпись стала другой. Повторный `make run` без единого изменения, наоборот, доступ сохраняет: подпись ad-hoc детерминирована. Это не баг в коде - не ищи его там. Релизы подписаны Developer ID: requirement у них - bundle id и Team ID, и доступ к Календарю, как и «Разрешать всегда» в связке ключей, переживает обновление через Sparkle (проверено на зонде 2026-10-05). Один раз он слетит у пользователей только при переходе с последнего ad-hoc релиза (v1.0.53) на первый подписанный. Приложение справляется само: `EventKitCalendarProvider.fetchEvents` вызывает `ensureReadAccess()`, и при статусе `notDetermined` система показывает диалог на первом же синке после обновления. Достаточно подтвердить его. Запрос не срабатывает у того, кто уже отказал: отказ - это тоже решение, и переспрашивать каждый синк значило бы донимать.

> **Тесты не должны трогать реальный EventKit.** Причина та же, что у Keychain: `swift test` - обязательный гейт `make release-package`, а диалог доступа к календарям повесит упаковку. Всё, что пересекает границу `EventKitStoring`, - это `Sendable`-снимки (`EventKitSnapshots.swift`), а `EKEventStore` не покидает `SystemEventKitStore`. Инжектируй фейковый стор через `CalendarService(eventKitStore:)` или `EventKitCalendarProvider(account:store:)`.
- `OWAWidget/Services/MeetingURLDetector.swift` - поиск ссылок на Teams, Zoom, Webex, Google Meet и другие платформы.
- `OWAWidget/Services/NotificationService.swift` - локальные уведомления о встречах.
- `OWAWidget/Services/MeetingInvitations.swift` - приглашения, переносы и отмены: `MeetingInvitationPolicy` сравнивает календарь с прошлым синком, `MeetingInvitationTracker` хранит состояние сравнения через `SecureStore`. Отслеживаются только встречи Exchange чужой организации (есть `changeKey`): read-only календари EventKit отдают «нет ответа» на каждую запись. Первый синк аккаунта (и первый после включения функции) запоминается молча, иначе весь календарь выглядел бы новым. Окно синка скользящее (+30 дней от «сейчас»), и каждый день в него въезжает очередной повтор каждой серии со своим новым ItemId: встреча, начинающаяся позже границы прошлого синка этого аккаунта (`windowEndByAccount`), новой не считается. Граница хранится по аккаунтам, чтобы синк без Exchange не сдвигал границу Exchange.
- `OWAWidget/Services/MeetingInvitationAlertController.swift` - панель приглашений. Та же схема «одна панель, мёрдж на месте», что у `CustomMeetingReminderController`, но **без автозакрытия**: панель висит, пока пользователь не ответит, не скроет строки или не закроет её. Вся функция (панель, счётчик ✉︎N в тексте метки строки меню, раздел «Новые приглашения» в поповере) за одной настройкой `invitationAlertsEnabled`, по умолчанию выключена. Счётчик считает только приглашения, о которых сообщила панель (`unhandledEventIDs`), а не все встречи без ответа: у многих десятки неотвеченных повторяющихся и FW-встреч, и такой бейдж был бы вечным шумом. Раздел «Новые приглашения» в поповере отключается отдельно (`invitationPopoverSectionEnabled`, по умолчанию выключен), и вместе с ним гаснет счётчик ✉︎N: без раздела счётчик, оставшийся после закрытия панели, нечем было бы сбросить. Сам счётчик дополнительно отключается своей настройкой (`invitationMenuBarBadgeEnabled`, по умолчанию включён, действует только при включённом разделе). Панель ни от одной из них не зависит. Отмена показывается только для встреч, которые пользователь принял или отметил «под вопросом» (`wasCommitted` в отпечатке прошлого синка): отмена неотвеченного приглашения - шум. Счётчик - часть текста метки, а не отдельный `Image`: метка `MenuBarExtra` рисует только одну картинку и один текст, остальное молча отбрасывается.
- `OWAWidget/Services/KeychainService.swift` - хранение паролей в Keychain.
- `OWAWidget/Services/SecureStore.swift` - шифрование всех данных на диске (AES-GCM, мастер-ключ в Keychain). Всё, что пишется в `~/Library/Application Support/OWAWidget/<bundle-id>/store/`, проходит через него. Новые хранилища добавляй сюда, а не в `UserDefaults`: там место только для настроек интерфейса.
- `OWAWidget/Services/SecureCodableStore.swift` - `Codable`-обёртка над `SecureStore` с одноразовой миграцией из открытого `UserDefaults`-ключа. Порядок миграции обязателен: записали -> перечитали и сверили -> удалили legacy.
- `OWAWidget/Services/SecureStoreMigrator.swift` - принудительный прогон миграций на старте для хранилищ, которые иначе мигрировали бы лениво.

> **Тесты не должны трогать реальный Keychain.** `swift test` - обязательный гейт `make release-package`, а диалог авторизации связки повесит упаковку. Инжектируй `SecureStore(directory:keyProvider:)` с `InMemorySecureStoreKeyProvider`; `SecureStore.shared` под XCTest сам уходит во временный каталог, но это страховка, а не замена инжекции.
- `OWAWidget/Services/LaunchAtLoginService.swift` - автозапуск при входе (`SMAppService.mainApp`).
- `OWAWidget/Services/UpdateCheckService.swift` - обертка над Sparkle (`SPUStandardUpdaterController`) для авто-обновлений по EdDSA-подписанному appcast.xml.
- `OWAWidget/Views/` - SwiftUI интерфейс меню и настроек.
- `OWAWidget/Views/MeetingListView.swift` - таймлайн-список встреч в popover (тайм-сетка + overlay карточек).
- `OWAWidget/Views/TimelineMeetingLayout.swift` - алгоритмы раскладки пересекающихся встреч (slotting, clusters, lanes, frame math).
- `OWAWidget/Views/TimelineMeetingBlockView.swift` - визуальная карточка встречи в таймлайне, включая compact-режим.
- `OWAWidget/Views/CreateMeeting/` - окно создания встречи: поиск участников через FindPeople, занятость через GetUserAvailabilityInternal, создание через CreateCalendarEvent (OWA JSON API). Ключевые файлы: `CreateMeetingView.swift`, `CreateMeetingViewModel.swift`, `AttendeeSearchField.swift`, `SlotSuggestionsView.swift`.
- `OWAWidget/Services/MeetingFreeSlotCalculator.swift` - алгоритм поиска свободных 30-мин слотов по MergedFreeBusy строке OWA.
- `OWAWidget/Views/Colleagues/` - раздел «Коллеги» в поповере: кто из закреплённых коллег свободен прямо сейчас и переход в личную комнату по ссылке.
- `OWAWidget/Services/ColleaguePresenceService.swift` - занятость коллег. Один запрос `GetUserAvailability` на весь список (адреса уходят массивом), окно - неделя от полуночи. Между обновлениями запросов нет: сетка уже скачана, поэтому текущий статус считается локально из часов и продолжает меняться офлайн. Кэш управляется настройкой, по умолчанию 5 минут.

> **Строки занятости сопоставляются с адресами по ответу каждого ящика** (`OWAAvailabilityResponseParser`): Exchange отвечает на каждый ящик отдельным элементом в порядке запроса, и ящик без данных (вне организации, нет доступа) приходит без `MergedFreeBusy`. Раньше все строки собирались подряд и сопоставлялись `zip`'ом, и пропуск одного ящика сдвигал всех следующих на чужие календари. Ящик без строки теперь просто отсутствует в ответе; если форму ответа распознать не удалось и строк меньше, чем адресов, не возвращается ничего - лучше «нет данных», чем уверенный чужой статус. `ColleaguePresenceService` по-прежнему считает короткий ответ неудачным обновлением.
- `OWAWidget/Services/ColleagueStatusCalculator.swift` - чистый расчёт статуса из строки занятости: текущая ячейка и конец серии. Код `4` - это «нет данных», а не «свободен». Агрегатор ячейки в форме создания встречи (`SlotAvailabilityState.aggregate`) тоже держит его отдельно (`.noData`), но считает другое - худший статус среди участников, поэтому объединять их нельзя. Порядок там задан явно: вне офиса > занят > под вопросом > нет данных > свободен. Сравнивать символы через `max()` нельзя: `4` больше `3`, и одна ячейка без данных прятала чужую занятость под «свободно».
- `OWAWidget/Services/ColleagueStatusFormatter.swift` - текст статуса. Ярлыки без рода («Свободен», «Занят», «Нет на месте»): адресная книга пола не отдаёт, а согласование с именем было бы угадыванием.
- `OWAWidget/Services/WatchedColleaguesStore.swift` - список коллег и ссылки на их комнаты, через `SecureStore` (имена, адреса и должности из адресной книги).
- `OWAWidget/Services/AppearanceService.swift` - тема приложения (light/dark/system).
- `OWAWidget/Services/RecentAttendeesStore.swift` / `RecentLocationsStore.swift` - история участников и локаций для быстрого ввода в форме создания встречи.
- `OWAWidget/MCP/` - MCP-сервер для AI-ассистентов (дизайн: `docs/superpowers/specs/2026-10-05-mcp-server-design.md`). Шесть инструментов календаря **только для чтения** и только в окне синка (−7 … +30 дней): `get_status`, `get_current_and_next`, `list_events`, `get_schedule_stats`, `find_events_with_person`, `get_event_details`; поиск в адресной книге `find_people`, подбор времени по занятости участников `find_free_slots` и единственный мутирующий `create_meeting`. Функция за настройкой `mcpServerEnabled`, создание встреч - за отдельной `mcpCreateMeetingsEnabled`; обе по умолчанию выключены. Вкладка «AI (MCP)» в настройках - `Views/MCPSettingsView.swift`.

> **Сервер живёт в приложении, клиент приходит через мост.** MCP-клиент запускает `Contents/Helpers/owawidget-mcp` (таргет `OWAWidgetMCPBridge`), тот перекладывает строки JSON-RPC между stdio и Unix-сокетом приложения. Отдельный самостоятельный сервер не делай: новый бинарь в связке - это диалог Keychain после каждого обновления, а второй процесс с теми же учётными данными обходит circuit breaker и рискует заблокировать доменную учётку. Мост не ходит ни в связку, ни в сеть, подписан **без entitlements** (`scripts/sign_app.sh`) и запускает приложение только через `NSWorkspace`, никогда exec'ом: иначе запросы TCC и связки приписались бы клиенту. Мост ничего не делает до первого сообщения в stdin - некоторые клиенты запускают сервер дважды (одноразовая проба версии).
>
> **Сокет - `~/Library/Caches/owawidget/mcp-<8 hex от bundle id>.sock`, не `$TMPDIR`.** `dirhelper` ночью удаляет из `$TMPDIR` файлы, к которым не обращались три дня, а у `sun_path` лимит 103 байта. Формула пути общая для приложения и моста (`OWAWidgetMCPShared/MCPSocketPath.swift`); сторож в `MCPServerService` раз в минуту пересоздаёт пропавший файл.
>
> **Протокол - своя реализация двух эпох** (`MCPProtocolHandler`): legacy с `initialize` (`2025-06-18`, `2025-11-25`) и stateless `2026-07-28` (`server/discover`, версия в `_meta` каждого запроса). Официальный Swift SDK умеет только `2025-11-25` и тянет `swift-nio`. `structuredContent` всегда объект; `outputSchema` не объявляем, описание полей - в тексте инструмента.
>
> **Сеть в MCP на чтение - `GetCalendarEvent` (детали встречи), `FindPeople` и `GetUserAvailabilityInternal`** и только через `MCPAccessGuard`: при `syncStatus.blocksSync` запрос не делается, ошибки уходят в общий circuit breaker (`CalendarService.reportExternalRequestFailure`), бюджет 60 запросов в минуту и не больше 2 одновременно. Не добавляй сетевые вызовы в MCP в обход guard'а. Кэш деталей (`MCPEventDetailsCache`) - только в памяти, по ключу (`id`, `changeKey`).
>
> **Мутирующий инструмент - только с подтверждением в окне приложения** (`MCPMeetingConfirmation.swift`), не в клиенте: модель можно уговорить чем угодно через описание прочитанной встречи. `create_meeting` так и устроен, и следующие (RSVP и т. п.) делай так же: окно ждёт не дольше 45 секунд (TypeScript SDK отменяет запрос через 60), закрывается по `notifications/cancelled`, повтор того же вызова в течение 10 минут отвечает первым результатом, внешние адреса подсвечены. После подтверждения запрос к Exchange доводится до конца даже при отмене клиентом. Причины - в дизайн-документе, раздел «Создание встреч».

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

## Xcode

`.xcodeproj` в проекте нет, и заводить его не нужно. Сборка идёт через SwiftPM и `Makefile` — это единственный поддерживаемый путь: он встраивает `Sparkle.framework`, правит `Info.plist`, копирует локализации и подписывает бандл.

Для работы в Xcode открывай сам пакет: `open Package.swift`. Настройки сборки меняй в `Package.swift` и `Makefile`. Подпись живёт в `scripts/sign_app.sh` - его вызывают и `make bundle`, и стенд обновления. Entitlements два файла, общие ключи держи одинаковыми (только ASCII, см. комментарий в файлах):

- `OWAWidget/OWAWidget.entitlements` - сборки с сертификатом (релизы Developer ID, `make run` при наличии Developer ID, Apple Development). Library validation включена: Sparkle переподписывается тем же Team ID.
- `OWAWidget/OWAWidget-dev.entitlements` - ad-hoc сборки (`make bundle`, `make run` без сертификата в связке). Дополнительно `disable-library-validation`: у ad-hoc подписи нет Team ID, и без этого ключа Sparkle не загрузится.

> **`make run` подписывает Developer ID, если сертификат есть в связке ключей.** Тогда «Разрешать всегда» в связке и доступ к Календарю переживают пересборки: у ad-hoc сборки requirement - `cdhash`, и диалог связки приходил после каждого изменения. Без сертификата `make run` подписывает ad-hoc, как раньше; `make run CODE_SIGN_IDENTITY=-` включает ad-hoc принудительно. Локальная подпись идёт без secure timestamp (`SIGN_TIMESTAMP=none`): метка нужна только нотаризации, а сервер меток - это сетевой запрос на каждый подписываемый объект, медленный и падающий без сети. Релиз (`make release-bundle`) всегда подписывается с меткой.

> **`make bundle` перезаписывает `.build/OWAWidget.app` на месте.** Если приложение запущено оттуда, процесс падает с `SIGKILL (Code Signature Invalid)`: бинарь меняется под работающим кодом. Перед `make bundle`, `make release-bundle` и `make release-package` проверь `pgrep -fl ".build/OWAWidget.app/Contents/MacOS/OWAWidget"` и закрой приложение (или предупреди пользователя).

Второй путь сборки означал бы дублирование всего, что делает `Makefile`, и неизбежное расхождение — не добавляй его.

## Правила изменений

- Не добавляй секреты, пароли, токены, cookies или реальные серверные адреса в репозиторий.
- Пароли аккаунтов должны оставаться только в Keychain.
- Не ослабляй TLS-проверки без явной настройки пользователя. Текущий OWA-клиент поддерживает локальные корпоративные Exchange-сценарии, но безопасность TLS нужно улучшать осторожно.
- Учитывай строгую конкурентность Swift 6. Сохраняй границы акторов у сервисов и провайдеров.
- Не включай `.build/`, `DerivedData/` и другие артефакты сборки в изменения.
- При добавлении нового календарного провайдера реализуй `CalendarProvider`, добавь тип аккаунта в `CalendarAccount`, затем подключи провайдер в `CalendarService.rebuildProviders()`. Заодно опиши возможности типа в `AccountType` (`requiresPassword`, `supportsMeetingCreation`): от них зависит, требуется ли запись в Keychain и показывать ли окно создания встречи. Read-only провайдеру не нужно ничего отключать в UI вручную - RSVP-кнопки скрываются сами, потому что завязаны на `changeKey`.
- Для UI параллельных встреч придерживайся инварианта: даже в compact-карточке нужно показывать собственный интервал времени события.
- Для проверки логики пересечений используй критерий полуинтервалов: `lhs.startDate < rhs.endDate && rhs.startDate < lhs.endDate`.
- `CustomMeetingReminderController` использует архитектуру **live-update single panel**: в любой момент времени отображается не более одного `NSPanel`. Если при срабатывании нового напоминания панель уже открыта, вызывается `updateCurrentPanel(merging:)`, который мёрджит новые встречи в `currentDisplayedItems`, пересчитывает title/subtitle и заменяет `currentHostingView.rootView` (SwiftUI делает diff in-place). Очереди (`queue: [Payload]`) не существует — не добавляй её. `finishPresentation()` очищает `currentPanel`, `currentHostingView`, `currentDisplayedItems`, `currentAnchorStartDate`, `currentDismissDeadline` без вызова какого-либо «следующего» элемента. Автозакрытие по таймеру и ручное закрытие оба вызывают `finishPresentation()` / `closeCurrentPanelAndFinish()` без дополнительных флагов.
- Reminder-панель показывается через `panel.orderFrontRegardless()` + `panel.makeKey()`. `orderFrontRegardless()` обязателен, потому что OWA Widget — фоновое menu-bar приложение: `makeKeyAndOrderFront(nil)` в таком случае молча не работает. `makeKey()` после `orderFrontRegardless()` даёт панели статус key window, и SwiftUI-кнопки срабатывают с первого клика. Без `makeKey()` первый клик «активирует» окно, а второй уже нажимает кнопку.
- Не обновляй версию вручную в `OWAWidget/Info.plist`: `make bundle`/`make release-package` автоматически ставят `CFBundleShortVersionString` из `VERSION` и `CFBundleVersion` из git-счётчика коммитов.
- RSVP (Accept/Decline/Tentative) реализован через **EWS SOAP** (`OWAClient.respondToMeeting`, строка ~511), а не через OWA JSON API. При расширении RSVP-функциональности сохраняй это разделение: EWS SOAP для мутирующих операций с письмами/ответами на встречи.
- **Аутентификация OWA — Integrated Windows Auth (NTLM).** С переходом сервера на SSO (июль 2026) OWA отвечает `401 WWW-Authenticate: Negotiate, NTLM` вместо веб-формы логина. Ключевые инварианты в `OWASessionDelegate` (`OWAClient.swift`):
  - Логин хранится/вводится в формате `ДОМЕН\логин` (например, `MOSCOW\U_12345`), а не email; пароль — доменный (тот же, что для входа в ПК). Поле аккаунта эту строку не валидирует как email — не добавляй такую валидацию.
  - На челлендж `NSURLAuthenticationMethodNegotiate` делегат отвечает `rejectProtectionSpace` (raw value `3`, в этом SDK нет именованного Swift-кейса), чтобы `URLSession` перешёл на NTLM. **Не** отдавай креды на Negotiate: Kerberos-с-паролем за VPN не работает (нет тикета/KDC), и `URLSession` сам на NTLM не откатывается.
  - На NTLM даём `URLCredential(user:password:.forSession)` один раз; повторный челлендж (`previousFailureCount > 0`) = настоящий неверный пароль → `cancelAuthenticationChallenge` + флаг `_authRejected`. Отказ приходит как `NSURLErrorCancelled` (-999); `fetchData` мапит `-999 + флаг` в `OWAError.authenticationFailed`. Обрыв сети (VPN off) даёт обычный `URLError` → путь «OWA недоступен», латч пароля не срабатывает.
  - `authenticate()` сначала пробует integrated-путь (`GET /owa/` под NTLM → CANARY из cookie/HTML), форм-логин (`/owa/auth.owa`) оставлен как fallback для серверов на старой схеме. EWS-запросы идут через тот же делегат — ручной `Basic`-заголовок не добавляй.

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
| `EventKitCalendarProvider` | `/tmp/owawidget_eventkit.log` |
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

> **Релиз собирается и публикуется ТОЛЬКО локально.** Все шаги (`make release-package`
> + `gh release create`) выполняй на локальной машине. Релизного GitHub Actions workflow
> в репозитории больше нет, и заводить его заново не нужно: на раннере стоит Xcode (16.4),
> несовместимый с зависимостью `KeyboardShortcuts` (`2.4.0`) — сборка падает с
> `no such module 'KeyboardShortcuts'` / `language versions ... (given: [5], supported: [])`.
> Вторая причина — приватный ключ подписи обновлений: держать его копию в GitHub Actions
> Secrets означает дать право подписать обновление всем пользователям каждому, кто может
> менять воркфлоу. Ключ живёт в login Keychain, бэкап — в менеджере паролей
> (`docs/sparkle-key-backup.md`).

> **Релизы подписываются Developer ID и нотаризуются.** `make release-bundle` подписывает
> сертификатом `Developer ID Application` из login Keychain (`RELEASE_SIGN_IDENTITY`) и падает
> на любой другой подписи. `make release-package` до сборки проверяет сертификат и профиль
> `notarytool`, после сборки отправляет приложение в Apple, пришивает тикет (`stapler`) и требует
> от Gatekeeper `Notarized Developer ID`. Профиль `owawidget-notary` создаётся один раз на машину
> командой `xcrun notarytool store-credentials owawidget-notary --key <AuthKey.p8> --key-id <KEYID>
> --issuer <ISSUER>` (ключ App Store Connect API; его копия - в менеджере паролей). Создаёт его
> мейнтейнер, не агент. Если нотаризация отклонена, скрипт печатает лог Apple - чини причину,
> не обходи шаг: без тикета Gatekeeper не откроет скачанное приложение.

> Если в изменениях затронуты подпись, entitlements или состав бандла — до публикации прогони
> `bash scripts/test_update_locally.sh`. Он проверяет, что уже установленная у пользователей
> версия сумеет применить обновление; `make release-package` проверяет только подпись артефактов.

- Если пользователь просит **"выпустить новый релиз"** (или эквивалентно), выполняй полный цикл публикации:
 1. Обновление `VERSION`.
 2. Обновление `RELEASE_NOTES.md`.
 - Обязательный формат секции версии:
 - `## vX.Y.Z - YYYY-MM-DD`
 - `### RU` и `### EN`
 - В обеих секциях обязательны подразделы про изменения и установку.
 - Установка: скачать zip, перенести `OWAWidget.app` в `/Applications`, запустить; обновления ставит Sparkle автоматически. Шаг `xattr -dr com.apple.quarantine` больше не нужен (релизы нотаризованы), и валидатор отвергает секцию, где он остался, - не копируй его из старых секций.
 - Первый релиз с Developer ID (после v1.0.53) - переходный: подпись меняется в последний раз, и пользователи один раз увидят два вопроса связки ключей и запрос доступа к Календарю. В секции этого релиза предупреди об этом и попроси нажать «Разрешать всегда» («Always Allow»; так кнопка называется в русской macOS 26 - проверено по скриншоту диалога): «Разрешить» пускает только на один запуск, и вопрос будет повторяться.
 3. Перед упаковкой обязательно зафиксируй релизные изменения (`VERSION`, `RELEASE_NOTES.md` и связанные файлы) в git commit, чтобы `CFBundleVersion`/`sparkle:version` гарантированно выросли относительно предыдущего релиза (build номер берется из `git rev-list --count HEAD`).
 4. Сборка архива и appcast: `make release-package` (создает `dist/OWAWidget-v<ver>-macos.zip` и `dist/appcast.xml`).
 - **Тесты — обязательный гейт.** `make release-package` зависит от таргета `test` и сам прогоняет `swift test` перед упаковкой. Если сьют красный — упаковка не запускается; сначала почини тесты, релиз не выпускай. Не обходи гейт (не вызывай `scripts/package_release.sh` напрямую) ради «быстрого» релиза.
 - Требуется доступ к EdDSA-приватнику (логин-Keychain или env `SPARKLE_ED_PRIVATE_KEY`). Если ключа нет — скрипт упадет; не пытайся выпустить релиз без подписи.
 5. Перед публикацией проверь `dist/appcast.xml`: `sparkle:version` нового релиза должен быть строго больше `sparkle:version` предыдущего опубликованного релиза.
 6. Публикация на GitHub через `gh release create` с двумя ассетами: zip и appcast.xml.
 - В `--notes-file` передавай **только секцию текущей версии**, а НЕ весь `RELEASE_NOTES.md` (он содержит весь changelog — иначе в тело релиза попадут все прошлые версии). `make release-package` сам вырезает секцию в `dist/release-notes-v<ver>.md` и печатает её путь как `NOTES_PATH=…`. Используй именно этот файл: `gh release create vX.Y.Z dist/OWAWidget-vX.Y.Z-macos.zip dist/appcast.xml --title vX.Y.Z --notes-file dist/release-notes-vX.Y.Z.md`.
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
