import Foundation

struct PopoverSize: Equatable {
    static let defaultValue = PopoverSize(width: 420, height: 560)
    static let minimum = PopoverSize(width: 360, height: 320)
    static let maximum = PopoverSize(width: 760, height: 820)

    let width: Double
    let height: Double

    func clamped() -> PopoverSize {
        PopoverSize(
            width: min(max(width, Self.minimum.width), Self.maximum.width),
            height: min(max(height, Self.minimum.height), Self.maximum.height)
        )
    }

    func resizedBy(widthDelta: Double, heightDelta: Double) -> PopoverSize {
        PopoverSize(
            width: width + widthDelta,
            height: height + heightDelta
        )
        .clamped()
    }
}

enum PopoverSizeStore {
    private static let widthKey = "popoverWidth"
    private static let heightKey = "popoverHeight"

    static func load(from defaults: UserDefaults = .standard) -> PopoverSize {
        let width = defaults.double(forKey: widthKey)
        let height = defaults.double(forKey: heightKey)

        guard width > 0, height > 0 else {
            return .defaultValue
        }

        return PopoverSize(width: width, height: height).clamped()
    }

    static func save(_ size: PopoverSize, to defaults: UserDefaults = .standard) {
        let clamped = size.clamped()
        defaults.set(clamped.width, forKey: widthKey)
        defaults.set(clamped.height, forKey: heightKey)
    }
}
