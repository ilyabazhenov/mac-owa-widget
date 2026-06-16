import XCTest
@testable import OWAWidget

/// Тесты на снап одиночного клика к выбранной длительности (`SlotClickSnap.fittedWindow`).
///
/// Покрывают регрессии, из-за которых:
///   • клик по ячейке всегда выделял 30 минут (игнорировал длительность);
///   • клик по нижней ячейке короткого ряда захватывал следующую — уже занятую — ячейку.
final class SlotClickSnapTests: XCTestCase {

    /// Удобный конструктор предиката «свободна ли ячейка» из набора свободных минут.
    private func freeSet(_ minutes: [Int]) -> (Int) -> Bool {
        let set = Set(minutes)
        return { set.contains($0) }
    }

    private func minutes(_ hour: Int, _ minute: Int = 0) -> Int { hour * 60 + minute }

    // MARK: - Базовое: клик выделяет окно выбранной длительности

    func testThirtyMinuteDurationSelectsSingleCell() {
        let free = freeSet([minutes(9), minutes(9, 30), minutes(10)])
        let w = SlotClickSnap.fittedWindow(clickMinute: minutes(9), durationMinutes: 30, isFree: free)
        XCTAssertEqual(w.start, minutes(9))
        XCTAssertEqual(w.end, minutes(9, 30))
    }

    func testOneHourClickOnTopCellSelectsFullHour() {
        // 09:00 и 09:30 свободны, 10:00 занято — ровно часовой ряд.
        let free = freeSet([minutes(9), minutes(9, 30)])
        let w = SlotClickSnap.fittedWindow(clickMinute: minutes(9), durationMinutes: 60, isFree: free)
        XCTAssertEqual(w.start, minutes(9))
        XCTAssertEqual(w.end, minutes(10))
    }

    // MARK: - Регрессия: клик по нижней ячейке короткого ряда не лезет на занятую

    func testOneHourClickOnBottomCellSnapsBackIntoFreeRun() {
        // Ряд из двух свободных ячеек 09:00–10:00; 10:00 занято. Клик по нижней (09:30)
        // должен дать 09:00–10:00, а НЕ 09:30–10:30 (захват занятой 10:00).
        let free = freeSet([minutes(9), minutes(9, 30)])
        let w = SlotClickSnap.fittedWindow(clickMinute: minutes(9, 30), durationMinutes: 60, isFree: free)
        XCTAssertEqual(w.start, minutes(9), "старт должен сдвинуться назад, чтобы окно влезло в ряд")
        XCTAssertEqual(w.end, minutes(10))
    }

    // MARK: - Длинный ряд: старт остаётся на клике

    func testTwoHourClickInLongRunAnchorsAtClick() {
        // Весь день 09:00–18:00 свободен. Клик 11:00, длительность 2ч → 11:00–13:00.
        let allDay = stride(from: minutes(9), to: minutes(18), by: 30).map { $0 }
        let w = SlotClickSnap.fittedWindow(clickMinute: minutes(11), durationMinutes: 120, isFree: freeSet(allDay))
        XCTAssertEqual(w.start, minutes(11))
        XCTAssertEqual(w.end, minutes(13))
    }

    func testTwoHourClickNearEndOfDaySlidesBackToFit() {
        // Весь день свободен. Клик 17:00 с 2ч не помещается до 18:00 → сдвиг назад 16:00–18:00.
        let allDay = stride(from: minutes(9), to: minutes(18), by: 30).map { $0 }
        let w = SlotClickSnap.fittedWindow(clickMinute: minutes(17), durationMinutes: 120, isFree: freeSet(allDay))
        XCTAssertEqual(w.start, minutes(16))
        XCTAssertEqual(w.end, minutes(18))
    }

    // MARK: - Окно ровно по размеру ряда

    func testRunExactlyDurationSelectsWholeRun() {
        // Свободный ряд 14:00–16:00 (4 ячейки), вокруг занято. Любой клик внутри → 14:00–16:00.
        let free = freeSet([minutes(14), minutes(14, 30), minutes(15), minutes(15, 30)])
        for click in [minutes(14), minutes(14, 30), minutes(15), minutes(15, 30)] {
            let w = SlotClickSnap.fittedWindow(clickMinute: click, durationMinutes: 120, isFree: free)
            XCTAssertEqual(w.start, minutes(14), "клик \(click): старт")
            XCTAssertEqual(w.end, minutes(16), "клик \(click): конец")
        }
    }

    // MARK: - Клик по занятой ячейке

    func testClickOnBusyCellReturnsRawWindowClampedToDayEnd() {
        let free = freeSet([])  // всё занято
        let w = SlotClickSnap.fittedWindow(clickMinute: minutes(17), durationMinutes: 120, isFree: free)
        XCTAssertEqual(w.start, minutes(17))
        XCTAssertEqual(w.end, minutes(18), "конец обрезается по концу дня 18:00")
    }

    // MARK: - Ряд короче длительности (полноценный слот не влезает)

    func testRunShorterThanDurationStillClampsWithinRun() {
        // Свободны только 11:00–11:30 (1 ячейка), хотим 1ч. Окно не может быть длиннее ряда.
        let free = freeSet([minutes(11)])
        let w = SlotClickSnap.fittedWindow(clickMinute: minutes(11), durationMinutes: 60, isFree: free)
        XCTAssertEqual(w.start, minutes(11))
        XCTAssertEqual(w.end, minutes(11, 30), "окно не вылезает на занятые ячейки")
    }
}
