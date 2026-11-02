import SwiftUI

struct WorkoutsView: View {
    @EnvironmentObject var store: WorkoutStore
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.workouts) { workout in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(workout.name).font(.headline)
                        Text(workout.exercises.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                    .onDelete(perform: store.remove)
            }
                .overlay {
                if store.workouts.isEmpty {
                    ContentUnavailableView("No workouts yet", systemImage: "dumbbell",
                        description: Text("Tap + to add one."))
                }
            }
                .navigationTitle("Workouts")
                .toolbar {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
            }
                .sheet(isPresented: $showingAdd) { AddWorkoutView() }
        }
    }
}

struct AddWorkoutView: View {
    @EnvironmentObject var store: WorkoutStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var exercises: [String] = []
    @State private var newExercise = ""

    private let suggestions = ["Curl", "Hammer curl", "Shoulder press", "Lateral raise",
        "Bent row", "Shrug", "Tricep kickback", "Overhead tricep",
        "Goblet squat", "Lunge", "Pull-up", "Push-up", "Squat", "Knee raise"]

    var body: some View {
        NavigationStack {
            Form {
                TextField("Workout name", text: $name)
                Section("Exercises") {
                    ForEach(exercises, id: \.self) { Text($0) }
                        .onDelete { exercises.remove(atOffsets: $0) }
                    HStack {
                        TextField("Add exercise", text: $newExercise)
                        Button("Add") { add(newExercise) }.disabled(newExercise.isEmpty)
                    }
                }
                Section("Quick add") {
                    ForEach(suggestions, id: \.self) { name in
                        Button(name) { add(name) }
                    }
                }
            }
                .navigationTitle("New workout")
                .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.add(Workout(name: name, exercises: exercises))
                        dismiss()
                    }
                        .disabled(name.isEmpty || exercises.isEmpty)
                }
            }
        }
    }

    private func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        exercises.append(trimmed)
        newExercise = ""
    }
}
