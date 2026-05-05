import Foundation

struct MeetingURLDetector: Sendable {

    private let patterns: [(regex: NSRegularExpression, platform: MeetingPlatform)] = {
        let defs: [(String, MeetingPlatform)] = [
            (#"https://teams\.microsoft\.com/l/meetup-join/[^\s<"')\]]+"#,          .teams),
            (#"https://teams\.live\.com/meet/[^\s<"')\]]+"#,                        .teams),
            (#"https://[a-z0-9-]+\.zoom\.us/j/[^\s<"')\]]+"#,                      .zoom),
            (#"https://[a-z0-9-]+\.webex\.com/(?:meet|j|wc)/[^\s<"')\]]+"#,        .webex),
            (#"https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}[^\s<"')\]]*"#, .googleMeet),
            (#"https://[a-z0-9-]+\.ktalk\.ru/[^\s<"')\]]+"#,                       .ktalk),
        ]
        return defs.compactMap { pattern, platform in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, platform)
        }
    }()

    func detect(in text: String) -> (url: URL, platform: MeetingPlatform)? {
        let plain = stripHTML(text)
        let sources = plain == text ? [text] : [text, plain]

        for source in sources {
            let nsString = source as NSString
            let range = NSRange(location: 0, length: nsString.length)

            for (regex, platform) in patterns {
                guard let match = regex.firstMatch(in: source, range: range) else { continue }
                var urlString = nsString.substring(with: match.range)
                urlString = urlString.trimmingCharacters(in: CharacterSet(charactersIn: ".,;\"'<>)\\]"))
                if let url = URL(string: urlString) {
                    return (url, platform)
                }
            }
        }
        return nil
    }

    func detectPlatform(from urlString: String) -> MeetingPlatform {
        detect(in: urlString)?.platform ?? .generic
    }

    private func stripHTML(_ string: String) -> String {
        guard string.contains("<") else { return string }
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>") else { return string }
        let nsString = string as NSString
        let range = NSRange(location: 0, length: nsString.length)
        return regex.stringByReplacingMatches(in: string, range: range, withTemplate: " ")
    }
}
