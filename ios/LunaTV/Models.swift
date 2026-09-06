import Foundation

enum MediaSection: String, CaseIterable, Codable, Identifiable, Sendable {
    case movie = "电影"
    case drama = "剧集"
    case anime = "动漫"
    case variety = "综艺"

    var id: String { rawValue }
}

struct BrowseFilters: Hashable, Codable, Sendable {
    var section: MediaSection
    var category = "全部"
    var genre = "全部"
    var region = "全部"
    var year = "全部"
    var platform = "全部"
    var sort = "综合排序"
    var weekday = "全部"
}

enum MediaTitleIdentity {
    private static let languageSuffixPattern = try! NSRegularExpression(
        pattern: #"(?i)(?:[\s·._\-—/]*[（(\[【]?\s*(?:国粤双语|粤国语|粤语|广东话|国语|普通话|国配|台配|台湾配音|双语|英语|英文|日语|韩语|泰语|法语|德语|西班牙语)(?:配音|中字|版)?\s*[）)\]】]?)$"#
    )

    static func canonicalTitle(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while !result.isEmpty {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            guard let match = languageSuffixPattern.firstMatch(in: result, range: range) else { break }
            result = languageSuffixPattern.stringByReplacingMatches(in: result, range: match.range,
                                                                     withTemplate: "")
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
                    .union(CharacterSet(charactersIn: "·._-—/（([【")))
        }
        return result.isEmpty ? value.trimmingCharacters(in: .whitespacesAndNewlines) : result
    }

    static func key(for value: String) -> String {
        normalizedSeasonTitle(canonicalTitle(value)).lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func searchVariants(for value: String) -> [String] {
        let canonical = canonicalTitle(value)
        var values = [canonical]
        let compact = canonical.replacingOccurrences(of: " ", with: "")
        if let variant = seasonVariant(for: compact), variant != compact { values.append(variant) }
        return values.reduce(into: []) { result, title in
            if !title.isEmpty && !result.contains(title) { result.append(title) }
        }
    }

    static func language(title: String, metadata: [String]) -> String {
        if let explicit = detectedLanguage(in: title) { return explicit }
        for value in metadata {
            if let detected = detectedLanguage(in: value) { return detected }
        }
        return "原声"
    }

    private static func detectedLanguage(in value: String) -> String? {
        let lowered = value.lowercased()
        if ["国粤双语", "粤国语", "双语"].contains(where: lowered.contains) { return "双语" }
        if ["粤语", "广东话", "cantonese"].contains(where: lowered.contains) { return "粤语" }
        if ["国语", "普通话", "国配", "中文", "mandarin"].contains(where: lowered.contains) { return "国语" }
        if ["日语", "日配", "japanese"].contains(where: lowered.contains) { return "日语" }
        if ["韩语", "韩配", "korean"].contains(where: lowered.contains) { return "韩语" }
        if ["英语", "英文", "english"].contains(where: lowered.contains) { return "英语" }
        if ["泰语", "thai"].contains(where: lowered.contains) { return "泰语" }
        if ["法语", "french"].contains(where: lowered.contains) { return "法语" }
        if ["德语", "german"].contains(where: lowered.contains) { return "德语" }
        if ["西班牙语", "spanish"].contains(where: lowered.contains) { return "西班牙语" }
        return nil
    }

    private static let chineseSeasons: [(text: String, number: Int)] = [
        ("第二十季", 20), ("第十九季", 19), ("第十八季", 18), ("第十七季", 17),
        ("第十六季", 16), ("第十五季", 15), ("第十四季", 14), ("第十三季", 13),
        ("第十二季", 12), ("第十一季", 11), ("第十季", 10), ("第九季", 9),
        ("第八季", 8), ("第七季", 7), ("第六季", 6), ("第五季", 5),
        ("第四季", 4), ("第三季", 3), ("第二季", 2), ("第一季", 1)
    ]

    private static func normalizedSeasonTitle(_ value: String) -> String {
        let compact = value.replacingOccurrences(of: " ", with: "")
        for season in chineseSeasons where compact.hasSuffix(season.text) {
            return String(compact.dropLast(season.text.count)) + String(season.number)
        }
        let range = NSRange(compact.startIndex..<compact.endIndex, in: compact)
        let pattern = try! NSRegularExpression(pattern: #"第([0-9]{1,2})季$"#)
        if let match = pattern.firstMatch(in: compact, range: range),
           let numberRange = Range(match.range(at: 1), in: compact) {
            let number = String(compact[numberRange])
            return pattern.stringByReplacingMatches(in: compact, range: match.range,
                                                      withTemplate: number)
        }
        return compact
    }

    private static func seasonVariant(for compact: String) -> String? {
        let normalized = normalizedSeasonTitle(compact)
        if normalized != compact { return normalized }
        let range = NSRange(compact.startIndex..<compact.endIndex, in: compact)
        let trailingPattern = try! NSRegularExpression(pattern: #"([0-9]{1,2})$"#)
        if let match = trailingPattern.firstMatch(in: compact, range: range),
           let numberRange = Range(match.range(at: 1), in: compact),
           let number = Int(compact[numberRange]), (1...20).contains(number),
           let chinese = chineseSeasons.first(where: { $0.number == number })?.text {
            return String(compact[..<numberRange.lowerBound]) + chinese
        }
        return nil
    }
}

struct CatalogItem: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var workID: String? = nil
    var title: String
    var aliases: [String] = []
    var posterURL: URL?
    var section: MediaSection
    var category = ""
    var genre = ""
    var region = ""
    var year = ""
    var platform = ""
    var score: Double?
    var summary = ""
    var sourceLabel = ""
    var updatedAt: Date?

    var searchableText: String {
        ([title] + aliases).joined(separator: " ").lowercased()
    }

    var deduplicationKey: String {
        if let workID = workID?.trimmingCharacters(in: .whitespacesAndNewlines), !workID.isEmpty {
            return workID.lowercased() + ":" + section.rawValue
        }
        return MediaTitleIdentity.key(for: title) + ":" + section.rawValue
    }
}

struct CatalogPageResult: Codable, Sendable {
    var items: [CatalogItem]
    var nextStart: Int
    var hasMore: Bool
    var paginationStatus: String
    var notice: String
}

struct Episode: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var url: URL
    var index: Int
}

