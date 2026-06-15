import Foundation

struct PopoverSize: Equatable {
    static let defaultValue = PopoverSize(width: 420, height: 560)
    static let minimum = PopoverSize(width: 360, height: 320)
    static let maximum = PopoverSize(width: 760, height: 820)

    /// Discrete user-selectable popover sizes — the ONLY sizes the popover ever takes.
    /// `compact` is the historical default; the larger presets grow mostly in height.
    /// Widths are kept modest on purpose: MenuBarExtra re-places (flips) a popover that
    /// would overflow the screen edge to the right of the menu-bar icon, and that
    /// placement can't be reliably overridden. Keeping widths within the space available
    /// beside a right-edge icon means macOS leaves the popover anchored under the icon at
    /// every size. All values stay within `minimum…maximum`.
    enum Preset: String, CaseIterable, Identifiable {
        case compact
        case medium
        case large

        var id: String { rawValue }

        var size: PopoverSize {
            switch self {
            case .compact: return PopoverSize(width: 420, height: 560)
            case .medium:  return PopoverSize(width: 480, height: 700)
            case .large:   return PopoverSize(width: 540, height: 820)
            }
        }

        var localizationKey: String { "popover.size.\(rawValue)" }
    }

    let width: Double
    let height: Double
}

/// Persists the selected popover-size preset. The preset (not a raw width/height) is the
/// stored unit, so a loaded value is always one of the offered presets — the popover
/// frame and the size pickers can never disagree.
enum PopoverSizePresetStore {
    private static let key = "popoverSizePreset"

    static func load(from defaults: UserDefaults = .standard) -> PopoverSize.Preset {
        guard let raw = defaults.string(forKey: key),
              let preset = PopoverSize.Preset(rawValue: raw) else {
            return .compact
        }
        return preset
    }

    static func save(_ preset: PopoverSize.Preset, to defaults: UserDefaults = .standard) {
        defaults.set(preset.rawValue, forKey: key)
    }
}
