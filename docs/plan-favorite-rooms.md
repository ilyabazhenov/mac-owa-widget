# Избранные комнаты (Favorite Rooms)

## Контекст

Пользователь хочет сохранять ссылки на часто используемые видеокомнаты (в первую очередь Контур.Толк / KTalk) и заходить в них за 2 клика из меню бара: клик по иконке → открывается popover → клик по комнате → открывается браузер.

Сейчас в приложении нет никакого механизма "избранного" — все события только из календаря.

---

## Что и где менять

### 1. Новая модель `FavoriteRoom` — `OWAWidget/Models/FavoriteRoom.swift` (новый файл)

```swift
struct FavoriteRoom: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var name: String
    var url: URL
    var platform: MeetingPlatform
}
```

Платформа определяется автоматически через уже существующий `MeetingURLDetector.detectPlatform(from:)` при создании комнаты.

---

### 2. `CalendarService.swift` — хранение и открытие комнат

Добавить рядом с другими ключами:

```swift
private let favoriteRoomsKey = "favoriteRooms"
@Published private(set) var favoriteRooms: [FavoriteRoom] = []
```

Методы:
- `func addFavoriteRoom(_ room: FavoriteRoom)` — добавить + сохранить в UserDefaults
- `func removeFavoriteRoom(id: UUID)` — удалить + сохранить
- `func reorderFavoriteRooms(_ rooms: [FavoriteRoom])` — для drag-to-reorder
- `func openFavoriteRoom(_ room: FavoriteRoom)` — `NSWorkspace.shared.open(room.url)`
- `private func persistFavoriteRooms()` — JSONEncoder → UserDefaults

Загрузка происходит в `init` аналогично аккаунтам.

---

### 3. `SettingsViewModel.swift` — состояние редактирования комнат

```swift
@Published var favoriteRooms: [FavoriteRoom] = []         // зеркало service.favoriteRooms
@Published var newRoomName: String = ""
@Published var newRoomURLString: String = ""
@Published var isAddingRoom: Bool = false
```

Методы:
- `func beginAddRoom()` — сбрасывает поля, `isAddingRoom = true`
- `func confirmAddRoom()` — валидирует URL, вызывает `service.addFavoriteRoom()`, обновляет зеркало
- `func cancelAddRoom()` — `isAddingRoom = false`, очистка полей
- `func deleteRoom(_ room: FavoriteRoom)` — `service.removeFavoriteRoom(id: room.id)`, обновляет зеркало
- `var newRoomURLIsValid: Bool` — `URL(string: newRoomURLString)?.scheme?.hasPrefix("http")`

Комнаты сохраняются **немедленно** (как аккаунты), не через кнопку "Сохранить". В `PreferencesSnapshot` не добавляются.

---

### 4. `PreferencesView.swift` — новая секция

Добавить секцию **после Notifications, перед Engagement**:

```swift
Section(localization.tr("preferences.rooms.section")) {
    // Список комнат с кнопкой удаления
    ForEach(vm.favoriteRooms) { room in
        HStack {
            Image(systemName: room.platform.sfSymbol)  // используем уже существующий sfSymbol
            Text(room.name)
            Spacer()
            Button(role: .destructive) { vm.deleteRoom(room) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }
    // Форма добавления
    if vm.isAddingRoom {
        VStack(alignment: .leading, spacing: 6) {
            TextField(localization.tr("preferences.rooms.name.prompt"), text: $vm.newRoomName)
            TextField(localization.tr("preferences.rooms.url.prompt"), text: $vm.newRoomURLString)
            HStack {
                Button(localization.tr("settings.account.cancel")) { vm.cancelAddRoom() }
                Button(localization.tr("settings.account.add")) { vm.confirmAddRoom() }
                    .disabled(!vm.newRoomURLIsValid || vm.newRoomName.isEmpty)
            }
        }
    } else {
        Button(localization.tr("preferences.rooms.add")) { vm.beginAddRoom() }
    }
}
```

Для иконки платформы переиспользуем существующий `MeetingPlatform.sfSymbol` (уже есть в модели `MeetingPlatform`).

---

### 5. `PopoverView.swift` — компактная строка комнат

Добавить `favoriteRoomsRow` computed var и вставить его в `dayTimelineContent` **между date nav bar и списком встреч**:

```swift
@ViewBuilder
private var favoriteRoomsRow: some View {
    if !service.favoriteRooms.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(service.favoriteRooms) { room in
                    Button {
                        service.openFavoriteRoom(room)
                    } label: {
                        Label(room.name, systemImage: room.platform.sfSymbol)
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, contentHorizontalPadding)
        }
        .padding(.vertical, 6)
        Divider()
    }
}
```

Размещение: в `dayTimelineContent` после date nav bar, перед `MeetingListView`. Высота при наличии комнат ~40px, исчезает если комнат нет.

---

### 6. Локализация — добавить строки

**`en.lproj/Localizable.strings`:**
```
"preferences.rooms.section" = "Favorite Rooms";
"preferences.rooms.add" = "Add Room";
"preferences.rooms.name.prompt" = "Room name";
"preferences.rooms.url.prompt" = "https://...";
```

**`ru.lproj/Localizable.strings`:**
```
"preferences.rooms.section" = "Избранные комнаты";
"preferences.rooms.add" = "Добавить комнату";
"preferences.rooms.name.prompt" = "Название";
"preferences.rooms.url.prompt" = "https://...";
```

---

### 7. Проверить что `MeetingPlatform` имеет `sfSymbol`

Нужно убедиться, что у `MeetingPlatform` есть `.sfSymbol` (или аналогичный computed var) для иконок в UI. Если нет — добавить. Для `.ktalk` можно использовать `"video.fill"` или `"phone.fill"`.

---

## Порядок реализации

1. `FavoriteRoom.swift` — создать модель
2. `CalendarService.swift` — добавить persistence + методы
3. `SettingsViewModel.swift` — добавить редактирование
4. `PreferencesView.swift` — добавить секцию
5. `PopoverView.swift` — добавить строку комнат
6. Локализация — добавить строки в оба файла

---

## Критические файлы

| Файл | Действие |
|------|----------|
| `OWAWidget/Models/FavoriteRoom.swift` | Создать |
| `OWAWidget/Models/MeetingPlatform.swift` | Проверить/добавить `sfSymbol` |
| `OWAWidget/Services/CalendarService.swift` | Добавить ~40 строк |
| `OWAWidget/Views/SettingsViewModel.swift` | Добавить ~30 строк |
| `OWAWidget/Views/PreferencesView.swift` | Добавить секцию ~35 строк |
| `OWAWidget/Views/PopoverView.swift` | Добавить `favoriteRoomsRow` + встроить |
| `OWAWidget/Resources/en.lproj/Localizable.strings` | 4 строки |
| `OWAWidget/Resources/ru.lproj/Localizable.strings` | 4 строки |

Переиспользуется: `MeetingURLDetector.detectPlatform(from:)`, `NSWorkspace.shared.open()`, паттерн immediate-save как у аккаунтов.

---

## Верификация

1. `make build` — компиляция без ошибок
2. Открыть Настройки → вкладка Настройки → добавить комнату "Толк ежедневки" с URL KTalk
3. Закрыть настройки — в popover появляется горизонтальная строка с кнопкой "Толк ежедневки"
4. Клик по кнопке → открывается URL в браузере
5. Удалить комнату в настройках — строка исчезает из popover
6. Убедиться: при 0 комнатах строка не занимает место в popover
7. `swift build` в режиме Release — нет предупреждений по Swift 6 concurrency
