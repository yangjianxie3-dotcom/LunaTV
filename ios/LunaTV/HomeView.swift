import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var repository: ContentRepository
    @EnvironmentObject private var persistence: PersistenceStore
    @State private var sections: [MediaSection: [CatalogItem]] = [:]
    @State private var isLoading = true

    private var featuredItem: CatalogItem? {
        MediaSection.allCases.compactMap { sections[$0]?.first }.first
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if let featuredItem {
                    featuredHero(featuredItem)
                }
                if !persistence.history.isEmpty {
                    CatalogSectionRow(title: "继续观看",
                                      items: Array(persistence.history.map(\.item).prefix(10)))
                }
                if isLoading && sections.isEmpty {
                    LoadingStateView(title: "正在聚合最新片库…")
                } else {
                    ForEach(MediaSection.allCases) { section in
                        if let items = sections[section], !items.isEmpty {
                            CatalogSectionRow(title: "最新\(section.rawValue)", items: items)
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("LunaTV")
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
                AsyncImage(url: item.posterURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        LinearGradient(colors: [LunaTheme.raised, LunaTheme.surface],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 220)
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
