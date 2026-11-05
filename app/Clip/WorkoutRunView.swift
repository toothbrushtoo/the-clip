import SwiftUI
import Combine
import UIKit

struct LoggedSet: Identifiable, Codable {
    var id = UUID()
    var exercise: String
    var reps: Int
    var weightKg: Double
    var seconds: Double
    var date: Date

    var volume: Double { Double(reps) * weightKg }
}

final class HistoryStore: ObservableObject {
    @Published var sets: [LoggedSet] = [] { didSet { save() } }
    private let key = "history"

    init() { load() }

    func log(_ set: LoggedSet) { sets.insert(set, at: 0) }
    func clear() { sets.removeAll() }

    func todaysSets(for exercise: String) -> [LoggedSet] {
        sets.filter { $0.exercise == exercise && Calendar.current.isDateInToday($0.date) }
    }

    var days: [(day: Date, sets: [LoggedSet])] {
        let groups = Dictionary(grouping: sets) { Calendar.current.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { (day: $0, sets: groups[$0] ?? []) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sets) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([LoggedSet].self, from: data) {
            sets = saved
        }
    }
}

struct WorkoutRunView: View {
    let workout: Workout
    @EnvironmentObject var history: HistoryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = ClipSession()
    @State private var index = 0
    @State private var weight: Double = 10
    @State private var restLeft = 0
    @AppStorage("restSeconds") private var restLength = 90
    @AppStorage("weightStep") private var weightStep = 2.5
    @AppStorage("defaultWeight") private var defaultWeight = 10.0
    @AppStorage("haptics") private var haptics = true
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var exercise: String {
        workout.exercises.isEmpty ? "-" : workout.exercises[index]
    }
    private var isLast: Bool { index >= workout.exercises.count - 1 }

    var body: some View {
        VStack(spacing: 20) {
            Picker("Source", selection: $session.source) {
                Text("Fake").tag(ClipSession.Source.fake)
                Text("Phone").tag(ClipSession.Source.phone)
                Text("Clip").tag(ClipSession.Source.clip)
            }
            .pickerStyle(.segmented)
            .disabled(session.inSet)

            if session.source == .clip { ClipStatusView() }

            VStack(spacing: 4) {
                Text("Exercise \(index + 1) of \(workout.exercises.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(exercise).font(.largeTitle.bold())
            }

            Stepper(value: $weight, in: 0...300, step: weightStep) {
                Text("Weight: \(weight, specifier: "%.1f") kg")
            }
            .disabled(session.inSet)

            if restLeft > 0 {
                VStack(spacing: 8) {
                    Text("Rest").font(.headline).foregroundStyle(.secondary)
                    Text(timeString(restLeft))
                        .font(.system(size: 96, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Button("Skip rest") { restLeft = 0 }
                        .buttonStyle(.bordered)
                }
            } else {
                Text("\(session.reps)")
                    .font(.system(size: 140, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text("reps").font(.title3).foregroundStyle(.secondary)
                if session.tempo > 0 {
                    Text(String(format: "%.1f s per rep", session.tempo))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            let done = history.todaysSets(for: exercise)
            if !done.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(done.reversed()) { s in
                            VStack {
                                Text("\(s.reps)").font(.headline)
                                Text("\(s.weightKg, specifier: "%.1f") kg")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }

            Spacer()
            controls
        }
        .padding()
        .navigationTitle(workout.name)
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(tick) { _ in
            if restLeft > 0 { restLeft -= 1 }
        }
        .onAppear { loadWeight() }
        .onChange(of: index) { loadWeight() }
        .onChange(of: session.reps) {
            if haptics && session.reps > 0 {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }

    @ViewBuilder private var controls: some View {
        if !session.connected {
            Button("Connect") { session.connect() }
                .buttonStyle(.borderedProminent)
        } else if session.inSet {
            Button("End set") { finishSet() }
                .buttonStyle(.bordered)
        } else {
            HStack {
                Button("Start set") {
                    restLeft = 0
                    session.startSet()
                }
                .buttonStyle(.borderedProminent)
                if isLast {
                    Button("Finish") { dismiss() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Next exercise") {
                        index += 1
                        restLeft = 0
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func finishSet() {
        session.endSet()
        guard session.reps > 0, let s = session.sets.first else { return }
        history.log(LoggedSet(exercise: exercise, reps: s.reps, weightKg: weight,
                              seconds: s.seconds, date: s.date))
        restLeft = restLength
    }

    private func loadWeight() {
        weight = history.lastWeight(for: exercise) ?? defaultWeight
    }

    private func timeString(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct HistoryView: View {
    @EnvironmentObject var history: HistoryStore

    var body: some View {
        NavigationStack {
            List {
                ForEach(history.days, id: \.day) { group in
                    Section {
                        ForEach(group.sets) { s in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(s.exercise).font(.headline)
                                    Text(s.date, style: .time)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(s.reps) × \(s.weightKg, specifier: "%.1f") kg")
                                    .monospacedDigit()
                            }
                        }
                    } header: {
                        HStack {
                            Text(group.day, style: .date)
                            Spacer()
                            Text("\(Int(group.sets.reduce(0) { $0 + $1.volume })) kg total")
                        }
                    }
                }
            }
            .overlay {
                if history.sets.isEmpty {
                    ContentUnavailableView("No sets yet", systemImage: "clock",
                                           description: Text("Run a workout and your sets show up here."))
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !history.sets.isEmpty {
                    Button("Clear", role: .destructive) { history.clear() }
                }
            }
        }
    }
}
