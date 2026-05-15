# План: Smart Suggestions + переключатель режимов отображения слотов

## Контекст

Сейчас слоты показываются единственным способом — недельной сеткой с бинарным «свободно/занято». Пользователю нужно:
1. **Smart Suggestions** — короткий шорт-лист рекомендаций сверху, чтобы не рыться в сетке вручную.
2. **Переключатель режимов отображения** под рекомендациями — три варианта: Сетка / Список / Heat-map.

**Стратегия ранжирования v1:** прайм-критерий — «раньше в дне» (9:00 лучше 17:30). Не требует расширенных данных от бэка. В будущем ранжирование можно усилить (optional, prime-time, ближе к now) — `FreeSlot.score` остаётся точкой расширения.

## Файлы изменений

| Файл | Назначение |
|---|---|
| `OWAWidget/Models/MeetingCreationModels.swift` | Добавить `score: Double` в `FreeSlot` |
| `OWAWidget/Services/MeetingFreeSlotCalculator.swift` | Вычислять score при компоновке слотов |
| `OWAWidget/Views/CreateMeeting/SlotSuggestionsView.swift` (новый) | Карточки Smart Suggestions |
| `OWAWidget/Views/CreateMeeting/SlotListView.swift` (новый) | Режим «Список» |
| `OWAWidget/Views/CreateMeeting/WeekGridSlotView.swift` (рефактор) | Параметризовать цвет ячейки → переиспользовать для Heat-map |
| `OWAWidget/Views/CreateMeeting/CreateMeetingView.swift` | Интеграция: Smart Suggestions сверху, segmented picker, switch по режимам |
| `OWAWidget/Resources/{en,ru}.lproj/Localizable.strings` | Новые ключи |

## Реализация

### 1. Модель `FreeSlot`

```swift
struct FreeSlot: Identifiable, Sendable {
    let id: UUID
    let start: Date
    let end: Date
    /// 0.0–1.0; 1.0 — слот раньше в дне (9:00), 0.0 — позже (18:00).
    /// Используется как фактор ранжирования и для окраски в heat-map.
    let score: Double

    init(start: Date, end: Date, score: Double = 0.0) {
        self.id = UUID()
        self.start = start
        self.end = end
        self.score = score
    }
}
```

### 2. Вычисление score в `MeetingFreeSlotCalculator`

Добавить вычисление в момент создания `FreeSlot`:
```swift
let hourOfDay = Double(cal.component(.hour, from: slotStart))
              + Double(cal.component(.minute, from: slotStart)) / 60.0
// бизнес-часы 9.0–18.0; чем раньше — тем выше
let score = max(0, min(1, (18.0 - hourOfDay) / 9.0))
results.append(FreeSlot(start: slotStart, end: slotEnd, score: score))
```

Порядок результатов — оставляем хронологический (сетка читает их именно так). Ранжирование делает UI.

### 3. `SlotSuggestionsView`

Хелпер выбора кандидатов:
```swift
enum SlotRanker {
    static func topPicks(from slots: [FreeSlot], limit: Int = 5) -> [FreeSlot] {
        let cal = Calendar.current
        // По одному «лучшему» слоту на каждый день; затем сортировка по дате
        let byDay = Dictionary(grouping: slots) { cal.startOfDay(for: $0.start) }
        return byDay
            .compactMap { _, group in group.max(by: { $0.score < $1.score }) }
            .sorted { $0.start < $1.start }
            .prefix(limit)
            .map { $0 }
    }

    static func reasonKey(for slot: FreeSlot) -> String {
        switch slot.score {
        case 0.85...: return "create.meeting.suggestions.reason.early"      // ~9:00
        case 0.55...: return "create.meeting.suggestions.reason.morning"    // ~10–11
        case 0.25...: return "create.meeting.suggestions.reason.afternoon"  // ~13–15
        default:      return "create.meeting.suggestions.reason.lateday"    // ~16+
        }
    }
}
```

Карточка — кликабельный ряд: день+дата · диапазон времени · бейдж причины. Выбранная карточка подсвечена accent (как чип в gri-сетке).

```
┌─ Лучшие варианты ───────────────────────────┐
│ ✓ Пт, 16 мая · 09:00 – 09:30   Раннее утро │
│   Пн, 19 мая · 09:00 – 09:30   Раннее утро │
│   Вт, 20 мая · 09:30 – 10:00   Утро        │
└─────────────────────────────────────────────┘
```

При нулевом списке слотов — не отображается (попадает в общий `freeSlots.isEmpty` блок).

### 4. Переключатель режимов

```swift
enum SlotViewMode: String, CaseIterable {
    case grid, list, heatmap
}

@State private var slotViewMode: SlotViewMode = .grid
```

Сам контрол — компактный `Picker(.segmented)` с иконками:
```swift
Picker("", selection: $slotViewMode) {
    Image(systemName: "square.grid.3x2").tag(SlotViewMode.grid)
    Image(systemName: "list.bullet").tag(SlotViewMode.list)
    Image(systemName: "thermometer.medium").tag(SlotViewMode.heatmap)
}
.pickerStyle(.segmented)
.labelsHidden()
.help(...) // tooltip с текущим режимом
.frame(width: 110)
```

### 5. Три режима

#### Grid (текущий)
Используем `WeekGridSlotView` как есть. Цвет ячейки — текущий accent для свободных.

#### List
Новый `SlotListView` — вертикальный список, сгруппирован по дням. Похоже на старый `SlotsByDayView` (был до week-grid; можно подсмотреть в git history `git log --all -- .../SlotsByDayView`).

