import Foundation

/// A message body shown on a dark background, as Apple Mail and Outlook do in a dark theme.
///
/// Only a message that leaves the page to the reader can go dark: one whose backgrounds are
/// all white or unset (plain text, an ordinary Outlook reply). Its dark text — black, Outlook's
/// `windowtext`, a signature's navy — is made light by turning its lightness over, so a dark blue
/// stays blue. A message with a design of its own (a coloured header, a background picture, a
/// grey panel the sender chose) stays on white: recolouring it would break it.
final class MailDarkMode {
    /// False once anything was seen that keeps the message light.
    private(set) var canGoDark = true

    /// A new value for an attribute: `""` drops it, `nil` keeps it as it is.
    func attribute(element: String, name: String, value: String) -> String? {
        switch name {
        case "style":
            let adapted = declarations(value)
            return adapted == value ? nil : adapted
        case "bgcolor":
            guard Self.isLightBackground(value) else { canGoDark = false; return nil }
            return ""
        case "background":
            // A picture behind the content.
            if !value.trimmingCharacters(in: .whitespaces).isEmpty { canGoDark = false }
            return nil
        case "color" where element == "font", "text" where element == "body",
             "link" where element == "body", "vlink" where element == "body", "alink" where element == "body":
            return Self.lightened(value)
        default:
            return nil
        }
    }

    /// A `<style>` element's text with its colours made for a dark page.
    func styleSheet(_ css: String) -> String {
        declarations(css)
    }

    // MARK: - Declarations

    /// Rewrites `color` and `background` declarations wherever they are: in a `style`
    /// attribute (declarations alone) or a style sheet (selectors and blocks around them).
    /// A stretch ending in `{` is a selector or an at-rule and is left alone.
    private func declarations(_ css: String) -> String {
        var out = ""
        var segment = ""
        for character in css {
            if character == ";" || character == "{" || character == "}" {
                out += character == "{" ? segment : declaration(segment)
                out.append(character)
                segment = ""
            } else {
                segment.append(character)
            }
        }
        out += declaration(segment)
        return out
    }

    private func declaration(_ text: String) -> String {
        guard let colon = text.firstIndex(of: ":") else { return text }
        let property = text[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var value = String(text[text.index(after: colon)...])
        var important = ""
        if let bang = value.range(of: "!important", options: .caseInsensitive) {
            important = " !important"
            value.removeSubrange(bang)
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = text[..<colon]
        switch property {
        case "color":
            guard let lightened = Self.lightened(trimmed) else { return text }
            return "\(prefix):\(lightened)\(important)"
        case "background", "background-color":
            if trimmed.lowercased().contains("url(") || !Self.isLightBackground(Self.colorPart(ofBackground: trimmed)) {
                canGoDark = false
                return text
            }
            return "\(prefix):transparent\(important)"
        case "background-image":
            if trimmed.lowercased() != "none" { canGoDark = false }
            return text
        case _ where property.hasPrefix("border") || property == "outline":
            // Outlook draws table rules in `windowtext`: black on a dark page would vanish.
            var changed = false
            let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: false).map { token -> String in
                guard let lightened = Self.lightened(String(token)) else { return String(token) }
                changed = true
                return lightened
            }
            return changed ? "\(prefix):\(tokens.joined(separator: " "))\(important)" : text
        default:
            return text
        }
    }

    /// The colour in a `background` shorthand: the first token that reads as one, or the
    /// whole value when none does (`none`, `inherit`, or something unknown).
    private static func colorPart(ofBackground value: String) -> String {
        for token in value.split(whereSeparator: \.isWhitespace) where parse(String(token)) != nil {
            return String(token)
        }
        return value
    }

    // MARK: - Colours

    struct RGB: Equatable {
        var r: Double, g: Double, b: Double
        var alpha: Double = 1
    }

    private static let keywordsWithoutColor: Set<String> = ["", "none", "transparent", "inherit", "initial", "unset", "revert", "currentcolor", "window"]

    private static let named: [String: RGB] = [
        "black": RGB(r: 0, g: 0, b: 0), "windowtext": RGB(r: 0, g: 0, b: 0), "white": RGB(r: 1, g: 1, b: 1),
        "gray": RGB(r: 0.5, g: 0.5, b: 0.5), "grey": RGB(r: 0.5, g: 0.5, b: 0.5), "silver": RGB(r: 0.75, g: 0.75, b: 0.75),
        "navy": RGB(r: 0, g: 0, b: 0.5), "blue": RGB(r: 0, g: 0, b: 1), "darkblue": RGB(r: 0, g: 0, b: 0.545),
        "maroon": RGB(r: 0.5, g: 0, b: 0), "darkred": RGB(r: 0.545, g: 0, b: 0), "red": RGB(r: 1, g: 0, b: 0),
        "green": RGB(r: 0, g: 0.5, b: 0), "darkgreen": RGB(r: 0, g: 0.392, b: 0), "purple": RGB(r: 0.5, g: 0, b: 0.5),
        "teal": RGB(r: 0, g: 0.5, b: 0.5), "olive": RGB(r: 0.5, g: 0.5, b: 0), "dimgray": RGB(r: 0.412, g: 0.412, b: 0.412),
        "darkgray": RGB(r: 0.663, g: 0.663, b: 0.663), "whitesmoke": RGB(r: 0.961, g: 0.961, b: 0.961),
    ]

    /// `#rgb`, `#rrggbb` (with or without `#`, as `bgcolor` writes it), `rgb()`/`rgba()`, or a
    /// common name. `nil` for anything else.
    static func parse(_ raw: String) -> RGB? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let color = named[value] { return color }
        if value.hasPrefix("rgb") {
            guard let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close else { return nil }
            let parts = value[value.index(after: open)..<close]
                .split(whereSeparator: { $0 == "," || $0 == "/" || $0.isWhitespace })
                .map { String($0) }
            guard parts.count >= 3 else { return nil }
            func channel(_ part: String) -> Double? {
                if part.hasSuffix("%") { return Double(part.dropLast()).map { $0 / 100 } }
                return Double(part).map { $0 / 255 }
            }
            guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
            var alpha = 1.0
            if parts.count > 3 {
                alpha = parts[3].hasSuffix("%") ? (Double(parts[3].dropLast()) ?? 100) / 100 : Double(parts[3]) ?? 1
            }
            return RGB(r: min(1, max(0, r)), g: min(1, max(0, g)), b: min(1, max(0, b)), alpha: alpha)
        }
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 3 || hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        let digits = hex.count == 3 ? hex.map { "\($0)\($0)" }.joined() : hex
        guard let number = Int(digits, radix: 16) else { return nil }
        return RGB(r: Double((number >> 16) & 0xFF) / 255, g: Double((number >> 8) & 0xFF) / 255, b: Double(number & 0xFF) / 255)
    }

