import Foundation
import Combine
import SwiftUI
import os.log

@MainActor
final class CreateMeetingViewModel: ObservableObject {
    private let log = Logger(subsystem: "com.owawidget", category: "CreateMeetingViewModel")

    @Published var draft = MeetingDraft() {
        didSet {
            // cellMatrix зависит только от подмножества draft (участники + неделя).
            // Печать в title/agenda/location не должна инвалидировать тяжёлый пересчёт.
            if oldValue.cellMatrixSignature != draft.cellMatrixSignature {
                cellMatrixDirty = true
            }
        }
    }

    // Two fully independent search states — one per attendee group.
    @Published var requiredQuery = ""
    @Published var requiredResults: [ResolvedAttendee] = []
    @Published var isRequiredSearching = false

    @Published var optionalQuery = ""
    @Published var optionalResults: [ResolvedAttendee] = []
    @Published var isOptionalSearching = false

    /// Which search field currently has keyboard focus — controls which dropdown is visible.
    @Published var focusedSearchKind: AttendeeKind? = nil

    @Published var freeSlots: [FreeSlot] = [] {
        didSet { cellMatrixDirty = true }
    }
    @Published var attendeeAvailabilities: [AttendeeAvailability] = [] {
        didSet { cellMatrixDirty = true }
    }
    @Published var optionalAvailabilities: [AttendeeAvailability] = [] {
        didSet { cellMatrixDirty = true }
    }
    @Published var organizerAvailability: AttendeeAvailability? = nil {
        didSet { cellMatrixDirty = true }
    }
    @Published var organizerEvents: [CalendarEvent] = [] {
        didSet { cellMatrixDirty = true }
    }
    @Published var selectedSlot: FreeSlot? = nil
    @Published var isLoadingSlots = false
    @Published var isCreating = false
    @Published var errorMessage: String? = nil
    @Published var successMessage: String? = nil
    @Published var slotsSearched = false
    @Published var recentAttendees: [AttendeeRecord] = []
    @Published var recentLocations: [LocationRecord] = []
    @Published var locationFocused = false

    var suggestedAttendees: [AttendeeRecord] { recentAttendees }