```swift
struct SlotListView: View {
    let slots: [FreeSlot]
    @Binding var selectedSlotID: UUID?

    private var grouped: [(Date, [FreeSlot])] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: slots) { cal.startOfDay(for: $0.start) }
        return dict.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(grouped, id: \.0) { day, slots in
                dayHeader(day)
                ForEach(slots) { slot in
                    slotRow(slot, isSelected: selectedSlotID == slot.id)
                }
            }
        }
    }
}
```

#### Heat-map
Переиспользуем `WeekGridSlotView`, параметризовав окраску. Идея: в `WeekGridSlotView` инжектируется closure `cellColor: (FreeSlot?, _ isSelected: Bool) -> Color`. Текущая реализация переезжает в default-провайдер.

```swift
struct WeekGridSlotView: View {
    let slots: [FreeSlot]
    @Binding var selectedSlotID: UUID?
    let gridWeekInterval: DateInterval
    var coloring: SlotCellColoring = .accent  // default = текущее поведение

    enum SlotCellColoring {
        case accent     // текущая бинарная окраска
        case heatmap    // градиент по score
    }
}
```

`heatmap` color formula:
```swift
func heatmapColor(for slot: FreeSlot) -> Color {
    // 1.0 → green; 0.0 → orange (light)
    let hue = 0.10 + slot.score * 0.20   // 0.10 (orange) → 0.30 (green)
    return Color(hue: hue, saturation: 0.55, brightness: 0.85)
}
```
Пустые ячейки в heat-map — `Color(nsColor: .separatorColor).opacity(0.05)`. Выбранная — обводка accent + checkmark, как в grid.

> Замечание: при v1-ранжировании (только «раньше в дне») heat-map выглядит как вертикальный градиент — верхние строки темнее. Это ожидаемо. Когда добавим другие факторы (optional, prime-time, ближе к now) — картина станет содержательнее.

### 6. Структура `slotsSection`

```swift
@ViewBuilder
private var slotsSection: some View {
    if vm.isLoadingSlots { /* spinner */ }
    else if vm.slotsSearched {
        if vm.freeSlots.isEmpty {
            noSlotsMessage
        } else {
            VStack(alignment: .leading, spacing: 14) {
                SlotSuggestionsView(
                    suggestions: SlotRanker.topPicks(from: vm.freeSlots),
                    selectedSlotID: $vm.selectedSlotID
                )

                HStack {
                    sectionLabel(localization.tr("create.meeting.available.slots"))
                    Spacer()
                    viewModePicker
                    TimeZoneBadge()
                }

                switch slotViewMode {
                case .grid:
                    WeekGridSlotView(slots: vm.freeSlots, selectedSlotID: $vm.selectedSlotID,
                                     gridWeekInterval: vm.draft.searchRange.slotGridWeekInterval())
                case .list:
                    SlotListView(slots: vm.freeSlots, selectedSlotID: $vm.selectedSlotID)
                case .heatmap:
                    WeekGridSlotView(slots: vm.freeSlots, selectedSlotID: $vm.selectedSlotID,
                                     gridWeekInterval: vm.draft.searchRange.slotGridWeekInterval(),
                                     coloring: .heatmap)
                }
            }
        }
    } else { /* idle prompt */ }
}
```

### 7. Локализация

```
// ru
"create.meeting.suggestions.title"           = "Лучшие варианты";
"create.meeting.suggestions.reason.early"    = "Раннее утро";
"create.meeting.suggestions.reason.morning"  = "Утро";
"create.meeting.suggestions.reason.afternoon"= "После обеда";
"create.meeting.suggestions.reason.lateday"  = "Конец дня";
"create.meeting.view.grid"                   = "Сетка";
"create.meeting.view.list"                   = "Список";
"create.meeting.view.heatmap"                = "Тепловая карта";

// en
"create.meeting.suggestions.title"           = "Top picks";
"create.meeting.suggestions.reason.early"    = "Early morning";
"create.meeting.suggestions.reason.morning"  = "Morning";
"create.meeting.suggestions.reason.afternoon"= "Afternoon";
"create.meeting.suggestions.reason.lateday"  = "Late day";
"create.meeting.view.grid"                   = "Grid";
"create.meeting.view.list"                   = "List";
"create.meeting.view.heatmap"                = "Heat map";
```

## Этапы реализации

1. `FreeSlot.score` + вычисление в `MeetingFreeSlotCalculator` → собрать, обновить тесты `MeetingDraftTests`/`OWARequestPayloadTests` если задеваем.
2. `SlotRanker.topPicks` + новый файл `SlotSuggestionsView.swift`.
3. Новый `SlotListView.swift` (по образу старого `SlotsByDayView` из истории).
4. Рефактор `WeekGridSlotView` — extract в отдельный файл, добавить `SlotCellColoring`, реализовать `.heatmap`.
5. В `CreateMeetingView.slotsSection`: вынести Smart Suggestions, добавить `@State` + segmented picker, switch по режиму.
6. Локализация: 8 новых ключей в ru + en.
7. Финальная проверка: `make build`, `swift test`.

## Проверка

```bash
make build
swift test
```

Ручная:
1. Добавить 1–2 участников, найти слоты → Smart Suggestions показывает топ-5 утренних.
2. Клик по карточке выбирает соответствующий слот в любом из режимов ниже.
3. Переключение Сетка → Список → Heat-map; выбор сохраняется.
4. Heat-map: видимый градиент (верхние строки темнее, нижние светлее).
5. Пустой результат поиска — ни карточек, ни переключателя.
6. Локаль en: «Top picks / Grid / List / Heat map».

## v2 (заделы)

- Усиление ранжирования: + optional-доля, + близость к now, + штраф за edge-hours.
- Heat-map становится богаче по факторам.
- В Smart Suggestions карточка показывает не только время, но и «3/3 required, 2/3 optional».
- Запоминание выбранного `SlotViewMode` между сессиями (UserDefaults).
