import SwiftUI
import Combine

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
