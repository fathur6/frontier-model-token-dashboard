import XCTest
@testable import OpencodeWidgetApp

final class UpdateCheckerTests: XCTestCase {
    /// Mutable stub payload shared with a @Sendable fetch closure.
    private final class Box: @unchecked Sendable {
        var value: Data?
        init(_ value: Data?) { self.value = value }
    }

    // MARK: - Version comparison

    func testNewerPatchMinorMajorAreUpdates() {
        XCTAssertTrue(UpdateVersion.isNewer(version: "1.5.2", build: 8, than: "1.5.1", currentBuild: 7))
        XCTAssertTrue(UpdateVersion.isNewer(version: "1.6.0", build: 1, than: "1.5.9", currentBuild: 99))
        XCTAssertTrue(UpdateVersion.isNewer(version: "2.0.0", build: 1, than: "1.99.99", currentBuild: 99))
    }

    func testEqualVersionNeedsHigherBuildAndOlderVersionNeverPrompts() {
        XCTAssertTrue(UpdateVersion.isNewer(version: "1.5.1", build: 8, than: "1.5.1", currentBuild: 7))
        XCTAssertFalse(UpdateVersion.isNewer(version: "1.5.1", build: 7, than: "1.5.1", currentBuild: 7))
        XCTAssertFalse(UpdateVersion.isNewer(version: "1.5.1", build: 6, than: "1.5.1", currentBuild: 7))
        XCTAssertFalse(UpdateVersion.isNewer(version: "1.4.9", build: 99, than: "1.5.0", currentBuild: 1))
    }

    func testTrailingZeroComponentsCompareNumerically() {
        XCTAssertFalse(UpdateVersion.isNewer(version: "1.5", build: 0, than: "1.5.0", currentBuild: 0))
        XCTAssertTrue(UpdateVersion.isNewer(version: "1.5.0.1", build: 0, than: "1.5.0", currentBuild: 0))
    }

    func testMalformedVersionsNeverTriggerAnUpdate() {
        for version in ["", " ", "1..2", "1.5.x", "1.5.1.2.3", "-1.5.1", "1.5.1-beta", "9999999999.1"] {
            XCTAssertFalse(UpdateVersion.isNewer(version: version, build: 999, than: "1.5.1", currentBuild: 7),
                           "expected rejection for '\(version)'")
        }
        XCTAssertFalse(UpdateVersion.isNewer(version: "1.5.2", build: -1, than: "1.5.1", currentBuild: 7))
    }

    // MARK: - Manifest validation

