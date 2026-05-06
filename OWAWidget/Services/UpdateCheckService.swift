import AppKit
import Foundation
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

@MainActor
final class UpdateCheckService: ObservableObject {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/ilyabazhenov/mac-owa-widget/releases/latest")!

    private static let minimumIntervalBetweenAutomaticChecks: TimeInterval = 6 * 3600
    private static let periodicTimerInterval: TimeInterval = 6 * 3600

    private enum Keys {
        static let automaticEnabled = "updateCheck.automaticChecksEnabled"
        static let lastCheckAttemptAt = "updateCheck.lastCheckAttemptAt"
        static let skippedVersion = "updateCheck.skippedVersion"
        static let cachedLatestVersion = "updateCheck.cachedLatestVersion"
        static let cachedLatestURL = "updateCheck.cachedLatestURL"
        static let cachedLatestPublishedAt = "updateCheck.cachedLatestPublishedAt"
    }

    private struct GitHubLatestRelease: Decodable {
        let tag_name: String
        let html_url: String
        let draft: Bool
        let prerelease: Bool
        let published_at: String
    }

    @Published private(set) var availableUpdate: AvailableUpdate?
    @Published private(set) var isChecking = false
    @Published var isAutomaticChecksEnabled: Bool {
        didSet {
            defaults.set(isAutomaticChecksEnabled, forKey: Keys.automaticEnabled)
            reschedulePeriodicTimer()
            if isAutomaticChecksEnabled {
                Task { await performRemoteCheck(automatic: true) }
            }
        }
    }

    private let defaults: UserDefaults
    private let urlSession: URLSession
    private let bundle: Bundle
    private let log = Logger(subsystem: "com.owawidget", category: "UpdateCheckService")
    private var periodicTimer: Timer?

    init(
        defaults: UserDefaults = .standard,
        urlSession: URLSession = .shared,
        bundle: Bundle = .main
    ) {
        self.defaults = defaults
        self.urlSession = urlSession
        self.bundle = bundle
        let enabled = defaults.object(forKey: Keys.automaticEnabled) as? Bool ?? true
        _isAutomaticChecksEnabled = Published(initialValue: enabled)
    }

    func start() {
        refreshPublishedState()
        reschedulePeriodicTimer()
        Task { await performRemoteCheck(automatic: true) }
    }

    func checkNow() async {
        await performRemoteCheck(automatic: false)
    }

    func skip(version: String) {
        let normalized = UpdateVersionComparison.normalize(version)
        defaults.set(normalized, forKey: Keys.skippedVersion)
        refreshPublishedState()
    }

    // MARK: - Private

    private func currentAppVersion() -> String {
        bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private func reschedulePeriodicTimer() {
        periodicTimer?.invalidate()
        periodicTimer = nil
        guard isAutomaticChecksEnabled else { return }
        let timer = Timer(timeInterval: Self.periodicTimerInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performRemoteCheck(automatic: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        periodicTimer = timer
    }

    private func isAutomaticFetchThrottled() -> Bool {
        guard let last = defaults.object(forKey: Keys.lastCheckAttemptAt) as? Date else { return false }
        return Date().timeIntervalSince(last) < Self.minimumIntervalBetweenAutomaticChecks
    }

    private func recordCheckAttempt() {
        defaults.set(Date(), forKey: Keys.lastCheckAttemptAt)
    }

    private func refreshPublishedState() {
        guard let version = defaults.string(forKey: Keys.cachedLatestVersion), !version.isEmpty else {
            availableUpdate = nil
            return
        }
        let normalizedLatest = UpdateVersionComparison.normalize(version)
        let current = currentAppVersion()
        if UpdateVersionComparison.compare(normalizedLatest, current) != .orderedDescending {
            availableUpdate = nil
            return
        }
        if let skipped = defaults.string(forKey: Keys.skippedVersion),
           UpdateVersionComparison.normalize(skipped) == normalizedLatest {
            availableUpdate = nil
            return
        }
        guard let urlString = defaults.string(forKey: Keys.cachedLatestURL),
              let url = URL(string: urlString)
        else {
            availableUpdate = nil
            return
        }
        let ts = defaults.double(forKey: Keys.cachedLatestPublishedAt)
        let published = ts > 0 ? Date(timeIntervalSince1970: ts) : Date()
        availableUpdate = AvailableUpdate(version: normalizedLatest, releaseURL: url, publishedAt: published)
    }

    private func performRemoteCheck(automatic: Bool) async {
        guard !isChecking else { return }
        if automatic {
            guard isAutomaticChecksEnabled else { return }
            guard !isAutomaticFetchThrottled() else { return }
        }

        isChecking = true
        defer { isChecking = false }

        recordCheckAttempt()

        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OWAWidget/\(currentAppVersion()) (macOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                log.error("Update check: non-HTTP response")
                return
            }
            guard (200 ... 299).contains(http.statusCode) else {
                log.error("Update check: HTTP \(http.statusCode)")
                return
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .useDefaultKeys
            let release = try decoder.decode(GitHubLatestRelease.self, from: data)
            guard !release.draft, !release.prerelease else {
                log.debug("Update check: ignoring draft/prerelease")
                return
            }
            let tagVersion = UpdateVersionComparison.normalize(release.tag_name)
            guard let url = URL(string: release.html_url) else {
                log.error("Update check: invalid release URL")
                return
            }
            let publishedDate = Self.parseGitHubDate(release.published_at) ?? Date()

            defaults.set(tagVersion, forKey: Keys.cachedLatestVersion)
            defaults.set(release.html_url, forKey: Keys.cachedLatestURL)
            defaults.set(publishedDate.timeIntervalSince1970, forKey: Keys.cachedLatestPublishedAt)

            refreshPublishedState()
        } catch {
            log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func parseGitHubDate(_ raw: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    func openRelease(_ update: AvailableUpdate) {
        NSWorkspace.shared.open(update.releaseURL)
    }
}
