# Фича: Создание встреч (OWA JSON API)

## Контекст

Пользователь хочет форму создания встречи прямо из menu bar приложения.
Все сетевые вызовы — только через OWA JSON API (`/owa/service.svc?action=...`),
тот же механизм что использует браузер OWA. EWS SOAP не используется.

Аутентификация: CANARY-токен.
**Открытие окна:** кнопка "+" в header popover.

---

## Три OWA JSON action (реальные форматы из HAR)

Примеры запросов захвачены в:
- [`tmp/owa-debug/FinePeopleRequestHARExample.txt`](tmp/owa-debug/FinePeopleRequestHARExample.txt)
- [`tmp/owa-debug/GetUserAvailabilityInternalHARExample.txt`](tmp/owa-debug/GetUserAvailabilityInternalHARExample.txt)
- [`tmp/owa-debug/CreateCalendarEventHARExample.txt`](tmp/owa-debug/CreateCalendarEventHARExample.txt)

### 1. `FindPeople` — поиск участников

> HAR: [`tmp/owa-debug/FinePeopleRequestHARExample.txt`](tmp/owa-debug/FinePeopleRequestHARExample.txt)

```
POST /owa/service.svc?action=FindPeople&ID=-199&AC=1
Content-Type: application/json; charset=UTF-8
X-OWA-CANARY: <token>
Action: FindPeople
X-Requested-With: XMLHttpRequest
Body: <raw JSON>
```

**Body payload:**
```json
{
  "__type": "FindPeopleJsonRequest:#Exchange",
  "Header": {
    "__type": "JsonRequestHeaders:#Exchange",
    "RequestServerVersion": "Exchange2013",
    "TimeZoneContext": {
      "__type": "TimeZoneContext:#Exchange",
      "TimeZoneDefinition": {"__type": "TimeZoneDefinitionType:#Exchange", "Id": "<windows tz id>"}
    }
  },
  "Body": {
    "__type": "FindPeopleRequest:#Exchange",
    "IndexedPageItemView": {"__type": "IndexedPageView:#Exchange", "BasePoint": "Beginning", "Offset": 0},
    "QueryString": "<поисковый запрос>",
    "AggregationRestriction": {
      "__type": "RestrictionType:#Exchange",
      "Item": {
        "__type": "Or:#Exchange",
        "Items": [
          {"__type": "Exists:#Exchange", "Item": {"__type": "PropertyUri:#Exchange", "FieldURI": "PersonaEmailAddress"}},
          {"__type": "IsEqualTo:#Exchange",
           "Item": {"__type": "PropertyUri:#Exchange", "FieldURI": "PersonaType"},
           "FieldURIOrConstant": {"__type": "FieldURIOrConstantType:#Exchange",
                                  "Item": {"__type": "Constant:#Exchange", "Value": "DistributionList"}}}
        ]
      }
    },
    "PersonaShape": {
      "__type": "PersonaResponseShape:#Exchange",
      "BaseShape": "Default",
      "AdditionalProperties": [{"__type": "PropertyUri:#Exchange", "FieldURI": "PersonaAttributions"}]
    },
    "ShouldResolveOneOffEmailAddress": true,
    "SearchPeopleSuggestionIndex": false,
    "Context": [
      {"__type": "ContextProperty:#Exchange", "Key": "AppName", "Value": "OWA"},
      {"__type": "ContextProperty:#Exchange", "Key": "AppScenario", "Value": "Calendar"},
      {"__type": "ContextProperty:#Exchange", "Key": "ClientSessionId", "Value": ""}
    ]
  }
}
```

> Ответ не был захвачен — парсить через JSONSerialization, искать ключи `"DisplayName"`, `"EmailAddress"` рекурсивно.

---

### 2. `GetUserAvailabilityInternal` — свободные/занятые слоты

> HAR: [`tmp/owa-debug/GetUserAvailabilityInternalHARExample.txt`](tmp/owa-debug/GetUserAvailabilityInternalHARExample.txt)

```
POST /owa/service.svc?action=GetUserAvailabilityInternal&EP=1&ID=-196&AC=1
Content-Type: application/json; charset=UTF-8
X-OWA-CANARY: <token>
X-OWA-UrlPostData: <url-encoded JSON>
Action: GetUserAvailabilityInternal
```

