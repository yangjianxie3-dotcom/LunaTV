import SwiftUI

struct LiveView: View {
    @EnvironmentObject private var repository: ContentRepository

    var body: some View {
        Group {
            if repository.configuration.liveSources.isEmpty {
                EmptyStateView(title: "暂无直播配置", message: "可在“我的－设置”中填写远程配置地址后刷新。")
            } else {
                List(repository.configuration.liveSources) { source in
                    NavigationLink {
                        LiveChannelView(source: source)
                    } label: {
                        Label(source.name, systemImage: "dot.radiowaves.left.and.right")
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("直播")
        .lunaBackground()
    }
}
private struct LivePlaybackRoute: Identifiable {
    let id = UUID()
    let item: CatalogItem
    let source: PlaybackSource
}

struct LiveChannelView: View {
    let source: LiveSource

    @EnvironmentObject private var repository: ContentRepository
    @EnvironmentObject private var persistence: PersistenceStore
    @State private var channels: [LiveChannel] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var route: LivePlaybackRoute?
    @State private var query = ""

    private var filteredChannels: [LiveChannel] {
        guard !query.isEmpty else { return channels }
        return channels.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.group.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView(title: "正在读取直播频道…")
            } else if let errorMessage {
                EmptyStateView(title: "直播读取失败", message: errorMessage)
            } else {
                List(filteredChannels) { channel in
                    Button {
                        route = playbackRoute(for: channel)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(channel.name)
                            if !channel.group.isEmpty {
                                Text(channel.group).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索频道")
        .task {
            do {
                channels = try await repository.liveChannels(from: source)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
        .fullScreenCover(item: $route) { route in
            PlayerView(item: route.item, sources: [route.source],
                       initialSourceIndex: 0, initialEpisodeIndex: 0)
                .environmentObject(persistence)
        }
        .lunaBackground()
    }

    private func playbackRoute(for channel: LiveChannel) -> LivePlaybackRoute {
        let item = CatalogItem(id: "live:" + channel.id, title: channel.name,
                               section: .variety, category: "直播", region: channel.group,
                               sourceLabel: source.name)
        let episode = Episode(id: channel.url.absoluteString, title: "直播", url: channel.url, index: 0)
        let playbackSource = PlaybackSource(id: source.id, name: source.name,
                                            responseTimeMilliseconds: nil, episodes: [episode])
        return LivePlaybackRoute(item: item, source: playbackSource)
    }
}
