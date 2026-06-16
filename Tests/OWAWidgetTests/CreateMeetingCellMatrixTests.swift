import XCTest
@testable import OWAWidget

/// Regression-тесты на текущую логику `CreateMeetingViewModel.cellMatrix`.
///
/// `cellMatrix` — горячий computed property, который пересчитывается на каждый рендер
/// грида. Перед перф-оптимизацией (мемоизацией) фиксируем визуальный output:
///   • три прохода (заполнение, multi-row free slot, run-merge для занятых) выдают одни
///     и те же позиции и состояния;
///   • organizer events продлеваются в attendeeStatuses первым элементом «Вы»;
///   • displayName fall-back на префикс email, если участник не в draft;
///   • прошедшая неделя и пустой ввод корректно дают пустую/полную матрицу.
@MainActor
final class CreateMeetingCellMatrixTests: XCTestCase {

    /// 2025-05-12 — понедельник по календарю Europe/Moscow. Все тесты якорятся к нему.
    private let mondayMSK: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return cal.date(from: DateComponents(year: 2025, month: 5, day: 12, hour: 0, minute: 0))!
    }()

    // MARK: - Helpers

    private func makeVM(
        attendees: [ResolvedAttendee] = [
            ResolvedAttendee(displayName: "Alice", email: "alice@x.com", jobTitle: nil)
        ],
        optionalAttendees: [ResolvedAttendee] = [],
        attendeeAvailabilities: [AttendeeAvailability] = [],
        optionalAvailabilities: [AttendeeAvailability] = [],
        organizerAvailability: AttendeeAvailability? = nil,
        organizerEvents: [CalendarEvent] = [],
        freeSlots: [FreeSlot] = []
    ) -> CreateMeetingViewModel {
        let svc = CalendarService(
            providers: [],
            eventCacheStore: TestInMemoryEventCacheStore(snapshot: nil),
            notificationService: TestNoOpNotificationService(),
            customMeetingReminders: TestNoOpMeetingReminderController(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )
        let vm = CreateMeetingViewModel(calendarService: svc, accountID: UUID())
        var draft = MeetingDraft()
        draft.selectedWeekStart = mondayMSK
        draft.requiredAttendees = attendees
        draft.optionalAttendees = optionalAttendees
        vm.draft = draft
        vm.attendeeAvailabilities = attendeeAvailabilities
        vm.optionalAvailabilities = optionalAvailabilities
        vm.organizerAvailability = organizerAvailability
        vm.organizerEvents = organizerEvents
        vm.freeSlots = freeSlots
        return vm
    }

    /// Строка занятости длиной 5 дней × 48 получасовиков (с Mon 00:00 MSK). Все free по умолчанию.
    /// `overrides` позволяет точечно подменить символы: 0=free, 1=tentative, 2=busy, 3=OOF.
    private func availabilityChars(overrides: [Int: Character] = [:]) -> String {
        var arr = Array(repeating: Character("0"), count: 5 * 48)
        for (idx, ch) in overrides { arr[idx] = ch }
        return String(arr)
    }

    /// Индекс получасовика от Mon 00:00 MSK в строке занятости.
    private func slotIndex(dayOffset: Int, hour: Int, minute: Int = 0) -> Int {
        dayOffset * 48 + hour * 2 + minute / 30
    }

    /// timeKey, по которому индексируется вторая dimension в `cellMatrix`.
    private func timeKey(hour: Int, minute: Int = 0) -> Int { hour * 60 + minute }

    /// Достаёт ячейку из матрицы по dayOffset (0=Mon … 4=Fri) и часу/минуте.
    private func cell(
        in matrix: [Date: [Int: CellAvailability]],
        dayOffset: Int,
        hour: Int,
        minute: Int = 0
    ) -> CellAvailability? {
        let sortedDays = matrix.keys.sorted()
        guard dayOffset < sortedDays.count else { return nil }
        return matrix[sortedDays[dayOffset]]?[timeKey(hour: hour, minute: minute)]
    }

    private func availability(email: String, chars: String) -> AttendeeAvailability {
        AttendeeAvailability(email: email, mergedFreeBusy: chars, windowStart: mondayMSK, intervalMinutes: 30)
    }

    private func makeFreeSlot(
        dayOffset: Int,
        hour: Int,
        minute: Int = 0,
        durationMinutes: Int = 30,
        score: Double = 0.5
    ) -> FreeSlot {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let dayStart = cal.date(byAdding: .day, value: dayOffset, to: mondayMSK)!
        let start = dayStart.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
        let end = start.addingTimeInterval(TimeInterval(durationMinutes * 60))
        return FreeSlot(start: start, end: end, score: score)
    }

    private func makeCalendarEvent(
        dayOffset: Int,
        startHour: Int,
        endHour: Int,
        title: String
    ) -> CalendarEvent {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let dayStart = cal.date(byAdding: .day, value: dayOffset, to: mondayMSK)!
        return CalendarEvent(
            id: UUID().uuidString,
            title: title,
            startDate: dayStart.addingTimeInterval(TimeInterval(startHour * 3600)),
            endDate: dayStart.addingTimeInterval(TimeInterval(endHour * 3600)),
            location: nil,
            bodyPreview: nil,
            joinURL: nil,
            platform: .teams,
            isAllDay: false,
            organizer: nil,
            accountID: UUID()
        )
    }

    // MARK: - Пустой ввод / структура матрицы

    func testEmptyAttendeeAvailabilitiesReturnsEmptyMatrix() {
        let vm = makeVM(attendeeAvailabilities: [])
        XCTAssertTrue(vm.cellMatrix.isEmpty, "матрица должна быть пустой, пока нет данных от сервера")
    }

    func testMatrixCoversMondayThroughFridayOnly() {
        let vm = makeVM(attendeeAvailabilities: [availability(email: "a@x.com", chars: availabilityChars())])
        XCTAssertEqual(vm.cellMatrix.count, 5, "Mon–Fri = 5 колонок, без Sat/Sun")
    }

    func testMatrixUsesNineToSixGridStep30Minutes() {
        let vm = makeVM(attendeeAvailabilities: [availability(email: "a@x.com", chars: availabilityChars())])
        let monday = vm.cellMatrix.keys.sorted().first!
        let timeKeys = vm.cellMatrix[monday]!.keys.sorted()
        XCTAssertEqual(timeKeys.first, 9 * 60)
        XCTAssertEqual(timeKeys.last, 17 * 60 + 30, "последний слот 17:30 (старт), кончается в 18:00")
        XCTAssertEqual(timeKeys.count, 18)
    }

    // MARK: - Состояния ячейки из чисел занятости

    func testAllZeroCharsProduceFreeState() {
        let vm = makeVM(attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())])
        guard let cell = cell(in: vm.cellMatrix, dayOffset: 0, hour: 10) else {
            XCTFail("expected Mon 10:00 cell"); return
        }
        if case .free = cell.state {} else { XCTFail("expected .free for all-zero chars") }
        XCTAssertEqual(cell.attendeeStatuses.count, 1)
    }

    func testBusyCharProducesBusyState() {
        let idx = slotIndex(dayOffset: 0, hour: 10)
        let vm = makeVM(
            attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars(overrides: [idx: "2"]))]
        )
        guard let cell = cell(in: vm.cellMatrix, dayOffset: 0, hour: 10) else { XCTFail(); return }
        if case .busy = cell.state {} else { XCTFail("expected .busy for char '2'") }
    }

    func testTentativeCharProducesTentativeState() {
        let idx = slotIndex(dayOffset: 0, hour: 11)
        let vm = makeVM(
            attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars(overrides: [idx: "1"]))]
        )
        guard let cell = cell(in: vm.cellMatrix, dayOffset: 0, hour: 11) else { XCTFail(); return }
        if case .tentative = cell.state {} else { XCTFail("expected .tentative for char '1'") }
    }

    func testOOFCharProducesOutOfOfficeState() {
        let idx = slotIndex(dayOffset: 0, hour: 12)
        let vm = makeVM(
            attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars(overrides: [idx: "3"]))]
        )
        guard let cell = cell(in: vm.cellMatrix, dayOffset: 0, hour: 12) else { XCTFail(); return }
        if case .outOfOffice = cell.state {} else { XCTFail("expected .outOfOffice for char '3'") }
    }

    // MARK: - Конфликт у организатора

    func testOrganizerEventSurfacesAsFirstAttendeeStatusWithTitle() {
        let vm = makeVM(
            attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())],
            organizerAvailability: availability(email: "me@x.com", chars: availabilityChars()),
            organizerEvents: [makeCalendarEvent(dayOffset: 0, startHour: 10, endHour: 11, title: "Standup")]
        )
        guard let cell = cell(in: vm.cellMatrix, dayOffset: 0, hour: 10) else { XCTFail(); return }
        XCTAssertEqual(cell.attendeeStatuses.first?.displayName, "Вы", "organizer row должен идти первым")
        XCTAssertEqual(cell.attendeeStatuses.first?.eventTitles, ["Standup"])
    }

    func testOrganizerEventTitleAbsentOutsideEventWindow() {
        let vm = makeVM(
            attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())],
            organizerAvailability: availability(email: "me@x.com", chars: availabilityChars()),
            organizerEvents: [makeCalendarEvent(dayOffset: 0, startHour: 10, endHour: 11, title: "Standup")]
        )
        guard let cell = cell(in: vm.cellMatrix, dayOffset: 0, hour: 14) else { XCTFail(); return }
        XCTAssertEqual(cell.attendeeStatuses.first?.displayName, "Вы")
        XCTAssertEqual(cell.attendeeStatuses.first?.eventTitles, [])
    }

    func testOrganizerMultipleOverlappingEventsAllSurfaceInCell() {
        let vm = makeVM(
            attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())],
            organizerAvailability: availability(email: "me@x.com", chars: availabilityChars()),
            organizerEvents: [
                makeCalendarEvent(dayOffset: 0, startHour: 10, endHour: 11, title: "Standup"),
                makeCalendarEvent(dayOffset: 0, startHour: 10, endHour: 11, title: "1:1 with Bob")
            ]
        )
        guard let cell = cell(in: vm.cellMatrix, dayOffset: 0, hour: 10) else { XCTFail(); return }
        XCTAssertEqual(cell.attendeeStatuses.first?.displayName, "Вы")
        XCTAssertEqual(cell.attendeeStatuses.first?.eventTitles, ["Standup", "1:1 with Bob"])
    }

    // MARK: - Self-only бронирование (без required attendees)

    /// Контракт новой фичи: пользователь может бронировать своё собственное время без
    /// добавления участников. Грид должен показывать его freebusy и подсвечивать FreeSlot'ы.
    /// Если кто-то снова поставит guard `attendeeAvailabilities.isEmpty -> return [:]`, тест упадёт.
    func testSelfOnlyMatrixRendersOrganizerBusyWithoutAttendees() {
        let idx = slotIndex(dayOffset: 0, hour: 10)
        let vm = makeVM(
            attendees: [],
            attendeeAvailabilities: [],
            organizerAvailability: availability(email: "me@x.com", chars: availabilityChars(overrides: [idx: "2"]))
        )
        XCTAssertEqual(vm.cellMatrix.count, 5, "self-only режим всё ещё должен покрывать Mon–Fri")
        guard let busy = cell(in: vm.cellMatrix, dayOffset: 0, hour: 10) else { XCTFail(); return }
        if case .busy = busy.state {} else { XCTFail("ячейка с busy организатора должна быть .busy, got \(busy.state)") }
        XCTAssertEqual(busy.attendeeStatuses.first?.displayName, "Вы", "в self-only единственная строка — организатор")
        XCTAssertEqual(busy.attendeeStatuses.count, 1, "никаких посторонних строк в self-only")
    }

    func testSelfOnlyMatrixSurfacesOrganizerEventTitlesWithoutAttendees() {
        let vm = makeVM(
            attendees: [],
            attendeeAvailabilities: [],
            organizerAvailability: availability(email: "me@x.com", chars: availabilityChars()),
            organizerEvents: [makeCalendarEvent(dayOffset: 1, startHour: 14, endHour: 15, title: "Design review")]
        )
        guard let conflict = cell(in: vm.cellMatrix, dayOffset: 1, hour: 14) else { XCTFail(); return }
        XCTAssertEqual(conflict.attendeeStatuses.first?.displayName, "Вы")
        XCTAssertEqual(conflict.attendeeStatuses.first?.eventTitles, ["Design review"])
    }

    /// `!freeSlots.isEmpty` — четвёртая ветка нового guard. Если её удалят, FreeSlot'ы перестанут
    /// рендериться в self-only сценарии, когда сервер ещё не отдал organizer freebusy, но calculator
    /// уже отработал по событиям из кэша. Кейс редкий, но без guard матрица будет пустой.
    func testMatrixBuildsFromFreeSlotsAloneWhenNoAvailability() {
        let slot = makeFreeSlot(dayOffset: 0, hour: 10, durationMinutes: 60, score: 0.5)
        let vm = makeVM(
            attendees: [],
            attendeeAvailabilities: [],
            organizerAvailability: nil,
            organizerEvents: [],
            freeSlots: [slot]
        )
        XCTAssertEqual(vm.cellMatrix.count, 5)
        XCTAssertEqual(cell(in: vm.cellMatrix, dayOffset: 0, hour: 10)?.slotPosition, .start)
        XCTAssertEqual(cell(in: vm.cellMatrix, dayOffset: 0, hour: 10, minute: 30)?.slotPosition, .end)
    }

    // MARK: - Жизненный цикл isLoadingSlots

    /// При первом открытии CreateMeetingView дебаунс на `$draft` подгружает слоты через 450 мс.
    /// До этого спиннер должен уже крутиться, иначе пользователь видит «пустую» подсказку
    /// и думает, что приложение ничего не делает.
    func testInitSetsIsLoadingSlotsToTrueToAvoidPlaceholderFlash() {
        let svc = CalendarService(
            providers: [],
            eventCacheStore: TestInMemoryEventCacheStore(snapshot: nil),
            notificationService: TestNoOpNotificationService(),
            customMeetingReminders: TestNoOpMeetingReminderController(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )
        let vm = CreateMeetingViewModel(calendarService: svc, accountID: UUID())
        XCTAssertTrue(vm.isLoadingSlots, "спиннер должен включаться сразу в init, до debounce findSlots")
    }

    func testShiftSelectedWeekResetsStateEvenWithoutRequiredAttendees() {
        // VM без участников, с заранее загруженными данными (например, остатки от прошлого поиска
        // через optional). Старая логика гейтила сброс на `!requiredAttendees.isEmpty` — переход
        // на новую неделю оставлял устаревшие freeSlots и спиннер не загорался.
        let vm = makeVM(
            attendees: [],
            attendeeAvailabilities: [availability(email: "stale@x.com", chars: availabilityChars())],
            optionalAvailabilities: [availability(email: "stale-opt@x.com", chars: availabilityChars())],
            organizerAvailability: availability(email: "me@x.com", chars: availabilityChars()),
            organizerEvents: [makeCalendarEvent(dayOffset: 0, startHour: 10, endHour: 11, title: "Stale")],
            freeSlots: [makeFreeSlot(dayOffset: 0, hour: 10)]
        )
        vm.isLoadingSlots = false

        vm.shiftSelectedWeek(by: 1)

        XCTAssertTrue(vm.isLoadingSlots, "переход на след. неделю всегда поднимает спиннер")
        XCTAssertTrue(vm.freeSlots.isEmpty, "устаревшие слоты должны быть очищены")
        XCTAssertTrue(vm.attendeeAvailabilities.isEmpty)
        XCTAssertTrue(vm.optionalAvailabilities.isEmpty, "optional availabilities тоже должны сбрасываться, иначе в тултипе остаются данные прошлой недели")
        XCTAssertNil(vm.organizerAvailability)
        XCTAssertTrue(vm.organizerEvents.isEmpty)
        XCTAssertNil(vm.selectedSlot)
    }

    func testResetToCurrentWeekResetsStateEvenWithoutRequiredAttendees() {
        let vm = makeVM(
            attendees: [],
            attendeeAvailabilities: [availability(email: "stale@x.com", chars: availabilityChars())],
            optionalAvailabilities: [availability(email: "stale-opt@x.com", chars: availabilityChars())],
            freeSlots: [makeFreeSlot(dayOffset: 0, hour: 10)]
        )
        // Уводим неделю в будущее, чтобы reset реально сработал (guard на ту же неделю).
        var d = vm.draft
        d.selectedWeekStart = d.weekStartOffset(by: 2)
        vm.draft = d
        vm.isLoadingSlots = false

        vm.resetToCurrentWeek()

        XCTAssertTrue(vm.isLoadingSlots)
        XCTAssertTrue(vm.freeSlots.isEmpty)
        XCTAssertTrue(vm.attendeeAvailabilities.isEmpty)
        XCTAssertTrue(vm.optionalAvailabilities.isEmpty)
        XCTAssertNil(vm.selectedSlot)
    }

    // MARK: - DisplayName fall-back

    func testAttendeeDisplayNameFallsBackToEmailLocalPartWhenNotInDraft() {
        // В draft пусто, но availability приходит на «незнакомый» email — берём префикс до `@`.
        let vm = makeVM(
            attendees: [],
            attendeeAvailabilities: [availability(email: "unknown@x.com", chars: availabilityChars())]
        )
        guard let cell = cell(in: vm.cellMatrix, dayOffset: 0, hour: 10) else { XCTFail(); return }
        XCTAssertEqual(cell.attendeeStatuses.first?.displayName, "unknown")
    }

    func testAttendeeDisplayNameUsesDraftEntryWhenPresent() {
        let alice = ResolvedAttendee(displayName: "Alice Doe", email: "alice@x.com", jobTitle: nil)
        let vm = makeVM(
            attendees: [alice],
            attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())]
        )
        guard let cell = cell(in: vm.cellMatrix, dayOffset: 0, hour: 10) else { XCTFail(); return }
        XCTAssertEqual(cell.attendeeStatuses.first?.displayName, "Alice Doe")
    }

    // MARK: - FreeSlot: позиция и score

    func test30MinuteFreeSlotHasSinglePositionAndCarriesScore() {
        let slot = makeFreeSlot(dayOffset: 0, hour: 10, durationMinutes: 30, score: 0.42)
        let vm = makeVM(
            attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())],
            freeSlots: [slot]
        )
        guard let c = cell(in: vm.cellMatrix, dayOffset: 0, hour: 10) else { XCTFail(); return }
        XCTAssertEqual(c.slotPosition, .single)
        XCTAssertNotNil(c.freeSlot)
        guard case let .free(score) = c.state else { XCTFail("expected .free state"); return }
        XCTAssertEqual(score, 0.42, accuracy: 0.001)
    }

    func test60MinuteFreeSlotSpansTwoRowsAsStartAndEnd() {
        let slot = makeFreeSlot(dayOffset: 0, hour: 10, durationMinutes: 60, score: 0.7)
        let vm = makeVM(
            attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())],
            freeSlots: [slot]
        )
        guard let start = cell(in: vm.cellMatrix, dayOffset: 0, hour: 10),
              let end   = cell(in: vm.cellMatrix, dayOffset: 0, hour: 10, minute: 30) else {
            XCTFail("expected both rows of 60-min slot"); return
        }
        XCTAssertEqual(start.slotPosition, .start)
        XCTAssertEqual(end.slotPosition, .end)
        XCTAssertNotNil(start.freeSlot)
        XCTAssertNotNil(end.freeSlot)
    }

    func test90MinuteFreeSlotSpansThreeRowsAsStartMiddleEnd() {
        let slot = makeFreeSlot(dayOffset: 0, hour: 10, durationMinutes: 90)
        let vm = makeVM(
            attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())],
            freeSlots: [slot]
        )
        XCTAssertEqual(cell(in: vm.cellMatrix, dayOffset: 0, hour: 10)?.slotPosition, .start)
        XCTAssertEqual(cell(in: vm.cellMatrix, dayOffset: 0, hour: 10, minute: 30)?.slotPosition, .middle)
        XCTAssertEqual(cell(in: vm.cellMatrix, dayOffset: 0, hour: 11)?.slotPosition, .end)
    }

    // MARK: - Третий проход: объединение последовательных занятых ячеек

    func testConsecutiveBusyCellsMergeIntoStartAndEndBlock() {
        // Два соседних busy получасовика 10:00–11:00 без FreeSlot.
        let idx1 = slotIndex(dayOffset: 0, hour: 10)
        let idx2 = slotIndex(dayOffset: 0, hour: 10, minute: 30)
        let chars = availabilityChars(overrides: [idx1: "2", idx2: "2"])
        let vm = makeVM(attendeeAvailabilities: [availability(email: "alice@x.com", chars: chars)])
        XCTAssertEqual(cell(in: vm.cellMatrix, dayOffset: 0, hour: 10)?.slotPosition, .start)
        XCTAssertEqual(cell(in: vm.cellMatrix, dayOffset: 0, hour: 10, minute: 30)?.slotPosition, .end)
    }

    func testThreeBusyCellsMergeIntoStartMiddleEndBlock() {
        let idxs = [
            slotIndex(dayOffset: 0, hour: 10),
            slotIndex(dayOffset: 0, hour: 10, minute: 30),
            slotIndex(dayOffset: 0, hour: 11),
        ]
        var overrides: [Int: Character] = [:]
        for i in idxs { overrides[i] = "2" }
        let vm = makeVM(
            attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars(overrides: overrides))]
        )
        XCTAssertEqual(cell(in: vm.cellMatrix, dayOffset: 0, hour: 10)?.slotPosition, .start)
        XCTAssertEqual(cell(in: vm.cellMatrix, dayOffset: 0, hour: 10, minute: 30)?.slotPosition, .middle)
        XCTAssertEqual(cell(in: vm.cellMatrix, dayOffset: 0, hour: 11)?.slotPosition, .end)
    }

    func testIsolatedBusyCellRemainsSinglePosition() {
        let idx = slotIndex(dayOffset: 0, hour: 10)
        let vm = makeVM(
            attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars(overrides: [idx: "2"]))]
        )
        XCTAssertEqual(cell(in: vm.cellMatrix, dayOffset: 0, hour: 10)?.slotPosition, .single)
    }

    func testBusyOfDifferentKindsDoNotMerge() {
        // Busy + tentative подряд — два разных kind, не сливаются в один блок.
        let idxBusy = slotIndex(dayOffset: 0, hour: 10)
        let idxTentative = slotIndex(dayOffset: 0, hour: 10, minute: 30)
        let overrides: [Int: Character] = [idxBusy: "2", idxTentative: "1"]
        let vm = makeVM(
            attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars(overrides: overrides))]
        )
        XCTAssertEqual(cell(in: vm.cellMatrix, dayOffset: 0, hour: 10)?.slotPosition, .single, "busy один")
        XCTAssertEqual(cell(in: vm.cellMatrix, dayOffset: 0, hour: 10, minute: 30)?.slotPosition, .single, "tentative один")
    }

    // MARK: - Мемоизация: cellMatrixComputeCount

    func testRepeatedReadsHitCacheWithoutRecomputing() {
        // Главная цель мемоизации: SwiftUI body может читать cellMatrix десятки раз
        // за рендер, и каждый hover вызывает новый рендер. Должен быть один пересчёт.
        let vm = makeVM(attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())])
        _ = vm.cellMatrix
        _ = vm.cellMatrix
        _ = vm.cellMatrix
        XCTAssertEqual(vm.cellMatrixComputeCount, 1, "повторные чтения должны брать из кэша")
    }

    func testTitleMutationDoesNotInvalidateCache() {
        let vm = makeVM(attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())])
        _ = vm.cellMatrix
        XCTAssertEqual(vm.cellMatrixComputeCount, 1)

        var d = vm.draft
        d.title = "New title"
        vm.draft = d
        _ = vm.cellMatrix
        XCTAssertEqual(vm.cellMatrixComputeCount, 1, "печать в title не должна дёргать пересчёт")
    }

    func testAgendaAndLocationMutationsDoNotInvalidateCache() {
        let vm = makeVM(attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())])
        _ = vm.cellMatrix
        XCTAssertEqual(vm.cellMatrixComputeCount, 1)

        var d = vm.draft
        d.agenda = "Discuss roadmap"
        d.location = "Room A"
        vm.draft = d
        _ = vm.cellMatrix
        XCTAssertEqual(vm.cellMatrixComputeCount, 1)
    }

    func testSelectedSlotMutationDoesNotInvalidateCache() {
        let slot = makeFreeSlot(dayOffset: 0, hour: 10)
        let vm = makeVM(
            attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())],
            freeSlots: [slot]
        )
        _ = vm.cellMatrix
        let before = vm.cellMatrixComputeCount

        vm.selectedSlot = slot
        _ = vm.cellMatrix
        XCTAssertEqual(vm.cellMatrixComputeCount, before, "выбор слота не должен дёргать пересчёт")
    }

    func testIsLoadingAndErrorMessageDoNotInvalidateCache() {
        let vm = makeVM(attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())])
        _ = vm.cellMatrix
        let before = vm.cellMatrixComputeCount

        vm.isLoadingSlots = true
        vm.errorMessage = "x"
        vm.successMessage = "y"
        _ = vm.cellMatrix
        XCTAssertEqual(vm.cellMatrixComputeCount, before)
    }

    func testAddingRequiredAttendeeInvalidatesCache() {
        let vm = makeVM(attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())])
        _ = vm.cellMatrix
        XCTAssertEqual(vm.cellMatrixComputeCount, 1)

        var d = vm.draft
        d.requiredAttendees.append(ResolvedAttendee(displayName: "Bob", email: "bob@x.com", jobTitle: nil))
        vm.draft = d
        _ = vm.cellMatrix
        XCTAssertEqual(vm.cellMatrixComputeCount, 2, "новый required участник должен инвалидировать кэш")
    }

    func testAddingOptionalAttendeeInvalidatesCache() {
        // Optional участники не влияют на закраску, но влияют на tooltip displayName — должны
        // инвалидировать кэш.
        let vm = makeVM(attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())])
        _ = vm.cellMatrix
        XCTAssertEqual(vm.cellMatrixComputeCount, 1)

        var d = vm.draft
        d.optionalAttendees.append(ResolvedAttendee(displayName: "Carol", email: "carol@x.com", jobTitle: nil))
        vm.draft = d
        _ = vm.cellMatrix
        XCTAssertEqual(vm.cellMatrixComputeCount, 2)
    }

    func testChangingSelectedWeekInvalidatesCache() {
        let vm = makeVM(attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())])
        _ = vm.cellMatrix

        var d = vm.draft
        d.selectedWeekStart = vm.draft.weekStartOffset(by: 1)
        vm.draft = d
        _ = vm.cellMatrix
        XCTAssertEqual(vm.cellMatrixComputeCount, 2, "смена недели должна инвалидировать кэш")
    }

    func testNewAvailabilityDataInvalidatesCache() {
        let vm = makeVM(attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())])
        _ = vm.cellMatrix

        let idx = slotIndex(dayOffset: 0, hour: 10)
        vm.attendeeAvailabilities = [availability(email: "alice@x.com", chars: availabilityChars(overrides: [idx: "2"]))]
        _ = vm.cellMatrix
        XCTAssertEqual(vm.cellMatrixComputeCount, 2)
        if case .busy = cell(in: vm.cellMatrix, dayOffset: 0, hour: 10)?.state {} else {
            XCTFail("cell должна перейти в .busy после обновления availability")
        }
    }

    func testNewFreeSlotsInvalidateCache() {
        let vm = makeVM(attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())])
        _ = vm.cellMatrix
        XCTAssertEqual(vm.cellMatrixComputeCount, 1)

        vm.freeSlots = [makeFreeSlot(dayOffset: 0, hour: 10, durationMinutes: 60)]
        _ = vm.cellMatrix
        XCTAssertEqual(vm.cellMatrixComputeCount, 2)
    }

    func testNewOrganizerEventsInvalidateCache() {
        let vm = makeVM(
            attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())],
            organizerAvailability: availability(email: "me@x.com", chars: availabilityChars())
        )
        _ = vm.cellMatrix
        XCTAssertEqual(vm.cellMatrixComputeCount, 1)

        vm.organizerEvents = [makeCalendarEvent(dayOffset: 0, startHour: 10, endHour: 11, title: "Standup")]
        _ = vm.cellMatrix
        XCTAssertEqual(vm.cellMatrixComputeCount, 2)
    }

    // MARK: - Optional attendees: tooltip-only surfacing

    func testOptionalAttendeeAppearsInOptionalStatusesButNotInRequired() {
        // Bob is optional, busy at Mon 10:00. He must appear in optionalAttendeeStatuses
        // and never in attendeeStatuses (which only carries required + organizer).
        let bob = ResolvedAttendee(displayName: "Bob", email: "bob@x.com", jobTitle: nil)
        let idx = slotIndex(dayOffset: 0, hour: 10)
        let vm = makeVM(
            optionalAttendees: [bob],
            attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())],
            optionalAvailabilities: [availability(email: "bob@x.com", chars: availabilityChars(overrides: [idx: "2"]))]
        )
        guard let c = cell(in: vm.cellMatrix, dayOffset: 0, hour: 10) else { XCTFail(); return }
        XCTAssertEqual(c.optionalAttendeeStatuses.count, 1)
        XCTAssertEqual(c.optionalAttendeeStatuses.first?.displayName, "Bob")
        XCTAssertEqual(c.optionalAttendeeStatuses.first?.rawChar, "2")
        XCTAssertFalse(c.attendeeStatuses.contains(where: { $0.displayName == "Bob" }), "необязательный не должен попасть в основной список")
    }

    func testOptionalAttendeeBusyDoesNotAffectCellState() {
        // Alice (required) is free, Bob (optional) is busy → cell colour must stay .free.
        // This is the invariant the user explicitly asked for: optional attendees never tint the grid.
        let bob = ResolvedAttendee(displayName: "Bob", email: "bob@x.com", jobTitle: nil)
        let idx = slotIndex(dayOffset: 0, hour: 10)
        let slot = makeFreeSlot(dayOffset: 0, hour: 10, score: 0.5)
        let vm = makeVM(
            optionalAttendees: [bob],
            attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())],
            optionalAvailabilities: [availability(email: "bob@x.com", chars: availabilityChars(overrides: [idx: "2"]))],
            freeSlots: [slot]
        )
        guard let c = cell(in: vm.cellMatrix, dayOffset: 0, hour: 10) else { XCTFail(); return }
        if case .free = c.state {} else { XCTFail("expected .free even with busy optional attendee, got \(c.state)") }
        XCTAssertNotNil(c.freeSlot, "слот всё ещё кликабелен — optional не блокирует выбор")
    }

    func testEmptyOptionalAvailabilitiesYieldEmptyOptionalStatuses() {
        // Без optional участников новое поле должно быть пустым массивом, а не nil/ошибкой.
        let vm = makeVM(attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())])
        guard let c = cell(in: vm.cellMatrix, dayOffset: 0, hour: 10) else { XCTFail(); return }
        XCTAssertTrue(c.optionalAttendeeStatuses.isEmpty)
    }

    func testOptionalStatusesPropagateThroughMultiRowFreeSlotPass() {
        // Второй проход в computeCellMatrix пересоздаёт CellAvailability для каждой строки
        // 60-/90-мин слота. Optional-статусы должны сохраняться во всех строках, иначе тултип
        // на верхней строке покажет «Опциональные», а на нижней — нет.
        let bob = ResolvedAttendee(displayName: "Bob", email: "bob@x.com", jobTitle: nil)
        let slot = makeFreeSlot(dayOffset: 0, hour: 10, durationMinutes: 60, score: 0.7)
        let vm = makeVM(
            optionalAttendees: [bob],
            attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())],
            optionalAvailabilities: [availability(email: "bob@x.com", chars: availabilityChars())],
            freeSlots: [slot]
        )
        guard let start = cell(in: vm.cellMatrix, dayOffset: 0, hour: 10),
              let end = cell(in: vm.cellMatrix, dayOffset: 0, hour: 10, minute: 30) else {
            XCTFail("expected both rows of 60-min slot"); return
        }
        XCTAssertEqual(start.slotPosition, .start)
        XCTAssertEqual(end.slotPosition, .end)
        XCTAssertEqual(start.optionalAttendeeStatuses.first?.displayName, "Bob", ".start строка теряет optional — регрессия второго прохода")
        XCTAssertEqual(end.optionalAttendeeStatuses.first?.displayName, "Bob", ".end строка теряет optional — регрессия второго прохода")
    }

    func testOptionalStatusesPropagateThroughMergedBusyBlockPass() {
        // Третий проход в computeCellMatrix объединяет соседние busy/tentative/OOF ячейки
        // в визуальный блок, пересоздавая CellAvailability. Optional-статусы должны выживать.
        let bob = ResolvedAttendee(displayName: "Bob", email: "bob@x.com", jobTitle: nil)
        let idx1 = slotIndex(dayOffset: 0, hour: 10)
        let idx2 = slotIndex(dayOffset: 0, hour: 10, minute: 30)
        let requiredChars = availabilityChars(overrides: [idx1: "2", idx2: "2"])
        let vm = makeVM(
            optionalAttendees: [bob],
            attendeeAvailabilities: [availability(email: "alice@x.com", chars: requiredChars)],
            optionalAvailabilities: [availability(email: "bob@x.com", chars: availabilityChars())]
        )
        guard let start = cell(in: vm.cellMatrix, dayOffset: 0, hour: 10),
              let end = cell(in: vm.cellMatrix, dayOffset: 0, hour: 10, minute: 30) else {
            XCTFail(); return
        }
        XCTAssertEqual(start.slotPosition, .start)
        XCTAssertEqual(end.slotPosition, .end)
        XCTAssertEqual(start.optionalAttendeeStatuses.first?.displayName, "Bob", "merged-busy блок теряет optional — регрессия третьего прохода")
        XCTAssertEqual(end.optionalAttendeeStatuses.first?.displayName, "Bob")
    }

    func testOptionalAvailabilityDataInvalidatesCache() {
        // Меняем только optionalAvailabilities — кэш обязан инвалидироваться, иначе тултип
        // покажет устаревшие статусы при обновлении ответа сервера.
        let vm = makeVM(attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())])
        _ = vm.cellMatrix
        XCTAssertEqual(vm.cellMatrixComputeCount, 1)

        vm.optionalAvailabilities = [availability(email: "carol@x.com", chars: availabilityChars())]
        _ = vm.cellMatrix
        XCTAssertEqual(vm.cellMatrixComputeCount, 2)
    }

    func testAttendeeReorderDoesNotInvalidateCache() {
        // cellMatrixSignature нормализует email-список (сортировка) — перестановка участников
        // не должна вызывать пересчёт.
        let alice = ResolvedAttendee(displayName: "Alice", email: "alice@x.com", jobTitle: nil)
        let bob = ResolvedAttendee(displayName: "Bob", email: "bob@x.com", jobTitle: nil)
        let vm = makeVM(
            attendees: [alice, bob],
            attendeeAvailabilities: [availability(email: "alice@x.com", chars: availabilityChars())]
        )
        _ = vm.cellMatrix
        XCTAssertEqual(vm.cellMatrixComputeCount, 1)

        var d = vm.draft
        d.requiredAttendees = [bob, alice]
        vm.draft = d
        _ = vm.cellMatrix
        XCTAssertEqual(vm.cellMatrixComputeCount, 1, "перестановка не должна инвалидировать")
    }

    // MARK: - Авто-триггер findSlots на init

    /// Регрессия на «зависание в плейсхолдере "Подбираем свободные слоты…"».
    /// Раньше первый findSlots ждал Combine-debounce 450 мс на RunLoop.main; под анимацию
    /// открытия окна на macOS RunLoop уходит в .tracking, и таймер в .default mode мог
    /// вообще не сработать. Фикс — явный `Task` в init. Если кто-то его уберёт обратно
    /// на чистую Combine-подписку, этот тест поймает регрессию.
    func testFindSlotsFiresImmediatelyOnInitWithoutWaitingForDebounce() async {
        let accountID = UUID()
        let provider = CountingAvailabilityProvider(accountID: accountID)
        let svc = CalendarService(
            providers: [provider],
            eventCacheStore: TestInMemoryEventCacheStore(snapshot: nil),
            notificationService: TestNoOpNotificationService(),
            customMeetingReminders: TestNoOpMeetingReminderController(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )
        let vm = CreateMeetingViewModel(calendarService: svc, accountID: accountID)

        // 150 мс — комфортно больше времени на Task hop + сетевые моки, но сильно меньше
        // 450 мс Combine-debounce. Если бы findSlots дёргался только подпиской, к этому
        // моменту он бы ещё не успел отстрелить.
        try? await Task.sleep(nanoseconds: 150_000_000)

        let calls = await provider.getUserAvailabilityCallCount
        XCTAssertEqual(calls, 1, "findSlots должен дёргаться один раз из явного Task в init")
        XCTAssertTrue(vm.slotsSearched, "после успешного findSlots плейсхолдер должен смениться на грид")
        XCTAssertFalse(vm.isLoadingSlots, "после успешного findSlots спиннер должен погаснуть")
    }

    /// Регрессия на двойной findSlots. Combine-подписка дропает первый эмит через
    /// `.dropFirst()`, чтобы инициальный fetch не дублировался с явным Task в init.
    /// Дополнительно проверяем, что мутация `draft.location` из recentLocations (которая
    /// эмитит $draft с тем же slotAutoRefreshKey) не приводит к лишнему findSlots —
    /// порядок `.removeDuplicates().dropFirst()` это гарантирует.
    func testInitDoesNotDoubleFireFindSlotsAfterDebounceWindow() async {
        let accountID = UUID()
        let provider = CountingAvailabilityProvider(accountID: accountID)
        let svc = CalendarService(
            providers: [provider],
            eventCacheStore: TestInMemoryEventCacheStore(snapshot: nil),
            notificationService: TestNoOpNotificationService(),
            customMeetingReminders: TestNoOpMeetingReminderController(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )
        let vm = CreateMeetingViewModel(calendarService: svc, accountID: accountID)

        // 700 мс — заведомо больше 450 мс debounce. Если порядок операторов сломан или
        // dropFirst убран, к этому моменту прилетит второй findSlots.
        try? await Task.sleep(nanoseconds: 700_000_000)

        let calls = await provider.getUserAvailabilityCallCount
        XCTAssertEqual(calls, 1, "после init должен быть ровно один findSlots, без дубля от Combine-подписки")
        XCTAssertTrue(vm.slotsSearched)
    }

    // MARK: - fitsDuration: грид помечает короткие свободные «дырки»

    /// Длительность 30 мин (slotsNeeded == 1) — проход пропускается, все свободные ячейки fits.
    func testFitsDurationTrueForAllFreeCellsAtThirtyMinutes() {
        let chars = availabilityChars(overrides: [slotIndex(dayOffset: 0, hour: 9, minute: 30): "2"])
        let vm = makeVM(attendeeAvailabilities: [availability(email: "a@x.com", chars: chars)])
        // duration по умолчанию 30
        let m = vm.cellMatrix
        XCTAssertEqual(cell(in: m, dayOffset: 0, hour: 9)?.fitsDuration, true,
                       "при 30 мин даже одиночная свободная ячейка помещается")
    }

    /// Длительность 1ч: ряд из 2 ячеек помещается, одиночная свободная ячейка — нет.
    func testFitsDurationOneHourMarksShortRun() {
        // 09:30 и 11:00 заняты → 09:00 одиночный (len1), 10:00–10:30 ряд (len2), 11:30+ длинный.
        let chars = availabilityChars(overrides: [
            slotIndex(dayOffset: 0, hour: 9, minute: 30): "2",
            slotIndex(dayOffset: 0, hour: 11, minute: 0): "2"
        ])
        let vm = makeVM(attendeeAvailabilities: [availability(email: "a@x.com", chars: chars)])
        var draft = vm.draft
        draft.durationMinutes = 60
        vm.draft = draft

        let m = vm.cellMatrix
        XCTAssertEqual(cell(in: m, dayOffset: 0, hour: 9)?.fitsDuration, false,
                       "одиночная свободная ячейка 09:00 — час не помещается")
        XCTAssertEqual(cell(in: m, dayOffset: 0, hour: 10)?.fitsDuration, true,
                       "ряд 10:00–11:00 (2 ячейки) — час помещается")
        XCTAssertEqual(cell(in: m, dayOffset: 0, hour: 10, minute: 30)?.fitsDuration, true)
        XCTAssertEqual(cell(in: m, dayOffset: 0, hour: 11, minute: 30)?.fitsDuration, true,
                       "длинный ряд после 11:00 помещает час")
    }

    /// Длительность 2ч (slotsNeeded == 4): ряды короче 4 ячеек помечаются как не вмещающие.
    func testFitsDurationTwoHoursMarksRunsShorterThanFour() {
        // 10:00 и 12:00 заняты → ряды [09:00–10:00]=2, [10:30–12:00]=3, [12:30–18:00]=long.
        let chars = availabilityChars(overrides: [
            slotIndex(dayOffset: 0, hour: 10, minute: 0): "2",
            slotIndex(dayOffset: 0, hour: 12, minute: 0): "2"
        ])
        let vm = makeVM(attendeeAvailabilities: [availability(email: "a@x.com", chars: chars)])
        var draft = vm.draft
        draft.durationMinutes = 120
        vm.draft = draft

        let m = vm.cellMatrix
        XCTAssertEqual(cell(in: m, dayOffset: 0, hour: 9)?.fitsDuration, false,
                       "ряд из 2 ячеек — 2ч не помещается")
        XCTAssertEqual(cell(in: m, dayOffset: 0, hour: 11)?.fitsDuration, false,
                       "ряд из 3 ячеек — 2ч не помещается")
        XCTAssertEqual(cell(in: m, dayOffset: 0, hour: 12, minute: 30)?.fitsDuration, true,
                       "длинный ряд после 12:00 помещает 2ч")
    }

    // MARK: - setDuration: растягивание выбранного слота

    func testSetDurationStretchesSelectedSlotFromStart() {
        let vm = makeVM()
        let slot = makeFreeSlot(dayOffset: 0, hour: 10, durationMinutes: 30)
        vm.selectedSlot = slot
        vm.setDuration(120)
        XCTAssertEqual(vm.draft.durationMinutes, 120)
        XCTAssertEqual(vm.selectedSlot?.start, slot.start, "старт сохраняется")
        XCTAssertEqual(vm.selectedSlot?.end, slot.start.addingTimeInterval(120 * 60),
                       "конец растягивается под новую длительность")
    }

    func testSetDurationSameValueIsNoOp() {
        let vm = makeVM()
        let slot = makeFreeSlot(dayOffset: 0, hour: 10, durationMinutes: 30)
        vm.selectedSlot = slot
        vm.setDuration(30)
        XCTAssertEqual(vm.selectedSlot?.end, slot.end, "та же длительность — слот не трогаем")
    }

    // MARK: - selectedSlotHasConflict

    func testSelectedSlotHasConflictWhenStartNotAmongFreeSlots() {
        let other = makeFreeSlot(dayOffset: 0, hour: 14, durationMinutes: 60)
        let vm = makeVM(freeSlots: [other])
        vm.selectedSlot = makeFreeSlot(dayOffset: 0, hour: 10, durationMinutes: 60)
        vm.slotsSearched = true
        vm.isLoadingSlots = false
        XCTAssertTrue(vm.selectedSlotHasConflict)
    }

    func testSelectedSlotNoConflictWhenStartMatchesFreeSlot() {
        // Конфликт определяется по старту окна, длина freeSlot роли не играет.
        let free = makeFreeSlot(dayOffset: 0, hour: 10, durationMinutes: 60)
        let vm = makeVM(freeSlots: [free])
        vm.selectedSlot = makeFreeSlot(dayOffset: 0, hour: 10, durationMinutes: 120)
        vm.slotsSearched = true
        vm.isLoadingSlots = false
        XCTAssertFalse(vm.selectedSlotHasConflict)
    }

    func testSelectedSlotNoConflictWhileLoading() {
        let vm = makeVM(freeSlots: [])
        vm.selectedSlot = makeFreeSlot(dayOffset: 0, hour: 10, durationMinutes: 60)
        vm.slotsSearched = true
        vm.isLoadingSlots = true
        XCTAssertFalse(vm.selectedSlotHasConflict, "во время загрузки конфликт не показываем")
    }
}

// MARK: - Test doubles

private final class TestInMemoryEventCacheStore: EventCacheStoring {
    var snapshot: EventCacheSnapshot?
    init(snapshot: EventCacheSnapshot?) { self.snapshot = snapshot }
    func load() -> EventCacheSnapshot? { snapshot }
    func save(events: [CalendarEvent], rangeStart: Date, rangeEnd: Date) {
        snapshot = EventCacheSnapshot(
            version: 1,
            savedAt: Date(),
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            events: events
        )
    }
    func clear() { snapshot = nil }
}

private actor TestNoOpNotificationService: NotificationServicing {
    func setup(localization: NotificationLocalization) {}
    func requestAuthorization() async {}
    func removeAllPendingMeetingNotifications() async {}
    func scheduleNotifications(
        for events: [CalendarEvent],
        leadMinutes: Int,
        localization: NotificationLocalization
    ) async {}
}

@MainActor
private final class TestNoOpMeetingReminderController: CustomMeetingReminderControlling {
    func cancelAll(closeActiveReminder: Bool) {}
    func reschedule(
        events: [CalendarEvent],
        leadMinutes: Int,
        localization: NotificationLocalization,
        sound: MeetingReminderSound
    ) {}
}

/// Считает вызовы getUserAvailability — proxy на findSlots() со стороны VM, поскольку
/// CalendarService.findFreeSlots всегда дёргает getUserAvailability, когда allEmails непуст
/// (организатор резолвится в `me@x.com`, так что allEmails ≥ 1).
private actor CountingAvailabilityProvider: CalendarProvider {
    let account: CalendarAccount
    private(set) var getUserAvailabilityCallCount = 0

    init(accountID: UUID) {
        self.account = CalendarAccount(
            id: accountID,
            displayName: "Test",
            serverURL: "example.com",
            email: "me@x.com"
        )
    }

    func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] { [] }
    func validateCredentials() async throws {}

    func resolveOrganizerSMTPEmail() async throws -> String? { "me@x.com" }

    func getUserAvailability(
        emails: [String],
        from start: Date,
        to end: Date
    ) async throws -> [AttendeeAvailability] {
        getUserAvailabilityCallCount += 1
        return []
    }
}