enum StreamHealth: String, Codable, Hashable, Sendable {
    case verified
    case untested
    case unavailable

    var title: String {
        switch self {
        case .verified: return "可播放"
        case .untested: return "待检测"
        case .unavailable: return "暂不可用"
        }
    }

    var rank: Int {
        switch self {
        case .verified: return 0
        case .untested: return 1
        case .unavailable: return 2
        }
    }
}

struct PlaybackSource: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var language = "原声"
    var apiURL: URL?
    var detailURL: URL?
    var responseTimeMilliseconds: Int?
    var episodes: [Episode]
    var streamHealth: StreamHealth = .untested
    var streamLatencyMilliseconds: Int?
    var streamThroughputKilobytesPerSecond: Int?
}

enum PlaybackSourceRank {
    static func sorted(_ sources: [PlaybackSource]) -> [PlaybackSource] {
        sources.sorted { lhs, rhs in
            if lhs.streamHealth.rank != rhs.streamHealth.rank {
                return lhs.streamHealth.rank < rhs.streamHealth.rank
            }
            let lhsThroughput = lhs.streamThroughputKilobytesPerSecond ?? -1
            let rhsThroughput = rhs.streamThroughputKilobytesPerSecond ?? -1
            if lhsThroughput != rhsThroughput { return lhsThroughput > rhsThroughput }
            let lhsStreamLatency = lhs.streamLatencyMilliseconds ?? Int.max
            let rhsStreamLatency = rhs.streamLatencyMilliseconds ?? Int.max
            if lhsStreamLatency != rhsStreamLatency { return lhsStreamLatency < rhsStreamLatency }
            let lhsAPILatency = lhs.responseTimeMilliseconds ?? Int.max
            let rhsAPILatency = rhs.responseTimeMilliseconds ?? Int.max
            if lhsAPILatency != rhsAPILatency { return lhsAPILatency < rhsAPILatency }
            return lhs.episodes.count > rhs.episodes.count
        }
    }
}

struct APISite: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var apiURL: URL
    var detailURL: URL?
}

struct LiveSource: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var url: String
    var userAgent: String?
}

struct LiveChannel: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var group: String
    var url: URL
}

struct ContentConfiguration: Codable, Sendable {
    var cacheSeconds: Int
    var apiSites: [APISite]
    var liveSources: [LiveSource]

    static let empty = ContentConfiguration(cacheSeconds: 7_200, apiSites: [], liveSources: [])
}

struct PlaybackRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var item: CatalogItem
    var sourceID: String
    var episode: Episode
    var positionSeconds: Double
    var durationSeconds: Double
    var updatedAt: Date
}

struct AppPreferences: Codable, Equatable, Sendable {
    static let publicUpdateURL = "https://lunatv-vidaa-app.pages.dev/ios/"
    private static let legacyUpdateURLs = [
        "http://192.168.1.181:8799/ios/",
        "http://192.168.1.181:8799/ios/index.html"
    ]

    var remoteConfigurationURL = ""
    var testFlightURL = AppPreferences.publicUpdateURL
    var refreshIntervalSeconds: TimeInterval = 600

    init(remoteConfigurationURL: String = "",
         testFlightURL: String = AppPreferences.publicUpdateURL,
         refreshIntervalSeconds: TimeInterval = 600) {
        self.remoteConfigurationURL = remoteConfigurationURL
        self.testFlightURL = Self.migratedUpdateURL(testFlightURL)
        self.refreshIntervalSeconds = refreshIntervalSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case remoteConfigurationURL, testFlightURL, refreshIntervalSeconds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        remoteConfigurationURL = try values.decodeIfPresent(String.self, forKey: .remoteConfigurationURL) ?? ""
        let storedUpdateURL = try values.decodeIfPresent(String.self, forKey: .testFlightURL) ?? ""
        testFlightURL = Self.migratedUpdateURL(storedUpdateURL)
        refreshIntervalSeconds = try values.decodeIfPresent(TimeInterval.self,
                                                             forKey: .refreshIntervalSeconds) ?? 600
    }

    private static func migratedUpdateURL(_ value: String) -> String {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty || legacyUpdateURLs.contains(candidate) { return publicUpdateURL }
        return candidate
    }
}
