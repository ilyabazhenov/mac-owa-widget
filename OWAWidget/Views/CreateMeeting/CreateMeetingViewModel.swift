import Foundation
import Combine
import SwiftUI

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
    private var searchTask: Task<Void, Never>?
    /// Invalidates in-flight slot fetches when parameters change again.
    private var findSlotsGeneration = 0

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
        var d = draft
        d.attendees.append(attendee)
        draft = d
        searchTask?.cancel()
        searchQuery = ""
        searchResults = []
    }

    func removeAttendee(_ attendee: ResolvedAttendee) {
        var d = draft
        let before = d.attendees.count
        d.attendees.removeAll { $0 == attendee }
        guard d.attendees.count != before else { return }
        draft = d
    }

    // MARK: - Slots

    func findSlots() async {
        findSlotsGeneration += 1
        let gen = findSlotsGeneration

        guard !draft.attendees.isEmpty else {
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

        let emails = draft.attendees.map(\.email)
        let range = draft.searchRange.dateInterval
        let duration = draft.durationMinutes

        do {
            let slots = try await calendarService.findFreeSlots(
                emails: emails,
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
