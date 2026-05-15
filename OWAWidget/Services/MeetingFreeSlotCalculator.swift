import Foundation

/// Pure free-busy → candidate slot computation used by `CalendarService.findFreeSlots`.
enum MeetingFreeSlotCalculator {
    /// Cap returned suggestions so UI stays responsive; must cover a Mon–Fri 9:00–17:30 half-hour grid
    /// (~90 starts for 30-minute meetings) so later weekdays are not hidden after filling the cap Mon–Wed.
    static let maxReturnedFreeSlots = 96

    static func compute(
        from availability: [AttendeeAvailability],
        optionalAvailability: [AttendeeAvailability] = [],
        organizerAvailability: AttendeeAvailability?,
        organizerEvents: [CalendarEvent],
        range: DateInterval,
        durationMinutes: Int
    ) -> [FreeSlot] {
        _ = optionalAvailability  // v1: optional attendees do not affect slot selection; param reserved for v2 ranking
        guard range.end > range.start else { return [] }
        let intervalSec: TimeInterval = 30 * 60
        let slotsNeeded = max(1, Int(ceil(Double(durationMinutes) / 30.0)))
        let cal = AppTimeZone.calendar
        var results: [FreeSlot] = []

        let windowStart: Date
        let totalSlots: Int
        if let first = availability.first {
            windowStart = first.windowStart
            totalSlots = availability.map { $0.mergedFreeBusy.count }.min() ?? 0
        } else {
            windowStart = cal.startOfDay(for: range.start)
            let totalSeconds = range.end.timeIntervalSince(windowStart)
            totalSlots = Int(totalSeconds / intervalSec)
        }

        #if DEBUG
        let dbgFmt = DateFormatter()
        dbgFmt.dateFormat = "MM-dd HH:mm"
        dbgFmt.timeZone = AppTimeZone.zone
        let logPath = "/tmp/owawidget_freeslots.log"
        func flog(_ msg: String) {
            let line = "[\(dbgFmt.string(from: Date()))] \(msg)\n"
            if let data = line.data(using: .utf8) {
                if let fh = FileHandle(forWritingAtPath: logPath) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    try? fh.close()
                } else {
                    try? data.write(to: URL(fileURLWithPath: logPath), options: .atomic)
                }
            }
        }
        let utcFmt = DateFormatter()
        utcFmt.dateFormat = "MM-dd HH:mm"
        utcFmt.timeZone = TimeZone(identifier: "UTC")
        flog(
            "=== computeFreeSlots: organizerEvents=\(organizerEvents.count) range=\(dbgFmt.string(from: range.start))–\(dbgFmt.string(from: range.end)) localTZ=\(TimeZone.current.identifier) (\(TimeZone.current.secondsFromGMT() / 3600)h)"
        )
        let inRange = organizerEvents.filter { $0.startDate < range.end && $0.endDate > range.start }
        flog("  organizerEvents in range: \(inRange.count)")
        for ev in inRange.sorted(by: { $0.startDate < $1.startDate }) {
            flog(
                "  • \(dbgFmt.string(from: ev.startDate))–\(dbgFmt.string(from: ev.endDate)) [UTC \(utcFmt.string(from: ev.startDate))] resp=\(ev.responseType.rawValue) '\(ev.title)'"
            )
        }
        #endif

        var i = 0
        while i <= totalSlots - slotsNeeded {
            let slotStart = windowStart.addingTimeInterval(Double(i) * intervalSec)
            let slotEnd = slotStart.addingTimeInterval(Double(durationMinutes) * 60)

            guard slotStart >= range.start, slotEnd <= range.end else { i += 1; continue }

            let startMinuteOfDay = cal.component(.hour, from: slotStart) * 60 + cal.component(.minute, from: slotStart)
            let endMinuteOfDay = cal.component(.hour, from: slotEnd) * 60 + cal.component(.minute, from: slotEnd)
            guard startMinuteOfDay >= 9 * 60, endMinuteOfDay > 0, endMinuteOfDay <= 18 * 60 else { i += 1; continue }

            let weekday = cal.component(.weekday, from: slotStart)
            guard weekday != 1, weekday != 7 else { i += 1; continue }

            let attendeesFree = availability.allSatisfy { avail in
                let chars = Array(avail.mergedFreeBusy)
                return (i..<(i + slotsNeeded)).allSatisfy { idx in
                    idx < chars.count && chars[idx] == "0"
                }
            }
            guard attendeesFree else { i += 1; continue }

            let conflictingEvent = organizerEvents.first { event in
                event.startDate < slotEnd && event.endDate > slotStart
            }
            if let conflict = conflictingEvent {
                #if DEBUG
                flog("  slot \(dbgFmt.string(from: slotStart)) BLOCKED by '\(conflict.title)' (\(conflict.responseType.rawValue))")
                #endif
                i += 1
                continue
            }

            if let orgAvail = organizerAvailability {
                let orgChars = Array(orgAvail.mergedFreeBusy)
                let orgWindowStart = orgAvail.windowStart
                let orgInterval: TimeInterval = Double(orgAvail.intervalMinutes) * 60
                let orgFree = (0..<slotsNeeded).allSatisfy { offset in
                    let t = slotStart.addingTimeInterval(Double(offset) * intervalSec)
                    let idx = Int(t.timeIntervalSince(orgWindowStart) / orgInterval)
                    guard idx >= 0, idx < orgChars.count else { return true }
                    return orgChars[idx] == "0"
                }
                if !orgFree {
                    #if DEBUG
                    flog("  slot \(dbgFmt.string(from: slotStart)) BLOCKED by organizer availability API (likely OOF)")
                    #endif
                    i += 1
                    continue
                }
            }

            #if DEBUG
            flog("  slot \(dbgFmt.string(from: slotStart)) → FREE (attendees ok, organizer ok)")
            #endif

            let hourOfDay = Double(cal.component(.hour, from: slotStart))
                + Double(cal.component(.minute, from: slotStart)) / 60.0
            // Business hours window [9, 18]; earlier slot → higher score.
            let score = max(0, min(1, (18.0 - hourOfDay) / 9.0))
            results.append(FreeSlot(start: slotStart, end: slotEnd, score: score))
            if results.count >= maxReturnedFreeSlots { break }
            i += slotsNeeded
        }

        return results
    }
}
