import AppKit
import Foundation
import Sparkle
import os.log

// MARK: - Version comparison

enum UpdateVersionComparison: Sendable {
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    /// Compares two dotted version strings. `.orderedAscending` means `lhs` is older than `rhs` (rhs is newer).
    static func compare(_ lhsRaw: String, _ rhsRaw: String) -> ComparisonResult {
        let lhs = normalize(lhsRaw)
        let rhs = normalize(rhsRaw)
        guard !lhs.isEmpty, !rhs.isEmpty else { return .orderedSame }
        guard lhs.contains(where: \.isNumber), rhs.contains(where: \.isNumber) else { return .orderedSame }

        let la = lhs.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let ra = rhs.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let maxCount = max(la.count, ra.count)

        for idx in 0 ..< maxCount {
            let lSeg = idx < la.count ? la[idx] : "0"
            let rSeg = idx < ra.count ? ra[idx] : "0"
            let (ln, ls) = parseSegment(lSeg)
            let (rn, rs) = parseSegment(rSeg)
            if ln != rn {
                return ln < rn ? .orderedAscending : .orderedDescending
            }
            if ls == rs { continue }
            if ls.isEmpty != rs.isEmpty {
                // Empty suffix = pure numeric release for this segment; non-empty = prerelease-style tail.
                return rs.isEmpty ? .orderedAscending : .orderedDescending
            }
            if ls < rs { return .orderedAscending }
            if ls > rs { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func parseSegment(_ segment: String) -> (Int, String) {
        let s = segment.trimmingCharacters(in: .whitespaces)
        var i = s.startIndex
        while i < s.endIndex, s[i].isNumber {
            i = s.index(after: i)
        }
        let numStr = String(s[..<i])
        let rest = String(s[i...])
        let n = Int(numStr) ?? 0
        return (n, rest)
    }
}

// MARK: - Models

struct AvailableUpdate: Equatable, Sendable {
    let version: String
    let releaseURL: URL
    let publishedAt: Date
}

// MARK: - Service

/// Front-end for Sparkle's auto-update flow.
///
/// Sparkle is the engine that does the heavy lifting (background polling of the
/// appcast, signature verification, download, install, relaunch). This wrapper
/// publishes a SwiftUI-friendly view of "is an update available right now" and
/// "is the user toggling automatic checks", plus thin commands the UI calls.
@MainActor
final class UpdateCheckService: NSObject, ObservableObject {

    // MARK: Published state

    @Published private(set) var availableUpdate: AvailableUpdate?
    @Published private(set) var isChecking = false
    @Published var isAutomaticChecksEnabled: Bool {
        didSet {
            updaterController?.updater.automaticallyChecksForUpdates = isAutomaticChecksEnabled
        }
    }

    // MARK: Dependencies

    private let bundle: Bundle
    private let defaults: UserDefaults
    private let appVersionOverride: String?
    private let log = Logger(subsystem: "com.owawidget", category: "UpdateCheckService")

    private var updaterController: SPUStandardUpdaterController?
    private var delegateBridge: SparkleUpdaterDelegateBridge?

    private enum Keys {
        static let bannerSkippedVersion = "updateBanner.skippedVersion"
    }

    private static let releasesIndexURL = URL(string: "https://github.com/ilyabazhenov/mac-owa-widget/releases")!

    // MARK: Init

    /// Designated initializer.
    /// - Parameter createUpdater: when `false`, no Sparkle controller is created.
    ///   Used by unit tests to exercise the state mutators in isolation, without
    ///   loading the Sparkle.framework or reading Info.plist keys.
    /// - Parameter appVersionOverride: when provided, used in place of the
    ///   bundle's `CFBundleShortVersionString`. Only used by tests.
    init(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        appVersionOverride: String? = nil,
        createUpdater: Bool = true
    ) {
        self.bundle = bundle
        self.defaults = defaults
        self.appVersionOverride = appVersionOverride
        // Sparkle persists this in UserDefaults under its own key; we mirror it here for SwiftUI binding.
        let enabled = defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
        _isAutomaticChecksEnabled = Published(initialValue: enabled)
        super.init()
        if createUpdater {
            installUpdaterController()
        }
    }

    // MARK: Public API

    /// Starts Sparkle's background updater. Call once per app launch.
    func start() {
        guard let updaterController else { return }
        do {
            try updaterController.updater.start()
            log.debug("Sparkle updater started")
        } catch {
            log.error("Sparkle start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// User-initiated check. Surfaces Sparkle's standard alert if an update is available.
    func checkNow() async {
        guard let updaterController else { return }
        isChecking = true
        defer { isChecking = false }
        updaterController.checkForUpdates(nil)
    }

    /// Triggers Sparkle's full install flow (alert -> download -> install -> relaunch).
    /// Mapped to the "Install" button in the in-app update banner.
    func installUpdate() {
        guard let updaterController else {
            log.error("installUpdate called without an updater controller")
            return
        }
        updaterController.checkForUpdates(nil)
    }

    /// Local UI-only dismissal of the update banner for a specific version.
    /// Does NOT cancel Sparkle's own bookkeeping; subsequent checks still surface
    /// other (newer) versions normally.
    func skip(version: String) {
        let normalized = UpdateVersionComparison.normalize(version)
        defaults.set(normalized, forKey: Keys.bannerSkippedVersion)
        if let current = availableUpdate, UpdateVersionComparison.normalize(current.version) == normalized {
            availableUpdate = nil
        }
    }

    /// Legacy entry point preserved for any external callers; under Sparkle this
    /// just routes to the install flow (no separate "open in browser" action exists).
    func openRelease(_ update: AvailableUpdate) {
        installUpdate()
    }

    // MARK: Sparkle bridge surface (also used by tests)

    /// Updates published state in response to "an update is available" event.
    /// Honors the local banner skip flag.
    func processFoundUpdate(version: String, fileURL: URL?, publishedAt: Date) {
        let normalized = UpdateVersionComparison.normalize(version)
        if let skipped = defaults.string(forKey: Keys.bannerSkippedVersion),
           UpdateVersionComparison.normalize(skipped) == normalized {
            availableUpdate = nil
            return
        }
        let current = currentAppVersion()
        if !current.isEmpty,
           UpdateVersionComparison.compare(normalized, current) != .orderedDescending {
            availableUpdate = nil
            return
        }
        let releaseURL = URL(string: "https://github.com/ilyabazhenov/mac-owa-widget/releases/tag/v\(normalized)")
            ?? fileURL
            ?? Self.releasesIndexURL
        availableUpdate = AvailableUpdate(version: normalized, releaseURL: releaseURL, publishedAt: publishedAt)
    }

    /// Updates published state when Sparkle reports no newer version available.
    func processNoUpdate() {
        availableUpdate = nil
    }

    // MARK: Private

    private func currentAppVersion() -> String {
        if let override = appVersionOverride { return override }
        return bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private func installUpdaterController() {
        let bridge = SparkleUpdaterDelegateBridge()
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: bridge,
            userDriverDelegate: bridge
        )
        bridge.owner = self
        self.delegateBridge = bridge
        self.updaterController = controller
        controller.updater.automaticallyChecksForUpdates = isAutomaticChecksEnabled
    }
}

// MARK: - Sparkle delegate bridge

/// Pure Obj-C delegate adapter. Sparkle requires `NSObject` conformance and
/// invokes the methods from arbitrary contexts; we extract Sendable primitives
/// and hop to the main actor before mutating ``UpdateCheckService`` state.
///
/// Also conforms to ``SPUStandardUserDriverDelegate`` so we can bring Sparkle's
/// update windows to the front. The app runs as an accessory (LSUIElement), so
/// without an explicit activation Sparkle's "new version available" / install
/// progress windows open *behind* other apps' windows.
final class SparkleUpdaterDelegateBridge: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate, @unchecked Sendable {
    weak var owner: UpdateCheckService?

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        let fileURL = item.fileURL
        let date = item.date ?? Date()
        Task { @MainActor [weak self] in
            self?.owner?.processFoundUpdate(version: version, fileURL: fileURL, publishedAt: date)
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor [weak self] in
            self?.owner?.processNoUpdate()
        }
    }

    // MARK: SPUStandardUserDriverDelegate

    /// Called right before Sparkle shows an update window. Activate the app so the
    /// window is ordered in front of all other apps instead of opening behind them.
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        Self.bringAppToFront()
    }

    /// Modal alerts (e.g. "you're up to date", errors) need the same treatment.
    nonisolated func standardUserDriverWillShowModalAlert() {
        Self.bringAppToFront()
    }

    private nonisolated static func bringAppToFront() {
        // Sparkle invokes its user-driver delegate on the main thread, but hop
        // explicitly to satisfy strict concurrency and guard against edge cases.
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
