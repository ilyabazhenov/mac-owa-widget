import Foundation
import Combine
import SwiftUI

@MainActor
final class CreateMeetingViewModel: ObservableObject {
    @Published var draft = MeetingDraft()

    // Two fully independent search states — one per attendee group.
    @Published var requiredQuery = ""
    @Published var requiredResults: [ResolvedAttendee] = []
    @Published var isRequiredSearching = false

    @Published var optionalQuery = ""
    @Published var optionalResults: [ResolvedAttendee] = []
    @Published var isOptionalSearching = false

    /// Which search field currently has keyboard focus — controls which dropdown is visible.
    @Published var focusedSearchKind: AttendeeKind? = nil

    @Published var freeSlots: [FreeSlot] = []
    @Published var attendeeAvailabilities: [AttendeeAvailability] = []
    @Published var selectedSlotID: UUID? = nil
    /// Слот, выбранный вручную на занятом/tentative времени (не из списка свободных).
    @Published var forcedSlot: FreeSlot? = nil
    @Published var isLoadingSlots = false
    @Published var isCreating = false
    @Published var errorMessage: String? = nil
    @Published var successMessage: String? = nil
    @Published var slotsSearched = false
    @Published var recentAttendees: [ResolvedAttendee] = []

    var suggestedAttendees: [ResolvedAttendee] { recentAttendees }

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

    var selectedDuration: MeetingDurationOption {
        get { MeetingDurationOption(rawValue: draft.durationMinutes) ?? .min30 }
        set {
            let newVal = newValue.rawValue
            guard draft.durationMinutes != newVal else { return }
            var d = draft
            d.durationMinutes = newVal
            draft = d
        }
    }

    /// Шаг навигации между неделями (positive = вперёд, negative = назад).
    /// Изменение `draft` запускает debounced auto-refresh слотов.
    func shiftSelectedWeek(by weeks: Int) {
        guard weeks != 0 else { return }
        var d = draft
        d.selectedWeekStart = d.weekStartOffset(by: weeks)
        draft = d
    }

    /// Переход на текущую неделю.
    func resetToCurrentWeek() {
        let monday = MeetingDraft.mondayOfWeek(containing: Date())
        guard MeetingDraft.weekCalendar.startOfDay(for: draft.selectedWeekStart) != monday else { return }
        var d = draft
        d.selectedWeekStart = monday
        draft = d
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

        guard !draft.requiredAttendees.isEmpty else {
            isLoadingSlots = false
            freeSlots = []
            attendeeAvailabilities = []
            selectedSlotID = nil
            forcedSlot = nil
            slotsSearched = false
            errorMessage = nil
            return
        }

        isLoadingSlots = true
        errorMessage = nil
        freeSlots = []
        attendeeAvailabilities = []
        selectedSlotID = nil
        forcedSlot = nil
        slotsSearched = false

        let requiredEmails = draft.requiredAttendees.map(\.email)
        let optionalEmails = draft.optionalAttendees.map(\.email)
        let range = draft.dateInterval()
        let duration = draft.durationMinutes

        do {
            let result = try await calendarService.findFreeSlots(
                requiredEmails: requiredEmails,
                optionalEmails: optionalEmails,
                range: range,
                durationMinutes: duration,
                accountID: accountID
            )
            guard gen == findSlotsGeneration else { return }
            freeSlots = result.slots
            attendeeAvailabilities = result.attendeeAvailability
            selectedSlotID = result.slots.first?.id
            slotsSearched = true
        } catch {
            guard gen == findSlotsGeneration else { return }
            attendeeAvailabilities = []
            errorMessage = error.localizedDescription
            slotsSearched = true
        }

        if gen == findSlotsGeneration {
            isLoadingSlots = false
        }
    }

    // MARK: - Create

    func selectForcedSlot(start: Date) {
        let end = start.addingTimeInterval(Double(draft.durationMinutes) * 60)
        let slot = FreeSlot(start: start, end: end, score: 0)
        forcedSlot = slot
        selectedSlotID = slot.id
    }

    private var effectiveSelectedSlot: FreeSlot? {
        guard let slotID = selectedSlotID else { return nil }
        if let slot = freeSlots.first(where: { $0.id == slotID }) { return slot }
        if let forced = forcedSlot, forced.id == slotID { return forced }
        return nil
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
                slot: slot,
                requiredAttendees: draft.requiredAttendees,
                optionalAttendees: draft.optionalAttendees,
                accountID: accountID
            )
            RecentAttendeesStore.record(draft.allAttendees)
            recentAttendees = RecentAttendeesStore.load()
            successMessage = "create.meeting.success"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var canCreate: Bool {
        !draft.title.trimmingCharacters(in: .whitespaces).isEmpty &&
        selectedSlotID != nil &&
        !isCreating
    }

    /// Полная матрица занятости: день → minuteKey (от полуночи) → ячейка.
    /// Рассчитывается из сырых данных attendeeAvailabilities + freeSlots.
    var cellMatrix: [Date: [Int: CellAvailability]] {
        guard !attendeeAvailabilities.isEmpty else { return [:] }
        let cal = AppTimeZone.calendar
        let intervalSec: TimeInterval = 30 * 60

        let nameLookup: [String: String] = Dictionary(
            uniqueKeysWithValues: draft.allAttendees.map { ($0.email, $0.displayName) }
        )
        let slotLookup: [Date: FreeSlot] = Dictionary(
            uniqueKeysWithValues: freeSlots.map { ($0.start, $0) }
        )

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

                var chars: [Character] = []
                var statusList: [AttendeeSlotStatus] = []

                for avail in attendeeAvailabilities {
                    let idx = Int(cellStart.timeIntervalSince(avail.windowStart) / intervalSec)
                    let freeBusyChars = Array(avail.mergedFreeBusy)
                    let ch: Character = (idx >= 0 && idx < freeBusyChars.count) ? freeBusyChars[idx] : "0"
                    chars.append(ch)
                    let displayName: String
                    if let name = nameLookup[avail.email] {
                        displayName = name
                    } else if let atIdx = avail.email.firstIndex(of: "@") {
                        displayName = String(avail.email[avail.email.startIndex..<atIdx])
                    } else {
                        displayName = avail.email
                    }
                    statusList.append(AttendeeSlotStatus(displayName: displayName, rawChar: ch))
                }

                var state = SlotAvailabilityState.aggregate(from: chars)
                let matchedSlot = slotLookup[cellStart]
                if case .free = state, let slot = matchedSlot {
                    state = .free(score: slot.score)
                }

                let cell = CellAvailability(state: state, attendeeStatuses: statusList, freeSlot: matchedSlot)
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
                        freeSlot: nil,
                        slotPosition: pos
                    )
                }
            }
        }

        return result
    }
}
