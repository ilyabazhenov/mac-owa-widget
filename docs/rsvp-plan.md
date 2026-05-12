# Plan: Accept/Decline встреч (RSVP)

## Контекст

Анализ JSON-дампа `GetCalendarView` (53 встречи) показал:
- OWA **уже возвращает** поля `ResponseType` и `IsResponseRequested` в каждом элементе
- Из 53 встреч ~35 имеют `ResponseType: NoResponseReceived` и `IsResponseRequested: true` — пользователь не ответил ни на одну!
- `ItemId` (Id + ChangeKey) уже декодируется в `OWACalendarItem` — именно он нужен для вызова accept/decline API
- Вся инфраструктура для нового API-запроса уже есть: `serviceRequest(action:canary:)`, аутентификация, CANARY-токен

**Возможные значения `ResponseType`:** `NoResponseReceived`, `Organizer`, `Tentative`, `Accept`, `Decline`

**OWA API для ответа на встречу:** action `CreateItem` с вложенным `AcceptItem` / `TentativelyAcceptItem` / `DeclineItem` и `ReferenceItemId` (ItemId + ChangeKey).

---

## Что нужно добавить

### 1. `MeetingResponseType` enum — новый файл
**`OWAWidget/Models/MeetingResponseType.swift`** (новый)
```swift
enum MeetingResponseType: String, Codable, Sendable, Hashable {
    case notResponded, accepted, tentative, declined, organizer
}
```

### 2. `OWAModels.swift` — добавить 2 поля в `OWACalendarItem`
- `ResponseType: String?`
- `IsResponseRequested: Bool?`
- Добавить в `CodingKeys` и оба `init`

### 3. `CalendarEvent.swift` — добавить 2 поля
- `changeKey: String?` — нужен для вызова OWA accept/decline API (nil для Google Calendar)
- `responseType: MeetingResponseType` — текущий статус ответа пользователя (default: `.notResponded`)
- Обновить `init`, `init(from:)`, `encode(to:)`, `CodingKeys`

### 4. `OWACalendarProvider.swift` — маппинг + новый метод
- В `mapItem()`: маппить `ResponseType` строку → `MeetingResponseType`, передавать `changeKey`
- Добавить `respondToMeeting(_ event:, action:) async throws` (реализация через `client`)

### 5. `OWARequestPayloads.swift` — новый payload
Добавить `OWAMeetingRespondPayload.make(itemId:changeKey:responseAction:timezone:)`:
```json
{
  "__type": "CreateItemJsonRequest:#Exchange",
  "Header": { ... },
  "Body": {
    "__type": "CreateItemRequest:#Exchange",
    "Items": {
      "__type": "NonEmptyArrayOfAllItemsType:#Exchange",
      "AcceptItem": {
        "__type": "AcceptItem:#Exchange",
        "ReferenceItemId": {
          "__type": "ItemId:#Exchange",
          "Id": "<ID>",
          "ChangeKey": "<CHANGE_KEY>"
        }
      }
    },
    "MessageDisposition": "SendAndSaveCopy"
  }
}
```
Аналогично для `DeclineItem` и `TentativelyAcceptItem`.

### 6. `OWAClient.swift` — новый метод
```swift
func respondToMeeting(itemId: String, changeKey: String, action: MeetingResponseAction) async throws
```
- Reuse `serviceRequest(action: "CreateItem", canary:)`
- Тело запроса — через `OWAMeetingRespondPayload.make(...)`
- Обработка 440/401 → reauth как в `fetchCalendarView`

### 7. `CalendarProvider.swift` — расширить протокол
```swift
func respondToMeeting(_ event: CalendarEvent, action: MeetingResponseAction) async throws
```
Добавить default implementation: `throw CalendarProviderError.notSupported` — чтобы GoogleCalendarProvider не требовал обязательной реализации.

### 8. `CalendarService.swift` — публичный метод
```swift
func respondToMeeting(_ event: CalendarEvent, action: MeetingResponseAction) async
```
Находит провайдер по `event.accountID`, делегирует вызов, обновляет `responseType` события локально (оптимистичный апдейт).

### 9. `MeetingDetailPanelView.swift` — UI кнопки
В `MeetingDetailActionsView` добавить блок RSVP под условием:
```
!event.isOrganizer && event.responseType != .organizer
```
Три кнопки: ✓ Принять / ? Под вопросом / ✗ Отклонить
- Активная кнопка (текущий `responseType`) — выделена цветом
- После нажатия → `calendarService.respondToMeeting(event, action: .accept/.tentative/.decline)`
- Показывать спиннер во время запроса, затем обновлять UI

---

## Критические файлы

| Файл | Изменение |
|------|-----------|
| `OWAWidget/Models/MeetingResponseType.swift` | **НОВЫЙ** — enum |
| `OWAWidget/Models/CalendarEvent.swift` | +`changeKey`, +`responseType` |
| `OWAWidget/Providers/OWA/OWAModels.swift` | +`ResponseType`, +`IsResponseRequested` в `OWACalendarItem` |
| `OWAWidget/Providers/OWA/OWARequestPayloads.swift` | +`OWAMeetingRespondPayload` |
| `OWAWidget/Providers/OWA/OWAClient.swift` | +`respondToMeeting(itemId:changeKey:action:)` |
| `OWAWidget/Providers/OWA/OWACalendarProvider.swift` | маппинг + реализация метода протокола |
| `OWAWidget/Providers/CalendarProvider.swift` | расширить протокол |
| `OWAWidget/Services/CalendarService.swift` | +публичный `respondToMeeting` |
| `OWAWidget/Views/MeetingDetailPanelView.swift` | RSVP-кнопки в `MeetingDetailActionsView` |

---

## Верификация

1. `make build` — компиляция без ошибок
2. Запустить приложение, открыть встречу с `ResponseType = NoResponseReceived`
3. Нажать "Принять" → OWA должна обновить статус (проверить в браузере OWA)
4. Убедиться, что для встреч-организатора (`IsOrganizer=true`) кнопки не показываются
5. Для Google Calendar аккаунтов — кнопки не показываются (провайдер не поддерживает)