**X-OWA-UrlPostData (decoded):**
```json
{
  "request": {
    "__type": "GetUserAvailabilityInternalJsonRequest:#Exchange",
    "Header": {
      "__type": "JsonRequestHeaders:#Exchange",
      "RequestServerVersion": "Exchange2013",
      "TimeZoneContext": {
        "__type": "TimeZoneContext:#Exchange",
        "TimeZoneDefinition": {"__type": "TimeZoneDefinitionType:#Exchange", "Id": "<windows tz id>"}
      }
    },
    "Body": {
      "__type": "GetUserAvailabilityRequest:#Exchange",
      "MailboxDataArray": [
        {
          "__type": "MailboxData:#Exchange",
          "Email": {"__type": "EmailAddress:#Exchange", "Address": "user@company.ru"}
        }
      ],
      "FreeBusyViewOptions": {
        "__type": "FreeBusyViewOptions:#Exchange",
        "MergedFreeBusyIntervalInMinutes": 30,
        "RequestedView": "DetailedMerged",
        "TimeWindow": {
          "__type": "Duration:#Exchange",
          "StartTime": "2026-05-14T00:00:00",
          "EndTime": "2026-05-21T00:00:00"
        }
      }
    }
  }
}
```

> Ответ содержит `MergedFreeBusy` строку (30-мин интервалы: 0=free, 1=tentative, 2=busy, 3=OOF) и `CalendarEventArray`. Парсить рекурсивно.

---

### 3. `CreateCalendarEvent` — создание встречи

> HAR: [`tmp/owa-debug/CreateCalendarEventHARExample.txt`](tmp/owa-debug/CreateCalendarEventHARExample.txt)

```
POST /owa/service.svc?action=CreateCalendarEvent&ID=-209&AC=1
Content-Type: application/json; charset=UTF-8
X-OWA-CANARY: <token>
Action: CreateCalendarEvent
X-Requested-With: XMLHttpRequest
Body: <raw JSON>
```

**Body payload (точный формат из HAR):**
```json
{
  "__type": "CreateItemJsonRequest:#Exchange",
  "Header": {
    "__type": "JsonRequestHeaders:#Exchange",
    "RequestServerVersion": "V2017_08_18",
    "TimeZoneContext": {
      "__type": "TimeZoneContext:#Exchange",
      "TimeZoneDefinition": {"__type": "TimeZoneDefinitionType:#Exchange", "Id": "<windows tz id>"}
    }
  },
  "Body": {
    "__type": "CreateItemRequest:#Exchange",
    "Items": [
      {
        "__type": "CalendarItem:#Exchange",
        "ClientSeriesId": "<UUID>",
        "Subject": "<название встречи>",
        "Body": {
          "__type": "BodyContentType:#Exchange",
          "BodyType": "HTML",
          "Value": "<html>...</html>"
        },
        "Sensitivity": "Normal",
        "ReminderIsSet": true,
        "ReminderMinutesBeforeStart": 15,
        "IsResponseRequested": true,
        "DoNotForwardMeeting": false,
        "IsAllDayEvent": false,
        "Start": "2026-05-14T10:00:00.000",
        "End": "2026-05-14T10:30:00.000",
        "FreeBusyType": "Busy",
        "RequiredAttendees": [
          {
            "__type": "AttendeeType:#Exchange",
            "Mailbox": {
              "Name": "<DisplayName из FindPeople>",
              "EmailAddress": "<email из FindPeople>",
              "RoutingType": "SMTP",
              "MailboxType": "Mailbox",
              "OriginalDisplayName": "<email из FindPeople>"
            }
          }
        ],
        "Location": {
          "__type": "EnhancedLocation:#Exchange",
          "Annotation": "",
          "DisplayName": "",
          "PostalAddress": {
            "__type": "PersonaPostalAddress:#Exchange",
            "Type": "Business",
            "LocationSource": "None"
          }
        },
        "unfoldedIndex": 0
      }
    ],
    "ClientSupportsIrm": true,
    "SavedItemFolderId": {
      "__type": "TargetFolderId:#Exchange",
      "BaseFolderId": {
        "__type": "DistinguishedFolderId:#Exchange",
        "Id": "calendar"
      }
    }
  }
}
```

