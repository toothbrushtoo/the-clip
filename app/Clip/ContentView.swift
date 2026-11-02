import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            SessionView()
                .tabItem { Label("Workout", systemImage: "figure.strengthtraining.traditional") }
            WorkoutsView()
                .tabItem { Label("Workouts", systemImage: "list.bullet.rectangle") }
        }
    }
}
