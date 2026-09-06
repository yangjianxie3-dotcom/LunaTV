import SwiftUI

private struct PlayerRoute: Identifiable {
    let id = UUID()
    let item: CatalogItem
    let sources: [PlaybackSource]
    let sourceIndex: Int
    let episodeIndex: Int
}

private struct PlaybackSourceOption: Identifiable {
    let order: Int
    let sourceIndex: Int
    let source: PlaybackSource
    var id: String { source.id }
}

struct DetailView: View {
    let item: CatalogItem

    @EnvironmentObject private var repository: ContentRepository
    @EnvironmentObject private var persistence: PersistenceStore
    @State private var sources: [PlaybackSource] = []
    @State private var selectedSourceIndex = 0
    @State private var selectedLanguage = "原声"
    @State private var isLoading = true
    @State private var route: PlayerRoute?

    private var selectedSource: PlaybackSource? {
        sources.indices.contains(selectedSourceIndex) ? sources[selectedSourceIndex] : nil
    }

    private var availableLanguages: [String] {
        var seen = Set<String>()
        let values = sources.map(\.language).filter { seen.insert($0).inserted }
        let preferredOrder: [String]
        if item.region.contains("香港") {
            preferredOrder = ["粤语", "国语", "双语", "原声"]
        } else if item.region.contains("中国") || item.region.contains("大陆") {
            preferredOrder = ["国语", "原声", "粤语", "双语"]
        } else {
            preferredOrder = ["原声", "国语", "粤语", "双语"]
        }
        return values.sorted {
            (preferredOrder.firstIndex(of: $0) ?? Int.max) <
                (preferredOrder.firstIndex(of: $1) ?? Int.max)
        }
    }

