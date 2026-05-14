import Foundation

/// Parses `GetPeopleFilters` responses so `FindPeople` can include `ParentFolderId` / `AddressListId` (required on many Exchange builds).
enum OWAGalAddressListSupport {
    /// Picks the default global address list folder id from `GetPeopleFilters` JSON.
    static func pickDefaultGlobalAddressListFolderId(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let dict = obj as? [String: Any], let d = dict["d"] {
            if let rows = d as? [[String: Any]] {
                return pick(from: rows)
            }
            if let json = try? JSONSerialization.data(withJSONObject: d) {
                return pickDefaultGlobalAddressListFolderId(from: json)
            }
        }
        if let rows = obj as? [[String: Any]] {
            return pick(from: rows)
        }
        if let dict = obj as? [String: Any] {
            if let rows = dict["Body"] as? [[String: Any]] {
                return pick(from: rows)
            }
            if let body = dict["Body"] as? [String: Any],
               let rows = body["Filters"] as? [[String: Any]] {
                return pick(from: rows)
            }
            if let rows = firstArrayOfFolderRows(in: dict) {
                return pick(from: rows)
            }
        }
        return nil
    }

    private static func firstArrayOfFolderRows(in dict: [String: Any]) -> [[String: Any]]? {
        for value in dict.values {
            if let rows = value as? [[String: Any]], !rows.isEmpty, folderId(from: rows[0]) != nil {
                return rows
            }
            if let nested = value as? [String: Any],
               let found = firstArrayOfFolderRows(in: nested) {
                return found
            }
        }
        return nil
    }

    private static func pick(from rows: [[String: Any]]) -> String? {
        let preferredDisplayNames = [
            "Default Global Address List",
            "Глобальный список адресов по умолчанию",
        ]
        for name in preferredDisplayNames {
            if let row = rows.first(where: { ($0["DisplayName"] as? String) == name }),
               let id = folderId(from: row) {
                return id
            }
        }
        for row in rows {
            if let dn = row["DisplayName"] as? String,
               dn.localizedCaseInsensitiveContains("global"),
               dn.localizedCaseInsensitiveContains("address"),
               let id = folderId(from: row) {
                return id
            }
        }
        for row in rows {
            if let id = folderId(from: row) { return id }
        }
        return nil
    }

    private static func folderId(from row: [String: Any]) -> String? {
        guard let folder = row["FolderId"] as? [String: Any],
              let id = folder["Id"] as? String,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return id
    }
}
