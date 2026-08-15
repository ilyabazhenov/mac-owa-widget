import Foundation

#if DEBUG
/// Хранилище DEBUG-трейсов с потенциальной PII: тела OWA-ответов, FreeBusy-строки, выдача GAL.
///
/// История: сначала это писалось в `/tmp`, читаемую всеми локальными пользователями, потом
/// переехало в `~/Library/Application Support/OWAWidget/debug/` с правами 0600. Теперь трейсы
/// шифруются через ``SecureStore`` — открытым текстом на диске не остаётся ничего, даже в
/// отладочной сборке.
///
/// API намеренно файловое, а не URL'ное: вернуть `URL` и дать вызывающему писать в него напрямую
/// означало бы писать мимо шифрования.
///
/// Контейнер AES-GCM нельзя дополнить на месте, поэтому `append` работает через копию трейса в
/// памяти и сбрасывает её на диск порогом. Без этого каждая строка перешифровывала бы весь трейс
/// целиком, а он у некоторых вызывающих доходит до мегабайтов.
enum DebugLogLocation {
    private static let lock = NSLock()
    /// Минимальный объём накопленного, после которого есть смысл платить за перешифровку.
    private static let minFlushBytes = 32 * 1024
    /// Потолок на трейс. Вызывающие могут ротировать и раньше (см. `CustomMeetingReminderController`),
    /// это страховка для трейсов без собственного ограничения — иначе `owaclient.log` растёт в
    /// памяти и на диске без края.
    static let maxTraceBytes = 4 * 1024 * 1024

    nonisolated(unsafe) private static var buffers: [String: Data] = [:]
    nonisolated(unsafe) private static var pendingBytes: [String: Int] = [:]

    /// Имя контейнера в ``SecureStore``. Точки и слэши из имени файла убираются, чтобы не
    /// сломать раскладку `<name>.enc`.
    static func storageName(for fileName: String) -> String {
        let sanitized = fileName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return "debug-\(sanitized)"
    }

    /// Перезаписывает трейс целиком (старт сессии, единичный дамп). Пишет на диск сразу.
    static func write(_ data: Data, to fileName: String) {
        lock.lock()
        defer { lock.unlock() }
        buffers[fileName] = data
        pendingBytes[fileName] = 0
        persist(fileName)
    }

    static func write(_ text: String, to fileName: String) {
        write(Data(text.utf8), to: fileName)
    }

    /// Дописывает строку в копию трейса в памяти; на диск уходит по достижении порога.
    static func append(_ text: String, to fileName: String) {
        lock.lock()
        defer { lock.unlock() }
        let chunk = Data(text.utf8)
        var content = buffers[fileName] ?? loadFromDisk(fileName) ?? Data()
        content.append(chunk)
        if content.count > maxTraceBytes {
            content = Self.droppingOldestHalf(of: content)
        }
        buffers[fileName] = content

        // Порог растёт вместе с трейсом. Контейнер AES-GCM переписывается целиком, поэтому при
        // фиксированном пороге объём записи был бы квадратичным по размеру трейса: на 10 МБ лога
        // сессия писала бы на диск полтора гигабайта. Сброс раз в четверть текущего размера
        // держит суммарную запись линейной.
        let pending = (pendingBytes[fileName] ?? 0) + chunk.count
        if pending >= max(minFlushBytes, content.count / 4) {
            pendingBytes[fileName] = 0
            persist(fileName)
        } else {
            pendingBytes[fileName] = pending
        }
    }

    /// Отрезает старшую половину трейса по границе строки, чтобы обрубок не начинался с середины.
    static func droppingOldestHalf(of content: Data) -> Data {
        let cut = content.count / 2
        let cutIndex = content.startIndex.advanced(by: cut)

        // Разрез уже на начале строки — доотрезать нечего, иначе потеряли бы целую строку зря.
        if cut == 0 || content[content.index(before: cutIndex)] == UInt8(ascii: "\n") {
            return Data(content[cutIndex...])
        }

        let tail = content[cutIndex...]
        guard let newline = tail.firstIndex(of: UInt8(ascii: "\n")) else { return Data(tail) }
        return Data(tail[tail.index(after: newline)...])
    }

    /// Возвращает трейс целиком, включая ещё не сброшенный на диск хвост.
    static func read(_ fileName: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let buffered = buffers[fileName] { return buffered }
        return loadFromDisk(fileName)
    }

    static func readText(_ fileName: String) -> String? {
        guard let data = read(fileName) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Размер трейса в байтах. Вызывающие используют его, чтобы ограничить рост трассы.
    static func size(of fileName: String) -> Int {
        read(fileName)?.count ?? 0
    }

    /// Переносит содержимое одного трейса в другой (ротация `x.log` -> `x.previous.log`).
    ///
    /// **Не атомарна:** три операции берут лок каждая по-своему, поэтому строка, дописанная
    /// другим потоком между копированием и удалением, потеряется. Так и оставлено намеренно.
    /// Протаскивать лок через все три шага означало бы заводить внутренние варианты
    /// `read`/`write`/`remove` без захвата, а `NSLock` нерекурсивен — цена ошибки там не
    /// потерянная строка отладочного трейса, а мёртвая блокировка.
    static func rotate(from fileName: String, to previousFileName: String) {
        guard let data = read(fileName) else { return }
        write(data, to: previousFileName)
        remove(fileName)
    }

    static func remove(_ fileName: String) {
        lock.lock()
        defer { lock.unlock() }
        buffers[fileName] = nil
        pendingBytes[fileName] = nil
        SecureStore.shared.remove(storageName(for: fileName))
    }

    /// Сбрасывает всё накопленное на диск. Полезно перед снятием трейсов вручную.
    static func flushAll() {
        lock.lock()
        defer { lock.unlock() }
        for fileName in buffers.keys {
            pendingBytes[fileName] = 0
            persist(fileName)
        }
    }

    // MARK: - Private

    /// Вызывающий держит `lock`.
    private static func persist(_ fileName: String) {
        guard let content = buffers[fileName] else { return }
        try? SecureStore.shared.write(content, name: storageName(for: fileName))
    }

    /// Вызывающий держит `lock`.
    private static func loadFromDisk(_ fileName: String) -> Data? {
        (try? SecureStore.shared.read(storageName(for: fileName))) ?? nil
    }
}
#endif