**Важные детали:**
- `__type` в body: `CreateItemJsonRequest:#Exchange` (не CreateCalendarEventJsonRequest!)
- `RequestServerVersion`: `V2017_08_18` (не Exchange2013 как у FindPeople)
- `Start`/`End` с `.000` миллисекундами
- `ClientSeriesId` — генерировать через `UUID().uuidString.lowercased()`
- Attendee mailbox нужны `Name`, `EmailAddress`, `RoutingType`, `MailboxType`, `OriginalDisplayName`
- Для body события — минимальный HTML шаблон (пустой)

---

## Архитектура

### Новые файлы

| Файл | Назначение |
|------|-----------|
| `OWAWidget/Models/MeetingCreationModels.swift` | `ResolvedAttendee`, `AttendeeAvailability`, `FreeSlot`, `MeetingDraft`, `MeetingSearchRange` |
| `OWAWidget/Views/CreateMeeting/CreateMeetingView.swift` | Основной UI окна |
| `OWAWidget/Views/CreateMeeting/CreateMeetingViewModel.swift` | ViewModel (`@MainActor`) |
| `OWAWidget/Views/CreateMeeting/AttendeeSearchField.swift` | Поле ввода с чипами и dropdown |

### Изменяемые файлы

| Файл | Изменение |
|------|-----------|
| `OWAWidget/Providers/OWA/OWAClient.swift` | +`findPeople`, `+getUserAvailabilityInternal`, `+createCalendarEvent` |
| `OWAWidget/Providers/OWA/OWARequestPayloads.swift` | +3 payload builder |
| `OWAWidget/Providers/CalendarProvider.swift` | +3 метода с default `notSupported` |
| `OWAWidget/Providers/OWA/OWACalendarProvider.swift` | Реализация новых методов |
| `OWAWidget/Services/CalendarService.swift` | +`findPeople`, `+findFreeSlots`, `+createMeeting` |
| `OWAWidget/OWAWidgetApp.swift` | +`Window` сцена `create-meeting` |
| `OWAWidget/Views/PopoverView.swift` | +кнопка "+" в header |
| `en.lproj/Localizable.strings` + `ru.lproj/Localizable.strings` | +новые ключи |

---

## Шаг 1: Модели (`MeetingCreationModels.swift`)

```swift
struct ResolvedAttendee: Identifiable, Hashable, Sendable {
    var id: String { email }
    let displayName: String
    let email: String
}

struct AttendeeAvailability: Sendable {
    let email: String
    let mergedFreeBusy: String   // "002200..." (30-мин интервалы: 0=free, 2=busy)
    let windowStart: Date
    let intervalMinutes: Int     // 30
}

struct FreeSlot: Identifiable, Sendable {
    let id: UUID
    let start: Date
    let end: Date
    init(start: Date, end: Date) { self.id = UUID(); self.start = start; self.end = end }
}

struct MeetingDraft: Sendable {
    var title: String = ""
    var attendees: [ResolvedAttendee] = []
    var durationMinutes: Int = 30
    var searchRange: MeetingSearchRange = .today
}

enum MeetingSearchRange: String, CaseIterable, Sendable {
    case today, tomorrow, thisWeek, nextWeek
    var dateInterval: DateInterval { ... } // рабочие часы 9:00–18:00
}
```

---

## Шаг 2: OWA Payload builders (`OWARequestPayloads.swift`)

Вынести `sharedHeader(timezoneID:version:)` и `localDateFormatter()` в общие helpers.

Три новых enum:
- `OWAFindPeoplePayload.make(query:timezoneID:) -> [String: Any]`
- `OWAUserAvailabilityPayload.make(emails:start:end:timezoneID:) -> [String: Any]`
- `OWACreateCalendarEventPayload.make(title:start:end:attendees:timezoneID:folderIdentifier:) -> [String: Any]`

`OWACreateCalendarEventPayload` принимает `[ResolvedAttendee]` чтобы собрать полный mailbox словарь из `Name`+`EmailAddress`. Формирует `ClientSeriesId` через `UUID().uuidString.lowercased()`. Дата в формате `"yyyy-MM-dd'T'HH:mm:ss.SSS"`.

---

## Шаг 3: OWAClient — три новых метода

