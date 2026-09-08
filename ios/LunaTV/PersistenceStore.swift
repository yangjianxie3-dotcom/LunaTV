import Foundation

@MainActor
final class PersistenceStore: ObservableObject {
    @Published private(set) var favorites: [CatalogItem] = []
    @Published private(set) var history: [PlaybackRecord] = []
    @Published private(set) var searchHistory: [String] = []
    @Published var preferences = AppPreferences() {
        didSet { save(preferences, key: Keys.preferences) }
    }

    private enum Keys {
        static let favorites = "ios.favorites.v1"
        static let history = "ios.history.v1"
        static let searchHistory = "ios.searchHistory.v1"
        static let preferences = "ios.preferences.v1"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favorites = load([CatalogItem].self, key: Keys.favorites) ?? []
        history = load([PlaybackRecord].self, key: Keys.history) ?? []
        searchHistory = load([String].self, key: Keys.searchHistory) ?? []
        preferences = load(AppPreferences.self, key: Keys.preferences) ?? AppPreferences()
    }

    func isFavorite(_ item: CatalogItem) -> Bool {
        favorites.contains { $0.id == item.id }
    }

    func toggleFavorite(_ item: CatalogItem) {
        if let index = favorites.firstIndex(where: { $0.id == item.id }) {
            favorites.remove(at: index)
        } else {
            favorites.insert(item, at: 0)
        }
        save(favorites, key: Keys.favorites)
    }

    func resumePosition(for episodeURL: URL) -> Double {
        history.first(where: { $0.episode.url == episodeURL })?.positionSeconds ?? 0
    }

    func resumePosition(item: CatalogItem, episode: Episode) -> Double {
        history.first {
            $0.item.id == item.id && EpisodeIdentity.matchingIndex(for: $0.episode, in: [episode]) != nil
        }?.positionSeconds ?? 0
    }

    func updateHistory(item: CatalogItem, sourceID: String, episode: Episode,
                       position: Double, duration: Double) {
        guard position.isFinite, duration.isFinite else { return }
        history.removeAll {
            $0.episode.url == episode.url || ($0.item.id == item.id
                && EpisodeIdentity.matchingIndex(for: $0.episode, in: [episode]) != nil)
        }
        guard duration <= 0 || position < max(0, duration - 15) else {
            save(history, key: Keys.history)
            return
        }
        let record = PlaybackRecord(id: episode.url.absoluteString, item: item,
                                    sourceID: sourceID, episode: episode,
                                    positionSeconds: max(0, position),
                                    durationSeconds: max(0, duration), updatedAt: Date())
        history.insert(record, at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
        save(history, key: Keys.history)
    }

    func clearHistory() {
        history = []
        save(history, key: Keys.history)
    }

    func rememberSearch(_ query: String) {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        searchHistory.removeAll { $0.localizedCaseInsensitiveCompare(value) == .orderedSame }
        searchHistory.insert(value, at: 0)
        if searchHistory.count > 12 { searchHistory.removeLast(searchHistory.count - 12) }
        save(searchHistory, key: Keys.searchHistory)
    }

    func clearSearchHistory() {
        searchHistory = []
        save(searchHistory, key: Keys.searchHistory)
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func save<T: Encodable>(_ value: T, key: String) {
        defaults.set(try? encoder.encode(value), forKey: key)
    }

    private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
