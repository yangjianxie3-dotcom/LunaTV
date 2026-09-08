import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var repository: ContentRepository
    @EnvironmentObject private var persistence: PersistenceStore
    @State private var query = ""
    @State private var results: [CatalogItem] = []
    @State private var discoveryItems: [CatalogItem] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @ObservedObject private var network = NetworkMonitor.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                NetworkStatusStrip()
                if isSearching && results.isEmpty {
                    LoadingStateView(title: "正在查询全部播放源…")
                } else if let errorMessage {
                    EmptyStateView(title: "搜索失败", message: errorMessage)
                } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    discovery
                } else if results.isEmpty {
                    EmptyStateView(title: network.snapshot.isConnected ? "没有匹配结果" : "网络暂时断开",
                                   message: "可重试查询，或尝试完整片名、中文别名、英文名。")
                    Button("重试搜索") { Task { await performSearch() } }.buttonStyle(.bordered)
                } else {
                    Text("找到 \(results.count) 部内容\(isSearching ? " · 其余线路查询中" : "")")
                        .font(.subheadline)
                        .foregroundStyle(LunaTheme.secondaryText)
                    CatalogGrid(items: results)
                }
            }
            .padding()
        }
        .navigationTitle("搜索")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "片名或别名")
        .onSubmit(of: .search) {
            persistence.rememberSearch(query)
        }
        .task(id: query) {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                results = []
                isSearching = false
                errorMessage = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await performSearch()
        }
        .task(id: repository.contentRevision) {
            let sections = await repository.homeSections()
            discoveryItems = Array(MediaSection.allCases
                .flatMap { sections[$0] ?? [] }
                .uniqued(by: \.id)
                .prefix(12))
        }
        .lunaBackground()
    }

    private var discovery: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !persistence.searchHistory.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("最近搜索").font(.title3.bold())
                        Spacer()
                        Button("清空") { persistence.clearSearchHistory() }
                            .font(.caption)
                            .foregroundStyle(LunaTheme.secondaryText)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(persistence.searchHistory, id: \.self) { keyword in
                                Button {
                                    query = keyword
                                    persistence.rememberSearch(keyword)
                                } label: {
                                    Label(keyword, systemImage: "clock")
                                        .font(.subheadline)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 9)
                                        .background(LunaTheme.surface, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("热门推荐").font(.title3.bold())
                if discoveryItems.isEmpty {
                    LoadingStateView(title: "正在加载热门内容…")
                } else {
                    CatalogGrid(items: discoveryItems)
                }
            }
        }
    }

    private func performSearch() async {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        isSearching = true
        errorMessage = nil
        let found = await repository.search(value) { partial in
            guard !Task.isCancelled, value == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            results = partial
        }
        guard !Task.isCancelled else { return }
        guard value == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        results = found
        isSearching = false
    }
}

private extension Sequence {
    func uniqued<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}
