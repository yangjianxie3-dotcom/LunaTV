import Foundation

enum RepositoryError: LocalizedError {
    case invalidConfiguration
    case invalidResponse
    case noPlayableEpisode

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "播放源配置格式无效"
        case .invalidResponse: return "内容接口返回了无法识别的数据"
        case .noPlayableEpisode: return "该线路没有返回可播放分集"
        }
    }
}

@MainActor
final class ContentRepository: ObservableObject {
    static let defaultSharedServiceURL = "https://lunatv-vidaa-service.tw-iproyal-worker.workers.dev"

    @Published private(set) var configuration = ContentConfiguration.empty
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var refreshError: String?
    @Published private(set) var contentRevision: UInt = 0

    private struct CachedCatalog {
        let createdAt: Date
        let items: [CatalogItem]
    }

    private struct SiteResult: Sendable {
        let item: CatalogItem
        let source: PlaybackSource
    }

    private struct CMSClassEntry: Sendable {
        let id: String
        let name: String
        let parentID: String
    }

    private struct SharedCatalogResponse: Decodable {
        let start: Int?
        let nextStart: Int?
        let hasMore: Bool?
        let paginationStatus: String?
        let list: [SharedCatalogItem]
    }

    private struct SharedCatalogItem: Decodable {
        let id: String?
        let workId: String?
        let title: String
        let poster: String?
        let rate: String?
        let year: LossyString?
    }

    private struct SharedSourcesResponse: Decodable {
        let sources: [SharedSource]
    }

    private struct SharedSource: Decodable {
        let name: String?
        let year: LossyString?
        let site: String?
        let source: String?
        let id: String?
        let type: String?
        let remarks: String?
        let latencyMs: Int?
        let episodes: [SharedEpisode]?
    }

    private struct SharedEpisode: Decodable {
        let label: String?
        let url: String
    }

