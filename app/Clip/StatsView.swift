import SwiftUI
import Charts

extension HistoryStore {
    func lastWeight(for exercise: String) -> Double? {
        sets.first { $0.exercise == exercise }?.weightKg
    }

    var exercises: [String] {
        Array(Set(sets.map(\.exercise))).sorted()r
    }ci

    func sets(for exese: String) -> [LoggedSet] {
        sets.filter { $0.exercise == exercise }
    }

    func sets(since date: Date) -> [LoggedSet] {
        sets.filter { $0.date >= date }
    }

    var streakDays: Int {
        let cal = Calendar.current
        let days = Set(sets.map { cal.startOfDay(for: $0.date) })
        var day = cal.startOfDay(for: Date())
        if !days.contains(day), let yesterday = cal.date(byAdding: .day, value: -1, to: day) {
            day = yesterday
        }
        var count = 0
        while days.contains(day) {
            count += 1
            guard let previous = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }
}

struct DayTotal: Identifiable {
    let day: Date
    let value: Double
    var id: Date { day }
}

struct ExerciseStats: Identifiable {
    let exercise: String
    let sets: [LoggedSet]
    var id: String { exercise }

    var totalReps: Int { sets.reduce(0) { $0 + $1.reps } }
    var bestWeight: Double { sets.map(\.weightKg).max() ?? 0 }
    var volume: Double { sets.reduce(0) { $0 + $1.volume } }
    var lastDate: Date? { sets.map(\.date).max() }
    var estimatedMax: Double {
        sets.map { $0.weightKg * (1 + Double($0.reps) / 30) }.max() ?? 0
    }

    var heaviestPerDay: [DayTotal] {
        let groups = Dictionary(grouping: sets) { Calendar.current.startOfDay(for: $0.date) }
        return groups.map { DayTotal(day: $0.key, value: $0.value.map(\.weightKg).max() ?? 0) }
            .sorted { $0.day < $1.day }
    }
}

struct StatsView: View {
    @EnvironmentObject var history: HistoryStore

    private var weekStart: Date {
        Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
    }

    private var thisWeek: [LoggedSet] { history.sets(since: weekStart) }

    private var stats: [ExerciseStats] {
        history.exercises
            .map { ExerciseStats(exercise: $0, sets: history.sets(for: $0)) }
            .sorted { ($0.lastDate ?? .distantPast) > ($1.lastDate ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        StatTile(title: "Sets this week", value: "\(thisWeek.count)", symbol: "square.stack.3d.up")
                        StatTile(title: "Reps this week", value: "\(thisWeek.reduce(0) { $0 + $1.reps })", symbol: "repeat")
                        StatTile(title: "Volume this week", value: "\(Int(thisWeek.reduce(0) { $0 + $1.volume })) kg", symbol: "scalemass")
                        StatTile(title: "Day streak", value: "\(history.streakDays)", symbol: "flame")
                    }

                    WeekChart(sets: thisWeek, weekStart: weekStart)

                    if stats.isEmpty {
                        ContentUnavailableView("No stats yet", systemImage: "chart.bar",
                                               description: Text("Finish a set and your numbers show up here."))
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Exercises").font(.headline)
                            ForEach(stats) { s in
                                ExerciseRow(stats: s)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Stats")
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.green)
            Text(value)
                .font(.title2.bold())
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct WeekChart: View {
    let sets: [LoggedSet]
    let weekStart: Date

    private var days: [DayTotal] {
        (0..<7).compactMap { i in
            guard let d = Calendar.current.date(byAdding: .day, value: i, to: weekStart) else { return nil }
            let reps = sets
                .filter { Calendar.current.isDate($0.date, inSameDayAs: d) }
                .reduce(0) { $0 + $1.reps }
            return DayTotal(day: d, value: Double(reps))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reps per day").font(.headline)
            Chart(days) { item in
                BarMark(x: .value("Day", item.day, unit: .day),
                        y: .value("Reps", item.value))
                    .foregroundStyle(Calendar.current.isDateInToday(item.day) ? Color.green : Color.gray.opacity(0.6))
                    .cornerRadius(4)t
            }
            .chartXAxis {
                AxisMarks(values: .x                 AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            }
            .frame(height: 160)
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ExerciseRow: View {
    let stats: ExerciseStats

    var body: some View {
        NavigationLink {
            ExerciseDetailView(stats: stats)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(stats.exercise).font(.headline)
                    Text("\(stats.sets.count) sets · \(stats.totalReps) reps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(stats.bestWeight, specifier: "%.1f") kg")
                        .font(.subheadline.bold())
                        .monospacedDigit()
                    Text("best")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

struct ExerciseDetailView: View {
    let stats: ExerciseStats

    var body: some View {
        List {
            Section {
                LabeledContent("Total sets", value: "\(stats.sets.count)")
                LabeledContent("Total reps", value: "\(stats.totalReps)")
                LabeledContent("Best weight", value: String(format: "%.1f kg", stats.bestWeight))
                LabeledContent("Estimated 1-rep max", value: String(format: "%.1f kg", stats.estimatedMax))
                LabeledContent("Total volume", value: "\(Int(stats.volume)) kg")
            }

            if stats.heaviestPerDay.count > 1 {
                Section("Heaviest set per day") {
                    Chart(stats.heaviestPerDay) { p in
                        LineMark(x: .value("Day", p.day, unit: .day),
                                 y: .value("kg", p.value))
                        PointMark(x: .value("Day", p.day, unit: .day),
                                  y: .value("kg", p.value))
                    }
                    .foregroundStyle(.green)
                    .frame(height: 180)
                }
            }

            Section("All sets") {
                ForEach(stats.sets) { s in
                    HStack {
                        Text(s.date, format: .dateTime.month().day().hour().minute())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(s.reps) × \(s.weightKg, specifier: "%.1f") kg")
                            .monospacedDigit()
                    }
                }
            }
        }
        .navigationTitle(stats.exercise)
    }
}