    private var visibleSourceOptions: [PlaybackSourceOption] {
        sources.enumerated()
            .filter { $0.element.language == selectedLanguage }
            .enumerated()
            .map { order, entry in
                PlaybackSourceOption(order: order, sourceIndex: entry.offset, source: entry.element)
            }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                sourceSelector
                episodeSelector
            }
            .padding()
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { persistence.toggleFavorite(item) } label: {
                    Image(systemName: persistence.isFavorite(item) ? "heart.fill" : "heart")
                }
                .accessibilityLabel(persistence.isFavorite(item) ? "取消收藏" : "收藏")
            }
        }
        .task(id: item.id) {
            isLoading = true
            sources = await repository.sources(for: item)
            selectedSourceIndex = preferredSourceIndex()
            if sources.indices.contains(selectedSourceIndex) {
                selectedLanguage = sources[selectedSourceIndex].language
            } else if let first = availableLanguages.first {
                selectedLanguage = first
            }
            isLoading = false
        }
        .fullScreenCover(item: $route) { route in
            PlayerView(item: route.item, sources: route.sources,
                       initialSourceIndex: route.sourceIndex,
                       initialEpisodeIndex: route.episodeIndex)
                .environmentObject(persistence)
        }
        .lunaBackground()
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                AsyncImage(url: item.posterURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        ZStack {
                            LunaTheme.surface
                            Image(systemName: "play.tv.fill")
                                .font(.largeTitle)
                                .foregroundStyle(LunaTheme.accent)
                        }
                    }
                }
                .frame(width: 132, height: 198)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 10) {
                    Text(item.title).font(.title2.bold())
                    Text([item.year, item.region, item.genre].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(LunaTheme.secondaryText)
                    if let score = item.score, score > 0 {
                        Label(score.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                    Button {
                        play(episodeIndex: preferredEpisodeIndex())
                    } label: {
                        Label(preferredEpisodeIndex() > 0 ? "继续播放" : "播放第 1 集",
                              systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LunaTheme.accent)
                    .disabled(selectedSource?.episodes.isEmpty ?? true)
                }
            }
            if !item.summary.isEmpty {
                Text(item.summary)
                    .font(.subheadline)
                    .foregroundStyle(LunaTheme.secondaryText)
                    .lineLimit(5)
            }
        }
    }

    @ViewBuilder
    private var sourceSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLoading {
                HStack { ProgressView(); Text("正在匹配全部已配置播放源…") }
                    .foregroundStyle(LunaTheme.secondaryText)
            } else if sources.isEmpty {
                Text("片库有该内容，但当前配置源没有返回可播放版本。可返回搜索尝试其他片名。")
                    .foregroundStyle(LunaTheme.secondaryText)
            } else {
                if availableLanguages.count > 1 {
                    Text("语种").font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(availableLanguages, id: \.self) { language in
                                Button(language) { selectLanguage(language) }
                                    .buttonStyle(.borderedProminent)
                                    .tint(language == selectedLanguage ? LunaTheme.accent : LunaTheme.surface)
                            }
                        }
                    }
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("播放线路").font(.headline)
                    Spacer()
                    Text("已按实测缓存速度排序")
                        .font(.caption)
                        .foregroundStyle(LunaTheme.secondaryText)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(visibleSourceOptions) { option in
                            let index = option.sourceIndex
                            let source = option.source
                            Button {
                                selectedSourceIndex = index
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text("线路 \(option.order + 1)").fontWeight(.semibold)
                                        Text(source.streamHealth.title)
                                            .font(.caption2.bold())
                                            .foregroundStyle(source.streamHealth == .verified ? LunaTheme.accent : LunaTheme.secondaryText)
                                    }
                                    Text(source.name).lineLimit(1)
                                        .font(.caption)
                                        .foregroundStyle(LunaTheme.secondaryText)
                                    Text(sourceSpeedDescription(source))
                                        .font(.caption)
                                        .foregroundStyle(LunaTheme.secondaryText)
                                }
                                .padding(12)
                                .background(index == selectedSourceIndex ? LunaTheme.accentSoft : LunaTheme.surface,
                                            in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .stroke(index == selectedSourceIndex ? LunaTheme.accent : .clear, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var episodeSelector: some View {
        if let source = selectedSource, !source.episodes.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("快速选集 · \(source.episodes.count) 集").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)], spacing: 10) {
                    ForEach(source.episodes) { episode in
                        Button(shortEpisodeTitle(episode)) { play(episodeIndex: episode.index) }
                            .buttonStyle(.bordered)
                            .tint(LunaTheme.accent)
                    }
                }
            }
        }
    }

    private func play(episodeIndex: Int) {
        guard !sources.isEmpty, sources.indices.contains(selectedSourceIndex),
              sources[selectedSourceIndex].episodes.indices.contains(episodeIndex) else { return }
        route = PlayerRoute(item: item, sources: sources,
                            sourceIndex: selectedSourceIndex, episodeIndex: episodeIndex)
    }

    private func preferredSourceIndex() -> Int {
        guard let record = persistence.history.first(where: { $0.item.id == item.id }),
              let index = sources.firstIndex(where: { $0.id == record.sourceID }) else {
            if item.region.contains("香港"),
               let cantonese = sources.firstIndex(where: { $0.language == "粤语" }) {
                return cantonese
            }
            if (item.region.contains("中国") || item.region.contains("大陆")),
               let mandarin = sources.firstIndex(where: { $0.language == "国语" }) {
                return mandarin
            }
            return 0
        }
        return index
    }

    private func selectLanguage(_ language: String) {
        selectedLanguage = language
        if let index = sources.firstIndex(where: { $0.language == language }) {
            selectedSourceIndex = index
        }
    }

    private func sourceSpeedDescription(_ source: PlaybackSource) -> String {
        let speed: String
        if let throughput = source.streamThroughputKilobytesPerSecond {
            speed = throughput >= 1_024
                ? String(format: "%.1f MB/s", Double(throughput) / 1_024)
                : "\(throughput) KB/s"
        } else {
            speed = "待测速"
        }
        let latency = source.streamLatencyMilliseconds.map { "\($0) ms" } ?? "-- ms"
        return "\(speed) · \(latency) · \(source.episodes.count) 集"
    }

    private func preferredEpisodeIndex() -> Int {
        guard let source = selectedSource,
              let record = persistence.history.first(where: { $0.item.id == item.id && $0.sourceID == source.id }),
              let index = source.episodes.firstIndex(where: { $0.url == record.episode.url }) else { return 0 }
        return index
    }

    private func shortEpisodeTitle(_ episode: Episode) -> String {
        let digits = episode.title.filter(\.isNumber)
        return digits.isEmpty ? String(episode.index + 1) : String(digits.prefix(4))
    }
}
