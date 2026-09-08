import XCTest
@testable import LunaTV

final class NetworkRecoveryTests: XCTestCase {
    private func episode(_ title: String, _ index: Int, host: String = "a") -> Episode {
        Episode(id: "\(host)-\(index)", title: title,
                url: URL(string: "https://\(host).example.test/\(index).m3u8")!, index: index)
    }

    func testPausedPlayerNeverAutoRecovers() {
        var policy = PlaybackRecoveryPolicy()
        XCTAssertEqual(policy.decide(connected: true, userWantsPlayback: false, stalledFor: 90,
                                     now: 100), .wait)
        XCTAssertEqual(policy.attempts, 0)
    }
    func testOfflineDoesNotConsumeRetryBudget() {
        var policy = PlaybackRecoveryPolicy()
        for time in 0..<20 {
            XCTAssertEqual(policy.decide(connected: false, userWantsPlayback: true, stalledFor: 90,
                                         now: Double(time * 10)), .wait)
        }
        XCTAssertEqual(policy.attempts, 0)
    }
    func testStallRecoveryIsBoundedAndDebounced() {
        var policy = PlaybackRecoveryPolicy()
        XCTAssertEqual(policy.decide(connected: true, userWantsPlayback: true, stalledFor: 7,
                                     now: 0), .wait)
        XCTAssertEqual(policy.decide(connected: true, userWantsPlayback: true, stalledFor: 8,
                                     now: 8), .reload)
        XCTAssertEqual(policy.decide(connected: true, userWantsPlayback: true, stalledFor: 8,
                                     now: 9), .wait)
        for time in [16.0, 24.0] {
            XCTAssertEqual(policy.decide(connected: true, userWantsPlayback: true, stalledFor: 8,
                                         now: time), .reload)
        }
        XCTAssertEqual(policy.decide(connected: true, userWantsPlayback: true, stalledFor: 8,
                                     now: 32), .exhausted)
        policy.reset()
        XCTAssertEqual(policy.attempts, 0)
    }
    func testNoAlternativeReloadsWithoutInventingASource() {
        var policy = PlaybackRecoveryPolicy()
        for time in [8.0, 16.0, 24.0] {
            XCTAssertEqual(policy.decide(connected: true, userWantsPlayback: true, stalledFor: 8,
                                         now: time), .reload)
        }
    }
    @MainActor func testUserVisibleNamePreservesBundleIdentity() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "YJTV")
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.lunatv.mobile.ios")
    }
    func testSparseSourceMatchesEpisodeNotOffset() {
        let source = episode("第12集", 11)
        let target = [episode("EP01", 0, host: "b"), episode("EP12", 1, host: "b")]
        XCTAssertEqual(EpisodeIdentity.matchingIndex(for: source, in: target), 1)
        XCTAssertNil(EpisodeIdentity.matchingIndex(for: episode("第2集", 1), in: target))
    }
    func testAmbiguousEpisodeIsNotAutomaticallySelected() {
        XCTAssertNil(EpisodeIdentity.matchingIndex(for: episode("第1集", 0),
            in: [episode("EP1", 0, host: "b"), episode("第01集", 1, host: "b")]))
        XCTAssertNil(EpisodeIdentity.number("第1集预告"))
        XCTAssertNil(EpisodeIdentity.number("2026特别篇"))
    }
    func testSpecialLabelsOnlyMatchExactly() {
        XCTAssertEqual(EpisodeIdentity.matchingIndex(for: episode("特别篇", 1),
            in: [episode("特别篇", 0, host: "b")]), 0)
        XCTAssertNil(EpisodeIdentity.matchingIndex(for: episode("花絮", 1),
            in: [episode("特别篇", 0, host: "b")]))
    }
    func testProbeDoesNotTreatHTMLOrJSONAsPlayableMedia() {
        for value in ["<html>error</html>", "<!DOCTYPE html><body>403</body>", "{\"error\":true}"] {
            XCTAssertTrue(StreamProbePayload.isErrorDocument(Data(value.utf8)))
            XCTAssertFalse(StreamProbePayload.isMediaSample(Data(value.utf8)))
        }
        XCTAssertFalse(StreamProbePayload.isMediaSample(Data("#EXTM3U\nseg.ts".utf8)))
        var ts = Data(repeating: 0, count: 376)
        ts[0] = 0x47; ts[188] = 0x47
        XCTAssertTrue(StreamProbePayload.isMediaSample(ts))
        XCTAssertTrue(StreamProbePayload.isMediaSample(Data([0, 0, 0, 20] + Array("ftypisom".utf8))))
    }
    @MainActor func testMonitorDetectsRouteChangesButDoesNotInventVPNOr5G() {
        let monitor = NetworkMonitor(startMonitoring: false)
        let wifi = NetworkSnapshot(kind: .wifi)
        monitor.accept(wifi, fingerprint: "route-a")
        let first = monitor.snapshot.generation
        monitor.accept(wifi, fingerprint: "route-a")
        XCTAssertEqual(monitor.snapshot.generation, first)
        monitor.accept(wifi, fingerprint: "route-b")
        XCTAssertEqual(monitor.snapshot.generation, first + 1)
        monitor.revalidateSystemRoute()
        XCTAssertEqual(monitor.snapshot.generation, first + 2)
        XCTAssertEqual(monitor.snapshot.title, "Wi-Fi")
    }
    func testCellularAvoidsHomeLANAndUsesSmallerBuffer() {
        let wifi = NetworkSnapshot(kind: .wifi)
        let cell = NetworkSnapshot(kind: .cellular, isExpensive: true)
        XCTAssertFalse(cell.permitsHomeLAN)
        XCTAssertTrue(wifi.permitsHomeLAN)
        XCTAssertLessThan(cell.bufferSeconds, wifi.bufferSeconds)
        XCTAssertEqual(cell.title, "移动网络")
    }
    @MainActor func testTransportFollowsAllSystemNetworkTypesAndInvalidatesPool() {
        let transport = NetworkTransport()
        let config = transport.session.configuration
        XCTAssertTrue(config.allowsCellularAccess)
        XCTAssertTrue(config.allowsExpensiveNetworkAccess)
        XCTAssertTrue(config.allowsConstrainedNetworkAccess)
        let initial = transport.session
        transport.update(NetworkSnapshot(kind: .cellular, isExpensive: true, generation: 1))
        XCTAssertFalse(initial === transport.session)
        let current = transport.session
        transport.update(transport.snapshot)
        XCTAssertTrue(current === transport.session)
    }
    @MainActor func testRetryPolicyDoesNotBypassTLSOrAuthentication() {
        XCTAssertTrue(NetworkTransport.mayRetry(URLError(.networkConnectionLost), routeChanged: false))
        XCTAssertFalse(NetworkTransport.mayRetry(URLError(.cancelled), routeChanged: false))
        XCTAssertTrue(NetworkTransport.mayRetry(URLError(.cancelled), routeChanged: true))
        XCTAssertFalse(NetworkTransport.mayRetry(URLError(.serverCertificateUntrusted), routeChanged: true))
        XCTAssertFalse(NetworkTransport.mayRetry(URLError(.userAuthenticationRequired), routeChanged: true))
    }
    @MainActor func testCrossSourceHistoryRetainsEpisodeProgressAndV1Storage() throws {
        let name = "LunaTVNetworkTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PersistenceStore(defaults: defaults)
        let work = CatalogItem(id: "season-one", title: "同名剧", section: .drama, year: "2024")
        let other = CatalogItem(id: "season-two", title: "同名剧2", section: .drama, year: "2026")
        store.toggleFavorite(work)
        store.updateHistory(item: work, sourceID: "a", episode: episode("第12集", 11), position: 125, duration: 1000)
        XCTAssertEqual(store.resumePosition(item: work, episode: episode("EP12", 1, host: "b")), 125)
        XCTAssertEqual(store.resumePosition(item: other, episode: episode("EP12", 1, host: "b")), 0)
        store.updateHistory(item: work, sourceID: "b", episode: episode("EP12", 1, host: "b"), position: 140, duration: 1000)
        let reloaded = PersistenceStore(defaults: defaults)
        XCTAssertEqual(reloaded.history.count, 1)
        XCTAssertEqual(reloaded.history.first?.positionSeconds, 140)
        XCTAssertTrue(reloaded.isFavorite(work))
        XCTAssertNotNil(defaults.data(forKey: "ios.history.v1"))
    }
    @MainActor func testCellularRepositoryKeepsPublicAlternativesAndCatalogRevision() {
        let repository = ContentRepository()
        let revision = repository.contentRevision
        repository.networkDidChange(NetworkSnapshot(kind: .cellular, isExpensive: true, generation: 1))
        let urls = repository.sharedCatalogURLs(filters: BrowseFilters(section: .drama), start: 0, pageSize: 24)
        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(urls.allSatisfy { $0.scheme == "https" })
        XCTAssertEqual(repository.contentRevision, revision)
        repository.networkDidChange(NetworkSnapshot(kind: .wifi, generation: 2))
        XCTAssertEqual(repository.sharedCatalogURLs(filters: BrowseFilters(section: .drama), start: 0, pageSize: 24).count, 3)
    }
}
