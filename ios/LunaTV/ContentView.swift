import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var repository: ContentRepository
    @EnvironmentObject private var persistence: PersistenceStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            catalogStack { HomeView() }
                .tabItem { Label("首页", systemImage: "house.fill") }
            catalogStack { LibraryView() }
                .tabItem { Label("片库", systemImage: "rectangle.grid.2x2.fill") }
            catalogStack { SearchView() }
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            NavigationStack { LiveView() }
                .tabItem { Label("直播", systemImage: "dot.radiowaves.left.and.right") }
            catalogStack { ProfileView() }
                .tabItem { Label("我的", systemImage: "person.crop.circle.fill") }
        }
        .tint(LunaTheme.accent)
        .lunaBackground()
        .task {
            await repository.bootstrap(remoteConfigurationURL: persistence.preferences.remoteConfigurationURL)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(persistence.preferences.refreshIntervalSeconds))
                guard scenePhase == .active else { continue }
                await repository.refresh(remoteConfigurationURL: persistence.preferences.remoteConfigurationURL)
            }
        }
    }

    private func catalogStack<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content()
                .navigationDestination(for: CatalogItem.self) { item in
                    DetailView(item: item)
                }
        }
    }
}
