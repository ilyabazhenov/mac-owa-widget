import Foundation

/// Разбивает длительность в минутах на единицы для countdown-строк.
///
/// Встречи бывают многодневными (отпуск, командировка, «блок» на всю неделю), поэтому
/// сырые минуты в баннере превращались в нечитаемое «осталось 2 464 мин». Здесь только
/// выбор единиц — рендер локализованных строк живёт в `LocalizationService`.
enum CompactDuration {
    enum Breakdown: Equatable {
        case minutes(Int)
        /// Часы и остаток минут (`minutes == 0`, если остатка нет).
        case hoursMinutes(hours: Int, minutes: Int)
        /// Дни и остаток часов (`hours == 0`, если остатка нет).
        case daysHours(days: Int, hours: Int)
    }

    static let minutesPerHour = 60
    static let minutesPerDay = 24 * minutesPerHour

    static func breakdown(minutes rawMinutes: Int) -> Breakdown {
        let total = max(0, rawMinutes)

        if total < minutesPerHour {
            return .minutes(total)
        }
        if total < minutesPerDay {
            return .hoursMinutes(hours: total / minutesPerHour, minutes: total % minutesPerHour)
        }
        let days = total / minutesPerDay
        return .daysHours(days: days, hours: (total % minutesPerDay) / minutesPerHour)
    }
}
