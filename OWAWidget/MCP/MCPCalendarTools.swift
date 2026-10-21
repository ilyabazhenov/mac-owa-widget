import Foundation

/// The MCP tools, implemented over `CalendarService`: those that read the calendar (including
/// `match_event`, which tells which meeting a time was), `find_people`, `find_free_slots` and
/// `create_meeting`.
///
/// The calendar tools read the in-memory calendar: no network, no load on Exchange, except for
/// meeting details and periods beyond the sync window (start of day -7 days ... now +30 days),
/// which `list_events`, `get_schedule_stats`, `find_events_with_person` and `match_event` load on
/// demand through `MCPCalendarArchive`. Every answer says how fresh the synced data is
/// (`data_as_of`, `coverage`, `sync_state`), because `events` may come from a days-old disk cache
/// or survive a failed sync.
@MainActor
final class MCPCalendarTools {
    static let maxNetworkRequestsPerPersonSearch = 40
    static let maxBodyCharacters = 8_000
    /// TypeScript SDK clients give up on a request after 60 seconds: the user's answer has to
    /// come back well before that, or the meeting gets created for a call nobody awaits.
    static let confirmationTimeout: TimeInterval = 45
    /// A repeated identical `create_meeting` within this window is answered from the first one.
    /// Models retry after a timeout, and a duplicate meeting sends a second set of invitations.
    static let duplicateWindow: TimeInterval = 10 * 60
    static let onDemandDeadline: TimeInterval = 35
    static let maxAttendees = 100
    /// How long `create_meeting` waits for the user's own address before showing the panel
    /// anyway: the panel's 45 seconds and this must fit in the client's 60.
    static let ownDomainWaitForCreate: TimeInterval = 5
    static let ownDomainWaitForSearch: TimeInterval = 20
    /// `get_status` is called first and often: it does not hold the answer long for the address.
    static let ownAddressWaitForStatus: TimeInterval = 5
    /// The address book does not know the user's address: asking again soon will not help.
    static let ownDomainRetryInterval: TimeInterval = 10 * 60
    /// The lookup failed (no network, VPN down): retry soon, or the domain stays "unknown" for
    /// minutes after the connection is back.
    static let ownDomainErrorRetryInterval: TimeInterval = 60

    static let disabledMessage = "Access for AI assistants is turned off in OWA Widget (Settings → MCP). Ask the user to turn it on."

    private let calendarService: CalendarService
    private let accessGuard: MCPAccessGuard
    private let detailsCache: MCPEventDetailsCache
    private let archive: MCPCalendarArchive
    /// How long a call waits for meetings outside the sync window: clients give up after 60
    /// seconds, and find_events_with_person still loads attendee lists after this.
    private let onDemandDeadline: TimeInterval
    private let clock: () -> Date
    private let isEnabled: () -> Bool
    private let canCreateMeetings: () -> Bool
    private let confirmer: MCPMeetingConfirming
    /// Sends a meeting the user chose to edit to the New Meeting window.
    private let handOff: (MeetingDraftSeed) -> Void
    private let confirmationTimeout: TimeInterval
    private let timeZoneProvider: () -> TimeZone
    /// Names seen next to addresses in `find_people` answers, for the confirmation panel.
    private var namesByEmail: [String: String] = [:]
    private var recentCreations: [String: (date: Date, result: [String: JSONValue])] = [:]
    /// The user's own address per Exchange account, from Exchange: a DOMAIN\login sign-in does
    /// not tell it. A `nil` address is a failed lookup, not repeated before `retryAfter`.
    private var ownAddresses: [UUID: (email: String?, retryAfter: Date)] = [:]
    private var ownAddressLookups: [UUID: Task<String?, Never>] = [:]
    private var isCreatingMeeting = false

    init(
        calendarService: CalendarService,
        accessGuard: MCPAccessGuard? = nil,
        detailsCache: MCPEventDetailsCache = MCPEventDetailsCache(),
        archive: MCPCalendarArchive = MCPCalendarArchive(),
        onDemandDeadline: TimeInterval = MCPCalendarTools.onDemandDeadline,
        confirmer: MCPMeetingConfirming? = nil,
        handOff: @escaping (MeetingDraftSeed) -> Void = { MeetingDraftInbox.shared.deliver($0) },
        confirmationTimeout: TimeInterval = MCPCalendarTools.confirmationTimeout,
        clock: @escaping () -> Date = { Date() },
        timeZone: @escaping () -> TimeZone = { AppTimeZone.zone },
        isEnabled: @escaping () -> Bool = { true },
        canCreateMeetings: @escaping () -> Bool = { false }
    ) {
        self.calendarService = calendarService
        self.accessGuard = accessGuard ?? MCPAccessGuard(calendarService: calendarService, clock: clock)
        self.detailsCache = detailsCache
        self.archive = archive
        self.onDemandDeadline = onDemandDeadline
        self.confirmer = confirmer ?? MCPMeetingConfirmationController()
        self.handOff = handOff
        self.confirmationTimeout = confirmationTimeout
        self.clock = clock
        self.timeZoneProvider = timeZone
        self.isEnabled = isEnabled
        self.canCreateMeetings = canCreateMeetings
    }

