import SwiftUI

@main
struct ClipApp: App {
    @StateObject private var store = WorkoutStore()
    @StateObject private var history = HistoryStore()
    @StateObject private var exercises = ExerciseStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(history)
                .environmentObject(exercises)
        }
    }
}
