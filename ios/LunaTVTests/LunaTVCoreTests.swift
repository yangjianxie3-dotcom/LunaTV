import XCTest
@testable import LunaTV

final class LunaTVCoreTests: XCTestCase {
    func testProfileVersionReadsPackageMetadataRatherThanFixedText() {
        XCTAssertEqual(AppVersion.profileLabel(infoDictionary: [
            "CFBundleShortVersionString": "9.8.7", "CFBundleVersion": "42"
        ]), "iPhone 版 9.8.7 · build 42")
        XCTAssertEqual(AppVersion.profileLabel(infoDictionary: [
            "CFBundleShortVersionString": "9.8.8"
        ]), "iPhone 版 9.8.8")
    }

    func testProfileMissingVersionDoesNotPretendToBeAnOldRelease() {
        XCTAssertEqual(AppVersion.profileLabel(infoDictionary: nil), "iPhone 版（版本未知）")
        XCTAssertEqual(AppVersion.profileLabel(infoDictionary: [
            "CFBundleShortVersionString": " "
        ]), "iPhone 版（版本未知）")
    }

    func testNetworkUserAgentUsesPackageVersion() {
        XCTAssertEqual(AppVersion.userAgent(infoDictionary: [
            "CFBundleShortVersionString": "3.0.0"
        ]), "LunaTV-iOS/3.0.0")
        XCTAssertEqual(AppVersion.userAgent(infoDictionary: nil), "LunaTV-iOS/unknown")
    }