### findPeople — raw JSON body
```swift
func findPeople(query: String) async throws -> [ResolvedAttendee] {
    guard query.count >= 2 else { return [] }
    let canary = try await ensureAuthenticated()
    let payload = OWAFindPeoplePayload.make(query: query, timezoneID: windowsTimezoneID())
    let jsonData = try JSONSerialization.data(withJSONObject: payload)

    var comps = URLComponents(url: url("/owa/service.svc"), resolvingAgainstBaseURL: false)!
    comps.queryItems = [
        URLQueryItem(name: "action", value: "FindPeople"),
        URLQueryItem(name: "ID", value: "-199"),
        URLQueryItem(name: "AC", value: "1"),
    ]
    var req = URLRequest(url: comps.url!, timeoutInterval: 10)
    req.httpMethod = "POST"
    req.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
    req.setValue(canary, forHTTPHeaderField: "X-OWA-CANARY")
    req.setValue("FindPeople", forHTTPHeaderField: "Action")
    req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
    req.httpBody = jsonData
    addCommonHeaders(&req)

    let (data, _) = try await session.data(for: req)
    return parseFindPeopleResponse(data)
}

private func parseFindPeopleResponse(_ data: Data) -> [ResolvedAttendee] {
    // Рекурсивный поиск объектов с "DisplayName" + "EmailAddress"
    guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
    return extractPersonas(from: json)
}
```

### getUserAvailabilityInternal — X-OWA-UrlPostData
```swift
func getUserAvailabilityInternal(emails: [String], from start: Date, to end: Date) async throws -> [AttendeeAvailability] {
    let canary = try await ensureAuthenticated()
    let payload = OWAUserAvailabilityPayload.make(emails: emails, start: start, end: end, timezoneID: windowsTimezoneID())
    var req = try serviceRequest(action: "GetUserAvailabilityInternal", canary: canary)
    req.setValue(try jsonString(from: payload).formEncoded, forHTTPHeaderField: "X-OWA-UrlPostData")
    let (data, _) = try await session.data(for: req)
    return parseAvailabilityResponse(data, emails: emails, windowStart: start)
}
```

### createCalendarEvent — raw JSON body
```swift
func createCalendarEvent(title: String, start: Date, end: Date, attendees: [ResolvedAttendee], folderIdentifier: OWAFolderIdentifier?) async throws {
    let canary = try await ensureAuthenticated()
    let payload = OWACreateCalendarEventPayload.make(
        title: title, start: start, end: end,
        attendees: attendees, timezoneID: windowsTimezoneID(),
        folderIdentifier: folderIdentifier
    )
    let jsonData = try JSONSerialization.data(withJSONObject: payload)

    var comps = URLComponents(url: url("/owa/service.svc"), resolvingAgainstBaseURL: false)!
    comps.queryItems = [
        URLQueryItem(name: "action", value: "CreateCalendarEvent"),
        URLQueryItem(name: "ID", value: "-209"),
        URLQueryItem(name: "AC", value: "1"),
    ]
    var req = URLRequest(url: comps.url!, timeoutInterval: 15)
    req.httpMethod = "POST"
    req.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
    req.setValue(canary, forHTTPHeaderField: "X-OWA-CANARY")
    req.setValue("CreateCalendarEvent", forHTTPHeaderField: "Action")
    req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
    req.httpBody = jsonData
    addCommonHeaders(&req)

    let (data, response) = try await session.data(for: req)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
        throw OWAError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0, body)
    }
    // Проверить на ошибку в теле (аналогично checkForServiceError)
}
```

`ensureAuthenticated()` — если `canaryToken == nil` → вызвать `authenticate()`, вернуть `canaryToken`.

---

## Шаг 4: CalendarProvider protocol

```swift
// CalendarProvider.swift — добавить с default notSupported:
func findPeople(query: String) async throws -> [ResolvedAttendee]
func getUserAvailability(emails: [String], from: Date, to: Date) async throws -> [AttendeeAvailability]
func createMeeting(title: String, start: Date, end: Date, attendees: [ResolvedAttendee]) async throws
```

`OWACalendarProvider` — реализации делегируют в `client` (передавая `folderIdentifier` из `client.resolvedFolderIdentifier`).

---

## Шаг 5: CalendarService