    /// Several CMS and metadata endpoints alternate between JSON strings and
    /// numbers for year fields. Decode both without invalidating the page.
    private struct LossyString: Decodable {
        let value: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                value = string
            } else if let integer = try? container.decode(Int.self) {
                value = String(integer)
            } else if let number = try? container.decode(Double.self) {
                value = String(number)
            } else {
                throw DecodingError.typeMismatch(String.self,
                    DecodingError.Context(codingPath: decoder.codingPath,
                                          debugDescription: "Expected a string or number"))
            }
        }
    }

    private var catalogCache: [String: CachedCatalog] = [:]
    private var siteClassCache: [String: [CMSClassEntry]] = [:]
    private let session: URLSession

    private let featuredOnAirAnimeTitles = [
        "完美世界", "遮天", "仙逆", "凡人修仙传", "光阴之外",
        "吞噬星空", "斗破苍穹年番", "牧神记", "师兄啊师兄", "神印王座",
        "斗罗大陆2绝世唐门", "诛仙", "沧元图", "灵笼", "一念永恒"
    ]

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadRevalidatingCacheData
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        session = URLSession(configuration: configuration)
    }

    func bootstrap(remoteConfigurationURL: String = "") async {
        do {
            let loadedConfiguration = try await loadConfiguration(remoteURL: remoteConfigurationURL)
            configuration = loadedConfiguration
            catalogCache.removeAll()
            siteClassCache.removeAll()
            lastRefresh = Date()
            refreshError = nil
            contentRevision &+= 1
        } catch {
            refreshError = error.localizedDescription
            if configuration.apiSites.isEmpty, let bundledConfiguration = try? loadBundledConfiguration() {
                configuration = bundledConfiguration
                catalogCache.removeAll()
                siteClassCache.removeAll()
                lastRefresh = Date()
                contentRevision &+= 1
            }
        }
    }

    func refresh(remoteConfigurationURL: String = "") async {
        await bootstrap(remoteConfigurationURL: remoteConfigurationURL)
    }

    func homeSections() async -> [MediaSection: [CatalogItem]] {
        await withTaskGroup(of: (MediaSection, [CatalogItem]).self) { group in
            for section in MediaSection.allCases {
                group.addTask { [weak self] in
                    guard let self else { return (section, []) }
                    let filters = BrowseFilters(section: section, sort: "近期更新")
                    let page = await self.catalogPage(filters: filters, start: 0, pageSize: 8)
                    return (section, page.items)
                }
            }
            var value: [MediaSection: [CatalogItem]] = [:]
            for await result in group { value[result.0] = result.1 }
            return value
        }
    }

    /// Loads the canonical cross-device catalogue first. A provider-direct
    /// query is retained only as an availability fallback when that request
    /// itself fails; a valid empty shared page remains empty.
    func catalogPage(filters: BrowseFilters, start: Int, pageSize: Int = 30) async -> CatalogPageResult {
        do {
            return try await sharedCatalogPage(filters: filters, start: start, pageSize: pageSize)
        } catch {
            let legacyPage = max(0, start) / max(1, pageSize)
            let items = await catalog(filters: filters, page: legacyPage, pageSize: pageSize)
            let nextStart = max(0, start) + items.count
            return CatalogPageResult(items: items, nextStart: nextStart,
                                     hasMore: items.count >= max(1, pageSize),
                                     paginationStatus: "provider-fallback",
                                     notice: "共享目录暂不可用，已读取同分类备用源")
        }
    }

    func sharedCatalogURL(filters: BrowseFilters, start: Int, pageSize: Int) -> URL? {
        guard var components = URLComponents(string: Self.defaultSharedServiceURL + "/api/catalog") else {
            return nil
        }
        var kind = filters.section == .movie ? "movie" : "tv"
        var category = filters.genre == "全部" ? "all" : filters.genre
        var format = "all"
        var region = filters.region == "全部" ? "all" : filters.region

        switch filters.section {
        case .movie:
            break
        case .drama:
            format = "电视剧"
            let categoryRegions = [
                "大陆剧": "中国大陆", "港剧": "中国香港", "台剧": "中国台湾",
                "韩剧": "韩国", "日剧": "日本", "欧美剧": "欧美", "泰剧": "泰国"
            ]
            if let categoryRegion = categoryRegions[filters.category] { region = categoryRegion }
        case .anime:
            category = category == "all" ? "动画" : category
            if filters.category == "剧场版" {
                kind = "movie"
            } else {
                format = "电视剧"
            }
            if filters.category == "在播国漫" { region = "中国大陆" }
            if filters.category == "日本新番" { region = "日本" }
        case .variety:
            format = "综艺"
        }

        let categorySort: String?
        switch filters.category {
        case "豆瓣高分": categorySort = "S"
        case "最新电影", "最近热门", "每日放送", "在播国漫", "日本新番": categorySort = "R"
        case "热门电影": categorySort = "U"
        default: categorySort = nil
        }
        let selectedSort: String
        if let categorySort {
            selectedSort = categorySort
        } else {
            switch filters.sort {
            case "高分优先": selectedSort = "S"
            case "近期更新", "首播时间": selectedSort = "R"
            case "近期热度": selectedSort = "U"
            default: selectedSort = "T"
            }
        }

        components.queryItems = [
            URLQueryItem(name: "kind", value: kind),
            URLQueryItem(name: "limit", value: String(min(50, max(1, pageSize)))),
            URLQueryItem(name: "start", value: String(max(0, start))),
            URLQueryItem(name: "category", value: category),
            URLQueryItem(name: "format", value: format),
            URLQueryItem(name: "region", value: region),
            URLQueryItem(name: "year", value: filters.year == "全部" ? "all" : filters.year),
            URLQueryItem(name: "platform", value: filters.platform == "全部" ? "all" : filters.platform),
            URLQueryItem(name: "sort", value: selectedSort),
            URLQueryItem(name: "label", value: "all")
        ]
        return components.url
    }

    private func sharedCatalogPage(filters: BrowseFilters, start: Int,
                                   pageSize: Int) async throws -> CatalogPageResult {
        guard let url = sharedCatalogURL(filters: filters, start: start, pageSize: pageSize) else {
            throw RepositoryError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.setValue(AppVersion.userAgent(), forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        let payload = try JSONDecoder().decode(SharedCatalogResponse.self, from: data)
        let items = payload.list.compactMap { row -> CatalogItem? in
            let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let workID = row.workId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawID = (workID?.isEmpty == false ? workID : nil) ?? row.id ?? title
            return CatalogItem(id: rawID, workID: workID, title: title,
                               posterURL: row.poster.flatMap(URL.init(string:)),
                               section: filters.section, category: filters.category,
                               genre: filters.genre,
                               region: filters.region == "全部" ? inferredRegion(for: filters) : filters.region,
                               year: row.year?.value ?? "", platform: filters.platform,
                               score: row.rate.flatMap(Double.init),
                               sourceLabel: "电脑版共享目录")
        }
        let responseStart = max(0, payload.start ?? start)
        let fallbackNext = responseStart + payload.list.count
        let nextStart = max(responseStart, payload.nextStart ?? fallbackNext)
        let hasMore = (payload.hasMore ?? (payload.list.count >= max(1, pageSize))) && nextStart > start
        let status = payload.paginationStatus ?? (hasMore ? "more" : "end-confirmed")
        let retryNotice = status == "probe-unavailable" ? "，下一页将在联网后重试" : ""
        return CatalogPageResult(items: items, nextStart: nextStart, hasMore: hasMore,
                                 paginationStatus: status,
                                 notice: "电脑版共享目录 · 同一剧集身份与播放源绑定" + retryNotice)
    }

    private func inferredRegion(for filters: BrowseFilters) -> String {
        switch filters.category {
        case "大陆剧", "在播国漫": return "中国大陆"
        case "港剧": return "中国香港"
        case "台剧": return "中国台湾"
        case "韩剧": return "韩国"
        case "日剧", "日本新番": return "日本"
        case "欧美剧": return "欧美"
        case "泰剧": return "泰国"
        default: return ""
        }
    }

    func catalog(filters: BrowseFilters, page: Int, pageSize: Int = 30) async -> [CatalogItem] {
        let key = cacheKey(filters: filters, page: page, pageSize: pageSize)
        if let cached = catalogCache[key], Date().timeIntervalSince(cached.createdAt) < 600 {
            return cached.items
        }
        let sites = catalogSites(for: filters.section)
        let startPage = max(1, page + 1)
        var results = await queryCatalogSites(sites, filters: filters,
                                              upstreamPage: startPage, pageSize: pageSize)
        if page == 0, filters.section == .anime,
           ["全部", "每日放送", "国产热播", "在播国漫"].contains(filters.category) {
            results.append(contentsOf: await featuredAnimeResults(in: sites))
        }
        var filtered = sort(filter(merge(results.map(\.item)), using: filters), using: filters)

        // A few CMS providers omit their class table. Keep a broad-query fallback,
        // but only when the targeted result is too small to form a useful page.
        if filtered.count < max(6, pageSize / 3) {
            let fallback = await querySites(sites, queryItems: catalogQueryItems(page: startPage,
                                                                                pageSize: pageSize))
            results.append(contentsOf: fallback)
            filtered = sort(filter(merge(results.map(\.item)), using: filters), using: filters)
        }

        let items = Array(filtered.prefix(pageSize))
        catalogCache[key] = CachedCatalog(createdAt: Date(), items: items)
        return items
    }

    func search(_ query: String, limit: Int = 60) async -> [CatalogItem] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        let results = await querySites(configuration.apiSites, queryItems: [
            URLQueryItem(name: "ac", value: "videolist"),
            URLQueryItem(name: "wd", value: keyword)
        ])
        return Array(merge(results.map(\.item))
            .sorted { searchRank($0, keyword: keyword) < searchRank($1, keyword: keyword) }
            .prefix(limit))
    }

    func sources(for item: CatalogItem) async -> [PlaybackSource] {
        do {
            let shared = try await sharedSources(for: item)
            let checked = await probePlaybackStreams(in: Array(shared.prefix(12)))
            return PlaybackSourceRank.sorted(checked + Array(shared.dropFirst(12)))
        } catch {
            // Retain direct CMS lookup only for shared-service transport or
            // schema failures. A successful shared response, including an
            // empty one, is authoritative across all clients.
        }
        let variants = MediaTitleIdentity.searchVariants(for: item.title)
        let sites = configuration.apiSites
        let results = await withTaskGroup(of: [SiteResult].self) { group in
            for title in variants {
                group.addTask { [weak self] in
                    guard let self else { return [] }
                    return await self.querySites(sites, queryItems: [
                        URLQueryItem(name: "ac", value: "videolist"),
                        URLQueryItem(name: "wd", value: title)
                    ], loadDetails: true)
                }
            }
            var values: [SiteResult] = []
            for await batch in group { values.append(contentsOf: batch) }
            return values
        }
        let wanted = item.deduplicationKey
        let matches = results.filter { $0.item.deduplicationKey == wanted }
        var seen = Set<String>()
        let candidates = matches.map(\.source)
            .filter { !$0.episodes.isEmpty && seen.insert($0.id).inserted }
            .sorted {
                ($0.responseTimeMilliseconds ?? Int.max) < ($1.responseTimeMilliseconds ?? Int.max)
            }
        let checked = await probePlaybackStreams(in: Array(candidates.prefix(12)))
        return PlaybackSourceRank.sorted(checked + Array(candidates.dropFirst(12)))
    }

    private func sharedSources(for item: CatalogItem) async throws -> [PlaybackSource] {
        guard var components = URLComponents(string: Self.defaultSharedServiceURL + "/api/catalog/sources") else {
            throw RepositoryError.invalidConfiguration
        }
        components.queryItems = [
            URLQueryItem(name: "title", value: item.title),
            URLQueryItem(name: "workId", value: item.workID ?? ""),
            URLQueryItem(name: "year", value: item.year),
            URLQueryItem(name: "language", value: "")
        ]
        guard let url = components.url else { throw RepositoryError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.setValue(AppVersion.userAgent(), forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        let payload = try JSONDecoder().decode(SharedSourcesResponse.self, from: data)
        return payload.sources.compactMap { source -> PlaybackSource? in
            let episodes = (source.episodes ?? []).enumerated().compactMap { index, raw -> Episode? in
                guard let url = URL(string: raw.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                    return nil
                }
                return Episode(id: url.absoluteString,
                               title: raw.label?.isEmpty == false ? raw.label! : "第 \(index + 1) 集",
                               url: url, index: index)
            }
            guard !episodes.isEmpty else { return nil }
            let sourceID = [source.source ?? "shared", source.id ?? item.id].joined(separator: ":")
            let language = MediaTitleIdentity.language(title: source.name ?? item.title,
                                                       metadata: [source.remarks ?? "", source.type ?? ""])
            return PlaybackSource(id: sourceID, name: source.site ?? "共享线路", language: language,
                                  responseTimeMilliseconds: source.latencyMs, episodes: episodes)
        }
    }

    private func probePlaybackStreams(in sources: [PlaybackSource]) async -> [PlaybackSource] {
        let probeSession = session
        var resultsByID: [String: (StreamHealth, Int?, Int?)] = [:]
        await withTaskGroup(of: (String, StreamHealth, Int?, Int?).self) { group in
            for source in sources {
                group.addTask {
                    let result = await Self.probe(source: source, using: probeSession)
                    return (source.id, result.0, result.1, result.2)
                }
            }
            for await result in group {
                resultsByID[result.0] = (result.1, result.2, result.3)
            }
        }
        return sources.map { source in
            var checked = source
            if let result = resultsByID[source.id] {
                checked.streamHealth = result.0
                checked.streamLatencyMilliseconds = result.1
                checked.streamThroughputKilobytesPerSecond = result.2
            }
            return checked
        }
    }

    nonisolated private static func probe(source: PlaybackSource,
                                          using session: URLSession) async -> (StreamHealth, Int?, Int?) {
        guard let url = source.episodes.first?.url else { return (.unavailable, nil, nil) }
        do {
            var sample = try await transferSample(url: url, using: session, maximumBytes: 65_536)
            for _ in 0..<2 {
                guard let nextURL = firstPlaylistMediaURL(in: sample.data,
                                                          relativeTo: sample.responseURL) else { break }
                let isPlaylist = nextURL.pathExtension.lowercased() == "m3u8"
                sample = try await transferSample(url: nextURL, using: session,
                                                  maximumBytes: isPlaylist ? 65_536 : 262_144)
            }
            return (.verified, sample.latencyMilliseconds, sample.throughputKilobytesPerSecond)
        } catch {
            return (.unavailable, nil, nil)
        }
    }

    private struct TransferSample: Sendable {
        let data: Data
        let responseURL: URL
        let latencyMilliseconds: Int
        let throughputKilobytesPerSecond: Int
    }

    nonisolated private static func transferSample(url: URL, using session: URLSession,
                                                   maximumBytes: Int) async throws -> TransferSample {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=0-\(maximumBytes - 1)", forHTTPHeaderField: "Range")
        request.setValue(AppVersion.userAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let startedAt = Date()
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<400).contains(httpResponse.statusCode) else {
            throw RepositoryError.invalidResponse
        }
        var firstByteAt: Date?
        var data = Data()
        data.reserveCapacity(maximumBytes)
        for try await byte in bytes {
            if firstByteAt == nil { firstByteAt = Date() }
            data.append(byte)
            if data.count >= maximumBytes || Date().timeIntervalSince(startedAt) >= 2.5 { break }
        }
        guard !data.isEmpty else { throw RepositoryError.noPlayableEpisode }
        let firstByteDate = firstByteAt ?? Date()
        let latency = max(1, Int(firstByteDate.timeIntervalSince(startedAt) * 1_000))
        let transferDuration = max(0.001, Date().timeIntervalSince(firstByteDate))
        let throughput = max(1, Int((Double(data.count) / 1_024) / transferDuration))
        return TransferSample(data: data, responseURL: httpResponse.url ?? url,
                              latencyMilliseconds: latency,
                              throughputKilobytesPerSecond: throughput)
    }

    nonisolated private static func firstPlaylistMediaURL(in data: Data, relativeTo baseURL: URL) -> URL? {
        guard let text = String(data: data, encoding: .utf8), text.contains("#EXTM3U") else { return nil }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            return URL(string: line, relativeTo: baseURL)?.absoluteURL
        }
        return nil
    }

    func liveChannels(from source: LiveSource) async throws -> [LiveChannel] {
        let text: String
        if source.url.hasPrefix("local:") {
            let suffix = String(source.url.dropFirst("local:".count))
            let components = suffix.split(separator: "/").map(String.init)
            let filename = components.last ?? ""
            let stem = (filename as NSString).deletingPathExtension
            let ext = (filename as NSString).pathExtension
            let subdirectory = components.dropLast().joined(separator: "/")
            let nestedURL = Bundle.main.url(forResource: stem, withExtension: ext,
                                            subdirectory: subdirectory.isEmpty ? nil : subdirectory)
            let flattenedURL = Bundle.main.url(forResource: stem, withExtension: ext)
            guard let url = nestedURL ?? flattenedURL else {
                return []
            }
            text = try String(contentsOf: url, encoding: .utf8)
        } else {
            guard let url = URL(string: source.url) else { return [] }
            var request = URLRequest(url: url)
            if let userAgent = source.userAgent, !userAgent.isEmpty {
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            }
            let (data, response) = try await session.data(for: request)
            try validate(response: response)
            text = String(decoding: data, as: UTF8.self)
        }
        return parseM3U(text)
    }

    private func loadConfiguration(remoteURL: String) async throws -> ContentConfiguration {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            guard let url = URL(string: trimmed) else { throw RepositoryError.invalidConfiguration }
            let (data, response) = try await session.data(from: url)
            try validate(response: response)
            return try parseConfiguration(data)
        }
        return try loadBundledConfiguration()
    }

    private func loadBundledConfiguration() throws -> ContentConfiguration {
        guard let url = Bundle.main.url(forResource: "lunatv-config", withExtension: "json") else {
            throw RepositoryError.invalidConfiguration
        }
        return try parseConfiguration(Data(contentsOf: url))
    }

    private func parseConfiguration(_ data: Data) throws -> ContentConfiguration {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RepositoryError.invalidConfiguration
        }
        let cacheSeconds = (root["cache_time"] as? NSNumber)?.intValue ?? 7_200
        let siteObject = root["api_site"] as? [String: Any] ?? [:]
        let sites = siteObject.compactMap { key, raw -> APISite? in
            guard let value = raw as? [String: Any],
                  let api = value["api"] as? String,
                  let apiURL = URL(string: api) else { return nil }
            let detailURL = (value["detail"] as? String).flatMap(URL.init(string:))
            return APISite(id: key, name: value["name"] as? String ?? key,
                           apiURL: apiURL, detailURL: detailURL)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let liveObject = root["lives"] as? [String: Any] ?? [:]
        let lives = liveObject.compactMap { key, raw -> LiveSource? in
            guard let value = raw as? [String: Any], let url = value["url"] as? String else { return nil }
            return LiveSource(id: key, name: value["name"] as? String ?? key,
                              url: url, userAgent: value["ua"] as? String)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !sites.isEmpty else { throw RepositoryError.invalidConfiguration }
        return ContentConfiguration(cacheSeconds: cacheSeconds, apiSites: sites, liveSources: lives)
    }

    private func querySites(_ sites: [APISite], queryItems: [URLQueryItem],
                            loadDetails: Bool = false) async -> [SiteResult] {
        await withTaskGroup(of: [SiteResult].self) { group in
            for site in sites {
                group.addTask { [weak self] in
                    guard let self else { return [] }
                    return (try? await self.query(site: site, queryItems: queryItems,
                                                  loadDetails: loadDetails)) ?? []
                }
            }
            var values: [SiteResult] = []
            for await batch in group { values.append(contentsOf: batch) }
            return values
        }
    }

    private func queryCatalogSites(_ sites: [APISite], filters: BrowseFilters,
                                   upstreamPage: Int, pageSize: Int) async -> [SiteResult] {
        let profiles = await withTaskGroup(of: (APISite, [CMSClassEntry]).self) { group in
            for site in sites {
                group.addTask { [weak self] in
                    guard let self else { return (site, []) }
                    return (site, await self.classEntries(for: site))
                }
            }
            var values: [(APISite, [CMSClassEntry])] = []
            for await value in group { values.append(value) }
            return values
        }

        let baseQueryItems = catalogQueryItems(page: upstreamPage, pageSize: pageSize)
        return await withTaskGroup(of: [SiteResult].self) { group in
            for (site, entries) in profiles {
                let typeIDs = catalogTypeIDs(in: entries, filters: filters)
                if typeIDs.isEmpty {
                    group.addTask { [weak self] in
                        guard let self else { return [] }
                        return (try? await self.query(site: site,
                                                     queryItems: baseQueryItems,
                                                     loadDetails: false)) ?? []
                    }
                } else {
                    for typeID in typeIDs {
                        group.addTask { [weak self] in
                            guard let self else { return [] }
                            var queryItems = baseQueryItems
                            queryItems.append(URLQueryItem(name: "t", value: typeID))
                            return (try? await self.query(site: site, queryItems: queryItems,
                                                         loadDetails: false)) ?? []
                        }
                    }
                }
            }
            var values: [SiteResult] = []
            for await batch in group { values.append(contentsOf: batch) }
            return values
        }
    }

    private func featuredAnimeResults(in sites: [APISite]) async -> [SiteResult] {
        let candidateSites = Array(sites.prefix(2))
        guard !candidateSites.isEmpty else { return [] }
        let titles = featuredOnAirAnimeTitles
        return await withTaskGroup(of: [SiteResult].self) { group in
            for title in titles {
                group.addTask { [weak self] in
                    guard let self else { return [] }
                    let wanted = self.normalize(title)
                    for site in candidateSites {
                        let results = (try? await self.query(site: site, queryItems: [
                            URLQueryItem(name: "ac", value: "videolist"),
                            URLQueryItem(name: "wd", value: title)
                        ], loadDetails: false)) ?? []
                        let exact = results.filter {
                            $0.item.section == .anime && self.normalize($0.item.title) == wanted
                        }
                        if !exact.isEmpty { return exact }
                    }
                    return []
                }
            }
            var values: [SiteResult] = []
            for await batch in group { values.append(contentsOf: batch) }
            return values
        }
    }

    private func classEntries(for site: APISite) async -> [CMSClassEntry] {
        if let cached = siteClassCache[site.id] { return cached }
        guard var components = URLComponents(url: site.apiURL, resolvingAgainstBaseURL: false) else {
            siteClassCache[site.id] = []
            return []
        }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "ac", value: "list")]
        guard let url = components.url else {
            siteClassCache[site.id] = []
            return []
        }
        do {
            var request = URLRequest(url: url)
            request.setValue(AppVersion.userAgent(), forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            try validate(response: response)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawEntries = root["class"] as? [[String: Any]] else {
                siteClassCache[site.id] = []
                return []
            }
            let entries = rawEntries.compactMap { raw -> CMSClassEntry? in
                let id = string(raw["type_id"])
                let name = string(raw["type_name"]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, !name.isEmpty else { return nil }
                return CMSClassEntry(id: id, name: name, parentID: string(raw["type_pid"]))
            }
            siteClassCache[site.id] = entries
            return entries
        } catch {
            siteClassCache[site.id] = []
            return []
        }
    }

    private func catalogQueryItems(page: Int, pageSize: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "ac", value: "videolist"),
            URLQueryItem(name: "pg", value: String(page)),
            URLQueryItem(name: "pagesize", value: String(max(24, pageSize))),
            URLQueryItem(name: "order", value: "desc")
        ]
    }

    private func catalogSites(for section: MediaSection) -> [APISite] {
        let preferredIDs: [String]
        switch section {
        case .movie:
            preferredIDs = ["iqiyizyapi.com", "dbzy.tv", "ffzyapi.com", "dyttzyapi.com"]
        case .anime:
            preferredIDs = ["caiji.moduapi.cc", "iqiyizyapi.com", "dbzy.tv", "ffzyapi.com"]
        case .drama:
            preferredIDs = ["iqiyizyapi.com", "ffzyapi.com", "dbzy.tv", "jszyapi.com"]
        case .variety:
            preferredIDs = ["iqiyizyapi.com", "ffzyapi.com", "dbzy.tv", "jszyapi.com"]
        }

        var selected: [APISite] = []
        for id in preferredIDs {
            if let site = configuration.apiSites.first(where: { $0.id == id }) { selected.append(site) }
        }
        if selected.count < 2 {
            selected.append(contentsOf: configuration.apiSites.filter { site in
                !selected.contains(where: { $0.id == site.id })
            })
        }
        return Array(selected.prefix(3))
    }

    private func catalogTypeIDs(in entries: [CMSClassEntry], filters: BrowseFilters) -> [String] {
        let matches = entries.filter { entry in
            let name = entry.name.lowercased()
            switch filters.section {
            case .movie:
                let denied = ["动漫", "动画", "伦理", "福利", "写真", "资讯", "预告", "解说", "短剧"]
                guard !denied.contains(where: name.contains) else { return false }
                return name == "电影" || name == "电影片" || name.contains("纪录片")
                    || name.contains("记录片") || name.hasSuffix("片")
            case .drama:
                let denied = ["短剧", "漫剧", "剧场", "综艺", "资讯"]
                guard !denied.contains(where: name.contains) else { return false }
                return name == "连续剧" || name == "电视剧" || name.contains("国产剧")
                    || name.contains("香港剧") || name.contains("韩国剧") || name.contains("韩剧")
                    || name.contains("欧美剧") || name.contains("台湾剧") || name.contains("日本剧")
                    || name.contains("海外剧") || name.contains("泰国剧")
            case .anime:
                let denied = ["里番", "ai漫剧", "动态漫", "有声", "解说", "短剧"]
                guard !denied.contains(where: name.contains) else { return false }
                if ["国产热播", "在播国漫"].contains(filters.category) {
                    return name.contains("国产动漫") || name.contains("中国动漫") || name.contains("国漫")
                }
                if filters.category == "日本新番" || filters.category == "番剧" {
                    return name.contains("日本动漫") || name.contains("日韩动漫") || name.contains("番剧")
                }
                if filters.category == "剧场版" {
                    return name.contains("动漫电影") || name.contains("动画片") || name.contains("剧场版")
                }
                return name == "动漫" || name == "动漫片" || name.contains("国产动漫")
                    || name.contains("中国动漫")
                    || name.contains("日本动漫") || name.contains("日韩动漫")
                    || name.contains("欧美动漫") || name.contains("港台动漫")
                    || name.contains("海外动漫") || name.contains("番剧")
                    || name.contains("动漫电影") || name.contains("动画片")
            case .variety:
                return name.contains("综艺") || name.contains("真人秀") || name.contains("脱口秀")
            }
        }

        var narrowed = matches
        if filters.section == .drama, !["全部", "最近热门"].contains(filters.category) {
            let categoryMatches = matches.filter {
                matchesDramaCategory($0.name.lowercased(), category: filters.category)
            }
            if !categoryMatches.isEmpty { narrowed = categoryMatches }
        }
        if filters.genre != "全部" {
            let wanted = filters.genre.replacingOccurrences(of: "记录", with: "纪录")
            let genreMatches = narrowed.filter {
                $0.name.replacingOccurrences(of: "记录", with: "纪录")
                    .localizedCaseInsensitiveContains(wanted)
            }
            if !genreMatches.isEmpty { narrowed = genreMatches }
        }

        let limit: Int
        switch filters.section {
        case .movie: limit = 10
        case .drama: limit = 12
        case .anime: limit = 8
        case .variety: limit = 8
        }
        return Array(narrowed.map(\.id).prefix(limit))
    }

    private func query(site: APISite, queryItems: [URLQueryItem],
                       loadDetails: Bool) async throws -> [SiteResult] {
        guard var components = URLComponents(url: site.apiURL, resolvingAgainstBaseURL: false) else { return [] }
        components.queryItems = (components.queryItems ?? []) + queryItems
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue(AppVersion.userAgent(), forHTTPHeaderField: "User-Agent")
        let started = Date()
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        let latency = Int(Date().timeIntervalSince(started) * 1_000)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["list"] as? [[String: Any]] else { return [] }
        var parsed: [SiteResult] = []
        for raw in list {
            var itemResults = parseCMSItems(raw, site: site, latency: latency)
            guard !itemResults.isEmpty else { continue }
            if loadDetails, itemResults.allSatisfy({ $0.source.episodes.isEmpty }) {
                let contentID = string(raw["vod_id"])
                if !contentID.isEmpty {
                    do {
                        let detailed = try await queryDetail(site: site, contentID: contentID,
                                                             latency: latency)
                        if !detailed.isEmpty { itemResults = detailed }
                    } catch {
                        // Keep the search result even when this one source
                        // omits or rejects its detail endpoint.
                    }
                }
            }
            parsed.append(contentsOf: itemResults)
        }
        return parsed
    }

    private func queryDetail(site: APISite, contentID: String, latency: Int) async throws -> [SiteResult] {
        guard var components = URLComponents(url: site.apiURL, resolvingAgainstBaseURL: false) else { return [] }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "ac", value: "detail"),
            URLQueryItem(name: "ids", value: contentID)
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue(AppVersion.userAgent(), forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = (root["list"] as? [[String: Any]])?.first else { return [] }
        return parseCMSItems(raw, site: site, latency: latency)
    }

    private func parseCMSItems(_ raw: [String: Any], site: APISite, latency: Int) -> [SiteResult] {
        let rawTitle = string(raw["vod_name"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTitle.isEmpty else { return [] }
        let title = MediaTitleIdentity.canonicalTitle(rawTitle)
        let type = [string(raw["type_name"]), string(raw["vod_class"]), string(raw["vod_type"])]
            .joined(separator: " ")
        let section = classify(type)
        let rawID = string(raw["vod_id"]).isEmpty ? rawTitle : string(raw["vod_id"])
        let poster = URL(string: string(raw["vod_pic"]))
        let item = CatalogItem(id: site.id + ":" + rawID, title: title,
                               aliases: Array(Set([rawTitle] + aliases(from: raw))), posterURL: poster,
                               section: section, category: type,
                               genre: string(raw["vod_class"]), region: string(raw["vod_area"]),
                               year: string(raw["vod_year"]), platform: string(raw["vod_remarks"]),
                               score: Double(string(raw["vod_score"])),
                               summary: stripHTML(string(raw["vod_content"])),
                               sourceLabel: site.name, updatedAt: parseDate(string(raw["vod_time"])))
        let playGroups = string(raw["vod_play_url"]).components(separatedBy: "$$$")
        let playFrom = string(raw["vod_play_from"]).components(separatedBy: "$$$")
        let languageMetadata = [string(raw["vod_lang"]), string(raw["vod_remarks"]),
                                string(raw["vod_area"])]
        var results: [SiteResult] = []

        for (index, group) in playGroups.enumerated() where !group.isEmpty {
            let episodes = parseEpisodeGroup(group)
            guard !episodes.isEmpty else { continue }
            let groupName = playFrom.indices.contains(index) ? playFrom[index] : ""
            let language = MediaTitleIdentity.language(title: rawTitle,
                                                       metadata: [groupName] + languageMetadata)
            let source = PlaybackSource(id: [site.id, rawID, String(index), normalize(groupName)]
                .joined(separator: ":"), name: site.name, language: language,
                apiURL: site.apiURL, detailURL: site.detailURL,
                responseTimeMilliseconds: latency, episodes: episodes)
            results.append(SiteResult(item: item, source: source))
        }

        if results.isEmpty {
            let language = MediaTitleIdentity.language(title: rawTitle, metadata: languageMetadata)
            let source = PlaybackSource(id: [site.id, rawID, "0"].joined(separator: ":"),
                                        name: site.name, language: language,
                                        apiURL: site.apiURL, detailURL: site.detailURL,
                                        responseTimeMilliseconds: latency, episodes: [])
            results.append(SiteResult(item: item, source: source))
        }
        return results
    }

    private func parseEpisodeGroup(_ value: String) -> [Episode] {
        var episodes: [Episode] = []
        for token in value.components(separatedBy: "#") where !token.isEmpty {
            let pieces = token.split(separator: "$", maxSplits: 1).map(String.init)
            let rawURL = pieces.count == 2 ? pieces[1] : pieces[0]
            guard let url = URL(string: rawURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                continue
            }
            let title = pieces.count == 2 && !pieces[0].isEmpty ? pieces[0] : "第 \(episodes.count + 1) 集"
            episodes.append(Episode(id: url.absoluteString, title: title,
                                    url: url, index: episodes.count))
        }
        return episodes
    }

    private func parseM3U(_ text: String) -> [LiveChannel] {
        var pendingName = ""
        var pendingGroup = ""
        var channels: [LiveChannel] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXTINF") {
                pendingName = line.split(separator: ",", maxSplits: 1).last.map(String.init) ?? "直播频道"
                if let range = line.range(of: "group-title=\"") {
                    let suffix = line[range.upperBound...]
                    pendingGroup = suffix.split(separator: "\"").first.map(String.init) ?? ""
                }
            } else if !line.isEmpty, !line.hasPrefix("#"), let url = URL(string: line) {
                channels.append(LiveChannel(id: url.absoluteString,
                                            name: pendingName.isEmpty ? "直播频道" : pendingName,
                                            group: pendingGroup, url: url))
                pendingName = ""
                pendingGroup = ""
            }
        }
        return channels
    }

    func classify(_ value: String) -> MediaSection {
        let lower = value.lowercased()
        if ["动漫", "动画", "国产动漫", "中国动漫", "日本动漫", "日韩动漫", "欧美动漫", "港台动漫", "海外动漫",
            "动漫片", "动漫电影", "动画片", "动画电影", "卡通", "国漫", "番剧"]
            .contains(where: lower.contains) { return .anime }
        if ["综艺", "真人秀", "脱口秀"].contains(where: lower.contains) { return .variety }
        if ["电影", "影片", "院线", "纪录片", "记录片", "动作片", "喜剧片", "爱情片",
            "科幻片", "恐怖片", "剧情片", "战争片", "惊悚片", "家庭片", "古装片",
            "历史片", "悬疑片", "犯罪片", "灾难片", "奇幻片", "西部片", "冒险片"]
            .contains(where: lower.contains) { return .movie }
        return .drama
    }

    private func filter(_ items: [CatalogItem], using value: BrowseFilters) -> [CatalogItem] {
        items.filter { item in
            guard item.section == value.section else { return false }
            let classification = [item.category, item.genre].joined(separator: " ").lowercased()
            let descriptor = [item.title, item.category, item.genre, item.region,
                              item.platform, item.summary]
                .joined(separator: " ").lowercased()
            let blocked = ["伦理片", "伦理", "福利视频", "写真", "体育赛事", "篮球", "足球",
                           "网球", "斯诺克", "lpl", "直播", "新闻资讯", "电影资讯"]
            if blocked.contains(where: classification.contains) { return false }

            if value.section == .anime {
                if isLikelyShortFormAnime(item, descriptor: descriptor) { return false }

                if animeEditorialRank(item) == Int.max {
                    let hasAnimationMetadata = ["动画", "动漫电影", "动画电影", "番剧"]
                        .contains(where: descriptor.localizedCaseInsensitiveContains)
                    let isJapaneseSeries = ["日本动漫", "日韩动漫", "番剧"]
                        .contains(where: classification.contains)
                    if !hasAnimationMetadata && !isJapaneseSeries { return false }
                }

                if value.category == "全部", value.year == "全部",
                   animeEditorialRank(item) == Int.max, !isRecentAnime(item) {
                    return false
                }

                if ["国产热播", "在播国漫"].contains(value.category) {
                    guard descriptor.contains("国产动漫") || descriptor.contains("中国动漫")
                        || descriptor.contains("国漫")
                        || item.region.contains("中国") else { return false }
                    guard isRecentAnime(item) else { return false }
                }
                if value.category == "日本新番" || value.category == "番剧" {
                    guard descriptor.contains("日本动漫") || descriptor.contains("日韩动漫")
                        || descriptor.contains("番剧") || item.region.contains("日本") else { return false }
                    if value.category == "日本新番" { guard isRecentAnime(item) else { return false } }
                }
                if value.category == "每日放送" && !isRecentAnime(item) { return false }
            }
            if value.section == .drama, !["全部", "最近热门"].contains(value.category),
               !matchesDramaCategory(classification, category: value.category) {
                return false
            }
            if value.category == "剧场版"
                && !["动漫电影", "动画电影", "动画片", "剧场版"].contains(where: descriptor.contains) {
                return false
            }
            if value.genre != "全部"
                && ![item.category, item.genre].joined(separator: " ")
                    .localizedCaseInsensitiveContains(value.genre) { return false }
            if value.region != "全部" && !matchesRegion(item, selection: value.region) { return false }
            if value.year != "全部" && item.year != value.year { return false }
            if value.platform != "全部" && !item.platform.localizedCaseInsensitiveContains(value.platform) { return false }
            return true
        }
    }

    private func sort(_ items: [CatalogItem], using filters: BrowseFilters) -> [CatalogItem] {
        if filters.category == "豆瓣高分" { return items.sorted { ($0.score ?? 0) > ($1.score ?? 0) } }
        if filters.section == .anime {
            return items.sorted {
                let lhsRank = animeEditorialRank($0)
                let rhsRank = animeEditorialRank($1)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                let lhsYear = Int($0.year) ?? 0
                let rhsYear = Int($1.year) ?? 0
                if lhsYear != rhsYear { return lhsYear > rhsYear }
                return isFresher($0, $1)
            }
        }
        if filters.category == "最新电影" || filters.category == "最近热门" {
            return items.sorted(by: isFresher)
        }
        if filters.category == "热门电影" {
            return items.sorted {
                if ($0.score ?? 0) != ($1.score ?? 0) { return ($0.score ?? 0) > ($1.score ?? 0) }
                return isFresher($0, $1)
            }
        }
        switch filters.sort {
        case "高分优先": return items.sorted { ($0.score ?? 0) > ($1.score ?? 0) }
        case "首播时间", "首映时间", "近期更新":
            return items.sorted(by: isFresher)
        default:
            return [.movie, .drama, .variety].contains(filters.section)
                ? items.sorted(by: isFresher) : items
        }
    }

    private func animeEditorialRank(_ item: CatalogItem) -> Int {
        let title = normalize(item.title)
        return featuredOnAirAnimeTitles.firstIndex { normalize($0) == title } ?? Int.max
    }

    private func isLikelyShortFormAnime(_ item: CatalogItem, descriptor: String) -> Bool {
        let blockedMetadata = [
            "ai漫剧", "ai动画", "ai短片", "短剧", "动漫短剧", "动画短剧", "微短剧",
            "动态漫", "动态漫画", "动态剧", "有声动漫", "有声漫画", "沙雕动画",
            "解说动漫", "漫画解说", "竖屏", "竖版", "爽文动漫", "脑洞动漫",
            "ppt动漫", "泡面番", "小剧场", "短视频", "漫剧", "少儿", "幼儿",
            "早教", "启蒙", "儿歌"
        ]
        if blockedMetadata.contains(where: descriptor.contains) { return true }

        let clickbaitTitles = [
            "系统", "重生", "绑定", "开局", "老祖", "先祖", "天帝", "神豪",
            "末日", "末世", "无敌", "模拟器", "签到", "反派", "逆袭", "穿越",
            "觉醒", "暴富", "亏成", "收徒", "万倍", "尸潮", "执掌", "氪金",
            "爽文", "靠抽卡", "修仙归来", "乞讨", "宠兽时代", "百万骨海",
            "零元购", "一斩苍穹"
        ]
        if animeEditorialRank(item) == Int.max,
           clickbaitTitles.contains(where: item.title.localizedCaseInsensitiveContains) {
            return true
        }
        return false
    }

    func matchesDramaCategory(_ classification: String, category: String) -> Bool {
        let names: [String]
        switch category {
        case "大陆剧": names = ["国产剧", "大陆剧", "内地剧"]
        case "港剧": names = ["香港剧", "港剧"]
        case "台剧": names = ["台湾剧", "台剧"]
        case "韩剧": names = ["韩国剧", "韩剧"]
        case "日剧": names = ["日本剧", "日剧"]
        case "欧美剧": names = ["欧美剧", "美国剧", "英国剧"]
        case "泰剧": names = ["泰国剧", "泰剧"]
        default: return true
        }
        return names.contains(where: classification.contains)
    }

    func matchesRegion(_ item: CatalogItem, selection: String) -> Bool {
        let region = [item.region, item.category, item.genre]
            .joined(separator: " ").lowercased().replacingOccurrences(of: " ", with: "")
        if selection == "中国大陆",
           ["香港", "台湾", "澳门", "港剧", "台剧"].contains(where: region.contains) {
            return false
        }
        let aliases: [String]
        switch selection {
        case "华语": aliases = ["中国大陆", "大陆", "内地", "中国", "香港", "台湾", "澳门", "华语"]
        case "欧美": aliases = ["欧美", "美国", "英国", "法国", "德国", "加拿大", "意大利", "西班牙",
                              "欧洲", "澳大利亚", "爱尔兰", "瑞典", "丹麦", "挪威"]
        case "中国大陆": aliases = ["中国大陆", "大陆", "内地", "中国"]
        case "中国香港": aliases = ["中国香港", "香港", "港剧"]
        case "中国台湾": aliases = ["中国台湾", "台湾", "台剧"]
        case "美国": aliases = ["美国", "usa", "unitedstates"]
        case "英国": aliases = ["英国", "uk", "unitedkingdom"]
        default: aliases = [selection]
        }
        return aliases.contains(where: region.localizedCaseInsensitiveContains)
    }

    private func isFresher(_ lhs: CatalogItem, _ rhs: CatalogItem) -> Bool {
        let lhsDate = lhs.updatedAt ?? .distantPast
        let rhsDate = rhs.updatedAt ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        if lhs.year != rhs.year { return lhs.year > rhs.year }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private func isRecentAnime(_ item: CatalogItem) -> Bool {
        let currentYear = Calendar.current.component(.year, from: Date())
        if let year = Int(item.year), year >= currentYear - 1 { return true }
        guard let updatedAt = item.updatedAt,
              let cutoff = Calendar.current.date(byAdding: .month, value: -18, to: Date()) else { return false }
        return updatedAt >= cutoff
    }

    private func merge(_ items: [CatalogItem]) -> [CatalogItem] {
        var order: [String] = []
        var merged: [String: CatalogItem] = [:]
        for var item in items {
            item.title = MediaTitleIdentity.canonicalTitle(item.title)
            let key = item.deduplicationKey
            guard var existing = merged[key] else {
                order.append(key)
                merged[key] = item
                continue
            }
            existing.aliases = Array(Set(existing.aliases + item.aliases + [item.title]))
            if existing.posterURL == nil { existing.posterURL = item.posterURL }
            if existing.summary.count < item.summary.count { existing.summary = item.summary }
            if existing.genre.isEmpty { existing.genre = item.genre }
            if existing.region.isEmpty { existing.region = item.region }
            if existing.year.isEmpty { existing.year = item.year }
            if (existing.score ?? 0) < (item.score ?? 0) { existing.score = item.score }
            if (existing.updatedAt ?? .distantPast) < (item.updatedAt ?? .distantPast) {
                existing.updatedAt = item.updatedAt
            }
            merged[key] = existing
        }
        return order.compactMap { merged[$0] }
    }

    private func searchRank(_ item: CatalogItem, keyword: String) -> Int {
        let normalizedKeyword = normalize(keyword)
        let title = normalize(item.title)
        if title == normalizedKeyword { return 0 }
        if title.hasPrefix(normalizedKeyword) { return 1 }
        if item.searchableText.contains(keyword.lowercased()) { return 2 }
        return 3
    }

    nonisolated private func normalize(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func aliases(from raw: [String: Any]) -> [String] {
        [string(raw["vod_sub"]), string(raw["vod_en"])]
            .flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ",/|")) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private func stripHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            throw RepositoryError.invalidResponse
        }
    }

    private func cacheKey(filters: BrowseFilters, page: Int, pageSize: Int) -> String {
        [filters.section.rawValue, filters.category, filters.genre, filters.region,
         filters.year, filters.platform, filters.sort, filters.weekday,
         String(page), String(pageSize)].joined(separator: "|")
    }
}
