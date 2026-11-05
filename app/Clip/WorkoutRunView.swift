import SwiftUI
import Combine
import UIKit

// Runs a workout: exercise by exercise, set by set. Reps come from the session (clip or phone)
// using the exercise's learned profile; when the target is reached the set ends by itself with a
// ding, the rest timer runs, and after the last set the next exercise comes up.
struct WorkoutRunView: View {
    let workout: Workout

    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var exercises: ExerciseStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = ClipSession()

    @State private var exerciseIndex = 0
    @State private var setIndex = 0
    @State private var weight: Double = 10
    @State private var restLeft = 0
    @State private var finished = false
    @State private var teaching = false
    @State private var banner: String?
    @State private var setsDone: [Int] = []   // reps logged per completed set of the current exercise

    @AppStorage("restSeconds") private var restLength = 90
    @AppStorage("weightStep") private var weightStep = 2.5
    @AppStorage("haptics") private var haptics = true

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var line: WorkoutExercise? {
        workout.exercises.indices.contains(exerciseIndex) ? workout.exercises[exerciseIndex] : nil
    }
    private var exerciseName: String { line?.name ?? "-" }
    private var targetReps: Int { line?.reps ?? 10 }
    private var targetSets: Int { line?.sets ?? 3 }
    private var isLastExercise: Bool { exerciseIndex >= workout.exercises.count - 1 }
    private var exercise: Exercise? { exercises.exercise(named: exerciseName) }

    var body: some View {
        Group {
            if finished {
                finishedView
            } else {
                runningView
            }
        }
        .navigationTitle(workout.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadExercise() }
        .onChange(of: exerciseIndex) { loadExercise() }
        .onChange(of: session.reps) { _, r in
            guard session.inSet, r > 0 else { return }
            if haptics { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            if r >= targetReps { completeSet() }
        }
        .onReceive(tick) { _ in
            if restLeft > 0 {
                restLeft -= 1
                if restLeft == 0 { banner = nil }
            }
        }
        .onDisappear {
            if session.inSet { session.endSet(record: false) }
        }
        .sheet(isPresented: $teaching) {
            TeachExerciseView(initialName: exerciseName)
                .presentationBackground(.clear)
                .interactiveDismissDisabled()
        }
    }

    // MARK: running

    private var runningView: some View {
        VStack(spacing: 16) {
            Picker("Source", selection: $session.source) {
                Text("Fake").tag(ClipSession.Source.fake)
                Text("Phone").tag(ClipSession.Source.phone)
                Text("Clip").tag(ClipSession.Source.clip)
            }
            .pickerStyle(.segmented)
            .disabled(session.inSet)

            if session.source == .clip { ClipStatusView() }

            VStack(spacing: 4) {
                Text("Exercise \(exerciseIndex + 1) of \(workout.exercises.count) · Set \(min(setIndex + 1, targetSets)) of \(targetSets)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(exerciseName)
                    .font(.largeTitle.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                learnedBadge
            }

            Stepper(value: $weight, in: 0...300, step: weightStep) {
                Text("Weight: \(weight, specifier: "%.1f") kg")
            }
            .disabled(session.inSet)

            if restLeft > 0 {
                VStack(spacing: 8) {
                    Text(banner ?? "Rest").font(.headline).foregroundStyle(.secondary)
                    Text(timeString(restLeft))
                        .font(.system(size: 88, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Button("Skip rest") { restLeft = 0; banner = nil }
                        .buttonStyle(.bordered)
                }
            } else {
                ZStack {
                    ProgressRing(progress: Double(session.reps) / Double(max(1, targetReps)),
                                 color: session.reps >= targetReps ? .green : .blue)
                        .frame(width: 220, height: 220)
                    VStack(spacing: 0) {
                        Text("\(session.reps)")
                            .font(.system(size: 84, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("of \(targetReps)")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: session.reps)
                if let banner, !session.inSet {
                    Text(banner).font(.headline).foregroundStyle(.green)
                } else if session.inSet, let c = session.counter {
                    Text(counterText(c))
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                } else if session.tempo > 0 {
                    Text(String(format: "%.1f s per rep", session.tempo))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if !setsDone.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(setsDone.enumerated()), id: \.offset) { _, reps in
                        Text("\(reps)")
                            .font(.headline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.quaternary, in: Capsule())
                    }
                    Text("done")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
            controls
        }
        .padding()
    }

    @ViewBuilder private var learnedBadge: some View {
        if let p = exercise?.profile {
            Label(exercise?.profileSource == .taught ? "Learned · \(p.qualityLabel)" : "Estimated · teach it for best results",
                  systemImage: exercise?.profileSource == .taught ? "brain.head.profile" : "waveform.path.ecg")
                .font(.caption)
                .foregroundStyle(exercise?.profileSource == .taught ? .green : .secondary)
        } else {
            Button {
                teaching = true
            } label: {
                Label("Not learned yet · teach it", systemImage: "graduationcap")
                    .font(.caption)
            }
            .disabled(session.inSet)
        }
    }

    @ViewBuilder private var controls: some View {
        if !session.connected {
            Button("Connect") {
                if session.source == .clip { ConnectionSheet.shared.present() }
                session.connect()
            }
            .buttonStyle(.borderedProminent)
        } else if session.inSet {
            Button("End set") { completeSet() }
                .buttonStyle(.bordered)
        } else {
            HStack {
                Button(setIndex == 0 ? "Start set" : "Start set \(setIndex + 1)") {
                    restLeft = 0
                    banner = nil
                    startSet()
                }
                .buttonStyle(.borderedProminent)
                if isLastExercise {
                    Button("Finish") { finishWorkout() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Next exercise") { nextExercise() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var finishedView: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
            Text("Workout complete")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("\(workout.exercises.count) exercises · \(workout.totalSets) sets planned")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding()
    }

    // MARK: flow

    private func loadExercise() {
        setIndex = 0
        setsDone = []
        weight = history.lastWeight(for: exerciseName) ?? line?.weightKg ?? 10
    }

    private func startSet() {
        session.profile = exercises.profile(for: exerciseName)
        session.startSet()
    }

    private func completeSet() {
        guard session.inSet else { return }
        session.endSet()
        let reps = session.reps
        if reps > 0, let s = session.sets.first {
            history.log(LoggedSet(exercise: exerciseName, reps: s.reps, weightKg: weight,
                                  seconds: s.seconds, date: s.date))
            setsDone.append(reps)
        }
        setIndex += 1
        if setIndex >= targetSets {
            if isLastExercise {
                Ding.play(.workout)
                finishWorkout()
            } else {
                Ding.play(.exercise)
                banner = "\(exerciseName) done · next: \(workout.exercises[exerciseIndex + 1].name)"
                restLeft = restLength
                exerciseIndex += 1
            }
        } else {
            Ding.play(.set)
            banner = "Set \(setIndex) done"
            restLeft = restLength
        }
    }

    private func nextExercise() {
        restLeft = 0
        banner = nil
        exerciseIndex += 1
    }

    private func finishWorkout() {
        if session.inSet { session.endSet(record: false) }
        finished = true
    }

    private func counterText(_ c: ClipSession.Counter) -> String {
        if let d = session.detector, c != .fake, c != .clipOnboard {
            let name: String
            switch d {
            case .rotation: name = "rotation"
            case .motion: name = "motion"
            case .velocity: name = "speed"
            }
            return "\(c.rawValue) · counting \(name)"
        }
        return c.rawValue
    }

    private func timeString(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }
}
