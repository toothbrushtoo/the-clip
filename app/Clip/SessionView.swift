import SwiftUI

struct SessionView: View {
    @StateObject private var session = ClipSession()
    @EnvironmentObject var history: HistoryStore

    var body: some View {
        VStack(spacing: 24) {
            Picker("Source", selection: $session.source) {
                Text("Fake clip").tag(ClipSession.Source.fake)
                Text("Phone motion").tag(ClipSession.Source.phone)
                Text("Clip").tag(ClipSession.Source.clip)
            }
                .pickerStyle(.segmented)
                .disabled(session.inSet)

            if session.source == .clip { ClipStatusView() }

            Text(session.connected ? "Connected (\(session.source.rawValue))" : "Not connected")
                .foregroundStyle(.secondary)
            Text("\(session.reps)")
                .font(.system(size: 160, weight: .bold, design: .rounded))
                .monospacedDigit()

                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text("reps")
                .font(.title2)
                .foregroundStyle(.secondary)

            if !session.sets.isEmpty {
                List(session.sets) { set in
                    HStack {
                        Text("\(set.reps) reps").fontWeight(.semibold)
                        Spacer()
                        Text(formatDuration(set.seconds)).foregroundStyle(.secondary)
                        Text(set.date, style: .time).foregroundStyle(.secondary)
                    }
                }
                    .listStyle(.plain)
                Button("Clear history", role: .destructive) { session.clearHistory() }
                    .buttonStyle(.bordered)
            } else {
                Spacer()
            }

            if !session.connected {
                Button("Connect") {
                    if session.source == .clip { ConnectionSheet.shared.present() }
                    session.connect()
                }
                    .buttonStyle(.borderedProminent)
            } else if session.inSet {
                Button("End set") { endQuickSet() }
                    .buttonStyle(.bordered)
            } else {
                Button("Start set") { session.startSet() }
                    .buttonStyle(.borderedProminent)
            }
        }
            .padding()
    }

    private func endQuickSet() {
        let before = session.sets.count
        session.endSet()
        guard session.sets.count > before, let s = session.sets.first else { return }
        history.log(LoggedSet(exercise: "Quick set", reps: s.reps, weightKg: 0,
                              seconds: s.seconds, date: s.date))
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
