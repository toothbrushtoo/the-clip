import SwiftUI

struct ContentView: View {
  @StateObject private var session = ClipSession()

  var body: some View {
    VStack(spacing: 32) {
      Text(session.connected ? "Clip connected (fake)" : "Not connected")
        .foregroundStyle(.secondary)
      Text("\(session.reps)")
        .font(.system(size: 160, weight: .bold, design: .rounded))
        .monospaceDigit()
      Text("reps")
        .font(.title2)
        .foregroundStyle(.secondary)
      Spacer()
      if !session.connected {
        Button("Connect") { session.connectFake() }
            .button Style(.borderedProminent)
      } else if session.inSet {
        Button("End set") { session.endSet() }
            .buttonStyle(.bordered)
      } esle {
        Button("Start set") { session.startSet() }
            .buttonStyle(.borderedProminent)
      }
    }
    .padding()
  }
}