```swift
func findPeople(query: String, accountID: UUID) async throws -> [ResolvedAttendee]
func findFreeSlots(emails: [String], range: DateInterval, durationMinutes: Int, accountID: UUID) async throws -> [FreeSlot]
func createMeeting(title: String, slot: FreeSlot, attendees: [ResolvedAttendee], accountID: UUID) async throws
```

### Алгоритм findFreeSlots (через MergedFreeBusy строку, 30-мин интервалы)

```
1. Вычислить requestStart = startOfDay(range.start), requestEnd = startOfDay(range.end) + 1 день
2. Вызвать getUserAvailability(from: requestStart, to: requestEnd)
3. Для каждого индекса i (каждые 30 мин от requestStart):
   a. slotStart = requestStart + i * 30min
   b. Пропустить если slotStart вне range или нерабочее время (до 9:00 или >= 18:00 local)
   c. slotEnd = slotStart + durationMinutes
   d. Пропустить если slotEnd > 18:00 или нерабочий день
   e. Нужно N = durationMinutes/30 последовательных свободных слотов
   f. Для каждого attendee: все N символов начиная с i == "0"?
4. Собрать FreeSlot(start: slotStart, end: slotEnd), вернуть первые 10
```

---

## Шаг 6: UI

### Window (`OWAWidgetApp.swift`)
```swift
Window(localizationService.tr("window.create.meeting.title"), id: "create-meeting") {
    if let account = calendarService.accounts.first(where: { $0.accountType == .owa }) {
        CreateMeetingView(calendarService: calendarService, accountID: account.id)
            .environmentObject(localizationService)
            .environment(\.locale, localizationService.locale)
    }
}
.windowResizability(.contentSize)
.defaultPosition(.center)
```

Если аккаунтов нет — показать сообщение "Добавьте OWA аккаунт в настройках".

### Кнопка "+" в PopoverView
```swift
Button { openWindow(id: "create-meeting") } label: {
    Image(systemName: "plus").font(.system(size: 13))
}
.buttonStyle(.plain)
.help(localization.tr("popover.new.meeting"))
```

### Layout CreateMeetingView
```
┌─────────────────────────────┐  width=420
│ Название                    │
│ [________________________]  │
│                             │
│ Участники                   │
│ [Иван ✕][Мария ✕][поиск..] │
│  ╔══ dropdown ══════════╗   │
│  ║ Иван Коваленко       ║   │
│  ╚══════════════════════╝   │
│                             │
│ Диапазон   [Сегодня     ▾] │
│ Длительность [30 мин    ▾] │
│                             │
│         [Найти слоты]       │
├─────────────────────────────┤
│ • Ср 14:00–14:30           │
│ • Ср 15:30–16:00           │
│ • Чт 09:00–09:30           │
│                             │
│  "Нет свободных слотов"    │ ← только после поиска
│                             │
│      [Создать встречу  →]   │
└─────────────────────────────┘
```

### CreateMeetingViewModel
```swift
@MainActor final class CreateMeetingViewModel: ObservableObject {
    @Published var draft = MeetingDraft()
    @Published var searchQuery = ""
    @Published var searchResults: [ResolvedAttendee] = []
    @Published var isSearching = false
    @Published var freeSlots: [FreeSlot] = []
    @Published var selectedSlotID: FreeSlot.ID? = nil
    @Published var isLoadingSlots = false
    @Published var isCreating = false
    @Published var errorMessage: String? = nil
    @Published var didSearchSlots = false
    private var searchTask: Task<Void, Never>?
    let calendarService: CalendarService
    let accountID: UUID

    var selectedSlot: FreeSlot? { freeSlots.first { $0.id == selectedSlotID } }
    var canCreate: Bool { !draft.title.isEmpty && selectedSlot != nil && !isCreating }

    func onSearchQueryChange(_ query: String) {
        searchTask?.cancel()
        guard query.count >= 2 else { searchResults = []; return }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            self.isSearching = true
            defer { self.isSearching = false }
            self.searchResults = (try? await self.calendarService.findPeople(
                query: query, accountID: self.accountID)) ?? []
        }
    }

    func addAttendee(_ attendee: ResolvedAttendee) {
        guard !draft.attendees.contains(attendee) else { return }
        draft.attendees.append(attendee)
        searchQuery = ""; searchResults = []
    }

    func findSlots() async { ... }
    func createMeeting() async { ... }
}
```

