import Foundation
import Combine

struct Workout: Identifiable, Codable {
    var id = UUID()
    var name: String
    var exercises: [String]
}

final class WorkoutStore: ObservableObject {
    @Published var workouts: [Workout] = [] { didSet { save() } }
    private let key = "workouts"

    init() { load() }

    func add(_ workout: Workout) { workouts.append(workout) }
    func remove(at offsets: IndexSet) { workouts.remove(atOffsets: offsets) }

    private func save() {
        if let data = try? JSONEncoder().encode(workouts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
        let saved = try? JSONDecoder().decode([Workout].self, from: data) {
            workouts = saved
        }
    }
}
