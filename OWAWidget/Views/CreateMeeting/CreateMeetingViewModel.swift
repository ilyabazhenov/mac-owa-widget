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
    @Published var selectedSlotID: UUID? = nil
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

    /// Picker binding so `searchRange` changes reassign `draft` and trigger slot auto-refresh.
    var searchRangeBinding: Binding<MeetingSearchRange> {
        Binding(
            get: { self.draft.searchRange },
            set: { newValue in
                guard self.draft.searchRange != newValue else { return }
                var d = self.draft
                d.searchRange = newValue
                self.draft = d
            }
        )
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
            selectedSlotID = nil
            slotsSearched = false
            errorMessage = nil
            return
        }

        isLoadingSlots = true
        errorMessage = nil
        freeSlots = []
        selectedSlotID = nil
        slotsSearched = false

        let requiredEmails = draft.requiredAttendees.map(\.email)
        let optionalEmails = draft.optionalAttendees.map(\.email)
        let range = draft.searchRange.dateInterval
        let duration = draft.durationMinutes

        do {
            let slots = try await calendarService.findFreeSlots(
                requiredEmails: requiredEmails,
                optionalEmails: optionalEmails,
                range: range,
                durationMinutes: duration,
                accountID: accountID
            )
            guard gen == findSlotsGeneration else { return }
            freeSlots = slots
            selectedSlotID = slots.first?.id
            slotsSearched = true
        } catch {
            guard gen == findSlotsGeneration else { return }
            errorMessage = error.localizedDescription
            slotsSearched = true
        }

        if gen == findSlotsGeneration {
            isLoadingSlots = false
        }
    }

    // MARK: - Create

    func createMeeting() async {
        guard let slotID = selectedSlotID,
              let slot = freeSlots.first(where: { $0.id == slotID }),
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
}
