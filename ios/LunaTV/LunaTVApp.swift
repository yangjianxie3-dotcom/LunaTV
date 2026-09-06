import SwiftUI

@main
struct LunaTVApp: App {
    @StateObject private var repository = ContentRepository()
    @StateObject private var persistence = PersistenceStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(repository)
                .environmentObject(persistence)
        }
    }
}
