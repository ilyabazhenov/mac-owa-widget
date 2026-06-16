import Foundation

/// Чистая логика «снапа» одиночного клика по гриду к выбранной длительности встречи.
///
/// Грид рисует получасовую сетку, но при клике по ячейке пользователь хочет выделить
/// окно выбранной длины (30м/1ч/1.5ч/2ч). Окно нужно вписать в непрерывный свободный
/// ряд вокруг клика, не задевая занятые ячейки и не вылезая за конец рабочего дня.
enum SlotClickSnap {
    /// Вписывает окно `durationMinutes` в непрерывный свободный ряд вокруг `clickMinute`.
    ///
    /// - Parameters:
    ///   - clickMinute: минута от полуночи кликнутой 30-мин ячейки (кратна 30).
    ///   - durationMinutes: желаемая длительность встречи.
    ///   - dayEndMinute: верхняя граница рабочего дня (по умолчанию 18:00) — на случай
    ///     клика по занятой ячейке, когда ряд не из чего строить.
    ///   - isFree: свободна ли (и доступна для брони) 30-мин ячейка с данной минутой старта.
    /// - Returns: `(start, end)` окна в минутах от полуночи.
    ///
    /// Поведение:
    ///   • Клик по занятой ячейке → `(clickMinute, clickMinute + duration)` с обрезкой по
    ///     `dayEndMinute` — пусть дальше подсветится как конфликт.
    ///   • Иначе якорим старт на клике; если окно вылезает за конец свободного ряда —
    ///     сдвигаем старт назад, чтобы поместиться, оставаясь внутри ряда и накрывая клик.
    static func fittedWindow(
        clickMinute: Int,
        durationMinutes: Int,
        dayEndMinute: Int = 18 * 60,
        isFree: (Int) -> Bool
    ) -> (start: Int, end: Int) {
        guard isFree(clickMinute) else {
            return (clickMinute, min(clickMinute + durationMinutes, dayEndMinute))
        }

        // Границы непрерывного свободного ряда [runStart, runEnd).
        var runStart = clickMinute
        while isFree(runStart - 30) { runStart -= 30 }
        var runEnd = clickMinute + 30
        while isFree(runEnd) { runEnd += 30 }

        // Размещаем окно, накрывая клик и оставаясь внутри свободного ряда.
        var start = clickMinute
        if start + durationMinutes > runEnd { start = runEnd - durationMinutes }
        if start < runStart { start = runStart }
        let end = min(start + durationMinutes, runEnd)
        return (start, end)
    }
}
