import Foundation

/// A search card represents one work, not one provider result. Keep years and
/// seasons distinct, while collapsing duplicate provider posters/languages.
enum WorkSearchIndex {
    static func merge(_ items: [CatalogItem], query: String, limit: Int = 60) -> [CatalogItem] {
        let wanted = MediaTitleIdentity.key(for: query)
        guard !wanted.isEmpty else { return [] }
        var order: [String] = []
        var works: [String: CatalogItem] = [:]
        for var item in items {
            let matches = ([item.title] + item.aliases).contains {
                MediaTitleIdentity.key(for: $0).contains(wanted)
            }
            guard matches else { continue }
            item.title = MediaTitleIdentity.canonicalTitle(item.title)
            let year = String(item.year.prefix(4))
            let key = [item.section.rawValue, MediaTitleIdentity.key(for: item.title), year]
                .joined(separator: "|")
            guard var current = works[key] else {
                works[key] = item
                order.append(key)
                continue
            }
            current.aliases = Array(Set(current.aliases + item.aliases + [item.title]))
            if current.posterURL == nil { current.posterURL = item.posterURL }
            if current.region.isEmpty { current.region = item.region }
            if current.genre.isEmpty { current.genre = item.genre }
            if current.summary.isEmpty { current.summary = item.summary }
            if current.workID == nil, item.workID != nil { current.workID = item.workID }
            if (current.updatedAt ?? .distantPast) < (item.updatedAt ?? .distantPast) {
                current.updatedAt = item.updatedAt
            }
            works[key] = current
        }
        return Array(order.compactMap { works[$0] }.sorted { lhs, rhs in
            let lhsRank = rank(lhs, wanted: wanted)
            let rhsRank = rank(rhs, wanted: wanted)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsYear = Int(lhs.year.prefix(4)) ?? 0
            let rhsYear = Int(rhs.year.prefix(4)) ?? 0
            if lhsYear != rhsYear { return lhsYear > rhsYear }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }.prefix(max(1, limit)))
    }

    private static func rank(_ item: CatalogItem, wanted: String) -> Int {
        let title = MediaTitleIdentity.key(for: item.title)
        if title == wanted { return 0 }
        if title.hasPrefix(wanted) { return 1 }
        return item.aliases.contains { MediaTitleIdentity.key(for: $0) == wanted } ? 2 : 3
    }
}