### AttendeeSearchField
- `FlowLayout`-подобная раскладка чипов через `HStack` с `flexibleWidth`
- Каждый чип: `Text(attendee.displayName)` + `Button("✕")`
- `TextField` в конце; `onChange` → `vm.onSearchQueryChange`
- Dropdown: `VStack` в `.overlay(alignment: .topLeading)` на все поле, `zIndex(1)`
- Keyboard: `Escape` очищает поиск, `Return` выбирает первый результат

---

## Шаг 7: Локализация

```
"window.create.meeting.title" = "New Meeting" / "Новая встреча"
"popover.new.meeting" = "New Meeting" / "Новая встреча"
"create.meeting.title.label" = "Title" / "Название"
"create.meeting.title.placeholder" = "Meeting title" / "Название встречи"
"create.meeting.attendees.label" = "Attendees" / "Участники"
"create.meeting.attendees.placeholder" = "Search by name…" / "Поиск по имени…"
"create.meeting.range.label" = "Date range" / "Диапазон"
"create.meeting.duration.label" = "Duration" / "Длительность"
"create.meeting.find.slots" = "Find available slots" / "Найти слоты"
"create.meeting.create.button" = "Create Meeting" / "Создать встречу"
"create.meeting.no.slots" = "No available slots" / "Нет свободных слотов"
"meeting.range.today" = "Today" / "Сегодня"
"meeting.range.tomorrow" = "Tomorrow" / "Завтра"
"meeting.range.this.week" = "This week" / "Эта неделя"
"meeting.range.next.week" = "Next week" / "Следующая неделя"
"meeting.duration.30min" = "30 min" / "30 мин"
"meeting.duration.60min" = "1 hour" / "1 час"
```

---

## Нюансы реализации

### Три разных режима отправки запроса
| Action | Body encoding | RequestServerVersion |
|--------|---------------|----------------------|
| FindPeople | raw JSON in body | Exchange2013 |
| GetUserAvailabilityInternal | X-OWA-UrlPostData | Exchange2013 |
| CreateCalendarEvent | raw JSON in body | V2017_08_18 |

FindPeople и CreateCalendarEvent требуют собственного URL builder (не `serviceRequest(action:canary:)`).

### Парсинг ответов — стратегия
Рекурсивный обход JSON через `JSONSerialization` (как `OWACalendarFoldersParser`).
Для FindPeople искать объекты с `"DisplayName"` + `"EmailAddress"` или `"EmailAddresses"`.
Для Availability искать `"MergedFreeBusy"` и `"WorkingHours"`.

### ensureAuthenticated()
Нужен приватный метод в `OWAClient` (или использовать существующий механизм):
```swift
private func ensureAuthenticated() async throws -> String {
    if let token = canaryToken { return token }
    try await authenticate()
    guard let token = canaryToken else { throw OWAError.authenticationFailed }
    return token
}
```

### Swift 6 concurrency
- Все модели — `Sendable` struct
- `CreateMeetingViewModel` — `@MainActor`
- `searchTask?.cancel()` перед каждым новым поиском

---

## Порядок реализации

1. `MeetingCreationModels.swift`
2. `OWARequestPayloads.swift` — 3 payload builder
3. `OWAClient.swift` — `findPeople`, `getUserAvailabilityInternal`, `createCalendarEvent`
4. `CalendarProvider.swift` + `OWACalendarProvider.swift`
5. `CalendarService.swift` + алгоритм слотов
6. `AttendeeSearchField.swift`
7. `CreateMeetingViewModel.swift` + `CreateMeetingView.swift`
8. `OWAWidgetApp.swift` + `PopoverView.swift`
9. Локализация
10. `swift build` → тест с реальным OWA

---

## Верификация

1. `swift build` — 0 ошибок
2. Кнопка "+" в header popover
3. "+" → открывается окно
4. Ввести 3 буквы → dropdown с Exchange GAL результатами (~300ms)
5. Выбрать участника → чип; добавить несколько
6. "Найти слоты" → список или "нет слотов"
7. Выбрать слот, ввести название → "Создать" → встреча в Exchange
8. Синхронизация → новая встреча в основном popover
