import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var repository: ContentRepository
    @EnvironmentObject private var persistence: PersistenceStore
    @Environment(\.openURL) private var openURL
    @State private var showSettings = false
    @State private var showUpdateHelp = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(LunaTheme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("我的 LunaTV").font(.title3.bold())
                        Text("三路共享服务 · \(repository.configuration.apiSites.count) 路直连源 · 缓存与内置片库后备")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(AppVersion.profileLabel())
                            .font(.caption).foregroundStyle(.secondary)
                        if let lastRefresh = repository.lastRefresh {
                            Text("更新于 \(lastRefresh.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            Section("个人内容") {
                NavigationLink {
                    FavoritesView()
                } label: {
                    Label("我的收藏（\(persistence.favorites.count)）", systemImage: "heart.fill")
                }
                NavigationLink {
                    HistoryView()
                } label: {
                    Label("观看记录（\(persistence.history.count)）", systemImage: "clock.fill")
                }
            }

            Section("内容与更新") {
                Button {
                    Task {
                        await repository.refresh(remoteConfigurationURL: persistence.preferences.remoteConfigurationURL)
                    }
                } label: {
                    Label("刷新片库、播放源和直播", systemImage: "arrow.clockwise")
                }
                Button(action: checkUpdate) {
                    Label("获取 iPhone 新版本", systemImage: "arrow.down.app.fill")
                }
                Button { showSettings = true } label: {
                    Label("设置", systemImage: "gearshape.fill")
                }
            }

            if let error = repository.refreshError {
                Section("最近一次刷新") {
                    Text(error).foregroundStyle(.orange)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("我的")
        .sheet(isPresented: $showSettings) { SettingsView() }
        .alert("iOS 应用更新", isPresented: $showUpdateHelp) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text("请先在 iPhone 安装 AltStore，再打开 LunaTV 更新页安装新版。普通 Apple ID 免费签名需要定期刷新；iOS 不允许未签名 App 静默覆盖安装。")
        }
        .lunaBackground()
    }

    private func checkUpdate() {
        let value = persistence.preferences.testFlightURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), !value.isEmpty else {
            showUpdateHelp = true
            return
        }
        openURL(url)
    }
}

struct FavoritesView: View {
    @EnvironmentObject private var persistence: PersistenceStore

    var body: some View {
        ScrollView {
            if persistence.favorites.isEmpty {
                EmptyStateView(title: "还没有收藏", message: "在影片详情页点击心形按钮即可收藏。")
            } else {
                CatalogGrid(items: persistence.favorites).padding()
            }
        }
        .navigationTitle("我的收藏")
        .lunaBackground()
    }
}

private struct HistoryPlaybackRoute: Identifiable {
    let id = UUID()
    let record: PlaybackRecord
}

struct HistoryView: View {
    @EnvironmentObject private var persistence: PersistenceStore
    @State private var route: HistoryPlaybackRoute?
    @State private var confirmClear = false

    var body: some View {
        Group {
            if persistence.history.isEmpty {
                EmptyStateView(title: "还没有观看记录", message: "播放后会自动保存当前集和进度。")
            } else {
                List(persistence.history) { record in
                    Button { route = HistoryPlaybackRoute(record: record) } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: record.item.posterURL) { phase in
                                if case .success(let image) = phase { image.resizable().scaledToFill() }
                                else { LunaTheme.surface.overlay(Image(systemName: "play.fill")) }
                            }
                            .frame(width: 56, height: 82).clipped().cornerRadius(8)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(record.item.title).font(.headline)
                                Text(record.episode.title).font(.subheadline).foregroundStyle(.secondary)
                                ProgressView(value: record.positionSeconds,
                                             total: max(1, record.durationSeconds))
                                    .tint(LunaTheme.accent)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("观看记录")
        .toolbar {
            if !persistence.history.isEmpty {
                Button("清空", role: .destructive) { confirmClear = true }
            }
        }
        .confirmationDialog("确认清空全部观看记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空观看记录", role: .destructive) { persistence.clearHistory() }
        }
        .fullScreenCover(item: $route) { route in
            let record = route.record
            let source = PlaybackSource(id: record.sourceID, name: "观看记录",
                                        responseTimeMilliseconds: nil, episodes: [record.episode])
            PlayerView(item: record.item, sources: [source], initialSourceIndex: 0, initialEpisodeIndex: 0)
                .environmentObject(persistence)
        }
        .lunaBackground()
    }
}

struct SettingsView: View {
    @EnvironmentObject private var repository: ContentRepository
    @EnvironmentObject private var persistence: PersistenceStore
    @Environment(\.dismiss) private var dismiss
    @State private var remoteConfigurationURL = ""
    @State private var testFlightURL = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("播放源配置") {
                    TextField("远程配置 JSON 地址（留空使用内置配置）", text: $remoteConfigurationURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("播放源配置与共享片库服务彼此独立。共享服务不可达时自动切换 Pages、家庭局域网、Worker、直连源、缓存和内置片库；前台每 10 分钟静默刷新。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("应用更新") {
                    TextField("IPA 下载页或发布页地址", text: $testFlightURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("默认打开当前 LunaTV iPhone 更新页；也可改成你的 TestFlight 或 AltStore Source 地址。免费签名需要定期刷新。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        persistence.preferences.remoteConfigurationURL = remoteConfigurationURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        persistence.preferences.testFlightURL = testFlightURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            await repository.refresh(remoteConfigurationURL: persistence.preferences.remoteConfigurationURL)
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                remoteConfigurationURL = persistence.preferences.remoteConfigurationURL
                testFlightURL = persistence.preferences.testFlightURL
            }
        }
    }
}
