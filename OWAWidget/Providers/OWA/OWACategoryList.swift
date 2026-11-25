import Foundation

/// The user's Outlook category list: every category with its colour. Exchange keeps it as the
/// `CategoryList` configuration item of the Calendar folder, whose `XmlData` is a base64 XML
/// document of `<category name="…" color="…"/>` elements.
///
/// `color` is Outlook's preset number: -1 for none, 0…24 for red … dark cranberry — the same
/// numbers as Graph's `preset0`…`preset24`.
enum OWACategoryListPayload {
    static func soap() -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types" \
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
          <soap:Header>
            <t:RequestServerVersion Version="Exchange2013_SP1"/>
          </soap:Header>
          <soap:Body>
            <m:GetUserConfiguration>
              <m:UserConfigurationName Name="CategoryList">
                <t:DistinguishedFolderId Id="calendar"/>
              </m:UserConfigurationName>
              <m:UserConfigurationProperties>XmlData</m:UserConfigurationProperties>
            </m:GetUserConfiguration>
          </soap:Body>
        </soap:Envelope>
        """
    }

    /// A mailbox whose categories were never edited has no list yet: an answer, not a failure.
    static let acceptedCodes: Set<String> = ["ErrorItemNotFound"]
}

enum OWACategoryListParser {
    /// Colour presets by lowercased category name (Exchange compares names case-insensitively).
    /// A category without a colour is in the map with -1. `nil` when the answer has no list.
    static func colors(fromSOAP soap: String) -> [String: Int]? {
        guard let base64 = xmlData(fromSOAP: soap),
              let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
        else { return nil }
        return colors(fromListXML: data)
    }

    static func colors(fromListXML data: Data) -> [String: Int]? {
        let collector = CategoryCollector()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = collector
        guard parser.parse(), collector.sawList else { return nil }
        return collector.colors
    }

    private static func xmlData(fromSOAP soap: String) -> String? {
        let collector = XMLDataCollector()
        let parser = XMLParser(data: Data(soap.utf8))
        parser.shouldProcessNamespaces = true
        parser.delegate = collector
        guard parser.parse() else { return nil }
        let text = collector.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private final class XMLDataCollector: NSObject, XMLParserDelegate {
        var text = ""
        private var inside = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "XmlData" { inside = true }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inside { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "XmlData" { inside = false }
        }
    }

    private final class CategoryCollector: NSObject, XMLParserDelegate {
        var colors: [String: Int] = [:]
        var sawList = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "categories" { sawList = true }
            guard name == "category",
                  let categoryName = attributes["name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !categoryName.isEmpty
            else { return }
            let preset = attributes["color"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            colors[categoryName.lowercased()] = preset.flatMap { OutlookCategoryColor.presets.contains($0) ? $0 : nil } ?? -1
        }
    }
}

extension OWAClient {
    /// One EWS `GetUserConfiguration` request for the user's category list. `nil` when the
    /// mailbox has none yet or the answer carries no list.
    func categoryColors() async throws -> [String: Int]? {
        let body = try await ewsCall(
            action: "GetUserConfiguration",
            soap: OWACategoryListPayload.soap(),
            mayRepeat: true,
            note: "CategoryList",
            area: "Calendar",
            acceptedCodes: OWACategoryListPayload.acceptedCodes
        )
        return OWACategoryListParser.colors(fromSOAP: body)
    }
}