    private func manifest(latest: String = "1.5.2", build: Int = 8,
                          url: String = "https://github.com/fathur6/frontier-model-token-dashboard/releases/tag/v1.5.2",
                          notes: String? = "  Fixes chart gaps  ") -> Data {
        var object: [String: Any] = ["latest": latest, "build": build, "url": url]
        if let notes { object["notes"] = notes }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testValidManifestProducesReleaseInfoWithTrimmedNotes() {
        let update = UpdateManifestDecoder.update(from: manifest(), currentVersion: "1.5.1", currentBuild: 7)
        XCTAssertEqual(update?.version, "1.5.2")
        XCTAssertEqual(update?.build, 8)
        XCTAssertEqual(update?.releaseURL.host, "github.com")
        XCTAssertEqual(update?.notes, "Fixes chart gaps")
    }

    func testManifestWithoutNotesIsAllowed() {
        let update = UpdateManifestDecoder.update(from: manifest(notes: nil), currentVersion: "1.5.1", currentBuild: 7)
        XCTAssertEqual(update?.notes, "")
    }

    func testSameOrOlderManifestDoesNotPrompt() {
        XCTAssertNil(UpdateManifestDecoder.update(from: manifest(latest: "1.5.1", build: 7), currentVersion: "1.5.1", currentBuild: 7))
        XCTAssertNil(UpdateManifestDecoder.update(from: manifest(latest: "1.5.0", build: 6), currentVersion: "1.5.1", currentBuild: 7))
    }

    func testUnsafeOrMalformedManifestsAreRejected() {
        let unsafeURLs = [
            "http://github.com/fathur6/frontier-model-token-dashboard/releases",
            "https://example.com/releases",
            "https://github.com.evil.example/releases",
            "file:///Applications/OpencodeWidgetApp.app",
            "not a url"
        ]
        for url in unsafeURLs {
            XCTAssertNil(UpdateManifestDecoder.update(from: manifest(url: url), currentVersion: "1.5.1", currentBuild: 7),
                         "expected rejection for '\(url)'")
        }
        XCTAssertNil(UpdateManifestDecoder.update(from: Data("{}".utf8), currentVersion: "1.5.1", currentBuild: 7))
        XCTAssertNil(UpdateManifestDecoder.update(from: Data("not json".utf8), currentVersion: "1.5.1", currentBuild: 7))
        XCTAssertNil(UpdateManifestDecoder.update(from: manifest(latest: "1.5.x"), currentVersion: "1.5.1", currentBuild: 7))
    }

    // MARK: - Throttle

    func testCheckIsDueAfterIntervalOnly() {
        let policy = UpdateCheckPolicy(interval: 24 * 3_600)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(policy.isDue(lastCheck: nil, now: now))
        XCTAssertFalse(policy.isDue(lastCheck: now.addingTimeInterval(-3_600), now: now))
        XCTAssertFalse(policy.isDue(lastCheck: now.addingTimeInterval(-23 * 3_600), now: now))
        XCTAssertTrue(policy.isDue(lastCheck: now.addingTimeInterval(-24 * 3_600), now: now))
        // A clock that moved backwards must not suppress checks indefinitely.
        XCTAssertTrue(policy.isDue(lastCheck: now.addingTimeInterval(3_600), now: now))
    }

    // MARK: - Service

    @MainActor
    func testServiceThrottlesAfterSuccessAndSuppressesDismissedVersion() async {
        let suite = "UpdateCheckerTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let box = Box(manifest())
        let service = UpdateService(defaults: defaults, now: { now }, fetch: { _ in box.value })

        let first = await service.checkIfDue(currentVersion: "1.5.1", currentBuild: 7)
        XCTAssertEqual(first?.version, "1.5.2")

        // Within the interval the cached result is not re-requested.
        let throttled = await service.checkIfDue(currentVersion: "1.5.1", currentBuild: 7)
        XCTAssertNil(throttled)

        // An explicit check still works, but a dismissed version is hidden.
        service.skip(version: "1.5.2")
        let dismissed = await service.checkIfDue(force: true, currentVersion: "1.5.1", currentBuild: 7)
        XCTAssertNil(dismissed)

        // A newer release overrides the dismissal.
        box.value = manifest(latest: "1.5.3", build: 9)
        let newer = await service.checkIfDue(force: true, currentVersion: "1.5.1", currentBuild: 7)
        XCTAssertEqual(newer?.version, "1.5.3")

        defaults.removePersistentDomain(forName: suite)
    }

    @MainActor
    func testFailedFetchIsSilentAndDoesNotConsumeTheInterval() async {
        let suite = "UpdateCheckerTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let box = Box(nil)
        let service = UpdateService(defaults: defaults, now: { now }, fetch: { _ in box.value })

        let offline = await service.checkIfDue(currentVersion: "1.5.1", currentBuild: 7)
        XCTAssertNil(offline)
        XCTAssertNil(defaults.object(forKey: UpdateService.lastCheckKey))

        // The next refresh may retry immediately because the failed attempt was
        // not recorded as a completed check.
        box.value = manifest()
        let recovered = await service.checkIfDue(currentVersion: "1.5.1", currentBuild: 7)
        XCTAssertEqual(recovered?.version, "1.5.2")
        XCTAssertEqual(defaults.object(forKey: UpdateService.lastCheckKey) as? Date, now)

        defaults.removePersistentDomain(forName: suite)
    }

    @MainActor
    func testConcurrentChecksAreCollapsed() async {
        let suite = "UpdateCheckerTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let payload = manifest()
        let service = UpdateService(defaults: defaults, fetch: { _ in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return payload
        })

        async let first = service.checkIfDue(currentVersion: "1.5.1", currentBuild: 7)
        async let second = service.checkIfDue(currentVersion: "1.5.1", currentBuild: 7)
        let results = await [first, second]
        XCTAssertEqual(results.compactMap { $0 }.count, 1)

        defaults.removePersistentDomain(forName: suite)
    }
}