    var locationSuggestions: [LocationRecord] {
        guard !recentLocations.isEmpty else { return [] }
        let q = draft.location.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return Array(recentLocations.prefix(5)) }
        return Array(recentLocations.filter { $0.url.localizedCaseInsensitiveContains(q) }.prefix(5))
    }

    var showLocationDropdown: Bool {
        locationFocused && !locationSuggestions.isEmpty
    }

    func recordLocationIfNeeded() {
        let loc = draft.location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !loc.isEmpty else { return }
        RecentLocationsStore.record(loc)
        recentLocations = RecentLocationsStore.load()
    }

    func results(for kind: AttendeeKind) -> [ResolvedAttendee] {
        kind == .required ? requiredResults : optionalResults
    }

    func isSearching(for kind: AttendeeKind) -> Bool {
        kind == .required ? isRequiredSearching : isOptionalSearching
    }

    /// Only the focused field's dropdown is shown — typing in one field never overlays the other.
    func showDropdown(for kind: AttendeeKind) -> Bool {
        focusedSearchKind == kind && !results(for: kind).isEmpty
    }

    /// Шаг навигации между неделями (positive = вперёд, negative = назад).
    /// Изменение `draft` запускает debounced auto-refresh слотов.
    func shiftSelectedWeek(by weeks: Int) {
        guard weeks != 0 else { return }
        clearSlotResults(showSpinner: true)
        var d = draft
        d.selectedWeekStart = d.weekStartOffset(by: weeks)
        draft = d
    }

    /// Переход на текущую неделю.
    func resetToCurrentWeek() {
        let monday = MeetingDraft.mondayOfWeek(containing: Date())
        guard MeetingDraft.weekCalendar.startOfDay(for: draft.selectedWeekStart) != monday else { return }
        clearSlotResults(showSpinner: true)
        var d = draft
        d.selectedWeekStart = monday
        draft = d
    }

    /// Обнуляет все availability- и slot-данные. Единая точка правды: при добавлении нового
    /// @Published-поля для результатов поиска слотов добавлять сброс здесь, а не в каждом
    /// вызывающем методе.
    private func clearSlotResults(showSpinner: Bool) {
        isLoadingSlots = showSpinner
        freeSlots = []
        attendeeAvailabilities = []
        optionalAvailabilities = []
        organizerAvailability = nil
        organizerEvents = []
        selectedSlot = nil
    }

    /// True, если выбранная неделя — та, что содержит сегодня.
    var isOnCurrentWeek: Bool {
        let cal = MeetingDraft.weekCalendar
        let todayMonday = MeetingDraft.mondayOfWeek(containing: Date())
        return cal.startOfDay(for: draft.selectedWeekStart) == todayMonday
    }

    let calendarService: CalendarService
    let accountID: UUID

    private var cancellables = Set<AnyCancellable>()
    private var requiredSearchTask: Task<Void, Never>?
    private var optionalSearchTask: Task<Void, Never>?
    /// Invalidates in-flight slot fetches when parameters change again.
    private var findSlotsGeneration = 0

    /// Cap dropdown height and OWA result noise; full directory matches can be huge.
    private static let maxSearchDropdownResults = 10

    init(calendarService: CalendarService, accountID: UUID) {
        self.calendarService = calendarService
        self.accountID = accountID

        $requiredQuery
            .removeDuplicates()
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] query in
                self?.scheduleSearch(kind: .required, query: query)
            }
            .store(in: &cancellables)

        $optionalQuery
            .removeDuplicates()
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] query in
                self?.scheduleSearch(kind: .optional, query: query)
            }
            .store(in: &cancellables)

        $draft
            .map(\.slotAutoRefreshKey)
            .removeDuplicates()
            .debounce(for: .milliseconds(450), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.findSlots() }
            }
            .store(in: &cancellables)

        recentAttendees = RecentAttendeesStore.load()
        recentLocations = RecentLocationsStore.load()
        if draft.location.isEmpty, let last = recentLocations.first {
            draft.location = last.url
        }

        // Дебаунс на $draft подгрузит слоты через 450 мс — на это время placeholder
        // показывал бы пустую подсказку. Сразу включаем спиннер, чтобы UI не флешил.
        isLoadingSlots = true
    }

    // MARK: - Search

    private func scheduleSearch(kind: AttendeeKind, query: String) {
        cancelSearch(kind: kind)
        guard query.count >= 2 else {
            setResults([], kind: kind)
            return
        }
        let task = Task { @MainActor in
            guard !Task.isCancelled else { return }
            setSearching(true, kind: kind)
            defer { setSearching(false, kind: kind) }
            do {
                let people = try await calendarService.findPeople(query: query, accountID: accountID)
                guard !Task.isCancelled, currentQuery(for: kind) == query else { return }
                let filtered = Array(
                    people
                        .filter { r in !draft.allAttendees.contains(r) }
                        .prefix(Self.maxSearchDropdownResults)
                )
                setResults(filtered, kind: kind)
            } catch is CancellationError {
                // normal — user typed more
            } catch {
                setResults([], kind: kind)
                print("[CreateMeetingVM] findPeople error: \(error)")
            }
        }
        switch kind {
        case .required: requiredSearchTask = task
        case .optional: optionalSearchTask = task
        }
    }

    func selectFirstResult(kind: AttendeeKind) {
        guard let first = results(for: kind).first else { return }
        addAttendee(first, kind: kind)
    }

    private func currentQuery(for kind: AttendeeKind) -> String {
        kind == .required ? requiredQuery : optionalQuery
    }

    private func setResults(_ results: [ResolvedAttendee], kind: AttendeeKind) {
        switch kind {
        case .required: requiredResults = results
        case .optional: optionalResults = results
        }
    }

    private func setSearching(_ value: Bool, kind: AttendeeKind) {
        switch kind {
        case .required: isRequiredSearching = value
        case .optional: isOptionalSearching = value
        }
    }

    private func cancelSearch(kind: AttendeeKind) {
        switch kind {
        case .required: requiredSearchTask?.cancel()
        case .optional: optionalSearchTask?.cancel()
        }
    }

    // MARK: - Attendees

    func addAttendee(_ attendee: ResolvedAttendee, kind: AttendeeKind = .required) {
        guard !draft.allAttendees.contains(attendee) else { return }
        var d = draft
        switch kind {
        case .required: d.requiredAttendees.append(attendee)
        case .optional: d.optionalAttendees.append(attendee)
        }
        draft = d
        clearSearch(kind: kind)
        RecentAttendeesStore.record([attendee])
        recentAttendees = RecentAttendeesStore.load()
    }

    func clearSearch(kind: AttendeeKind) {
        cancelSearch(kind: kind)
        switch kind {
        case .required:
            requiredQuery = ""
            requiredResults = []
        case .optional:
            optionalQuery = ""
            optionalResults = []
        }
    }

    func removeAttendee(_ attendee: ResolvedAttendee) {
        var d = draft
        let beforeReq = d.requiredAttendees.count
        let beforeOpt = d.optionalAttendees.count
        d.requiredAttendees.removeAll { $0 == attendee }
        d.optionalAttendees.removeAll { $0 == attendee }
        guard d.requiredAttendees.count != beforeReq || d.optionalAttendees.count != beforeOpt else { return }
        draft = d
    }

    func toggleAttendeeKind(_ attendee: ResolvedAttendee) {
        var d = draft
        if let idx = d.requiredAttendees.firstIndex(where: { $0 == attendee }) {
            let item = d.requiredAttendees.remove(at: idx)
            d.optionalAttendees.append(item)
        } else if let idx = d.optionalAttendees.firstIndex(where: { $0 == attendee }) {
            let item = d.optionalAttendees.remove(at: idx)
            d.requiredAttendees.append(item)
        } else {
            return
        }
        draft = d
    }

    // MARK: - Slots

    func findSlots() async {
        findSlotsGeneration += 1
        let gen = findSlotsGeneration

        clearSlotResults(showSpinner: true)
        errorMessage = nil
        slotsSearched = false

        let requiredEmails = draft.requiredAttendees.map(\.email)
        let optionalEmails = draft.optionalAttendees.map(\.email)
        let range = draft.dateInterval()
        let displayRange = draft.slotGridWeekInterval()

        do {
            let result = try await calendarService.findFreeSlots(
                requiredEmails: requiredEmails,
                optionalEmails: optionalEmails,
                range: range,
                displayRange: displayRange,
                durationMinutes: 30,
                accountID: accountID
            )
            guard gen == findSlotsGeneration else { return }
            freeSlots = result.slots
            attendeeAvailabilities = result.attendeeAvailability
            optionalAvailabilities = result.optionalAvailability
            organizerAvailability = result.organizerAvailability
            organizerEvents = result.organizerEvents
            slotsSearched = true
        } catch {
            guard gen == findSlotsGeneration else { return }
            attendeeAvailabilities = []
            optionalAvailabilities = []
            organizerAvailability = nil
            organizerEvents = []
            errorMessage = error.localizedDescription
            slotsSearched = true
        }

        if gen == findSlotsGeneration {
            isLoadingSlots = false
        }
    }

    // MARK: - Create

    func selectSlot(start: Date, end: Date) {
        guard end > Date() else { return }
        selectedSlot = FreeSlot(start: start, end: end, score: 0)
    }

    // MARK: - Time picker bindings

    private func nextRoundedSlotStart() -> Date {
        let now = Date()
        let cal = AppTimeZone.calendar
        let minute = cal.component(.minute, from: now)
        let addMinutes = minute < 30 ? (30 - minute) : (60 - minute)
        return cal.date(byAdding: .minute, value: addMinutes, to: now) ?? now
    }

    var slotStartBinding: Binding<Date> {
        Binding(
            get: { self.selectedSlot?.start ?? self.nextRoundedSlotStart() },
            set: { newStart in
                let duration = self.selectedSlot.map { $0.end.timeIntervalSince($0.start) } ?? 1800
                let newEnd = newStart.addingTimeInterval(max(1800, duration))
                self.selectedSlot = FreeSlot(start: newStart, end: newEnd, score: 0)
                var d = self.draft
                d.selectedWeekStart = MeetingDraft.mondayOfWeek(containing: newStart)
                self.draft = d
            }
        )
    }

    var slotEndBinding: Binding<Date> {
        Binding(
            get: { self.selectedSlot?.end ?? self.nextRoundedSlotStart().addingTimeInterval(1800) },
            set: { newEnd in
                let start = self.selectedSlot?.start ?? self.nextRoundedSlotStart()
                guard newEnd > start else { return }
                self.selectedSlot = FreeSlot(start: start, end: newEnd, score: 0)
            }
        )
    }

    private var effectiveSelectedSlot: FreeSlot? { selectedSlot }

    func reset() {
        requiredSearchTask?.cancel()
        optionalSearchTask?.cancel()
        draft = MeetingDraft()
        requiredQuery = ""
        requiredResults = []
        isRequiredSearching = false
        optionalQuery = ""
        optionalResults = []
        isOptionalSearching = false
        focusedSearchKind = nil
        clearSlotResults(showSpinner: false)
        isCreating = false
        errorMessage = nil
        successMessage = nil
        slotsSearched = false
        locationFocused = false
    }

    func createMeeting() async {
        guard let slot = effectiveSelectedSlot,
              !draft.title.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }

        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        do {
            try await calendarService.createMeeting(
                title: draft.title,
                agenda: draft.agenda,
                location: draft.location,
                slot: slot,
                requiredAttendees: draft.requiredAttendees,
                optionalAttendees: draft.optionalAttendees,
                accountID: accountID
            )
            successMessage = "create.meeting.success"
        } catch {
            log.error("createMeeting UI error: \(error, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    var canCreate: Bool {
        !draft.title.trimmingCharacters(in: .whitespaces).isEmpty &&
        selectedSlot != nil &&
        !isCreating
    }

    // MARK: - cellMatrix: ленивая мемоизация

    /// Кэш матрицы. Невалиден, пока `cellMatrixDirty == true`.
    /// SwiftUI body читает `cellMatrix` много раз за рендер — без кэша каждый hover
    /// триггерил полный пересчёт (5 дней × 18 строк × N attendees × 3 прохода).
    private var cachedCellMatrix: [Date: [Int: CellAvailability]] = [:]
    private var cellMatrixDirty: Bool = true

    #if DEBUG
    /// Видимый только в тестах счётчик реальных пересчётов матрицы — нужен, чтобы
    /// доказать, что hover / selectedSlot / печать в title не дёргают пересчёт.
    private(set) var cellMatrixComputeCount = 0
    #endif

    /// Хотя бы один источник для отрисовки грида: required-список, организатор
    /// (availability или его события) или подсчитанные freeSlots. В self-only сценарии
    /// required может быть пуст, но organizerAvailability/events дают данные для отрисовки.
    private var hasAnyAvailabilityData: Bool {
        !attendeeAvailabilities.isEmpty
            || organizerAvailability != nil
            || !organizerEvents.isEmpty
            || !freeSlots.isEmpty
    }

    /// Полная матрица занятости: день → minuteKey (от полуночи) → ячейка.
    /// O(1) при чистом кэше; пересчитывается только при изменении входов.
    var cellMatrix: [Date: [Int: CellAvailability]] {
        if cellMatrixDirty {
            cachedCellMatrix = computeCellMatrix()
            cellMatrixDirty = false
        }
        return cachedCellMatrix
    }

    private func computeCellMatrix() -> [Date: [Int: CellAvailability]] {
        #if DEBUG
        cellMatrixComputeCount += 1
        #endif
        // Self-only бронирование: required может быть пуст, но если есть availability
        // организатора или его события — грид всё равно должен отрисовать свою занятость
        // и подсветить freeSlots, иначе пользователь не видит, какие окна свободны.
        guard hasAnyAvailabilityData else { return [:] }
        let cal = AppTimeZone.calendar
        let intervalSec: TimeInterval = 30 * 60

        let nameLookup: [String: String] = Dictionary(
            uniqueKeysWithValues: draft.allAttendees.map { ($0.email, $0.displayName) }
        )
        let slotLookup: [Date: FreeSlot] = Dictionary(
            uniqueKeysWithValues: freeSlots.map { ($0.start, $0) }
        )

        // Pre-decode mergedFreeBusy into [Character] once per attendee to avoid
        // re-allocating the array on every cell visit (5 days × 18 rows = 90 cells).
        let requiredChars: [(avail: AttendeeAvailability, chars: [Character])] =
            attendeeAvailabilities.map { ($0, Array($0.mergedFreeBusy)) }
        let optionalChars: [(avail: AttendeeAvailability, chars: [Character])] =
            optionalAvailabilities.map { ($0, Array($0.mergedFreeBusy)) }
        let organizerChars: [Character]? = organizerAvailability.map { Array($0.mergedFreeBusy) }

        func status(for avail: AttendeeAvailability, chars: [Character], at cellStart: Date) -> AttendeeSlotStatus {
            let idx = Int(cellStart.timeIntervalSince(avail.windowStart) / intervalSec)
            let ch: Character = (idx >= 0 && idx < chars.count) ? chars[idx] : "0"
            let displayName: String
            if let name = nameLookup[avail.email] {
                displayName = name
            } else if let atIdx = avail.email.firstIndex(of: "@") {
                displayName = String(avail.email[avail.email.startIndex..<atIdx])
            } else {
                displayName = avail.email
            }
            return AttendeeSlotStatus(displayName: displayName, rawChar: ch)
        }

        let days = draft.slotGridWeekInterval().weekdayColumnStartDates(calendar: cal)
        var result: [Date: [Int: CellAvailability]] = [:]

        for timeKey in stride(from: 9 * 60, to: 18 * 60, by: 30) {
            for day in days {
                guard let cellStart = cal.date(
                    bySettingHour: timeKey / 60,
                    minute: timeKey % 60,
                    second: 0,
                    of: day
                ) else { continue }

                // Required + organizer feed both the tooltip list AND the aggregated cell color.
                var chars: [Character] = []
                var statusList: [AttendeeSlotStatus] = []

                for pair in requiredChars {
                    let s = status(for: pair.avail, chars: pair.chars, at: cellStart)
                    chars.append(s.rawChar)
                    statusList.append(s)
                }

                if let orgAvail = organizerAvailability, let orgChars = organizerChars {
                    let idx = Int(cellStart.timeIntervalSince(orgAvail.windowStart) / intervalSec)
                    let ch: Character = (idx >= 0 && idx < orgChars.count) ? orgChars[idx] : "0"
                    chars.append(ch)
                    let cellEnd = cellStart.addingTimeInterval(intervalSec)
                    let conflictTitles = organizerEvents
                        .filter { ev in ev.startDate < cellEnd && ev.endDate > cellStart }
                        .map(\.title)
                    statusList.insert(AttendeeSlotStatus(displayName: "Вы", rawChar: ch, eventTitles: conflictTitles), at: 0)
                }

                // Optional attendees feed ONLY the tooltip — their chars are intentionally
                // excluded from the aggregation so cell color never reacts to their busyness.
                var optionalStatusList: [AttendeeSlotStatus] = []
                optionalStatusList.reserveCapacity(optionalChars.count)
                for pair in optionalChars {
                    optionalStatusList.append(status(for: pair.avail, chars: pair.chars, at: cellStart))
                }

                var state = SlotAvailabilityState.aggregate(from: chars)
                let matchedSlot = slotLookup[cellStart]
                if case .free = state, let slot = matchedSlot {
                    state = .free(score: slot.score)
                }

                let cell = CellAvailability(
                    state: state,
                    attendeeStatuses: statusList,
                    optionalAttendeeStatuses: optionalStatusList,
                    freeSlot: matchedSlot
                )
                if result[day] == nil { result[day] = [:] }
                result[day]?[timeKey] = cell
            }
        }

        // Второй проход: маркируем позиции строк для многострочных слотов.
        // Слот на 60 мин занимает 2 строки — первая получает .start, вторая .end.
        for slot in freeSlots {
            let n = max(1, Int((slot.end.timeIntervalSince(slot.start) / intervalSec).rounded()))
            guard n > 1 else { continue }
            let day = cal.startOfDay(for: slot.start)
            for i in 0..<n {
                let rowDate = slot.start.addingTimeInterval(Double(i) * intervalSec)
                let h = cal.component(.hour, from: rowDate)
                let m = cal.component(.minute, from: rowDate)
                let tk = h * 60 + m
                guard let existing = result[day]?[tk] else { continue }
                let pos: FreeSlotPosition = i == 0 ? .start : (i == n - 1 ? .end : .middle)
                result[day]?[tk] = CellAvailability(
                    state: .free(score: slot.score),
                    attendeeStatuses: existing.attendeeStatuses,
                    optionalAttendeeStatuses: existing.optionalAttendeeStatuses,
                    freeSlot: slot,
                    slotPosition: pos
                )
            }
        }

        // Третий проход: объединяем последовательные занятые/tentative/OOF ячейки в визуальные блоки.
        let sortedTimeKeys = Array(stride(from: 9 * 60, to: 18 * 60, by: 30))
        for day in days {
            guard result[day] != nil else { continue }

            var runs: [(kind: Int, keys: [Int])] = []
            var currentKind: Int? = nil
            var currentKeys: [Int] = []

            for tk in sortedTimeKeys {
                guard let cell = result[day]?[tk], cell.freeSlot == nil else {
                    if let k = currentKind, !currentKeys.isEmpty {
                        runs.append((kind: k, keys: currentKeys))
                    }
                    currentKind = nil
                    currentKeys = []
                    continue
                }
                let kind: Int
                switch cell.state {
                case .busy:        kind = 1
                case .tentative:   kind = 2
                case .outOfOffice: kind = 3
                case .free:        kind = 4
                }
                if kind == currentKind {
                    currentKeys.append(tk)
                } else {
                    if let k = currentKind, !currentKeys.isEmpty {
                        runs.append((kind: k, keys: currentKeys))
                    }
                    currentKind = kind
                    currentKeys = [tk]
                }
            }
            if let k = currentKind, !currentKeys.isEmpty {
                runs.append((kind: k, keys: currentKeys))
            }

            for run in runs where run.keys.count > 1 {
                for (i, tk) in run.keys.enumerated() {
                    guard let existing = result[day]?[tk] else { continue }
                    let pos: FreeSlotPosition = i == 0 ? .start : (i == run.keys.count - 1 ? .end : .middle)
                    result[day]?[tk] = CellAvailability(
                        state: existing.state,
                        attendeeStatuses: existing.attendeeStatuses,
                        optionalAttendeeStatuses: existing.optionalAttendeeStatuses,
                        freeSlot: nil,
                        slotPosition: pos
                    )
                }
            }
        }

        return result
    }
}
