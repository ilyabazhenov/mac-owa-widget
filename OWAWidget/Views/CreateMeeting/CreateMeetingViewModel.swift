import Foundation
import Combine

@MainActor
final class CreateMeetingViewModel: ObservableObject {
    @Published var draft = MeetingDraft()
    @Published var searchQuery = ""
    @Published var searchResults: [ResolvedAttendee] = []
    @Published var isSearching = false
    @Published var freeSlots: [FreeSlot] = []
    @Published var selectedSlotID: UUID? = nil
    @Published var isLoadingSlots = false
    @Published var isCreating = false
    @Published var errorMessage: String? = nil
    @Published var successMessage: String? = nil
    @Published var slotsSearched = false
    @Published var recentAttendees: [ResolvedAttendee] = []

    var showDropdown: Bool { !searchResults.isEmpty }

    var suggestedAttendees: [ResolvedAttendee] { recentAttendees }

    var selectedDuration: MeetingDurationOption {
        get { MeetingDurationOption(rawValue: draft.durationMinutes) ?? .min30 }
        set { draft.durationMinutes = newValue.rawValue }
    }

    let calendarService: CalendarService
    let accountID: UUID

    private var cancellables = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>?

    /// Cap dropdown height and OWA result noise; full directory matches can be huge.
    private static let maxSearchDropdownResults = 10

    init(calendarService: CalendarService, accountID: UUID) {
        self.calendarService = calendarService
        self.accountID = accountID

        $searchQuery
            .removeDuplicates()
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] query in
                self?.scheduleSearch(query: query)
            }
            .store(in: &cancellables)

        recentAttendees = RecentAttendeesStore.load()
    }

    // MARK: - Search

    private func scheduleSearch(query: String) {
        searchTask?.cancel()
        guard query.count >= 2 else {
            searchResults = []
            return
        }
        searchTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { isSearching = false }
            do {
                let results = try await calendarService.findPeople(query: query, accountID: accountID)
                guard !Task.isCancelled, searchQuery == query else { return }
                searchResults = Array(
                    results
                        .filter { r in !draft.attendees.contains(r) }
                        .prefix(Self.maxSearchDropdownResults)
                )
            } catch is CancellationError {
                // normal — user typed more
            } catch {
                searchResults = []
                print("[CreateMeetingVM] findPeople error: \(error)")
            }
        }
    }

    func selectFirstResult() {
        guard let first = searchResults.first else { return }
        addAttendee(first)
    }

    // MARK: - Attendees

    func addAttendee(_ attendee: ResolvedAttendee) {
        guard !draft.attendees.contains(attendee) else { return }
        draft.attendees.append(attendee)
        searchTask?.cancel()
        searchQuery = ""
        searchResults = []
    }

    func removeAttendee(_ attendee: ResolvedAttendee) {
        draft.attendees.removeAll { $0 == attendee }
    }

    // MARK: - Slots

    func findSlots() async {
        guard !draft.attendees.isEmpty else { return }
        isLoadingSlots = true
        slotsSearched = false
        freeSlots = []
        selectedSlotID = nil
        errorMessage = nil
        defer { isLoadingSlots = false; slotsSearched = true }

        do {
            let slots = try await calendarService.findFreeSlots(
                emails: draft.attendees.map(\.email),
                range: draft.searchRange.dateInterval,
                durationMinutes: draft.durationMinutes,
                accountID: accountID
            )
            freeSlots = slots
            selectedSlotID = slots.first?.id
        } catch {
            errorMessage = error.localizedDescription
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
                slot: slot,
                attendees: draft.attendees,
                accountID: accountID
            )
            RecentAttendeesStore.record(draft.attendees)
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
