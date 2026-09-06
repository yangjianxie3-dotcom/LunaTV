import SwiftUI

private struct LibraryLoadID: Hashable {
    let filters: BrowseFilters
    let contentRevision: UInt
}

struct LibraryView: View {
    @EnvironmentObject private var repository: ContentRepository
    @State private var filters = BrowseFilters(section: .movie)
    @State private var items: [CatalogItem] = []
    @State private var nextStart = 0
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var lastAddedCount = 0
    @State private var loadNotice = ""

    private let pageSize = 24

    private let sorts = ["综合排序", "近期更新", "首播时间", "高分优先"]

    private var categories: [String] {
        switch filters.section {
        case .movie: return ["全部", "热门电影", "最新电影", "豆瓣高分", "冷门佳片"]
        case .drama: return ["全部", "最近热门", "大陆剧", "港剧", "台剧", "韩剧", "日剧", "欧美剧", "泰剧"]
        case .anime: return ["全部", "每日放送", "在播国漫", "日本新番", "番剧", "剧场版"]
        case .variety: return ["全部", "最近热门"]
        }
    }

    private var genres: [String] {
        switch filters.section {
        case .movie:
            return ["全部", "喜剧", "爱情", "动作", "科幻", "悬疑", "犯罪", "冒险", "奇幻", "纪录片"]
        case .drama:
            return ["全部", "剧情", "喜剧", "爱情", "悬疑", "犯罪", "古装"]
        case .anime:
            return ["全部", "国产动漫", "日本动漫", "日韩动漫", "欧美动漫", "动漫电影"]
        case .variety:
            return ["全部", "大陆综艺", "日韩综艺", "欧美综艺", "真人秀", "脱口秀"]
        }
    }

    private var regions: [String] {
        switch filters.section {
        case .movie:
            return ["全部", "中国大陆", "中国香港", "中国台湾", "华语", "日本", "韩国", "欧美", "美国", "英国", "泰国"]
        case .drama:
            return ["全部", "中国大陆", "中国香港", "中国台湾", "华语", "日本", "韩国", "欧美", "泰国"]
        case .anime:
            return ["全部", "中国大陆", "日本", "欧美", "美国"]
        case .variety:
            return ["全部", "中国大陆", "中国香港", "中国台湾", "华语", "日本", "韩国", "欧美"]
        }
    }

    private var years: [String] {
        ["全部"] + stride(from: Calendar.current.component(.year, from: Date()), through: 1990, by: -1).map(String.init)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("内容分类", selection: $filters.section) {
                    ForEach(MediaSection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(categories, id: \.self) { category in
                            Button(category) { filters.category = category }
                                .buttonStyle(.borderedProminent)
                                .tint(filters.category == category ? LunaTheme.accent : LunaTheme.surface)
                        }
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        filterMenu("类型", selection: $filters.genre, values: genres)
                        filterMenu("地区", selection: $filters.region, values: regions)
                        filterMenu("年代", selection: $filters.year, values: years)
                        filterMenu("排序", selection: $filters.sort, values: sorts)
                    }
                }

                if isLoading && items.isEmpty {
                    LoadingStateView(title: "正在读取\(filters.section.rawValue)片库…")
                } else if items.isEmpty {
                    EmptyStateView(title: "当前筛选暂无结果", message: "可调整地区、年代或类型后重试。")
                } else {
                    if !loadNotice.isEmpty {
                        Text(loadNotice)
                            .font(.caption)
                            .foregroundStyle(LunaTheme.secondaryText)
                    }
                    CatalogGrid(items: items)
                    Button {
                        Task { await load(reset: false) }
                    } label: {
                        VStack(spacing: 4) {
                            HStack {
                                Spacer()
                                if isLoading {
                                    ProgressView()
                                    Text("正在聚合更多内容…")
                                } else {
                                    Text(hasMore ? "加载更多" : "已经到底")
                                }
                                Spacer()
                            }
                            if !isLoading, lastAddedCount > 0 {
                                Text("本次新增 \(lastAddedCount) 部")
                                    .font(.caption)
                                    .foregroundStyle(.black.opacity(0.65))
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LunaTheme.accent)
                    .disabled(isLoading || !hasMore)
                }
            }
            .padding()
            .padding(.bottom, 96)
        }
        .navigationTitle(filters.section.rawValue)
        .refreshable { await load(reset: true) }
        .task(id: LibraryLoadID(filters: filters, contentRevision: repository.contentRevision)) {
            await load(reset: true)
        }
        .onChange(of: filters.section) { _ in
            filters.category = "全部"
            filters.genre = "全部"
            filters.region = "全部"
            filters.year = "全部"
            filters.platform = "全部"
            filters.sort = "综合排序"
        }
        .lunaBackground()
    }

    private func filterMenu(_ title: String, selection: Binding<String>, values: [String]) -> some View {
        Menu {
            Picker(title, selection: selection) {
                ForEach(values, id: \.self) { Text($0).tag($0) }
            }
        } label: {
            Label("\(title)：\(selection.wrappedValue)", systemImage: "chevron.down")
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(LunaTheme.surface, in: Capsule())
        }
    }

    private func load(reset: Bool) async {
        let requestedFilters = filters
        var requestedStart = reset ? 0 : nextStart
        if reset {
            items = []
            hasMore = true
            lastAddedCount = 0
            loadNotice = ""
        }
        isLoading = true

        var knownIDs = reset ? Set<String>() : Set(items.map(\.deduplicationKey))
        var additions: [CatalogItem] = []
        var lastPage = CatalogPageResult(items: [], nextStart: requestedStart,
                                         hasMore: true, paginationStatus: "initial", notice: "")
        var lastRequestedStart = requestedStart
        let maximumAttempts = reset ? 1 : 3

        for _ in 0..<maximumAttempts {
            lastRequestedStart = requestedStart
            lastPage = await repository.catalogPage(filters: requestedFilters,
                                                    start: requestedStart,
                                                    pageSize: pageSize)
            for item in lastPage.items where knownIDs.insert(item.deduplicationKey).inserted {
                additions.append(item)
            }
            if additions.count >= pageSize || !lastPage.hasMore
                || lastPage.nextStart <= requestedStart { break }
            requestedStart = lastPage.nextStart
        }

        guard !Task.isCancelled, requestedFilters == filters else { return }
        nextStart = lastPage.nextStart
        if reset { items = additions } else { items.append(contentsOf: additions) }
        lastAddedCount = additions.count
        hasMore = lastPage.hasMore && lastPage.nextStart > lastRequestedStart
        loadNotice = lastPage.notice
        isLoading = false
    }
}
