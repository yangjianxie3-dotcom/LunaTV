import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var repository: ContentRepository
    @EnvironmentObject private var persistence: PersistenceStore
    @State private var sections: [MediaSection: [CatalogItem]] = [:]
    @State private var isLoading = true
    @ObservedObject private var network = NetworkMonitor.shared

    private var recentRecords: [PlaybackRecord] {
        var seen = Set<String>()
        return Array(persistence.history.filter { seen.insert($0.item.id).inserted }.prefix(10))
    }

    private var featuredItem: CatalogItem? {
        MediaSection.allCases.compactMap { sections[$0]?.first }.first
    }

    private var hasCatalogContent: Bool {
        sections.values.contains { !$0.isEmpty }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                NetworkStatusStrip()
                HStack(spacing: 8) {
                    ForEach(MediaSection.allCases) { section in
                        NavigationLink { LibraryView(initialSection: section) } label: {
                            Text(section.rawValue).font(.subheadline.bold())
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(LunaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                    }
                }
                if let featuredItem {
                    featuredHero(featuredItem)
                }
                if !persistence.history.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("继续观看").font(.title3.bold())
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(recentRecords) { record in
                                    NavigationLink(value: record.item) {
                                        HStack(spacing: 12) {
                                            PosterImageView(url: record.item.posterURL)
                                                .frame(width: 52, height: 76).clipped()
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(record.item.title).font(.subheadline.bold()).lineLimit(1)
                                                Text(record.episode.title).font(.caption).foregroundStyle(LunaTheme.secondaryText)
                                                ProgressView(value: min(1, record.positionSeconds / max(1, record.durationSeconds)))
                                                    .tint(LunaTheme.accent)
                                                Text("已看 \(Int(record.positionSeconds / 60)) 分钟").font(.caption2)
                                            }
                                        }.padding(10).frame(width: 250)
                                            .background(LunaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                if isLoading && sections.isEmpty {
                    LoadingStateView(title: "正在聚合最新片库…")
                } else if hasCatalogContent {
                    ForEach(MediaSection.allCases) { section in
                        if let items = sections[section], !items.isEmpty {
                            CatalogSectionRow(title: "最新\(section.rawValue)", items: items)
                        }
                    }
                } else {
                    EmptyStateView(title: "暂未读到片库",
                                   message: "三路共享服务、28 路直连、历史缓存与内置片库当前均未返回内容，请稍后下拉重试。")
                }
            }
            .padding()
        }
        .navigationTitle("YJTV")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: network.snapshot.generation) { _ in
            if network.snapshot.isConnected && !hasCatalogContent && !isLoading { Task { await load() } }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("刷新首页")
            }
        }
        .refreshable { await refresh() }
        .task(id: repository.contentRevision) {
            guard !repository.configuration.apiSites.isEmpty else { return }
            await load()
        }
        .lunaBackground()
    }

    private func featuredHero(_ item: CatalogItem) -> some View {
        NavigationLink(value: item) {
            ZStack(alignment: .bottomLeading) {
                PosterImageView(url: item.posterURL)
                .frame(maxWidth: .infinity, minHeight: 186, maxHeight: 186)
                .clipped()

                LinearGradient(colors: [.clear, LunaTheme.background.opacity(0.97)],
                               startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 8) {
                    Text("本周精选")
                        .font(.caption.bold())
                        .foregroundStyle(LunaTheme.accent)
                    Text(item.title)
                        .font(.title.bold())
                        .lineLimit(2)
                    Text([item.year, item.region, item.genre].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(LunaTheme.secondaryText)
                        .lineLimit(1)
                    Label("查看详情", systemImage: "play.fill")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 15)
                        .padding(.vertical, 9)
                        .background(LunaTheme.accent, in: Capsule())
                        .foregroundStyle(.black)
                }
                .padding(18)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func refresh() async {
        await repository.refresh(remoteConfigurationURL: persistence.preferences.remoteConfigurationURL)
    }

    private func load() async {
        isLoading = true
        let loadedSections = await repository.homeSections()
        guard !Task.isCancelled else { return }
        sections = loadedSections
        isLoading = false
    }
}