    func call(name: String, arguments: [String: JSONValue], client: String? = nil) async -> MCPToolResult {
        guard isEnabled() else {
            return .failure(Self.disabledMessage)
        }
        let context = CallContext(now: clock(), coder: MCPDateCoder(timeZone: timeZoneProvider()))
        do {
            switch name {
            case "get_status": return await getStatus(context)
            case "get_current_and_next": return try getCurrentAndNext(arguments, context)
            case "list_events": return try await listEvents(arguments, context)
            case "get_schedule_stats": return try await getScheduleStats(arguments, context)
            case "find_events_with_person": return try await findEventsWithPerson(arguments, context)
            case "get_event_details": return try await getEventDetails(arguments, context)
            case "find_people": return try await findPeople(arguments, context)
            case "find_free_slots": return try await findFreeSlots(arguments, context)
            case "match_event": return try await matchEvent(arguments, context)
            case "create_meeting": return try await createMeeting(arguments, context, client: client)
            default: return .failure("Unknown tool: \(name)")
            }
        } catch let error as ArgumentError {
            return .failure(error.message)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - get_status

    private func getStatus(_ context: CallContext) async -> MCPToolResult {
        var result = commonFields(context)
        var accounts: [JSONValue] = []
        for account in calendarService.accounts {
            // `email` is the sign-in name: an address, or DOMAIN\login for some Exchange servers.
            let login = account.email.trimmingCharacters(in: .whitespacesAndNewlines)
            var email = Self.isEmailAddress(login) ? login : nil
            if email == nil, account.accountType == .owa {
                // Exchange knows the address behind DOMAIN\login. One request, shared with the
                // own-domain check of find_people and create_meeting, and remembered.
                email = await ownAddress(account, wait: Self.ownAddressWaitForStatus)
            }
            let name = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            // The name is whatever the user typed in Settings, often nothing.
            let fallbackName = login.isEmpty ? account.accountType.displayName : login
            var fields: [String: JSONValue] = [
                "account_id": .string(account.id.uuidString),
                "name": .string(name.isEmpty ? fallbackName : name),
                "type": .string(Self.accountTypeName(account.accountType)),
                // The user's own address tells them apart from the other attendees.
                "email": .optional(email),
            ]
            if email == nil || email?.caseInsensitiveCompare(login) != .orderedSame, !login.isEmpty {
                fields["login"] = .string(login)
            }
            if let userName = userName(account) { fields["user_name"] = .string(userName) }
            accounts.append(.object(fields))
        }
        result["accounts"] = .array(accounts)
        return .success(result)
    }

    /// The user's own name as other people see it: the organizer of the meetings the user
    /// organized. No request to Exchange; `nil` when the calendar has no such meeting.
    private func userName(_ account: CalendarAccount) -> String? {
        var counts: [String: Int] = [:]
        for event in calendarService.events where event.accountID == account.id && event.responseType == .organizer {
            guard let name = event.organizer?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            counts[name, default: 0] += 1
        }
        return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }

    /// The user's own address on the event's account, if already known: `get_event_details`
    /// does not wait for a lookup just to mark the user.
    private func knownOwnAddress(_ accountID: UUID) -> String? {
        if let account = calendarService.accounts.first(where: { $0.id == accountID }),
           Self.isEmailAddress(account.email.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return account.email.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ownAddresses[accountID]?.email
    }

    // MARK: - get_current_and_next

    private func getCurrentAndNext(_ arguments: [String: JSONValue], _ context: CallContext) throws -> MCPToolResult {
        let accountID = try optionalAccountID(arguments)
        let now = context.now
        let relevant = calendarService.events.filter {
            (accountID == nil || $0.accountID == accountID)
                && !$0.isEffectivelyCancelled
                && $0.responseType != .declined
        }
        let current = relevant
            .filter { !$0.isAllDay && NextMeetingGroupPolicy.isHappening($0, now: now) }
            .sorted { $0.startDate < $1.startDate }
        let next = NextMeetingGroupPolicy.upcomingGroup(from: relevant, now: now)
        let todayStart = context.coder.calendar.startOfDay(for: now)
        let tomorrowStart = context.coder.calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now
        let allDayToday = relevant.filter { $0.isAllDay && $0.startDate < tomorrowStart && $0.endDate > todayStart }

        var result = commonFields(context)
        result["current"] = .array(current.map { .object(eventFields($0, context)) })
        result["next"] = .array(next.map { .object(eventFields($0, context)) })
        result["all_day_today"] = .array(allDayToday.map { .object(eventFields($0, context)) })
        if current.isEmpty, let first = next.first {
            result["free_until"] = .string(context.coder.string(first.startDate))
        } else {
            result["free_until"] = .null
        }
        if let first = next.first {
            result["minutes_until_next"] = .int(Int64(max(0, first.startDate.timeIntervalSince(now)) / 60))
        }
        if next.isEmpty {
            result["note"] = "No upcoming meetings until the end of the available period (coverage.to)."
        }
        return .success(result)
    }

    // MARK: - list_events

    private func listEvents(_ arguments: [String: JSONValue], _ context: CallContext) async throws -> MCPToolResult {
        let todayStart = context.coder.calendar.startOfDay(for: context.now)
        let today = DateInterval(start: todayStart, end: context.coder.calendar.date(byAdding: .day, value: 1, to: todayStart) ?? context.now)
        let seriesID = arguments["series_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seriesID, seriesID.isEmpty { throw ArgumentError("`series_id` is empty; take it from another event's `series_id`") }
        // A series is asked for as a whole: every occurrence the calendar holds, not just today's.
        let defaultRange = seriesID == nil ? today : try requireCoverage()
        let resolved = try resolveRange(arguments, default: defaultRange, spanWhenOnlyFrom: .day, onDemand: true, context)
        let accountID = try optionalAccountID(arguments)
        let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let responses = try responseFilter(arguments["response"])
        let includeCancelled = try optionalBool(arguments, "include_cancelled") ?? false
        let includeAllDay = try optionalBool(arguments, "include_all_day") ?? true
        let limit = try optionalInt(arguments, "limit", range: 1...300) ?? 100
        let lookup = try await calendarEvents(for: resolved, accountID: accountID, context)

        let matching = lookup.events
            .filter { Self.overlaps($0, resolved.range) }
            .filter { accountID == nil || $0.accountID == accountID }
            .filter { includeCancelled || !$0.isEffectivelyCancelled }
            .filter { includeAllDay || !$0.isAllDay }
            .filter { responses.contains($0.responseType) }
            .filter { seriesID == nil || $0.seriesID == seriesID }
            .filter { event in
                guard let query, !query.isEmpty else { return true }
                return [event.title, event.location, event.organizer].contains {
                    $0?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
            }
            .sorted { ($0.startDate, $0.endDate) < ($1.startDate, $1.endDate) }

        var result = commonFields(context)
        result["range"] = rangeJSON(resolved, context)
        lookup.annotate(&result)
        result["events"] = .array(matching.prefix(limit).map { .object(eventFields($0, context)) })
        result["total"] = .int(Int64(matching.count))
        result["truncated"] = .bool(matching.count > limit)
        return .success(result)
    }

    // MARK: - get_schedule_stats

    private func getScheduleStats(_ arguments: [String: JSONValue], _ context: CallContext) async throws -> MCPToolResult {
        let calendar = context.coder.calendar
        let todayStart = calendar.startOfDay(for: context.now)
        // Current week, Monday to Sunday.
        let mondayOffset = (calendar.component(.weekday, from: todayStart) + 5) % 7
        let weekStart = calendar.date(byAdding: .day, value: -mondayOffset, to: todayStart) ?? todayStart
        let week = DateInterval(start: weekStart, end: calendar.date(byAdding: .day, value: 7, to: weekStart) ?? context.now)
        let resolved = try resolveRange(arguments, default: week, spanWhenOnlyFrom: .week, onDemand: true, context)
        let accountID = try optionalAccountID(arguments)

        var options = ScheduleStatsCalculator.Options()
        let workHours = try parseWorkHours(arguments)
        options.workStartMinute = workHours.startMinute
        options.workEndMinute = workHours.endMinute
        options.workDays = workHours.workDays
        options.minFocusMinutes = try optionalInt(arguments, "min_focus_minutes", range: 15...480) ?? 60
        options.countUnanswered = try optionalBool(arguments, "count_unanswered") ?? true

        let lookup = try await calendarEvents(for: resolved, accountID: accountID, context)
        let events = lookup.events.filter { accountID == nil || $0.accountID == accountID }
        let stats = ScheduleStatsCalculator.compute(events: events, range: resolved.range, calendar: calendar, options: options)
        let coder = context.coder

        var result = commonFields(context)
        result["range"] = rangeJSON(resolved, context)
        lookup.annotate(&result)
        result["totals"] = [
            "meeting_count": .int(Int64(stats.meetingCount)),
            "meeting_minutes": .int(Self.minutes(stats.meetingSeconds)),
            "work_minutes": .int(Self.minutes(stats.workSeconds)),
            "meeting_minutes_in_work_hours": .int(Self.minutes(stats.meetingSecondsInWorkHours)),
            "meeting_share_of_work_time": .double((stats.meetingShareOfWorkTime * 100).rounded() / 100),
            "overlap_count": .int(Int64(stats.overlapCount)),
            "all_day_count": .int(Int64(stats.allDayCount)),
            "focus_block_count": .int(Int64(stats.focusBlockCount)),
            "focus_minutes": .int(Self.minutes(stats.focusSeconds)),
        ]
        result["days"] = .array(stats.days.map { day in
            var fields: [String: JSONValue] = [
                "date": .string(coder.dayString(day.date)),
                "meeting_count": .int(Int64(day.meetingCount)),
                "meeting_minutes": .int(Self.minutes(day.meetingSeconds)),
                "work_minutes": .int(Self.minutes(day.workSeconds)),
                "longest_free_minutes_in_work_hours": .int(Self.minutes(day.longestFreeSecondsInWorkHours)),
                "back_to_back_count": .int(Int64(day.backToBackCount)),
                "first_start": day.firstStart.map { .string(coder.string($0)) } ?? .null,
                "last_end": day.lastEnd.map { .string(coder.string($0)) } ?? .null,
            ]
            if day.isPartial { fields["partial"] = true }
            return .object(fields)
        })
        result["overlaps"] = .array(stats.overlaps.map { overlap in
            [
                "event_ids": [.string(MCPEventID.short(overlap.firstID)), .string(MCPEventID.short(overlap.secondID))],
                "start": .string(coder.string(overlap.interval.start)),
                "end": .string(coder.string(overlap.interval.end)),
            ]
        })
        result["focus_blocks"] = .array(stats.focusBlocks.map { block in
            [
                "start": .string(coder.string(block.start)),
                "end": .string(coder.string(block.end)),
                "minutes": .int(Self.minutes(block.duration)),
            ]
        })
        result["options"] = [
            "work_start": .string(Self.hhmm(options.workStartMinute)),
            "work_end": .string(Self.hhmm(options.workEndMinute)),
            "work_days": .array(Self.weekdayOrder.filter { options.workDays.contains(Self.weekdays[$0]!) }.map(JSONValue.string)),
            "min_focus_minutes": .int(Int64(options.minFocusMinutes)),
            "count_unanswered": .bool(options.countUnanswered),
        ]
        return .success(result)
    }

    // MARK: - find_free_slots

    static let maxPeoplePerSlotSearch = 20

    private func findFreeSlots(_ arguments: [String: JSONValue], _ context: CallContext) async throws -> MCPToolResult {
        let required = try emailList(arguments, "required")
        guard !required.isEmpty else {
            throw ArgumentError("`required` needs at least one email address (find them with find_people)")
        }
        let optional = try emailList(arguments, "optional").filter { !required.contains($0) }
        guard required.count + optional.count <= Self.maxPeoplePerSlotSearch else {
            throw ArgumentError("At most \(Self.maxPeoplePerSlotSearch) people per search")
        }
        guard let duration = try optionalInt(arguments, "duration_minutes", range: 15...480) else {
            throw ArgumentError("`duration_minutes` is required, from 15 to 480")
        }
        let limit = try optionalInt(arguments, "limit", range: 1...50) ?? 10
        let workHours = try parseWorkHours(arguments)
        let account = try exchangeAccount(arguments)

        // Default: from now to the end of the 7th day. The past has no free slots.
        let calendar = context.coder.calendar
        let todayStart = calendar.startOfDay(for: context.now)
        let week = DateInterval(start: context.now, end: calendar.date(byAdding: .day, value: 7, to: todayStart) ?? context.now)
        let resolved = try resolveRange(arguments, default: week, spanWhenOnlyFrom: .week, context)
        let start = max(resolved.range.start, context.now)
        guard resolved.range.end > start else { throw ArgumentError("The period is in the past") }
        let range = DateInterval(start: start, end: resolved.range.end)

        // Free/busy, plus the user's own address on the first search.
        if let denial = accessGuard.permitRequest(count: 2) {
            return .failure(denial.message)
        }
        let search: (slots: [FreeSlot], attendeeAvailability: [AttendeeAvailability], optionalAvailability: [AttendeeAvailability], organizerAvailability: AttendeeAvailability?, organizerEvents: [CalendarEvent])
        do {
            await accessGuard.acquireSlot()
            defer { accessGuard.releaseSlot() }
            search = try await calendarService.findFreeSlots(
                requiredEmails: required,
                optionalEmails: optional,
                range: range,
                durationMinutes: duration,
                accountID: account.id,
                workHours: workHours,
                ignoreAttendeesWithoutData: true
            )
        } catch {
            accessGuard.report(error, context: "mcp.findFreeSlots")
            if let reason = MCPAccessGuard.blockReason(calendarService.syncStatus) {
                return .failure(reason)
            }
            return .failure("Exchange did not return free/busy: \(error.localizedDescription)")
        }

        var rows: [String: AttendeeAvailability] = [:]
        for row in search.attendeeAvailability + search.optionalAvailability {
            rows[row.email.lowercased()] = row
        }
        let withoutData = (required + optional).filter { email in
            rows[email].map(CalendarService.hasNoData) ?? true
        }
        let coder = context.coder

        var result = commonFields(context)
        result["range"] = rangeJSON(ResolvedRange(range: range, clipped: resolved.clipped), context)
        result["duration_minutes"] = .int(Int64(duration))
        result["slots"] = .array(search.slots.prefix(limit).map { slot in
            let busy = optional.filter { email in
                guard let row = rows[email], !CalendarService.hasNoData(row) else { return false }
                return Self.isBusy(row, from: slot.start, to: slot.end)
            }
            return [
                "start": .string(coder.string(slot.start)),
                "end": .string(coder.string(slot.end)),
                "optional_busy": .array(busy.map(JSONValue.string)),
            ]
        })
        result["total"] = .int(Int64(search.slots.count))
        result["truncated"] = .bool(search.slots.count > limit)
        result["attendees"] = .array((required.map { ($0, true) } + optional.map { ($0, false) }).map { email, isRequired in
            [
                "email": .string(email),
                "name": .optional(knownName(email)),
                "required": .bool(isRequired),
                "availability": .string(withoutData.contains(email) ? "no_data" : "ok"),
            ]
        })
        result["options"] = [
            "work_start": .string(Self.hhmm(workHours.startMinute)),
            "work_end": .string(Self.hhmm(workHours.endMinute)),
            "work_days": .array(Self.weekdayOrder.filter { workHours.workDays.contains(Self.weekdays[$0]!) }.map(JSONValue.string)),
        ]
        if !withoutData.isEmpty {
            result["note"] = .string(
                "Exchange has no calendar for \(withoutData.joined(separator: ", ")) (outside the organization or no access): the slots do not take them into account. Tell the user."
            )
        } else if search.slots.isEmpty {
            result["note"] = "No time when everyone is free in this period and these working hours. Try a longer period, a shorter meeting or wider working hours."
        }
        return .success(result)
    }

    /// Any tentative, busy or out-of-office interval of `row` inside [start, end).
    static func isBusy(_ row: AttendeeAvailability, from start: Date, to end: Date) -> Bool {
        let chars = Array(row.mergedFreeBusy)
        let interval = TimeInterval(row.intervalMinutes * 60)
        var t = start
        while t < end {
            let index = Int(t.timeIntervalSince(row.windowStart) / interval)
            if index >= 0, index < chars.count, "123".contains(chars[index]) { return true }
            t = t.addingTimeInterval(interval)
        }
        return false
    }

    // MARK: - find_events_with_person

    private enum Direction: String { case past, upcoming, both }

    private struct PersonHit {
        let event: CalendarEvent
        let match: EventPersonMatcher.Match
    }

    private func findEventsWithPerson(_ arguments: [String: JSONValue], _ context: CallContext) async throws -> MCPToolResult {
        guard let person = arguments["person"]?.stringValue, let matcher = EventPersonMatcher(query: person) else {
            throw ArgumentError("`person` is required: a name (any word order) or an email address")
        }
        let coverage = try requireCoverage()
        let resolved = try resolveRange(arguments, default: coverage, spanWhenOnlyFrom: nil, onDemand: true, context)
        let accountID = try optionalAccountID(arguments)
        let directionText = arguments["direction"]?.stringValue ?? Direction.both.rawValue
        guard let direction = Direction(rawValue: directionText) else {
            throw ArgumentError("`direction` must be past, upcoming or both")
        }
        let limit = try optionalInt(arguments, "limit", range: 1...20) ?? 5
        let includeTitles = try optionalBool(arguments, "include_title_matches") ?? true
        let includeSkipped = try optionalBool(arguments, "include_declined_and_cancelled") ?? false

        let now = context.now
        let lookup = try await calendarEvents(for: resolved, accountID: accountID, context)
        let inRange = lookup.events
            .filter { Self.overlaps($0, resolved.range) }
            .filter { accountID == nil || $0.accountID == accountID }
        // A declined or cancelled meeting is not "the last time we met", as in the other tools.
        let candidates = includeSkipped
            ? inRange
            : inRange.filter { !$0.isEffectivelyCancelled && $0.responseType != .declined }
        // Nearest first on both sides, so "when did we last meet" is answered by a few requests.
        let past = candidates.filter { $0.startDate < now }.sorted { $0.startDate > $1.startDate }
        let upcoming = candidates.filter { $0.startDate >= now }.sorted { $0.startDate < $1.startDate }

        // An address query can only match an organizer (sync knows organizers by name) through
        // names already seen next to that address in a participant list. Skipped meetings still
        // tell which name goes with the address.
        var knownNames = Set<String>()
        if matcher.isEmailQuery {
            for event in inRange {
                for attendee in localAttendees(event) ?? [] where matcher.matchesPerson(name: nil, email: attendee.email) {
                    knownNames.insert(EventPersonMatcher.normalizedName(attendee.name))
                }
            }
        }

        var sides: [(events: [CalendarEvent], index: Int, hits: [PersonHit], done: Bool, unchecked: Int)] = []
        if direction != .upcoming { sides.append((past, 0, [], false, 0)) }
        if direction != .past { sides.append((upcoming, 0, [], false, 0)) }

        var networkUsed = 0
        var blockedReason: String?
        var stopNetwork = false

        while sides.contains(where: { !$0.done }) {
            for s in sides.indices where !sides[s].done {
                if sides[s].index >= sides[s].events.count || sides[s].hits.count >= limit {
                    sides[s].done = true
                    continue
                }
                let event = sides[s].events[sides[s].index]
                var attendees = localAttendees(event)

                if attendees == nil, needsNetworkForAttendees(event), !organizerMatches(event, matcher, knownNames) {
                    if stopNetwork || networkUsed >= Self.maxNetworkRequestsPerPersonSearch {
                        // Stop this side here: answering past an unchecked meeting could report a
                        // later "last time" than the real one.
                        sides[s].unchecked += sides[s].events[sides[s].index...].filter {
                            localAttendees($0) == nil && needsNetworkForAttendees($0)
                        }.count
                        sides[s].done = true
                        continue
                    }
                    networkUsed += 1
                    switch await loadAttendeesAndBody(event) {
                    case .available(let loaded, _, _):
                        attendees = loaded
                    case .unavailable(let reason, let stop):
                        if stop {
                            stopNetwork = true
                            blockedReason = reason
                            continue // retried by the branch above, which then marks the side unchecked
                        }
                        // One meeting failed to load: judge it by organizer and title only.
                        sides[s].unchecked += 1
                    }
                }

                sides[s].index += 1
                if let match = personMatch(event, attendees: attendees, matcher: matcher, knownNames: &knownNames, includeTitles: includeTitles) {
                    sides[s].hits.append(PersonHit(event: event, match: match))
                }
            }
        }

        let pastHits = direction != .upcoming ? sides[0].hits : []
        let upcomingHits = direction == .upcoming ? sides[0].hits : (direction == .both ? sides[1].hits : [])
        let unchecked = sides.reduce(0) { $0 + $1.unchecked }

        var result = commonFields(context)
        result["range"] = rangeJSON(resolved, context)
        lookup.annotate(&result)
        result["past"] = .array(pastHits.map { hitJSON($0, context) })
        result["upcoming"] = .array(upcomingHits.map { hitJSON($0, context) })
        result["partial"] = .bool(unchecked > 0)
        result["unchecked_count"] = .int(Int64(unchecked))
        result["detail_requests_made"] = .int(Int64(networkUsed))
        if let blockedReason { result["blocked_reason"] = .string(blockedReason) }
        if unchecked > 0, blockedReason == nil {
            result["note"] = "Some meetings were not checked yet. Call again to continue: already checked meetings are cached."
        }

        // Several different people answered to the name: let the model ask which one.
        if !matcher.isEmailQuery {
            var people: [String: (name: String, email: String?, count: Int)] = [:]
            for hit in pastHits + upcomingHits where hit.match.role != .title {
                let key = hit.match.email?.lowercased() ?? EventPersonMatcher.normalizedName(hit.match.name ?? "")
                let entry = people[key] ?? (hit.match.name ?? "", hit.match.email, 0)
                people[key] = (entry.name, entry.email, entry.count + 1)
            }
            let withEmail = people.values.filter { $0.email != nil }
            if withEmail.count > 1 {
                result["ambiguous_people"] = .array(withEmail.sorted { $0.count > $1.count }.map {
                    ["name": .string($0.name), "email": .optional($0.email), "meetings": .int(Int64($0.count))]
                })
            }
        }
        return .success(result)
    }

    private func personMatch(
        _ event: CalendarEvent,
        attendees: [EventAttendee]?,
        matcher: EventPersonMatcher,
        knownNames: inout Set<String>,
        includeTitles: Bool
    ) -> EventPersonMatcher.Match? {
        if let attendees {
            for attendee in attendees {
                if let match = matcher.match(attendee: attendee) {
                    knownNames.insert(EventPersonMatcher.normalizedName(attendee.name))
                    return match
                }
            }
        }
        if organizerMatches(event, matcher, knownNames) {
            return EventPersonMatcher.Match(role: .organizer, name: event.organizer, email: matcher.email)
        }
        if includeTitles, matcher.matchesTitle(event.title) {
            return EventPersonMatcher.Match(role: .title, name: nil, email: nil)
        }
        return nil
    }

    private func organizerMatches(_ event: CalendarEvent, _ matcher: EventPersonMatcher, _ knownNames: Set<String>) -> Bool {
        !event.isOrganizer && matcher.matchesOrganizer(event.organizer, knownNames: knownNames)
    }

    private func hitJSON(_ hit: PersonHit, _ context: CallContext) -> JSONValue {
        var fields = eventFields(hit.event, context)
        fields["match"] = .string(hit.match.role.rawValue)
        if hit.match.role != .title {
            fields["matched_person"] = ["name": .optional(hit.match.name), "email": .optional(hit.match.email)]
        }
        return .object(fields)
    }

    // MARK: - get_event_details

    private func getEventDetails(_ arguments: [String: JSONValue], _ context: CallContext) async throws -> MCPToolResult {
        guard let handle = arguments["event_id"]?.stringValue, !handle.isEmpty else {
            throw ArgumentError("`event_id` is required (take it from list_events)")
        }
        guard let event = MCPEventID.resolve(handle, in: calendarService.events)
            ?? MCPEventID.resolve(handle, in: archive.allEvents) else {
            return .failure("Event \(handle) not found. It may have been removed, or the calendar was refreshed — call list_events again.")
        }

        var result = commonFields(context)
        result.merge(eventFields(event, context)) { _, new in new }
        result["join_url"] = .optional(event.joinURLForActions?.absoluteString)

        switch await loadAttendeesAndBody(event) {
        case .available(let attendees, let body, let source):
            let own = knownOwnAddress(event.accountID)
            result["attendees"] = .array(attendees.map { attendee in
                var fields: [String: JSONValue] = [
                    "name": .string(attendee.name),
                    "email": .optional(attendee.email),
                    "kind": .string(attendee.kind.rawValue),
                    "response": .string(Self.responseName(attendee.response)),
                ]
                if let own, attendee.email?.caseInsensitiveCompare(own) == .orderedSame {
                    fields["is_you"] = true
                }
                return .object(fields)
            })
            let text = (body ?? event.displayBody)?.trimmingCharacters(in: .whitespacesAndNewlines)
            setBody(text, into: &result)
            result["details_source"] = .string(source)
            // The details just loaded may be the first to carry a one-off meeting's UID.
            if result["ical_uid"] == nil, let uid = calendarService.events.first(where: { $0.id == event.id })?.icalUID
                ?? detailsCache.entry(for: event)?.icalUID {
                result["ical_uid"] = .string(uid)
            }
        case .unavailable(let reason, _):
            setBody(event.displayBody, into: &result)
            result["details_unavailable_reason"] = .string(reason)
        }
        return .success(result)
    }

    private func setBody(_ text: String?, into result: inout [String: JSONValue]) {
        guard let text, !text.isEmpty else {
            result["body"] = .null
            return
        }
        if text.count > Self.maxBodyCharacters {
            result["body"] = .string(String(text.prefix(Self.maxBodyCharacters)))
            result["body_truncated"] = true
        } else {
            result["body"] = .string(text)
        }
    }

    // MARK: - find_people

    static let maxPeopleQueries = 10

    private func findPeople(_ arguments: [String: JSONValue], _ context: CallContext) async throws -> MCPToolResult {
        let (queries, isBatch) = try peopleQueries(arguments)
        let limit = try optionalInt(arguments, "limit", range: 1...25) ?? 10
        let account = try exchangeAccount(arguments)

        // The whole batch is paid for up front: a half-done batch would leave the model guessing
        // which names were never looked up.
        let cost = queries.reduce(0) { $0 + Self.findPeopleRequestCost($1) }
        if let denial = accessGuard.permitRequest(count: cost) {
            return .failure(denial.message)
        }
        var outcomes: [(query: String, people: [ResolvedAttendee]?, error: String?)] = []
        for query in queries {
            do {
                await accessGuard.acquireSlot()
                defer { accessGuard.releaseSlot() }
                let people = try await calendarService.findPeople(query: query, accountID: account.id)
                outcomes.append((query, people, nil))
            } catch {
                accessGuard.report(error, context: "mcp.findPeople")
                if let reason = MCPAccessGuard.blockReason(calendarService.syncStatus) {
                    return .failure(reason)
                }
                outcomes.append((query, nil, "Address book search failed: \(error.localizedDescription)"))
            }
        }

        let own = await ownAddress(account, wait: Self.ownDomainWaitForSearch)
        let ownDomain = own.flatMap(Self.domain(of:))
        let personJSON = { (person: ResolvedAttendee) -> JSONValue in
            var fields: [String: JSONValue] = [
                "name": .string(person.displayName),
                "email": .string(person.email),
                // Unknown rather than a confident `false` when the own domain is unknown.
                "external": ownDomain == nil ? .null : .bool(Self.isExternal(person.email, ownDomain: ownDomain)),
            ]
            if let own, person.email.caseInsensitiveCompare(own) == .orderedSame {
                // Namesakes are common: without this the model cannot tell which one is the user.
                fields["is_you"] = true
            }
            if let title = person.jobTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                fields["job_title"] = .string(title)
            }
            return .object(fields)
        }
        for person in outcomes.flatMap({ $0.people ?? [] }) where !person.displayName.isEmpty {
            namesByEmail[person.email.lowercased()] = person.displayName
        }

        var result = commonFields(context)
        if !isBatch, let single = outcomes.first {
            guard let people = single.people else { return .failure(single.error ?? "Address book search failed") }
            result["people"] = .array(people.prefix(limit).map(personJSON))
            result["total"] = .int(Int64(people.count))
            result["truncated"] = .bool(people.count > limit)
            return .success(result)
        }
        result["results"] = .array(outcomes.map { outcome in
            var group: [String: JSONValue] = ["query": .string(outcome.query)]
            if let people = outcome.people {
                group["people"] = .array(people.prefix(limit).map(personJSON))
                group["total"] = .int(Int64(people.count))
                group["truncated"] = .bool(people.count > limit)
            } else {
                group["error"] = .string(outcome.error ?? "Address book search failed")
            }
            return .object(group)
        })
        return .success(result)
    }

    /// `query` or `queries`, exactly one; `queries` comes back de-duplicated, in order.
    private func peopleQueries(_ arguments: [String: JSONValue]) throws -> (queries: [String], isBatch: Bool) {
        let hasQuery = arguments["query"].map { $0 != .null } ?? false
        let hasQueries = arguments["queries"].map { $0 != .null } ?? false
        guard hasQuery != hasQueries else {
            throw ArgumentError("Pass either `query` (one name) or `queries` (several), not both and not neither")
        }
        let tooShort = "needs at least 2 characters: a name, a surname or an email address"
        if hasQuery {
            let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard query.count >= 2 else { throw ArgumentError("`query` \(tooShort)") }
            return ([query], false)
        }
        guard let array = arguments["queries"]?.arrayValue else {
            throw ArgumentError("`queries` must be an array of names or email addresses")
        }
        var seen = Set<String>()
        var queries: [String] = []
        for item in array {
            guard let text = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), text.count >= 2 else {
                throw ArgumentError("Every item of `queries` \(tooShort), got \(item)")
            }
            if seen.insert(text.lowercased()).inserted { queries.append(text) }
        }
        guard !queries.isEmpty else { throw ArgumentError("`queries` is empty") }
        guard queries.count <= Self.maxPeopleQueries else {
            throw ArgumentError("At most \(Self.maxPeopleQueries) names per call, got \(queries.count)")
        }
        return (queries, true)
    }

    // MARK: - create_meeting

    private func createMeeting(_ arguments: [String: JSONValue], _ context: CallContext, client: String?) async throws -> MCPToolResult {
        guard canCreateMeetings() else {
            return .failure(
                "Creating meetings is turned off in OWA Widget (Settings → MCP → \"Allow creating meetings\"). Nothing was created. Ask the user to turn it on."
            )
        }
        let title = arguments["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty, title.count <= 255 else { throw ArgumentError("`title` is required, up to 255 characters") }
        let start = try requiredDateTime(arguments, "start", context)
        let end = try requiredDateTime(arguments, "end", context)
        guard end > start else { throw ArgumentError("`end` must be later than `start`") }
        guard end.timeIntervalSince(start) <= 24 * 3600 else { throw ArgumentError("A meeting can last at most 24 hours") }
        guard start > context.now else { throw ArgumentError("`start` is in the past (now is \(context.coder.string(context.now)))") }
        guard start < context.now.addingTimeInterval(366 * 86400) else { throw ArgumentError("`start` is more than a year ahead") }
        let required = try emailList(arguments, "required")
        let optional = try emailList(arguments, "optional").filter { !required.contains($0) }
        guard required.count + optional.count <= Self.maxAttendees else {
            throw ArgumentError("At most \(Self.maxAttendees) attendees")
        }
        let location = arguments["location"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard location.count <= 255 else { throw ArgumentError("`location` is limited to 255 characters") }
        let agenda = MCPMeetingTextPolicy.normalizedAgenda(arguments["agenda"]?.stringValue ?? "")
        guard agenda.count <= Self.maxBodyCharacters else {
            throw ArgumentError("`agenda` is limited to \(Self.maxBodyCharacters) characters")
        }
        for (name, text) in [("title", title), ("location", location), ("agenda", agenda)]
        where MCPMeetingTextPolicy.containsBidiControls(text) {
            throw ArgumentError(
                "`\(name)` contains bidirectional control characters (U+202A–U+202E, U+2066–U+2069), "
                    + "which make text display differently from what is sent. Remove them."
            )
        }
        let account = try exchangeAccount(arguments)

        let key = [
            account.id.uuidString, context.coder.string(start), context.coder.string(end), title.lowercased(),
            required.sorted().joined(separator: ","), optional.sorted().joined(separator: ","),
        ].joined(separator: "|")
        recentCreations = recentCreations.filter { context.now.timeIntervalSince($0.value.date) < Self.duplicateWindow }
        if let earlier = recentCreations[key] {
            var result = earlier.result
            result["duplicate"] = true
            result["note"] = "This exact meeting was already created a few minutes ago; nothing new was sent."
            return .success(result)
        }
        guard !isCreatingMeeting else {
            return .failure("Another meeting is waiting for the user's answer in OWA Widget. Wait for that call to finish before asking again.")
        }
        if let reason = MCPAccessGuard.blockReason(calendarService.syncStatus) {
            return .failure(reason)
        }
        isCreatingMeeting = true
        defer { isCreatingMeeting = false }

        let ownDomain = await ownMailDomain(account, wait: Self.ownDomainWaitForCreate)
        let attendee = { (email: String) in
            MCPMeetingProposal.Attendee(email: email, name: self.knownName(email), isExternal: Self.isExternal(email, ownDomain: ownDomain))
        }
        let conflicts = calendarService.events
            .filter {
                $0.accountID == account.id && !$0.isAllDay && !$0.isEffectivelyCancelled
                    && $0.responseType != .declined && $0.startDate < end && $0.endDate > start
            }
            .sorted { $0.startDate < $1.startDate }
        let proposal = MCPMeetingProposal(
            title: title,
            start: start,
            end: end,
            required: required.map(attendee),
            optional: optional.map(attendee),
            location: location,
            agenda: agenda,
            conflicts: conflicts.map { .init(title: $0.title, start: $0.startDate, end: $0.endDate) },
            client: client ?? "",
            externalCheckAvailable: ownDomain != nil
        )

        switch await confirmer.confirm(proposal, timeout: confirmationTimeout) {
        case .confirmed:
            break
        case .rejected:
            return .failure("The user declined in OWA Widget. Nothing was created; do not retry unless the user asks.")
        case .handedOff:
            // Not an error: models retry errors, and this one is settled — the user took over.
            handOff(MeetingDraftSeed(proposal: proposal, accountID: account.id))
            var result = commonFields(context)
            result["created"] = false
            result["handed_off"] = true
            result["note"] = "The user chose to finish this meeting in OWA Widget's New Meeting window: they may change the time, attendees or text and send it themselves. Nothing has been sent yet. Do not call create_meeting for it again. You will not learn whether it gets created; if asked, check list_events after the next sync."
            recentCreations[key] = (context.now, result)
            return .success(result)
        case .timedOut:
            return .failure("The user did not answer in OWA Widget within \(Int(confirmationTimeout)) seconds. Nothing was created; ask the user whether to try again.")
        case .cancelled:
            return .failure("The request was cancelled. Nothing was created.")
        }

        // Past "Create" the request must finish even if the client cancels now: a half-sent
        // CreateItem would leave the user unsure whether invitations went out.
        let service = calendarService
        let toResolved = { (people: [MCPMeetingProposal.Attendee]) in
            people.map { ResolvedAttendee(displayName: $0.name ?? $0.email, email: $0.email, jobTitle: nil) }
        }
        let creation = Task { @MainActor in
            try await service.createMeeting(
                title: title,
                agenda: RichText(plain: agenda),
                location: location,
                slot: FreeSlot(start: start, end: end),
                requiredAttendees: toResolved(proposal.required),
                optionalAttendees: toResolved(proposal.optional),
                accountID: account.id
            )
        }
        do {
            try await creation.value
        } catch {
            MCPDebugLog.log("create_meeting failed: \(error.localizedDescription)")
            return .failure(
                "Exchange did not confirm the meeting: \(error.localizedDescription). It may still have been created: check list_events after the next sync before trying again."
            )
        }

        var result = commonFields(context)
        result["created"] = true
        result["title"] = .string(title)
        result["start"] = .string(context.coder.string(start))
        result["end"] = .string(context.coder.string(end))
        result["account_id"] = .string(account.id.uuidString)
        result["required"] = .array(required.map(JSONValue.string))
        result["optional"] = .array(optional.map(JSONValue.string))
        result["invitations_sent"] = .bool(!(required.isEmpty && optional.isEmpty))
        result["note"] = "Created in Exchange. It appears in list_events after the next sync, within a few minutes."
        recentCreations[key] = (context.now, result)
        return .success(result)
    }

    /// Only Exchange creates meetings and searches the address book. With one Exchange account
    /// `account_id` may be left out.
    private func exchangeAccount(_ arguments: [String: JSONValue]) throws -> CalendarAccount {
        let exchange = calendarService.accounts.filter { $0.accountType == .owa }
        if let id = try optionalAccountID(arguments) {
            guard let account = calendarService.accounts.first(where: { $0.id == id }) else {
                throw ArgumentError("Unknown `account_id`; take one from get_status")
            }
            guard account.accountType == .owa else {
                throw ArgumentError("Only Exchange accounts (type `exchange` in get_status) support this")
            }
            return account
        }
        switch exchange.count {
        case 1: return exchange[0]
        case 0: throw ArgumentError("No Exchange account is connected in OWA Widget")
        default: throw ArgumentError("Several Exchange accounts are connected: pass `account_id` from get_status")
        }
    }

    /// The user's own mail domain, waiting at most `wait` for the address lookup.
    private func ownMailDomain(_ account: CalendarAccount, wait: TimeInterval) async -> String? {
        await ownAddress(account, wait: wait).flatMap(Self.domain(of:))
    }

    /// The user's own address, waiting at most `wait` for a lookup in flight. A lookup that
    /// outlives the wait keeps running and fills the cache for the next call.
    private func ownAddress(_ account: CalendarAccount, wait: TimeInterval) async -> String? {
        if let cached = ownAddresses[account.id], cached.email != nil || clock() < cached.retryAfter {
            return cached.email
        }
        let lookup = ownAddressLookups[account.id] ?? startOwnAddressLookup(account)
        return await withTaskGroup(of: String??.self) { group in
            group.addTask { .some(await lookup.value) }
            group.addTask {
                try? await Task.sleep(for: .seconds(wait))
                return .none
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }

    /// One Exchange request, counted against the budget and reported to the circuit breaker
    /// like any other MCP request.
    private func startOwnAddressLookup(_ account: CalendarAccount) -> Task<String?, Never> {
        let task = Task { @MainActor [weak self] () -> String? in
            guard let self else { return nil }
            defer { self.ownAddressLookups[account.id] = nil }
            if accessGuard.permitRequest() != nil {
                return nil
            }
            await accessGuard.acquireSlot()
            defer { accessGuard.releaseSlot() }
            do {
                let found = try await calendarService.ownEmail(accountID: account.id)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let email = found.flatMap { Self.isEmailAddress($0) ? $0 : nil }
                ownAddresses[account.id] = (email, clock().addingTimeInterval(Self.ownDomainRetryInterval))
                return email
            } catch {
                accessGuard.report(error, context: "mcp.ownEmail")
                ownAddresses[account.id] = (nil, clock().addingTimeInterval(Self.ownDomainErrorRetryInterval))
                return nil
            }
        }
        ownAddressLookups[account.id] = task
        return task
    }

    /// `OWAClient.findPeople` searches the whole query and, when that finds nobody, each word
    /// of two or more letters again.
    static func findPeopleRequestCost(_ query: String) -> Int {
        let words = query.split(whereSeparator: \.isWhitespace).filter { $0.count >= 2 }
        return words.count >= 2 ? 1 + words.count : 1
    }

    /// From `find_people`, else from attendee lists already loaded.
    private func knownName(_ email: String) -> String? {
        if let name = namesByEmail[email] { return name }
        for event in calendarService.events {
            for attendee in localAttendees(event) ?? [] where attendee.email?.lowercased() == email {
                if !attendee.name.isEmpty { return attendee.name }
            }
        }
        return nil
    }

    /// `work_start`, `work_end`, `work_days`, shared by get_schedule_stats and find_free_slots.
    private func parseWorkHours(_ arguments: [String: JSONValue]) throws -> MeetingFreeSlotCalculator.WorkHours {
        var hours = MeetingFreeSlotCalculator.WorkHours.standard
        if let text = arguments["work_start"]?.stringValue {
            guard let minute = MCPDateCoder.minuteOfDay(text) else { throw ArgumentError("`work_start` must be HH:mm") }
            hours.startMinute = minute
        }
        if let text = arguments["work_end"]?.stringValue {
            guard let minute = MCPDateCoder.minuteOfDay(text) else { throw ArgumentError("`work_end` must be HH:mm") }
            hours.endMinute = minute
        }
        guard hours.endMinute > hours.startMinute else {
            throw ArgumentError("`work_end` must be later than `work_start`")
        }
        if let days = arguments["work_days"] {
            guard let array = days.arrayValue else { throw ArgumentError("`work_days` must be an array like [\"mon\", \"tue\"]") }
            hours.workDays = try Set(array.map { value in
                guard let name = value.stringValue?.lowercased(), let weekday = Self.weekdays[name] else {
                    throw ArgumentError("Unknown day in `work_days`; use mon, tue, wed, thu, fri, sat, sun")
                }
                return weekday
            })
        }
        return hours
    }

    private func requiredDateTime(_ arguments: [String: JSONValue], _ key: String, _ context: CallContext) throws -> Date {
        guard let text = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw ArgumentError("`\(key)` is required: an ISO 8601 date-time")
        }
        // A bare date would silently mean midnight.
        guard text.count > 10, let date = context.coder.parse(text, as: .start) else {
            throw ArgumentError("Invalid `\(key)`: use an ISO 8601 date-time such as 2026-10-06T15:00")
        }
        return date
    }

    private func emailList(_ arguments: [String: JSONValue], _ key: String) throws -> [String] {
        guard let value = arguments[key], value != .null else { return [] }
        guard let array = value.arrayValue else { throw ArgumentError("`\(key)` must be an array of email addresses") }
        var seen = Set<String>()
        return try array.compactMap { item in
            guard let text = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  Self.isEmailAddress(text), MCPMeetingTextPolicy.isPlainASCIIAddress(text) else {
                throw ArgumentError("`\(key)` must hold email addresses (find them with find_people), got \(item)")
            }
            return seen.insert(text).inserted ? text : nil
        }
    }

    static func isEmailAddress(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else { return false }
        return !text.contains(where: { $0.isWhitespace || "<>,;\"()[]\\".contains($0) })
    }

    static func domain(of email: String) -> String? {
        email.split(separator: "@").last.map { $0.lowercased() }
    }

    /// Outside the user's own domain, or a subdomain of it. Unknown own domain: not flagged.
    static func isExternal(_ email: String, ownDomain: String?) -> Bool {
        guard let ownDomain, let domain = domain(of: email) else { return false }
        return domain != ownDomain && !domain.hasSuffix("." + ownDomain)
    }

    // MARK: - Details loading

    private enum DetailsOutcome {
        case available(attendees: [EventAttendee], body: String?, source: String)
        /// `stop`: no further detail requests should be attempted in this call.
        case unavailable(reason: String, stop: Bool)
    }

    // MARK: - match_event

    /// Exchange attendee lists are loaded for at most this many candidates, best by time first.
    static let matchAttendeeLoads = 5
    static let maxMatchParticipants = 30

    private func matchEvent(_ arguments: [String: JSONValue], _ context: CallContext) async throws -> MCPToolResult {
        let start = try requiredDateTime(arguments, "start", context)
        let hasEnd = arguments["end"].map { $0 != .null } ?? false
        let duration = try optionalInt(arguments, "duration_minutes", range: 1...1440)
        guard !(hasEnd && duration != nil) else { throw ArgumentError("Pass `end` or `duration_minutes`, not both") }
        var end = start
        if hasEnd {
            end = try requiredDateTime(arguments, "end", context)
            guard end > start else { throw ArgumentError("`end` must be later than `start`") }
            guard end.timeIntervalSince(start) <= 24 * 3600 else { throw ArgumentError("The interval can be at most 24 hours") }
        } else if let duration {
            end = start.addingTimeInterval(TimeInterval(duration * 60))
        }
        let participants = try nameList(arguments, "participants")
        let hint = arguments["title_hint"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountID = try optionalAccountID(arguments)
        let limit = try optionalInt(arguments, "limit", range: 1...10) ?? 3

        // The meetings around the interval, loaded on demand when it is outside the sync window.
        let around = DateInterval(
            start: start.addingTimeInterval(-MeetingMatchScorer.slack),
            end: max(end, start).addingTimeInterval(MeetingMatchScorer.slack)
        )
        let reach = try onDemandReach(context)
        guard start < reach.end, end >= reach.start else {
            return .failure(
                "\(context.coder.string(start)) is outside the calendar data OWA Widget can read (\(context.coder.string(reach.start)) to \(context.coder.string(reach.end))). Nothing can be matched there; do not guess."
            )
        }
        let resolved = try clip(around, onDemand: true, context)
        let lookup = try await calendarEvents(for: resolved, accountID: accountID, context)
        // Outside the sync window with no calendar read there, "no candidates" would be a guess.
        let coverage = try requireCoverage()
        if !(start < coverage.end && end >= coverage.start), !lookup.attempted.isEmpty,
           lookup.unavailable.count == lookup.attempted.count {
            return .failure(
                "Could not load the calendar around \(context.coder.string(start)): \(lookup.unavailable.map(\.reason).joined(separator: "; ")) Nothing can be matched there; do not guess."
            )
        }

        let events = lookup.events.filter { accountID == nil || $0.accountID == accountID }
        let byTime = MeetingMatchScorer.candidates(events, start: start, end: end)
            .map { (event: $0, time: MeetingMatchScorer.timeScore(event: $0, start: start, end: end)) }
            .sorted { $0.time > $1.time }

        // Attendees: free where already known, a request each for the likeliest Exchange meetings.
        var attendees: [String: [EventAttendee]] = [:]
        var attendeesNote: String?
        if !participants.isEmpty {
            var loads = 0
            for candidate in byTime {
                let event = candidate.event
                if let known = localAttendees(event) {
                    attendees[event.id] = known
                    continue
                }
                guard attendeesNote == nil, loads < Self.matchAttendeeLoads, needsNetworkForAttendees(event) else { continue }
                loads += 1
                switch await loadAttendeesAndBody(event) {
                case .available(let list, _, _):
                    attendees[event.id] = list
                case .unavailable(let reason, let stop):
                    if stop { attendeesNote = reason }
                }
            }
        }

        let scored = byTime.map { candidate -> (event: CalendarEvent, score: Double, match: MeetingMatchScorer.ParticipantMatch?, title: Double?) in
            let event = candidate.event
            let match = attendees[event.id].map {
                MeetingMatchScorer.matchParticipants(participants, attendees: $0, organizer: event.organizer)
            }
            let participantScore = match.flatMap { match -> Double? in
                let total = match.matched.count + match.unmatched.count
                return total > 0 ? Double(match.matched.count) / Double(total) : nil
            }
            let title = hint.flatMap { MeetingMatchScorer.titleScore(hint: $0, title: event.title) }
            let components = MeetingMatchScorer.Components(time: candidate.time, participants: participantScore, title: title)
            return (event, MeetingMatchScorer.score(components, event: event), match, title)
        }
        .sorted { ($0.score, $1.event.startDate) > ($1.score, $0.event.startDate) }

        let verdict = MeetingMatchScorer.confidence(scores: scored.map(\.score))
        var result = commonFields(context)
        result["interval"] = [
            "start": .string(context.coder.string(start)),
            "end": .string(context.coder.string(end)),
        ]
        result["candidates"] = .array(scored.prefix(limit).map { candidate in
            var fields = eventFields(candidate.event, context)
            fields["score"] = .double(candidate.score)
            fields["overlap_minutes"] = .int(Int64(MeetingMatchScorer.overlapMinutes(event: candidate.event, start: start, end: end)))
            fields["start_offset_minutes"] = .int(Int64((candidate.event.startDate.timeIntervalSince(start) / 60).rounded()))
            if !participants.isEmpty {
                if let match = candidate.match {
                    fields["matched_participants"] = .array(match.matched.map(JSONValue.string))
                    fields["unmatched_participants"] = .array(match.unmatched.map(JSONValue.string))
                } else {
                    fields["attendees_unknown"] = true
                }
            }
            if let title = candidate.title { fields["title_match"] = .double((title * 100).rounded() / 100) }
            return .object(fields)
        })
        result["total_candidates"] = .int(Int64(scored.count))
        result["confidence"] = .string(scored.isEmpty ? "none" : verdict.confidence.rawValue)
        result["ambiguous"] = .bool(verdict.ambiguous)
        if let attendeesNote { result["attendees_note"] = .string(attendeesNote) }
        lookup.annotate(&result)
        return .success(result)
    }

    /// Names or addresses, de-duplicated, at most `maxMatchParticipants`.
    private func nameList(_ arguments: [String: JSONValue], _ key: String) throws -> [String] {
        guard let value = arguments[key], value != .null else { return [] }
        guard let array = value.arrayValue else { throw ArgumentError("`\(key)` must be an array of names or email addresses") }
        var seen = Set<String>()
        var names: [String] = []
        for item in array {
            guard let text = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw ArgumentError("`\(key)` must hold names or email addresses, got \(item)")
            }
            if !text.isEmpty, seen.insert(text.lowercased()).inserted { names.append(text) }
        }
        guard names.count <= Self.maxMatchParticipants else {
            throw ArgumentError("At most \(Self.maxMatchParticipants) names in `\(key)`")
        }
        return names
    }

    /// Attendees known without a request: EventKit events arrive with them, Exchange ones only
    /// after a `GetCalendarEvent`.
    private func localAttendees(_ event: CalendarEvent) -> [EventAttendee]? {
        event.detailedAttendees ?? detailsCache.entry(for: event)?.attendees
    }

    private func needsNetworkForAttendees(_ event: CalendarEvent) -> Bool {
        // Cancelled and all-day entries are almost never what the question is about, and would
        // eat the request budget.
        guard !event.isEffectivelyCancelled, !event.isAllDay else { return false }
        return calendarService.accountType(for: event.accountID) == .owa
    }

    private func loadAttendeesAndBody(_ event: CalendarEvent) async -> DetailsOutcome {
        if let attendees = event.detailedAttendees {
            let local = calendarService.accountType(for: event.accountID) == .eventKit
            return .available(attendees: attendees, body: event.fullBody, source: local ? "local" : "cache")
        }
        if let cached = detailsCache.entry(for: event) {
            return .available(attendees: cached.attendees, body: cached.body, source: "cache")
        }
        if let denial = accessGuard.permitRequest() {
            return .unavailable(reason: denial.message, stop: true)
        }
        await accessGuard.acquireSlot()
        defer { accessGuard.releaseSlot() }
        do {
            let details = try await calendarService.loadDetails(for: event)
            detailsCache.store(details, for: event)
            return .available(attendees: details.attendees, body: details.body, source: "network")
        } catch {
            accessGuard.report(error)
            if case CalendarProviderError.notSupported = error {
                return .unavailable(reason: "This calendar does not provide meeting details.", stop: false)
            }
            if let reason = MCPAccessGuard.blockReason(calendarService.syncStatus) {
                return .unavailable(reason: reason, stop: true)
            }
            MCPDebugLog.log("details request failed: \(error.localizedDescription)")
            return .unavailable(reason: "Could not load meeting details: \(error.localizedDescription)", stop: false)
        }
    }

    // MARK: - Shared fields

    private struct CallContext {
        let now: Date
        let coder: MCPDateCoder
    }

    private struct ResolvedRange {
        let range: DateInterval
        let clipped: Bool
        /// The parts of `range` outside the sync window, loaded on demand.
        var outside: [DateInterval] = []
        var note: String? = nil
    }

    private enum DefaultSpan { case day, week }

    struct ArgumentError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private func commonFields(_ context: CallContext) -> [String: JSONValue] {
        let coder = context.coder
        var fields: [String: JSONValue] = [
            "now": .string(coder.string(context.now)),
            "timezone": .string(coder.timeZone.identifier),
        ]
        if let coverage = calendarService.eventCoverage {
            fields["coverage"] = ["from": .string(coder.string(coverage.start)), "to": .string(coder.string(coverage.end))]
            fields["data_as_of"] = .string(coder.string(coverage.refreshedAt))
        } else {
            fields["coverage"] = .null
            fields["data_as_of"] = .null
        }
        let (state, detail) = Self.syncState(calendarService.syncStatus)
        fields["sync_state"] = .string(state)
        if let detail { fields["sync_detail"] = .string(detail) }
        return fields
    }

    private func eventFields(_ event: CalendarEvent, _ context: CallContext) -> [String: JSONValue] {
        let coder = context.coder
        var fields: [String: JSONValue] = [
            "event_id": .string(MCPEventID.short(event.id)),
            "title": .string(event.title),
            "start": .string(coder.string(event.startDate)),
            "end": .string(coder.string(event.endDate)),
            "all_day": .bool(event.isAllDay),
            "my_response": .string(Self.responseName(event.responseType)),
            "is_organizer": .bool(event.isOrganizer),
            "cancelled": .bool(event.isEffectivelyCancelled),
            "has_join_url": .bool(event.joinURLForActions != nil),
            "account_id": .string(event.accountID.uuidString),
        ]
        if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            fields["location"] = .string(location)
        }
        if let organizer = event.organizer, !organizer.isEmpty {
            fields["organizer"] = .string(organizer)
        }
        if event.joinURLForActions != nil {
            fields["platform"] = .string(event.platform.rawValue)
        }
        // Exchange gives a one-off meeting's UID only with its details: known once loaded.
        if let uid = event.icalUID ?? detailsCache.entry(for: event)?.icalUID {
            fields["ical_uid"] = .string(uid)
        }
        if let series = event.seriesID {
            fields["series_id"] = .string(series)
        }
        if event.isRecurring {
            fields["is_recurring"] = true
        }
        return fields
    }

    private func rangeJSON(_ resolved: ResolvedRange, _ context: CallContext) -> JSONValue {
        var fields: [String: JSONValue] = [
            "from": .string(context.coder.string(resolved.range.start)),
            "to": .string(context.coder.string(resolved.range.end)),
            "clipped": .bool(resolved.clipped),
        ]
        if !resolved.outside.isEmpty { fields["outside_sync_window"] = true }
        if let note = resolved.note { fields["note"] = .string(note) }
        return .object(fields)
    }

    private func requireCoverage() throws -> DateInterval {
        guard let coverage = calendarService.eventCoverage else {
            throw ArgumentError("No calendar data yet: OWA Widget has not synced. Check get_status.")
        }
        return coverage.interval
    }

    /// `onDemand`: periods beyond the sync window are loaded from the calendar (see
    /// `MCPCalendarArchive`), within its limits; otherwise the period is clipped to `coverage`.
    private func resolveRange(
        _ arguments: [String: JSONValue],
        default defaultRange: DateInterval,
        spanWhenOnlyFrom: DefaultSpan?,
        onDemand: Bool = false,
        _ context: CallContext
    ) throws -> ResolvedRange {
        let coverage = try requireCoverage()
        let coder = context.coder
        var from = try arguments["from"]?.stringValue.map { text -> Date in
            guard let date = coder.parse(text, as: .start) else { throw ArgumentError("Invalid `from`: use YYYY-MM-DD or ISO 8601") }
            return date
        }
        var to = try arguments["to"]?.stringValue.map { text -> Date in
            guard let date = coder.parse(text, as: .end) else { throw ArgumentError("Invalid `to`: use YYYY-MM-DD or ISO 8601") }
            return date
        }
        let spanDays = spanWhenOnlyFrom.map { $0 == .day ? 1 : 7 }
        if to == nil, let from, let spanDays {
            let start = coder.calendar.startOfDay(for: from)
            to = coder.calendar.date(byAdding: .day, value: spanDays, to: start)
        }
        // Only `to` given ("what did I have until Saturday"): the same span, ending there.
        // Falling back to today's start instead put `from` after `to` for any past date.
        if from == nil, let to {
            if let spanDays {
                let lastDay = coder.calendar.startOfDay(for: to.addingTimeInterval(-1))
                from = coder.calendar.date(byAdding: .day, value: 1 - spanDays, to: lastDay)
            } else {
                from = coverage.start
            }
        }
        let start = from ?? defaultRange.start
        let end = to ?? (from == nil ? defaultRange.end : coverage.end)
        guard end > start else { throw ArgumentError("`to` must be later than `from`") }
        return try clip(DateInterval(start: start, end: end), onDemand: onDemand, context)
    }

    /// From a year back (start of that day) to a year ahead, and never less than `coverage`.
    private func onDemandReach(_ context: CallContext) throws -> DateInterval {
        let coverage = try requireCoverage()
        let start = context.coder.calendar.startOfDay(for: context.now.addingTimeInterval(-MCPCalendarArchive.horizon))
        let end = context.now.addingTimeInterval(MCPCalendarArchive.horizon)
        return DateInterval(start: min(start, coverage.start), end: max(end, coverage.end))
    }

    private func clip(_ requested: DateInterval, onDemand: Bool, _ context: CallContext) throws -> ResolvedRange {
        let coverage = try requireCoverage()
        let coder = context.coder
        guard onDemand else {
            let clippedStart = max(requested.start, coverage.start)
            let clippedEnd = min(requested.end, coverage.end)
            guard clippedEnd > clippedStart else {
                throw ArgumentError(
                    "No data for that period. OWA Widget only holds meetings from \(coder.string(coverage.start)) to \(coder.string(coverage.end))."
                )
            }
            return ResolvedRange(
                range: DateInterval(start: clippedStart, end: clippedEnd),
                clipped: clippedStart != requested.start || clippedEnd != requested.end
            )
        }

        let reach = try onDemandReach(context)
        var start = max(requested.start, reach.start)
        var end = min(requested.end, reach.end)
        guard end > start else {
            throw ArgumentError(
                "No data for that period. OWA Widget reads meetings from \(coder.string(reach.start)) to \(coder.string(reach.end)) (a year back and a year ahead)."
            )
        }
        var note: String?
        if start != requested.start || end != requested.end {
            note = "OWA Widget reads meetings from at most a year back to a year ahead."
        }
        // At most `maxSpan` outside the sync window, keeping what is nearest to it: "the last
        // time" and "the next time" are found there. With both sides, the later one gets at
        // least half.
        let maxSpan = MCPCalendarArchive.maxSpan
        let beforeEnd = min(end, coverage.start)
        let before = max(0, beforeEnd.timeIntervalSince(start))
        let afterStart = max(start, coverage.end)
        let after = max(0, end.timeIntervalSince(afterStart))
        if before + after > maxSpan {
            let keptAfter = min(after, max(maxSpan / 2, maxSpan - before))
            let keptBefore = min(before, maxSpan - keptAfter)
            if before > 0 { start = beforeEnd.addingTimeInterval(-keptBefore) }
            if after > 0 { end = afterStart.addingTimeInterval(keptAfter) }
            note = "Outside the sync window (`coverage`) OWA Widget loads at most \(Int(maxSpan / 86_400)) days per call, nearest to `coverage` first: call again with `from`/`to` for the rest."
        }

        var outside: [DateInterval] = []
        if start < coverage.start { outside.append(DateInterval(start: start, end: min(end, coverage.start))) }
        if end > coverage.end { outside.append(DateInterval(start: max(start, coverage.end), end: end)) }
        return ResolvedRange(
            range: DateInterval(start: start, end: end),
            clipped: start != requested.start || end != requested.end,
            outside: outside,
            note: note
        )
    }

    // MARK: - Meetings outside the sync window

    private struct CalendarLookup {
        let events: [CalendarEvent]
        /// Accounts whose meetings outside the sync window were asked for.
        var attempted: [UUID] = []
        /// Accounts whose meetings outside the sync window could not be loaded, with the reason.
        var unavailable: [(accountID: UUID, reason: String)] = []

        func annotate(_ result: inout [String: JSONValue]) {
            guard !unavailable.isEmpty else { return }
            result["unavailable_accounts"] = .array(unavailable.map {
                ["account_id": .string($0.accountID.uuidString), "reason": .string($0.reason)]
            })
            result["unavailable_note"] = "Meetings outside the sync window could not be loaded for these accounts, so the answer lacks them there. Tell the user rather than concluding there were none."
        }
    }

    private struct OnDemandJob: Sendable {
        let account: CalendarAccount
        let interval: DateInterval
        /// `nil` for a local calendar: read every time, never cached or budgeted.
        let key: MCPCalendarArchive.Key?
    }

    /// The loads of one call. They outlive it when it stops waiting — at the deadline or when the
    /// client cancels — so that a request already paid for still lands in the archive, but none
    /// still queued is started after that.
    @MainActor
    private final class LoadProgress {
        /// The first failure of an account stops its remaining loads: every Exchange request
        /// re-submits the credentials.
        var failedAccounts: Set<UUID> = []
        private(set) var stopped = false
        private(set) var outcomes: [Int: Result<[CalendarEvent], Error>?] = [:]
        private var pending: Int
        private var waiter: CheckedContinuation<Void, Never>?
        private var timer: Task<Void, Never>?

        init(jobs: Int) { pending = jobs }

        func finish(_ index: Int, _ outcome: Result<[CalendarEvent], Error>?) {
            outcomes[index] = outcome
            pending -= 1
            if pending == 0 { stop() }
        }

        /// Until every load is done, `deadline` passes or `stop()` is called.
        func wait(deadline: TimeInterval) async {
            guard pending > 0, !stopped else { return }
            await withCheckedContinuation { continuation in
                waiter = continuation
                timer = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(deadline))
                    self?.stop()
                }
            }
        }

        func stop() {
            stopped = true
            timer?.cancel()
            timer = nil
            waiter?.resume()
            waiter = nil
        }
    }

    /// The synced meetings plus, when `resolved` reaches beyond the sync window, those of the
    /// parts outside it: cached blocks first, the rest loaded from the calendars (Exchange through
    /// `accessGuard`, its whole cost taken up front), within `onDemandDeadline`.
    private func calendarEvents(for resolved: ResolvedRange, accountID: UUID?, _ context: CallContext) async throws -> CalendarLookup {
        let synced = calendarService.events
        guard !resolved.outside.isEmpty, let coverage = calendarService.eventCoverage?.interval else {
            return CalendarLookup(events: synced)
        }
        let accounts = calendarService.readableAccounts.filter {
            (accountID == nil || $0.id == accountID) && ($0.accountType == .owa || $0.accountType == .eventKit)
        }
        let blocks = Set(resolved.outside.flatMap(MCPCalendarArchive.blocks(covering:))).sorted()
        var loaded: [CalendarEvent] = []
        var jobs: [OnDemandJob] = []
        for account in accounts {
            guard account.accountType == .owa else {
                // A local database: always current and free to read.
                jobs += resolved.outside.map { OnDemandJob(account: account, interval: $0, key: nil) }
                continue
            }
            for block in blocks {
                let key = MCPCalendarArchive.Key(accountID: account.id, block: block)
                if let cached = archive.events(for: key, now: context.now) {
                    loaded += cached
                } else {
                    jobs.append(OnDemandJob(account: account, interval: MCPCalendarArchive.interval(of: block), key: key))
                }
            }
        }
        let cost = jobs.filter { $0.key != nil }.count
        if cost > 0, let denial = accessGuard.permitRequest(count: cost) {
            throw ArgumentError(denial.message)
        }

        // Started together, run at most two at a time (`accessGuard`'s slots).
        let progress = LoadProgress(jobs: jobs.count)
        for (index, job) in jobs.enumerated() {
            Task { @MainActor in progress.finish(index, await self.load(job, progress)) }
        }
        await withTaskCancellationHandler {
            await progress.wait(deadline: onDemandDeadline)
        } onCancel: {
            Task { @MainActor in progress.stop() }
        }
        try Task.checkCancellation()

        var unavailable: [UUID: String] = [:]
        var interrupted = false
        for (index, job) in jobs.enumerated() {
            switch progress.outcomes[index] {
            case .some(.success(let events)):
                loaded += events
            case .some(.failure(let error)):
                unavailable[job.account.id] = unavailable[job.account.id] ?? Self.loadFailureReason(error)
            case .some(.none):
                interrupted = interrupted || job.key != nil // skipped: the account failed, or sync got blocked
            case .none:
                // Still loading at the deadline: it lands in the archive for the next call.
                unavailable[job.account.id] = unavailable[job.account.id]
                    ?? "The calendar did not answer within \(Int(onDemandDeadline)) seconds. Call again: the periods loaded meanwhile are kept for a few minutes."
            }
        }
        if interrupted || !unavailable.isEmpty, let reason = MCPAccessGuard.blockReason(calendarService.syncStatus) {
            throw ArgumentError(reason)
        }

        // The sync's own copy wins inside `coverage`: a block loaded minutes ago may still hold a
        // meeting that has since been moved or cancelled there.
        var seen = Set(synced.map(\.id))
        let extra = loaded.filter { !Self.overlaps($0, coverage) && seen.insert($0.id).inserted }
        return CalendarLookup(
            events: synced + extra,
            attempted: accounts.map(\.id),
            unavailable: accounts.compactMap { account in unavailable[account.id].map { (account.id, $0) } }
        )
    }

    /// One block or local period. An Exchange block waits for a slot, is skipped once the call
    /// stopped waiting, its account failed or sync got blocked, and is archived as soon as it
    /// arrives.
    private func load(_ job: OnDemandJob, _ progress: LoadProgress) async -> Result<[CalendarEvent], Error>? {
        let accountID = job.account.id
        if let key = job.key {
            await accessGuard.acquireSlot()
            defer { accessGuard.releaseSlot() }
            guard !progress.stopped, !progress.failedAccounts.contains(accountID), !accessGuard.isBlocked else { return nil }
            return await fetch(job, progress, archiveAs: key)
        }
        return await fetch(job, progress, archiveAs: nil)
    }

    private func fetch(_ job: OnDemandJob, _ progress: LoadProgress, archiveAs key: MCPCalendarArchive.Key?) async -> Result<[CalendarEvent], Error> {
        do {
            let events = try await calendarService.fetchEventsOutsideSync(accountID: job.account.id, from: job.interval.start, to: job.interval.end)
            if let key { archive.store(events, for: key, now: clock()) }
            return .success(events)
        } catch {
            if key != nil {
                progress.failedAccounts.insert(job.account.id)
                accessGuard.report(error, context: "mcp.calendarView")
            }
            MCPDebugLog.log("on-demand calendar load failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    private static func loadFailureReason(_ error: Error) -> String {
        if case CalendarProviderError.notSupported = error {
            return "This calendar cannot be read right now."
        }
        return "Could not load meetings: \(error.localizedDescription)"
    }

    private func optionalAccountID(_ arguments: [String: JSONValue]) throws -> UUID? {
        guard let text = arguments["account_id"]?.stringValue else { return nil }
        guard let id = UUID(uuidString: text) else { throw ArgumentError("`account_id` must be an account_id from get_status") }
        return id
    }

    private func optionalBool(_ arguments: [String: JSONValue], _ key: String) throws -> Bool? {
        guard let value = arguments[key], value != .null else { return nil }
        guard let bool = value.boolValue else { throw ArgumentError("`\(key)` must be true or false") }
        return bool
    }

    private func optionalInt(_ arguments: [String: JSONValue], _ key: String, range: ClosedRange<Int>) throws -> Int? {
        guard let value = arguments[key], value != .null else { return nil }
        guard let int = value.intValue, range.contains(int) else {
            throw ArgumentError("`\(key)` must be an integer from \(range.lowerBound) to \(range.upperBound)")
        }
        return int
    }

    private func responseFilter(_ value: JSONValue?) throws -> Set<MeetingResponseType> {
        guard let value, value != .null else {
            return [.accepted, .tentative, .notResponded, .organizer]
        }
        let names: [JSONValue] = value.arrayValue ?? [value]
        return try Set(names.map { name in
            guard let text = name.stringValue, let type = Self.responseTypes[text] else {
                throw ArgumentError("`response` values: accepted, tentative, not_responded, declined, organizer")
            }
            return type
        })
    }

    private static func overlaps(_ event: CalendarEvent, _ range: DateInterval) -> Bool {
        if event.endDate <= event.startDate {
            return event.startDate >= range.start && event.startDate < range.end
        }
        return event.startDate < range.end && event.endDate > range.start
    }

    // MARK: - Names

    private static let responseTypes: [String: MeetingResponseType] = [
        "accepted": .accepted, "tentative": .tentative, "not_responded": .notResponded,
        "declined": .declined, "organizer": .organizer,
    ]

    static func responseName(_ type: MeetingResponseType) -> String {
        switch type {
        case .accepted: "accepted"
        case .tentative: "tentative"
        case .notResponded: "not_responded"
        case .declined: "declined"
        case .organizer: "organizer"
        }
    }

    static func accountTypeName(_ type: AccountType) -> String {
        switch type {
        case .owa: "exchange"
        case .eventKit: "macos_calendar"
        case .googleCalendar: "google_calendar"
        }
    }

    static func syncState(_ status: SyncStatus) -> (String, String?) {
        switch status {
        case .idle: ("idle", nil)
        case .syncing: ("syncing", nil)
        case .lastSynced: ("ok", nil)
        case .offlineCached(let message): ("offline_cached", "Last sync failed, showing saved data: \(message)")
        case .error(let message): ("error", message)
        case .authenticationRequired, .certificateTrustRequired, .loginHostApprovalRequired:
            (Self.blockedStateName(status), MCPAccessGuard.blockReason(status))
        }
    }

    private static func blockedStateName(_ status: SyncStatus) -> String {
        switch status {
        case .authenticationRequired: "auth_required"
        case .certificateTrustRequired: "certificate_untrusted"
        default: "login_host_approval_required"
        }
    }

    private static let weekdays: [String: Int] = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
    private static let weekdayOrder = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

    private static func minutes(_ seconds: TimeInterval) -> Int64 {
        Int64((seconds / 60).rounded())
    }

    private static func hhmm(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}
