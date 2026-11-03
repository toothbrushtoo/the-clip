import SwiftUI

@main
struct ClipApp: App {
    @StateObject private var store = WorkoutStore()
    @StateObject private var history = HistoryStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(history)
        }
    }
}
