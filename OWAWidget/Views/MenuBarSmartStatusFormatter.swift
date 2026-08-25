import Foundation

/// "Smart status" for the menu bar (opt-in `MenuBarDisplayMode.smart`).
///
/// Collapses the many fine-grained states into two coarse glyph categories so meaning is
/// carried by the *glyph* + *pulse* + a compact label rather than by words:
///
/// - `engaged` (a meeting is imminent or in progress) → a **duration** ("how long"), pulses
///   when it's time to act (≤2 min before start, or during the meeting).
/// - `idle` (free / done for the day) → the **time** of the next meeting ("when"), or icon-only
///   when nothing is upcoming at all.
///
/// Fine distinctions (has-join-link, overlap count, "free until", "tomorrow") are exposed via
/// `Tooltip`, not a distinct glyph. The `problem` state (broken sync) is not produced here — it
/// stays driven by `CalendarService.syncStatus` in `MenuBarLabelView`, which takes precedence.
///
/// This type is pure and localization-free so it can be unit-tested; the view renders the final
/// (localized, timezone-aware) strings from the semantic result.
enum MenuBarSmartStatusFormatter {
    /// Menu bar glyph category. Maps 1:1 to an SF Symbol in the view.
    enum Category: Equatable {
        case idle       // "calendar"
        case engaged    // "calendar.badge.clock"
    }

    /// What the trailing label shows. Durations ("12m"/"2h") and relative-day counts ("3d") are
    /// language-neutral and produced here; a `time` is formatted by the view with the user's
    /// short-time formatter + timezone.
    enum Content: Equatable {
        case iconOnly
        case duration(String)
        /// Whole-day distance to a meeting that is neither today nor tomorrow (rendered "Nd").
        case relativeDays(Int)
        case time(Date)
    }

    /// Semantic hover text; the view turns each case into a localized string.
    enum Tooltip: Equatable {
        case inMeeting(remainingMinutes: Int, hasJoinURL: Bool)
        case overlap(count: Int)
        case joinNow(hasJoinURL: Bool)
        case soon(start: Date, hasJoinURL: Bool)
        case freeUntil(start: Date)
        case nextDay(start: Date)
        /// Next meeting is 2+ days out; carries the whole-day distance.
        case laterDays(count: Int)
        case nothingUpcoming
    }

    struct Presentation: Equatable {
        let category: Category
        let content: Content
        /// Motion cue for "act now / live" — imminent (≤2 min) or a meeting in progress.
        let pulse: Bool
        let tooltip: Tooltip
    }

    /// Start is this close or closer → "act now" (pulse).
    static let imminentThresholdMinutes = 2
    /// Start is within this window → "engaged" glyph, but no pulse yet.
    static let soonThresholdMinutes = 15

    static func presentation(
        events: [CalendarEvent],
        now: Date,
        calendar: Calendar = .current
    ) -> Presentation {
        // Cancelled meetings are still present in `events` (shown struck-through elsewhere), but
        // they must not drive the status — mirror the "next meeting" filter in `MeetingReminderShared`.
        let relevant = events.filter { !$0.isAllDay && !$0.isEffectivelyCancelled }

        let active = relevant
            .filter { $0.startDate <= now && $0.endDate > now }
            .sorted { $0.endDate < $1.endDate }

        if active.count > 1, let soonestEnding = active.first {
            return Presentation(
                category: .engaged,
                content: .duration(compact(minutes(from: now, to: soonestEnding.endDate))),
                pulse: true,
                tooltip: .overlap(count: active.count)
            )
        }

        if let current = active.first {
            let remaining = minutes(from: now, to: current.endDate)
            return Presentation(
                category: .engaged,
                content: .duration(compact(remaining)),
                pulse: true,
                tooltip: .inMeeting(remainingMinutes: remaining, hasJoinURL: current.joinURLForActions != nil)
            )
        }

        let next = relevant
            .filter { $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
            .first

        guard let next else {
            return Presentation(category: .idle, content: .iconOnly, pulse: false, tooltip: .nothingUpcoming)
        }

        let until = minutes(from: now, to: next.startDate)
        let hasJoin = next.joinURLForActions != nil

        if until <= imminentThresholdMinutes {
            return Presentation(
                category: .engaged,
                content: .duration(compact(until)),
                pulse: true,
                tooltip: .joinNow(hasJoinURL: hasJoin)
            )
        }
        if until <= soonThresholdMinutes {
            return Presentation(
                category: .engaged,
                content: .duration(compact(until)),
                pulse: false,
                tooltip: .soon(start: next.startDate, hasJoinURL: hasJoin)
            )
        }

        // Idle: convey *when* the next meeting is, not how long until it. Distinguish today /
        // tomorrow / 2+ days out — collapsing "later" into "tomorrow" would mislabel far meetings.
        let dayDelta = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: next.startDate)
        ).day ?? 0

        if dayDelta <= 0 {
            return Presentation(category: .idle, content: .time(next.startDate), pulse: false, tooltip: .freeUntil(start: next.startDate))
        }
        if dayDelta == 1 {
            return Presentation(category: .idle, content: .time(next.startDate), pulse: false, tooltip: .nextDay(start: next.startDate))
        }
        // 2+ days out: a bare wall-clock time would read as "today", so show the day distance.
        return Presentation(category: .idle, content: .relativeDays(dayDelta), pulse: false, tooltip: .laterDays(count: dayDelta))
    }

    private static func minutes(from now: Date, to target: Date) -> Int {
        max(0, Int(ceil(target.timeIntervalSince(now) / 60)))
    }

    /// Компактная метка меню-бара. Многодневная встреча (отпуск, командировка) иначе
    /// показывалась бы как "42h" — для суток и больше переходим на дни, как в `.relativeDays`.
    private static func compact(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 { return "\(Int(ceil(Double(minutes) / 60)))h" }
        return "\(Int(ceil(Double(minutes) / (24 * 60))))d"
    }
}
