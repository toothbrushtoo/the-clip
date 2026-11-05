import Foundation
import Combine

// The exercise library: the built-in ones (some with a profile estimated from the phyphox
// recordings in hardware/data/phyphox) plus anything you teach the app yourself.
struct Exercise: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var isCustom: Bool
    var profile: ExerciseProfile?
    var profileSource: ProfileSource?

    enum ProfileSource: String, Codable {
        case recorded   // learned from our phone recordings before the board existed
        case taught     // learned from you doing the reps in the app
    }

    var statusText: String {
        guard let profile else { return "Not learned yet" }
        switch profileSource {
        case .taught: return "Learned from \(profile.repsTaught) reps · \(profile.qualityLabel)"
        case .recorded: return "Estimated from our recordings"
        case .none: return "Learned"
        }
    }
}

final class ExerciseStore: ObservableObject {
    @Published var exercises: [Exercise] = [] { didSet { save() } }
    private let key = "exercises"

    init() {
        load()
        if exercises.isEmpty { exercises = Self.presets }
    }

    func exercise(named name: String) -> Exercise? {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        return exercises.first { $0.name.lowercased() == n }
    }

    func profile(for name: String) -> ExerciseProfile? {
        exercise(named: name)?.profile
    }

    func add(_ exercise: Exercise) {
        if let i = exercises.firstIndex(where: { $0.name.lowercased() == exercise.name.lowercased() }) {
            exercises[i] = exercise
        } else {
            exercises.append(exercise)
        }
    }

    func remove(_ exercise: Exercise) {
        exercises.removeAll { $0.id == exercise.id }
    }

