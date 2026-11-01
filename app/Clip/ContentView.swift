import SwiftUI

struct ContentView: View {
    @StateObject private var session = ClipSession()

    var body: some View {
        VStack(spacing: 32) {
            Text(session.connected ? "Clip connected (fake)" : "Not connected")
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
                        Text("\(set.reps) reps")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(formatDuration(set.seconds))
                            .foregroundStyle(.secondary)
                        Text(set.date, style: .time)
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain)
                Button("Clear history", role: .destructive) {
                    session.clearHistory()
                }
                .buttonStyle(.bordered)
            } else {
                Spacer()
            }

            if !session.connected {
                Button("Connect") { session.connectFake() }
                    .buttonStyle(.borderedProminent)
            } else if session.inSet {
                Button("End set") { session.endSet() }
                    .buttonStyle(.bordered)
            } else {
                Button("Start set") { session.startSet() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
