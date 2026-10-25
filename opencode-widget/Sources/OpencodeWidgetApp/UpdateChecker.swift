import Foundation

/// A newer release advertised by the project's `version.json` manifest.
struct UpdateInfo: Equatable, Sendable {
    let version: String
    let build: Int
    let releaseURL: URL
    let notes: String
}

enum UpdateVersion {
    /// Parses a dotted numeric version. Returns nil unless every component is a
    /// non-negative integer of at most nine digits, so a malformed manifest can
    /// never win a comparison by accident.
    static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part) else { return nil }
            values.append(value)
        }
        return values
    }

    static func isNewer(version: String, build: Int, than currentVersion: String, currentBuild: Int) -> Bool {
        guard build >= 0, currentBuild >= 0,
              let remote = components(version), let current = components(currentVersion) else { return false }
        for index in 0..<max(remote.count, current.count) {
            let remotePart = index < remote.count ? remote[index] : 0
            let currentPart = index < current.count ? current[index] : 0
            if remotePart != currentPart { return remotePart > currentPart }
        }
        // Same marketing version: only a higher build is an update.
        return build > currentBuild
    }
}

struct UpdateManifest: Decodable, Sendable {
    let latest: String
    let build: Int
    let url: String
    let notes: String?
}

enum UpdateManifestDecoder {
    /// Release links must be HTTPS on GitHub so a compromised or malformed
    /// manifest cannot send the user somewhere unexpected.
    static let allowedHost = "github.com"

    static func update(from data: Data, currentVersion: String, currentBuild: Int) -> UpdateInfo? {
        guard let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: data),
              manifest.build >= 0, manifest.build <= 1_000_000_000,
              let releaseURL = URL(string: manifest.url),
              releaseURL.scheme?.lowercased() == "https",
              releaseURL.host?.lowercased() == allowedHost,
              UpdateVersion.isNewer(version: manifest.latest, build: manifest.build,
                                    than: currentVersion, currentBuild: currentBuild) else { return nil }
        return UpdateInfo(
            version: manifest.latest,
            build: manifest.build,
            releaseURL: releaseURL,
            notes: (manifest.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct UpdateCheckPolicy: Equatable {
    var interval: TimeInterval = 24 * 3_600
    /// A missing or future last-check date triggers a check rather than
    /// suppressing updates because the system clock moved.
    func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck, lastCheck <= now else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }
}

enum AppVersion {
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var build: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
    }
}

/// Checks the published manifest at most once per policy interval. Failures are
/// silent: a missing network never changes quota, usage or cached history.
@MainActor
final class UpdateService {
    static let shared = UpdateService()
    static let manifestURL = URL(string: "https://raw.githubusercontent.com/fathur6/frontier-model-token-dashboard/main/version.json")!
    static let lastCheckKey = "UpdateService.lastCheck"
    static let skippedVersionKey = "UpdateService.skippedVersion"

    private let defaults: UserDefaults
    private let policy: UpdateCheckPolicy
    private let now: @Sendable () -> Date
    private let fetch: @Sendable (URL) async -> Data?
    private var isChecking = false

    init(
        defaults: UserDefaults = .standard,
        policy: UpdateCheckPolicy = UpdateCheckPolicy(),
        now: @escaping @Sendable () -> Date = Date.init,
        fetch: @escaping @Sendable (URL) async -> Data? = UpdateService.download
    ) {
        self.defaults = defaults
        self.policy = policy
        self.now = now
        self.fetch = fetch
    }

    static func download(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("OpencodeWidget/\(AppVersion.short)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              data.count <= 64 * 1_024 else { return nil }
        return data
    }

    func checkIfDue(force: Bool = false, currentVersion: String, currentBuild: Int) async -> UpdateInfo? {
        guard !isChecking else { return nil }
        let moment = now()
        let lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date
        guard force || policy.isDue(lastCheck: lastCheck, now: moment) else { return nil }
        isChecking = true
        defer { isChecking = false }

        guard let data = await fetch(Self.manifestURL) else { return nil }
        defaults.set(moment, forKey: Self.lastCheckKey)
        guard let update = UpdateManifestDecoder.update(from: data, currentVersion: currentVersion, currentBuild: currentBuild),
              update.version != defaults.string(forKey: Self.skippedVersionKey) else { return nil }
        return update
    }

    func skip(version: String) {
        defaults.set(version, forKey: Self.skippedVersionKey)
    }

    /// Publishes the result to the menu after the normal (throttled) check.
    func publishAvailability() async {
        guard let update = await checkIfDue(currentVersion: AppVersion.short, currentBuild: AppVersion.build) else { return }
        MenuBarState.shared.availableUpdate = update
    }
}