    /// White, near white, see-through or no colour at all: a page the reader may paint.
    static func isLightBackground(_ value: String) -> Bool {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if keywordsWithoutColor.contains(lowered) { return true }
        guard let color = parse(lowered) else { return false }
        return color.alpha < 0.05 || luminance(color) >= 0.8
    }

    /// The text colour for a dark page: a dark colour with its lightness turned over (black is
    /// the reader's own light grey), a light one as it is. `nil` keeps the value.
    static func lightened(_ value: String) -> String? {
        guard let color = parse(value) else { return nil }
        var (hue, saturation, lightness) = hsl(color)
        guard lightness < 0.5 else { return nil }
        if saturation < 0.08 && lightness < 0.2 { return textColor }
        lightness = max(1 - lightness, 0.62)
        let rgb = rgbFrom(hue: hue, saturation: saturation, lightness: lightness)
        return String(format: "#%02x%02x%02x", Int((rgb.r * 255).rounded()), Int((rgb.g * 255).rounded()), Int((rgb.b * 255).rounded()))
    }

    /// The reader's text on a dark page.
    static let textColor = "#e3e3e6"

    private static func luminance(_ c: RGB) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    private static func hsl(_ c: RGB) -> (Double, Double, Double) {
        let maxValue = max(c.r, c.g, c.b), minValue = min(c.r, c.g, c.b)
        let lightness = (maxValue + minValue) / 2
        guard maxValue != minValue else { return (0, 0, lightness) }
        let delta = maxValue - minValue
        let saturation = lightness > 0.5 ? delta / (2 - maxValue - minValue) : delta / (maxValue + minValue)
        var hue: Double
        switch maxValue {
        case c.r: hue = (c.g - c.b) / delta + (c.g < c.b ? 6 : 0)
        case c.g: hue = (c.b - c.r) / delta + 2
        default: hue = (c.r - c.g) / delta + 4
        }
        hue /= 6
        return (hue, saturation, lightness)
    }

    private static func rgbFrom(hue: Double, saturation: Double, lightness: Double) -> RGB {
        guard saturation > 0 else { return RGB(r: lightness, g: lightness, b: lightness) }
        let q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return RGB(r: channel(hue + 1 / 3), g: channel(hue), b: channel(hue - 1 / 3))
    }
}
