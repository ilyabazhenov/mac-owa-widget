# План: Недельная сетка для выбора слота встречи

## Контекст

Текущий список слотов (`SlotsByDayView`) показывает доступное время вертикальным списком, сгруппированным по дням. Это скрывает пространственный контекст: непонятно, насколько день загружен, где стоят слоты относительно рабочего времени. Заменяем на **мини-календарную сетку** — дни как колонки, время как строки.

## Целевой вид

```
         Пн 18  Вт 19  Чт 21
09:00  [ ████ ] [      ] [      ]
       [      ] [ ████ ] [      ]
10:00  [      ] [      ] [ ████ ]
       ...
17:30  [      ] [ ████ ] [      ]
```

- Колонки: только дни, в которых есть хотя бы один слот
- Строки: все 30-минутные интервалы 09:00–17:30 (18 строк)
- Ячейка со слотом: accent-цвет, кликабельная
- Ячейка без слота: прозрачная, не кликабельная
- Выбранная ячейка: насыщенный accent + иконка `checkmark`
- Метки времени: только на целых часах (09:00, 10:00...)

## Критические файлы

- `OWAWidget/Views/CreateMeeting/CreateMeetingView.swift` — единственный файл изменений
  - **Заменить** `SlotsByDayView` (строки 483–572) на `WeekGridSlotView`
  - **Заменить** вызов на строке 234

## Реализация

### 1. Вспомогательные типы

```swift
private typealias TimeKey = Int   // минуты от полуночи: 540 = 09:00, 570 = 09:30
private typealias DayKey  = Date  // Calendar.current.startOfDay(for:)
```

Статическая константа строк сетки:
```swift
private static let timeRows: [TimeKey] = stride(from: 540, to: 1080, by: 30).map { $0 }
// [540, 570, 600, ..., 1050]  — 18 элементов
```

### 2. Lookup-таблица слотов

```swift
private struct GridData {
    let days: [DayKey]
    let lookup: [DayKey: [TimeKey: FreeSlot]]
}

private var gridData: GridData {
    let cal = Calendar.current
    var order: [DayKey] = []
    var lookup: [DayKey: [TimeKey: FreeSlot]] = [:]
    for slot in slots {
        let day = cal.startOfDay(for: slot.start)
        let comps = cal.dateComponents([.hour, .minute], from: slot.start)
        let key = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        if lookup[day] == nil { order.append(day); lookup[day] = [:] }
        lookup[day]![key] = slot
    }
    return GridData(days: order, lookup: lookup)
}
```

### 3. Форматтеры (static let, как в SlotsByDayView)

```swift
private static let weekdayFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "EEE"; return f  // "Пн"/"Mon"
}()
private static let dayNumFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "d"; return f
}()
```

Метки времени — из `TimeKey` без форматтера:
```swift
private func timeLabel(_ key: TimeKey) -> String {
    String(format: "%02d:%02d", key / 60, key % 60)
}
```

### 4. Ячейка `SlotCell`

```swift
private struct SlotCell: View {
    let slot: FreeSlot?
    let isSelected: Bool
    let onTap: () -> Void
    @State private var isHovered = false

    private var bg: Color {
        guard slot != nil else { return .clear }
        if isSelected { return Color.accentColor }
        return Color.accentColor.opacity(isHovered ? 0.22 : 0.12)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(bg)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .onTapGesture { if slot != nil { onTap() } }
        .onHover { isHovered = $0 && slot != nil }
        .animation(.easeInOut(duration: 0.12), value: isSelected)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}
```

### 5. Заголовок колонки

```swift
private func columnHeader(for day: DayKey) -> some View {
    VStack(spacing: 1) {
        Text(Self.weekdayFmt.string(from: day).capitalized)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
        Text(Self.dayNumFmt.string(from: day))
            .font(.system(size: 12, weight: .semibold))
    }
    .frame(maxWidth: .infinity)
}
```

### 6. Тело WeekGridSlotView

```swift
private struct WeekGridSlotView: View {
    let slots: [FreeSlot]
    @Binding var selectedSlotID: UUID?

    var body: some View {
        let data = gridData
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            // Заголовок
            GridRow {
                Color.clear.frame(width: 38, height: 1)
                ForEach(data.days, id: \.self) { columnHeader(for: $0) }
            }
            // 18 строк времени
            ForEach(Self.timeRows, id: \.self) { timeKey in
                GridRow {
                    Text(timeKey % 60 == 0 ? timeLabel(timeKey) : "")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(width: 38, alignment: .trailing)
                        .gridColumnAlignment(.trailing)
                    ForEach(data.days, id: \.self) { day in
                        let slot = data.lookup[day]?[timeKey]
                        SlotCell(
                            slot: slot,
                            isSelected: slot != nil && slot?.id == selectedSlotID
                        ) { selectedSlotID = slot?.id }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
    // … gridData, форматтеры, timeLabel
}
```

### 7. Замена вызова (строка 234)

```swift
// Было:
SlotsByDayView(slots: vm.freeSlots, selectedSlotID: $vm.selectedSlotID)

// Стало:
WeekGridSlotView(slots: vm.freeSlots, selectedSlotID: $vm.selectedSlotID)
```

Удалить `SlotsByDayView` (строки 483–572) полностью.

## Нюансы реализации

- **Кол-во колонок в Grid** динамическое (1–5). `Grid` требует одинакового числа ячеек в каждом `GridRow` — это обеспечивается тем, что `data` вычисляется один раз в `body` через `let data = gridData`.
- **Ширина колонок**: время-колонка 38pt фиксирована, 4pt горизонтальный спейсинг; остаток делится поровну между днями. При 5 днях: ≈56pt/колонка в правой панели 340pt — достаточно.
- **Локализация**: `DateFormatter()` без явной локали использует системную локаль — так же, как текущий `SlotsByDayView`. Изменять не нужно.
- **Скролл**: существующий `ScrollView` в родительском `slotsSection` обрабатывает переполнение (18 строк × 26pt ≈ 468pt).

## Проверка

```bash
make build
```

Ручная проверка:
1. Открыть "Новая встреча", добавить участников, нажать "Найти свободные слоты"
2. Убедиться, что появляется сетка с днями как колонками
3. Кликнуть на слот — ячейка подсвечивается + галочка; кнопка "Создать встречу" становится активной
4. Переключить диапазон / длительность, повторить поиск — сетка обновляется
5. При нулевых слотах — показывается существующее сообщение "слоты не найдены" (не сетка)
