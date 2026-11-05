import Foundation
import Combine

// One line of a workout plan: an exercise with the weight, sets and reps to do.
struct WorkoutExercise: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var weightKg: Double = 10
    var sets: Int = 3
    var reps: Int = 10

    var summary: String {
        let w = weightKg == weightKg.rounded() ? String(format: "%.0f", weightKg) : String(format: "%.1f", weightKg)
        return "\(sets) × \(reps) · \(w) kg"
    }
}

struct Workout: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var exercises: [WorkoutExercise]

    init(id: UUID = UUID(), name: String, exercises: [WorkoutExercise]) {
        self.id = id
        self.name = name
        self.exercises = exercises
    }

    enum CodingKeys: String, CodingKey { case id, name, exercises }

    // Older saves stored exercises as plain names; give those default sets and reps.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        if let list = try? c.decode([WorkoutExercise].self, forKey: .exercises) {
            exercises = list
        } else {
            let names = (try? c.decode([String].self, forKey: .exercises)) ?? []
            exercises = names.map { WorkoutExercise(name: $0) }
        }
    }

    var totalSets: Int { exercises.reduce(0) { $0 + $1.sets } }
}

final class WorkoutStore: ObservableObject {
    @Published var workouts: [Workout] = [] { didSet { save() } }
    private let key = "workouts"

    init() { load() }

    func add(_ workout: Workout) { workouts.append(workout) }

    func update(_ workout: Workout) {
        if let i = workouts.firstIndex(where: { $0.id == workout.id }) {
            workouts[i] = workout
        } else {
            workouts.append(workout)
        }
    }

    func remove(at offsets: IndexSet) { workouts.remove(atOffsets: offsets) }

    func remove(_ workout: Workout) { workouts.removeAll { $0.id == workout.id } }

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
