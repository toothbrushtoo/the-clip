import SwiftUI

struct WorkoutsView: View {
    @EnvironmentObject var store: WorkoutStore
    @EnvironmentObject var exercises: ExerciseStore
    @State private var editing: Workout?
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.workouts) { workout in
                    NavigationLink {
                        WorkoutRunView(workout: workout)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(workout.name).font(.headline)
                            Text(workout.exercises.map { "\($0.name) \($0.sets)×\($0.reps)" }.joined(separator: " · "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { store.remove(workout) } label: { Label("Delete", systemImage: "trash") }
                        Button { editing = workout } label: { Label("Edit", systemImage: "pencil") }
                            .tint(.blue)
                    }
                    .contextMenu {
                        Button { editing = workout } label: { Label("Edit", systemImage: "pencil") }
                        Button(role: .destructive) { store.remove(workout) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .overlay {
                if store.workouts.isEmpty {
                    ContentUnavailableView("No workouts yet", systemImage: "dumbbell",
                                           description: Text("Tap + to build one from the exercise library, or teach the clip a new exercise."))
                }
            }
            .navigationTitle("Workouts")
            .toolbar {
                Button { creating = true } label: { Image(systemName: "plus") }
            }
            .sheet(isPresented: $creating) {
                WorkoutEditorView(workout: Workout(name: "", exercises: []), isNew: true)
            }
            .sheet(item: $editing) { workout in
                WorkoutEditorView(workout: workout, isNew: false)
            }
        }
    }
}

// Build or change a workout: a name, and a list of exercises each with weight, sets and reps.
struct WorkoutEditorView: View {
    @State var workout: Workout
    let isNew: Bool

    @EnvironmentObject var store: WorkoutStore
    @EnvironmentObject var exercises: ExerciseStore
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var teaching = false
    @State private var editingLine: WorkoutExercise?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Workout name", text: $workout.name)
                }

                Section("Exercises") {
                    ForEach(workout.exercises) { line in
                        Button {
                            editingLine = line
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.name)
                                        .foregroundStyle(.primary)
                                    Text(exercises.exercise(named: line.name)?.statusText ?? "Not learned yet")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(line.summary)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .onDelete { workout.exercises.remove(atOffsets: $0) }
                    .onMove { workout.exercises.move(fromOffsets: $0, toOffset: $1) }

                    Button { picking = true } label: {
                        Label("Add exercise", systemImage: "plus.circle.fill")
                    }
                    Button { teaching = true } label: {
                        Label("Teach a new exercise", systemImage: "graduationcap.fill")
                    }
                }

                if workout.exercises.isEmpty {
                    Section {
                        Text("Add exercises from the library, or teach the clip one of your own by doing \(TeachExerciseView.targetReps) reps.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(isNew ? "New workout" : "Edit workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if isNew { store.add(workout) } else { store.update(workout) }
                        dismiss()
                    }
                    .disabled(workout.name.trimmingCharacters(in: .whitespaces).isEmpty || workout.exercises.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) { EditButton() }
            }
            .sheet(isPresented: $picking) {
                ExercisePickerView { exercise in
                    workout.exercises.append(WorkoutExercise(name: exercise.name))
                }
            }
            .sheet(isPresented: $teaching) {
                TeachExerciseView { exercise in
                    workout.exercises.append(WorkoutExercise(name: exercise.name))
                }
                .presentationBackground(.clear)
                .interactiveDismissDisabled()
            }
            .sheet(item: $editingLine) { line in
                ExerciseLineEditor(line: line) { updated in
                    if let i = workout.exercises.firstIndex(where: { $0.id == updated.id }) {
                        workout.exercises[i] = updated
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }
}

// Weight, sets and reps for one exercise in a workout.
struct ExerciseLineEditor: View {
    @State var line: WorkoutExercise
    let onDone: (WorkoutExercise) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("weightStep") private var weightStep = 2.5

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $line.weightKg, in: 0...300, step: weightStep) {
                        LabeledContent("Weight", value: String(format: "%.1f kg", line.weightKg))
                    }
                    Stepper(value: $line.sets, in: 1...12) {
                        LabeledContent("Sets", value: "\(line.sets)")
                    }
                    Stepper(value: $line.reps, in: 1...60) {
                        LabeledContent("Reps per set", value: "\(line.reps)")
                    }
                }
            }
            .navigationTitle(line.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(line)
                        dismiss()
                    }
                }
            }
        }
    }
}

// The exercise library: built-in ones and the ones you've taught.
struct ExercisePickerView: View {
    let onPick: (Exercise) -> Void

    @EnvironmentObject var exercises: ExerciseStore
    @Environment(\.dismiss) private var dismiss
    @State private var teaching = false
    @State private var search = ""

    private var filtered: [Exercise] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = exercises.exercises.sorted { a, b in
            if a.isCustom != b.isCustom { return a.isCustom }
            return a.name.lowercased() < b.name.lowercased()
        }
        return q.isEmpty ? list : list.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        teaching = true
                    } label: {
                        Label("Teach a new exercise", systemImage: "graduationcap.fill")
                    }
                }
                Section("Library") {
                    ForEach(filtered) { exercise in
                        Button {
                            onPick(exercise)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(exercise.name).foregroundStyle(.primary)
                                    Text(exercise.statusText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if exercise.profile != nil {
                                    Image(systemName: exercise.profileSource == .taught ? "brain.head.profile" : "waveform.path.ecg")
                                        .foregroundStyle(exercise.profileSource == .taught ? .green : .secondary)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if exercise.isCustom {
                                Button(role: .destructive) { exercises.remove(exercise) } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search exercises")
            .navigationTitle("Add exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(isPresented: $teaching) {
                TeachExerciseView { exercise in
                    onPick(exercise)
                    dismiss()
                }
                .presentationBackground(.clear)
                .interactiveDismissDisabled()
            }
        }
    }
}
