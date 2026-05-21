import Foundation

#if DEBUG
/// Локация для DEBUG-трейсов с потенциальной PII (тела OWA-ответов, FreeBusy-строки и т.п.).
///
/// До этого логи писались в `/tmp/`, которая на macOS читаема для всех локальных пользователей —
/// чувствительные данные (имена, email'ы, должности из GAL) могли утечь.
/// Сейчас они живут в `~/Library/Application Support/OWAWidget/debug/`, которая ограничена
/// домашней директорией текущего пользователя; файлы создаются с правами 0600.
enum DebugLogLocation {
    /// Возвращает URL файла под `debug/<fileName>`, создавая директорию при необходимости.
    /// Если создать не получилось — возвращается nil (запись просто молча пропускается вызывающим).
    static func url(for fileName: String) -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = support.appendingPathComponent("OWAWidget/debug", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return nil
        }
        return dir.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Применяет права 0600 к файлу, если он существует. Безопасно вызывать многократно.
    static func tightenPermissions(at url: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
#endif
