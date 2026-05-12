# Текущее время на таймлайне + приглушение прошедших встреч

## Контекст

Две взаимодополняющие визуальные фичи для ориентации во времени:
1. **Линия текущего времени** — горизонтальная линия с кружком, отмечающая «сейчас» на таймлайне
2. **Приглушение прошедших встреч** — opacity 0.45 для встреч, которые уже закончились сегодня

Масштаб таймлайна: `1 pt = 1 минута`, `fixedSlotHeight = 30pt` (30 мин/слот).
Встречи в таймлайне рендерятся через `TimelineMeetingBlockView`, не `MeetingRowView` (та используется только в `NextMeetingBannerView`, которая фильтрует прошедшие).

---

## Изменяемые файлы

- `OWAWidget/Models/CalendarEvent.swift`
- `OWAWidget/Views/TimelineMeetingBlockView.swift`
- `OWAWidget/Views/MeetingListView.swift`

---

## Реализация

### 1. `CalendarEvent.swift` — computed property `isPast`

```swift
var isPast: Bool {
    endDate < Date() && Calendar.current.isDateInToday(startDate)
}
```

- Использует `endDate` — текущая встреча (`isHappeningNow`) не считается прошедшей
- `isDateInToday` — scope только сегодняшний день; вчерашние/позавчерашние не затрагиваются

### 2. `TimelineMeetingBlockView.swift` — opacity для прошедших встреч

Применить к корневому контейнеру карточки:

```swift
.opacity(event.isPast ? 0.45 : 1.0)
```

Отменённые встречи уже имеют своё визуальное лечение (серый фон + зачёркивание), оба стиля могут сочетаться.

### 3. `MeetingListView.swift` — линия текущего времени

Добавить `.overlay` к `VStack` внутри `hourlySection` **до** существующего оверлея с карточками. В SwiftUI оверлеи стекаются в порядке добавления — первый находится ниже, поэтому линия окажется визуально под встречами:

```swift
// Сначала линия (под карточками)
.overlay(alignment: .topLeading) {
    currentTimeLineOverlay(for: section, gridStart: gridStart)
}
// Затем карточки встреч (поверх линии)
.overlay(alignment: .topLeading) {
    if !allItems.isEmpty { /* существующий код */ }
}
```

Новая private функция:

```swift
@ViewBuilder
private func currentTimeLineOverlay(
    for section: (label: String, date: Date, events: [CalendarEvent]),
    gridStart: Date
) -> some View {
    if Calendar.current.isDateInToday(section.date) {
        GeometryReader { geo in
            TimelineView(.periodic(every: 60, from: .now)) { context in
                let leftInset: CGFloat = timeColumnWidth + 10
                let minutesSinceStart = CGFloat(context.date.timeIntervalSince(gridStart) / 60)
                if minutesSinceStart >= 0 {
                    let yPos = minutesSinceStart * timelinePointsPerMinute
                    ZStack(alignment: .topLeading) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                            .offset(x: leftInset - 4, y: yPos - 3.5)
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.8))
                            .frame(width: geo.size.width - leftInset, height: 1)
                            .offset(x: leftInset, y: yPos)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
    }
}
```

Детали:
- `TimelineView(.periodic(every: 60))` — линия обновляется каждую минуту без ручного таймера
- Кружок диаметром 7pt центрируется на линии со стороны карточек (`leftInset - 4`)
- Линия: 1pt высотой, `accentColor` с opacity 0.8, от `leftInset` до правого края
- `minutesSinceStart < 0` — линия скрыта, если сейчас раньше начала грида

---

## Проверка

1. `make build` — нет ошибок компиляции
2. `make run` — проверить визуально:
   - Линия текущего времени видна только для сегодняшнего дня
   - Линия точно позиционирована между слотами (совпадает с ожидаемым временем)
   - Прошедшие встречи приглушены opacity 0.45, текущая/будущие — нет
   - Переключиться на другой день — линия и opacity исчезают
   - Подождать смену минуты — линия сдвигается
3. `swift test` — все тесты зелёные