    func setProfile(_ profile: ExerciseProfile, for name: String) {
        if let i = exercises.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            exercises[i].profile = profile
            exercises[i].profileSource = .taught
        } else {
            exercises.append(Exercise(name: name, isCustom: true, profile: profile, profileSource: .taught))
        }
    }

    func forgetProfile(for name: String) {
        guard let i = exercises.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) else { return }
        if let preset = Self.presets.first(where: { $0.name.lowercased() == name.lowercased() }) {
            exercises[i].profile = preset.profile
            exercises[i].profileSource = preset.profileSource
        } else {
            exercises[i].profile = nil
            exercises[i].profileSource = nil
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(exercises) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([Exercise].self, from: data) {
            exercises = saved
        }
    }

    // Profiles below were learned by tools/rep_engine.py from the recordings in
    // hardware/data/phyphox (phone in hand, before the board arrived). Only the ones that
    // learned cleanly are included; the rest start without a profile.
    static let presets: [Exercise] = [
        Exercise(name: "Curl", isCustom: false,
                 profile: ExerciseProfile(detector: .motion, threshold: 2.8895, amplitude: 17.231,
                                          period: 3.917, minGap: 0.982,
                                          template: [-0.239, -0.122, 0.011, 0.133, 0.24, 0.345, 0.444, 0.555, 0.607, 0.675, 0.726, 0.764, 0.792, 0.819, 0.825, 0.827, 0.839, 0.837, 0.833, 0.858, 0.836, 0.848, 0.812, 0.772, 0.663, 0.529, 0.347, 0.19, -0.004, -0.197, -0.335, -0.474, -0.599, -0.653, -0.72, -0.798, -0.812, -0.832, -0.855, -0.875, -0.885, -0.902, -0.898, -0.88, -0.816, -0.743, -0.66, -0.545, -0.392, -0.206],
                                          repsTaught: 10, quality: 14, exact: true, learnedAt: Date(timeIntervalSince1970: 0)),
                 profileSource: .recorded),
        Exercise(name: "Hammer curl", isCustom: false,
                 profile: ExerciseProfile(detector: .motion, threshold: 9.6817, amplitude: 21.466,
                                          period: 2.611, minGap: 0.653,
                                          template: [0.63, 0.726, 0.804, 0.846, 0.888, 0.894, 0.882, 0.835, 0.802, 0.785, 0.762, 0.766, 0.78, 0.8, 0.822, 0.856, 0.881, 0.879, 0.861, 0.836, 0.738, 0.622, 0.468, 0.26, 0.082, -0.109, -0.287, -0.461, -0.604, -0.731, -0.856, -0.919, -0.954, -0.962, -0.966, -0.968, -0.964, -0.944, -0.903, -0.854, -0.77, -0.666, -0.525, -0.352, -0.183, -0.011, 0.191, 0.3, 0.432, 0.54],
                                          repsTaught: 10, quality: 5, exact: true, learnedAt: Date(timeIntervalSince1970: 0)),
                 profileSource: .recorded),
        Exercise(name: "Shoulder press", isCustom: false, profile: nil, profileSource: nil),
        Exercise(name: "Lateral raise", isCustom: false,
                 profile: ExerciseProfile(detector: .motion, threshold: 7.602, amplitude: 12.879,
                                          period: 2.179, minGap: 0.545,
                                          template: [0.562, 0.546, 0.546, 0.552, 0.548, 0.569, 0.566, 0.539, 0.528, 0.586, 0.633, 0.677, 0.714, 0.759, 0.801, 0.836, 0.852, 0.866, 0.865, 0.815, 0.694, 0.549, 0.398, 0.206, 0.041, -0.174, -0.337, -0.556, -0.7, -0.795, -0.877, -0.894, -0.892, -0.807, -0.665, -0.525, -0.368, -0.212, -0.113, 0.045, 0.137, 0.255, 0.333, 0.394, 0.431, 0.432, 0.431, 0.429, 0.429, 0.42],
                                          repsTaught: 10, quality: 5, exact: true, learnedAt: Date(timeIntervalSince1970: 0)),
                 profileSource: .recorded),
        Exercise(name: "Bent row", isCustom: false, profile: nil, profileSource: nil),
        Exercise(name: "Shrug", isCustom: false, profile: nil, profileSource: nil),
        Exercise(name: "Tricep kickback", isCustom: false,
                 profile: ExerciseProfile(detector: .velocity, threshold: 0.2464, amplitude: 1.937,
                                          period: 1.848, minGap: 0.462,
                                          template: [-0.112, -0.176, -0.209, -0.209, -0.198, -0.196, -0.192, -0.188, -0.159, -0.117, -0.059, 0.008, 0.098, 0.167, 0.293, 0.367, 0.435, 0.478, 0.516, 0.537, 0.543, 0.523, 0.489, 0.426, 0.35, 0.231, 0.138, 0.028, -0.068, -0.13, -0.197, -0.251, -0.298, -0.332, -0.4, -0.428, -0.428, -0.428, -0.427, -0.394, -0.388, -0.344, -0.271, -0.196, -0.122, -0.003, 0.056, 0.095, 0.116, 0.127],
                                          repsTaught: 11, quality: 3, exact: true, learnedAt: Date(timeIntervalSince1970: 0)),
                 profileSource: .recorded),
        Exercise(name: "Overhead tricep", isCustom: false,
                 profile: ExerciseProfile(detector: .velocity, threshold: 0.4602, amplitude: 6.293,
                                          period: 2.2, minGap: 0.55,
                                          template: [-0.701, -0.691, -0.664, -0.617, -0.539, -0.463, -0.343, -0.251, -0.126, -0.023, 0.111, 0.255, 0.391, 0.488, 0.61, 0.701, 0.805, 0.889, 0.945, 0.967, 0.987, 0.996, 0.979, 0.935, 0.855, 0.778, 0.713, 0.616, 0.525, 0.414, 0.31, 0.206, 0.127, 0.052, -0.041, -0.109, -0.19, -0.254, -0.33, -0.391, -0.465, -0.521, -0.577, -0.611, -0.647, -0.661, -0.671, -0.675, -0.655, -0.633],
                                          repsTaught: 10, quality: 15, exact: true, learnedAt: Date(timeIntervalSince1970: 0)),
                 profileSource: .recorded),
        Exercise(name: "Goblet squat", isCustom: false,
                 profile: ExerciseProfile(detector: .velocity, threshold: 0.2792, amplitude: 2.656,
                                          period: 1.989, minGap: 0.497,
                                          template: [-0.874, -0.836, -0.792, -0.739, -0.675, -0.604, -0.528, -0.451, -0.355, -0.237, -0.106, 0.032, 0.182, 0.322, 0.459, 0.575, 0.669, 0.756, 0.825, 0.876, 0.992, 0.992, 0.97, 0.915, 0.833, 0.694, 0.573, 0.448, 0.318, 0.184, 0.077, 0.009, -0.039, -0.09, -0.143, -0.196, -0.245, -0.29, -0.343, -0.399, -0.464, -0.534, -0.609, -0.684, -0.771, -0.829, -0.869, -0.883, -0.883, -0.86],
                                          repsTaught: 10, quality: 22, exact: true, learnedAt: Date(timeIntervalSince1970: 0)),
                 profileSource: .recorded),
        Exercise(name: "Lunge", isCustom: false, profile: nil, profileSource: nil),
        Exercise(name: "Pull-up", isCustom: false, profile: nil, profileSource: nil),
        Exercise(name: "Push-up", isCustom: false,
                 profile: ExerciseProfile(detector: .velocity, threshold: 0.4602, amplitude: 2.228,
                                          period: 2.4, minGap: 0.6,
                                          template: [-0.42, -0.363, -0.304, -0.264, -0.162, -0.123, -0.066, 0.026, 0.082, 0.096, 0.166, 0.237, 0.326, 0.373, 0.429, 0.422, 0.468, 0.523, 0.562, 0.586, 0.541, 0.52, 0.472, 0.417, 0.329, 0.147, 0.048, -0.046, -0.115, -0.181, -0.321, -0.38, -0.426, -0.437, -0.457, -0.477, -0.476, -0.464, -0.42, -0.39, -0.341, -0.282, -0.224, -0.139, -0.082, -0.025, 0.084, 0.144, 0.242, 0.293],
                                          repsTaught: 10, quality: 6, exact: true, learnedAt: Date(timeIntervalSince1970: 0)),
                 profileSource: .recorded),
        Exercise(name: "Squat", isCustom: false,
                 profile: ExerciseProfile(detector: .velocity, threshold: 0.4602, amplitude: 4.508,
                                          period: 2.119, minGap: 0.53,
                                          template: [-0.521, -0.426, -0.314, -0.221, -0.121, 0.01, 0.115, 0.217, 0.31, 0.406, 0.484, 0.558, 0.644, 0.703, 0.767, 0.818, 0.855, 0.884, 0.9, 0.899, 0.914, 0.888, 0.837, 0.779, 0.701, 0.591, 0.497, 0.388, 0.235, 0.093, -0.054, -0.203, -0.377, -0.501, -0.614, -0.719, -0.782, -0.823, -0.86, -0.88, -0.87, -0.834, -0.783, -0.707, -0.64, -0.546, -0.467, -0.384, -0.281, -0.182],
                                          repsTaught: 10, quality: 16, exact: true, learnedAt: Date(timeIntervalSince1970: 0)),
                 profileSource: .recorded),
        Exercise(name: "Knee raise", isCustom: false,
                 profile: ExerciseProfile(detector: .velocity, threshold: 0.7587, amplitude: 3.196,
                                          period: 2.27, minGap: 0.568,
                                          template: [0.179, 0.227, 0.262, 0.329, 0.376, 0.423, 0.455, 0.499, 0.525, 0.589, 0.618, 0.641, 0.673, 0.723, 0.791, 0.836, 0.868, 0.91, 0.953, 0.968, 0.956, 0.898, 0.809, 0.679, 0.553, 0.352, 0.191, -0.041, -0.262, -0.432, -0.617, -0.738, -0.823, -0.836, -0.81, -0.763, -0.725, -0.671, -0.598, -0.539, -0.473, -0.409, -0.349, -0.279, -0.24, -0.182, -0.131, -0.093, -0.038, 0.009],
                                          repsTaught: 10, quality: 10, exact: true, learnedAt: Date(timeIntervalSince1970: 0)),
                 profileSource: .recorded),
    ]
}