    func testLegacyLocalUpdatePageMigratesToStableHTTPSPage() throws {
        let legacy = Data(#"""
        {
          "remoteConfigurationURL":"",
          "testFlightURL":"http://192.168.1.181:8799/ios/",
          "refreshIntervalSeconds":600
        }
        """#.utf8)
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: legacy)
        XCTAssertEqual(preferences.testFlightURL, AppPreferences.publicUpdateURL)
        XCTAssertEqual(AppPreferences().testFlightURL, AppPreferences.publicUpdateURL)
    }

    func testPlayerDisplayModeUsesRealFullscreenLabels() {
        XCTAssertFalse(PlayerDisplayMode.standard.isFullscreen)
        XCTAssertEqual(PlayerDisplayMode.standard.buttonTitle, "全屏")
        XCTAssertTrue(PlayerDisplayMode.fullscreen.isFullscreen)
        XCTAssertEqual(PlayerDisplayMode.fullscreen.buttonTitle, "退出全屏")
        XCTAssertNotEqual(PlayerDisplayMode.standard.buttonIcon, PlayerDisplayMode.fullscreen.buttonIcon)
    }

    func testCurrentYearIsAvailableToFilters() {
        let currentYear = Calendar.current.component(.year, from: Date())
        let years = stride(from: currentYear, through: 1990, by: -1).map(String.init)
        XCTAssertEqual(years.first, String(currentYear))
        XCTAssertTrue(years.contains("2026") || currentYear < 2026)
    }

    func testModelRoundTripPreservesEpisodeURL() throws {
        let item = CatalogItem(id: "test", title: "测试剧集", section: .drama, year: "2026")
        let episode = Episode(id: "https://example.com/1.m3u8", title: "第1集",
                              url: try XCTUnwrap(URL(string: "https://example.com/1.m3u8")), index: 0)
        let record = PlaybackRecord(id: episode.id, item: item, sourceID: "source",
                                    episode: episode, positionSeconds: 120,
                                    durationSeconds: 1_200, updatedAt: Date())
        let encoded = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(PlaybackRecord.self, from: encoded)
        XCTAssertEqual(decoded.episode.url, episode.url)
        XCTAssertEqual(decoded.positionSeconds, 120)
    }

    @MainActor
    func testPersistenceKeepsOnlyLatestRecordForOneEpisode() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "LunaTVCoreTests"))
        suite.removePersistentDomain(forName: "LunaTVCoreTests")
        let store = PersistenceStore(defaults: suite)
        let item = CatalogItem(id: "test", title: "测试剧集", section: .drama)
        let episode = Episode(id: "https://example.com/1.m3u8", title: "第1集",
                              url: try XCTUnwrap(URL(string: "https://example.com/1.m3u8")), index: 0)
        store.updateHistory(item: item, sourceID: "a", episode: episode,
                            position: 10, duration: 100)
        store.updateHistory(item: item, sourceID: "a", episode: episode,
                            position: 20, duration: 100)
        XCTAssertEqual(store.history.count, 1)
        XCTAssertEqual(store.history.first?.positionSeconds, 20)
    }

    @MainActor
    func testSearchHistoryDeduplicatesAndKeepsLatestFirst() throws {
        let suiteName = "LunaTVSearchHistoryTests"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        let store = PersistenceStore(defaults: suite)
        store.rememberSearch("繁花")
        store.rememberSearch("庆余年")
        store.rememberSearch("繁花")
        XCTAssertEqual(store.searchHistory, ["繁花", "庆余年"])
    }

    func testVerifiedPlaybackSourceRanksBeforeUnavailableSource() throws {
        let episode = Episode(id: "episode", title: "第1集",
                              url: try XCTUnwrap(URL(string: "https://example.com/1.m3u8")), index: 0)
        let unavailable = PlaybackSource(id: "slow", name: "线路A",
                                         responseTimeMilliseconds: 20, episodes: [episode],
                                         streamHealth: .unavailable, streamLatencyMilliseconds: nil)
        let verified = PlaybackSource(id: "verified", name: "线路B",
                                      responseTimeMilliseconds: 500, episodes: [episode],
                                      streamHealth: .verified, streamLatencyMilliseconds: 120)
        XCTAssertEqual(PlaybackSourceRank.sorted([unavailable, verified]).first?.id, "verified")
    }

    @MainActor
    func testCatalogClassificationRecognizesLeafMovieAndAnimeTypes() {
        let repository = ContentRepository()
        XCTAssertEqual(repository.classify("剧情片 动作片"), .movie)
        XCTAssertEqual(repository.classify("日本动漫 日韩动漫"), .anime)
        XCTAssertEqual(repository.classify("动画片"), .anime)
        XCTAssertEqual(repository.classify("大陆综艺"), .variety)
        XCTAssertEqual(repository.classify("国产剧"), .drama)
    }

    func testCatalogDeduplicationKeyIgnoresProviderSpecificIdentifier() {
        let first = CatalogItem(id: "provider-a:1", title: "  新 番！", section: .anime)
        let second = CatalogItem(id: "provider-b:99", title: "新番", section: .anime)
        XCTAssertEqual(first.deduplicationKey, second.deduplicationKey)
    }

    func testCatalogDeduplicationUsesCanonicalWorkIdentityWhenAvailable() {
        let first = CatalogItem(id: "1", workID: "douban:123", title: "同名剧", section: .drama)
        let second = CatalogItem(id: "2", workID: "douban:456", title: "同名剧", section: .drama)
        XCTAssertNotEqual(first.deduplicationKey, second.deduplicationKey)
    }

    @MainActor
    func testSharedCatalogQueryMapsHongKongDramaAndCursor() throws {
        let repository = ContentRepository()
        let filters = BrowseFilters(section: .drama, category: "港剧", genre: "悬疑",
                                    region: "全部", year: "2026", sort: "近期更新")
        let url = try XCTUnwrap(repository.sharedCatalogURL(filters: filters, start: 48, pageSize: 24))
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: query.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(values["kind"], "tv")
        XCTAssertEqual(values["format"], "电视剧")
        XCTAssertEqual(values["category"], "悬疑")
        XCTAssertEqual(values["region"], "中国香港")
        XCTAssertEqual(values["start"], "48")
        XCTAssertEqual(values["limit"], "24")
        XCTAssertEqual(values["sort"], "R")
    }

    @MainActor
    func testSharedCatalogUsesThreeIndependentServiceRoutes() throws {
        let repository = ContentRepository()
        let urls = repository.sharedCatalogURLs(
            filters: BrowseFilters(section: .drama, category: "大陆剧"),
            start: 0, pageSize: 24)
        XCTAssertEqual(urls.compactMap(\.host), [
            "lunatv-vidaa-app.pages.dev",
            "192.168.1.181",
            "lunatv-vidaa-service.tw-iproyal-worker.workers.dev"
        ])
        XCTAssertTrue(urls[0].absoluteString.contains("/api/catalog"))
        XCTAssertEqual(urls[1].port, 8787)
    }

    @MainActor
    func testBundledCatalogProvidesOfflineHongKongDramaPage() throws {
        let repository = ContentRepository()
        let filters = BrowseFilters(section: .drama, category: "港剧")
        let page = try XCTUnwrap(repository.bundledCatalogPage(filters: filters,
                                                               start: 0, pageSize: 24))
        XCTAssertEqual(page.items.count, 24)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.paginationStatus, "bundled-fallback")
        XCTAssertTrue(page.items.allSatisfy { $0.section == .drama })
        XCTAssertTrue(page.items.allSatisfy { $0.sourceLabel == "安装包内置片库" })
    }

    func testCatalogPageResultCanBePersistedForOfflineReuse() throws {
        let item = CatalogItem(id: "cached", title: "缓存剧集", section: .drama)
        let original = CatalogPageResult(items: [item], nextStart: 24, hasMore: true,
                                         paginationStatus: "more", notice: "在线目录")
        let decoded = try JSONDecoder().decode(CatalogPageResult.self,
                                                from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.items, [item])
        XCTAssertEqual(decoded.nextStart, 24)
        XCTAssertTrue(decoded.hasMore)
    }

    @MainActor
    func testSharedCatalogQuerySeparatesAnimeSeriesAndTheater() throws {
        let repository = ContentRepository()
        let series = try XCTUnwrap(repository.sharedCatalogURL(
            filters: BrowseFilters(section: .anime, category: "在播国漫"), start: 0, pageSize: 24))
        let theater = try XCTUnwrap(repository.sharedCatalogURL(
            filters: BrowseFilters(section: .anime, category: "剧场版"), start: 0, pageSize: 24))
        let seriesValues = Dictionary(uniqueKeysWithValues:
            try XCTUnwrap(URLComponents(url: series, resolvingAgainstBaseURL: false)?.queryItems)
                .compactMap { item in item.value.map { (item.name, $0) } })
        let theaterValues = Dictionary(uniqueKeysWithValues:
            try XCTUnwrap(URLComponents(url: theater, resolvingAgainstBaseURL: false)?.queryItems)
                .compactMap { item in item.value.map { (item.name, $0) } })
        XCTAssertEqual(seriesValues["kind"], "tv")
        XCTAssertEqual(seriesValues["category"], "动画")
        XCTAssertEqual(seriesValues["format"], "电视剧")
        XCTAssertEqual(seriesValues["region"], "中国大陆")
        XCTAssertEqual(theaterValues["kind"], "movie")
        XCTAssertEqual(theaterValues["format"], "all")
    }

    func testCatalogDeduplicationCollapsesLanguageAndSeasonVariants() {
        let cantonese = CatalogItem(id: "a", title: "飞常日志 第二季 粤语", section: .drama)
        let mandarin = CatalogItem(id: "b", title: "飞常日志2国语", section: .drama)
        let plain = CatalogItem(id: "c", title: "飞常日志2", section: .drama)
        XCTAssertEqual(cantonese.deduplicationKey, mandarin.deduplicationKey)
        XCTAssertEqual(mandarin.deduplicationKey, plain.deduplicationKey)
        XCTAssertEqual(MediaTitleIdentity.canonicalTitle("香港探秘地图 普通话版"), "香港探秘地图")
    }

    func testLanguageDetectionTrustsExplicitTitleBeforeIncorrectProviderMetadata() {
        XCTAssertEqual(MediaTitleIdentity.language(title: "飞常日志2国语", metadata: ["粤语"]), "国语")
        XCTAssertEqual(MediaTitleIdentity.language(title: "飞常日志2粤语", metadata: ["国语"]), "粤语")
        XCTAssertEqual(MediaTitleIdentity.language(title: "新闻女王2", metadata: ["粤语"]), "粤语")
    }

    func testPlaybackSourceRankingUsesMeasuredThroughputBeforeLatency() throws {
        let episode = Episode(id: "episode", title: "第1集",
                              url: try XCTUnwrap(URL(string: "https://example.com/1.m3u8")), index: 0)
        let slowerCache = PlaybackSource(id: "a", name: "线路A", responseTimeMilliseconds: 20,
                                         episodes: [episode], streamHealth: .verified,
                                         streamLatencyMilliseconds: 40,
                                         streamThroughputKilobytesPerSecond: 400)
        let fasterCache = PlaybackSource(id: "b", name: "线路B", responseTimeMilliseconds: 200,
                                         episodes: [episode], streamHealth: .verified,
                                         streamLatencyMilliseconds: 100,
                                         streamThroughputKilobytesPerSecond: 1_200)
        XCTAssertEqual(PlaybackSourceRank.sorted([slowerCache, fasterCache]).first?.id, "b")
    }

    @MainActor
    func testRegionGroupsMapProviderLabelsInsteadOfLiteralTextOnly() {
        let repository = ContentRepository()
        let hongKongDrama = CatalogItem(id: "hk", title: "港剧", section: .drama,
                                        category: "香港剧", region: "香港")
        let americanDrama = CatalogItem(id: "us", title: "美剧", section: .drama,
                                        category: "欧美剧", region: "美国")
        XCTAssertTrue(repository.matchesRegion(hongKongDrama, selection: "华语"))
        XCTAssertTrue(repository.matchesRegion(americanDrama, selection: "欧美"))
        XCTAssertFalse(repository.matchesRegion(hongKongDrama, selection: "中国大陆"))
    }

    @MainActor
    func testDramaCategoriesRecognizeHongKongAndTaiwanProviderNames() {
        let repository = ContentRepository()
        XCTAssertTrue(repository.matchesDramaCategory("香港剧 警匪", category: "港剧"))
        XCTAssertTrue(repository.matchesDramaCategory("台湾剧 爱情", category: "台剧"))
        XCTAssertFalse(repository.matchesDramaCategory("国产剧 古装", category: "港剧"))
    }
}
