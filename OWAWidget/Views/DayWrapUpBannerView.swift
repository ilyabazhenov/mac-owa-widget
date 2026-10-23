import SwiftUI

/// Today with nothing left: says so and names the next meeting, which opens its day on click.
///
/// Stands where the next-meeting banner stands during the day. Without it, the evening popover
/// showed an empty grid under a meeting that ended hours ago, and tomorrow's first meeting took
/// a swipe to find.
struct DayWrapUpBannerView: View {
    let next: CalendarEvent
    /// Today had meetings with a time: "no more meetings" rather than "no meetings".
    let hadMeetingsToday: Bool
    var horizontalPadding: CGFloat = 12
    let onOpenDay: () -> Void
    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        Button(action: onOpenDay) {
            HStack(spacing: 8) {
                Image(systemName: "moon.stars")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(localization.tr(hadMeetingsToday ? "popover.day.done" : "popover.day.free"))
                        .font(.app(.footnote, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("\(whenLabel) · \(next.title)")
                        .font(.app(.body, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.app(.footnote, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(localization.tr("a11y.popover.day.next.hint"))
    }

    /// "Завтра, 10:30" or "Пн, 26 окт., 10:30".
    private var whenLabel: String {
        let calendar = AppTimeZone.calendar
        let day: String
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())),
           calendar.isDate(next.startDate, inSameDayAs: tomorrow) {
            day = localization.tr("date.tomorrow")
        } else {
            let formatted = localization.formatDate(next.startDate, format: "EE, d MMM")
            day = formatted.prefix(1).uppercased() + formatted.dropFirst()
        }
        return "\(day), \(localization.shortTime(next.startDate))"
    }
}
