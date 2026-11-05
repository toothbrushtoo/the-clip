import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var store: WorkoutStore
    @ObservedObject private var ble = ClipBLE.shared
    @AppStorage("restSeconds") private var restSeconds = 90
    @AppStorage("weightStep") private var weightStep = 2.5
    @AppStorage("defaultWeight") private var defaultWeight = 10.0
    @AppStorage("haptics") private var haptics = true
    @State private var confirmClear = false
    @State private var showingFind = false

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Rest timer") {
                    Picker("Rest between sets", selection: $restSeconds) {
                        Text("60 s").tag(60)
                        Text("90 s").tag(90)
                        Text("2 min").tag(120)
                        Text("3 min").tag(180)
                    }
                }

                Section("Weights") {
                    Picker("Weight step", selection: $weightStep) {
                        Text("1 kg").tag(1.0)
                        Text("2.5 kg").tag(2.5)
                        Text("5 kg").tag(5.0)
                    }
                    Stepper(value: $defaultWeight, in: 0...200, step: weightStep) {
                        Text("Starting weight: \(defaultWeight, specifier: "%.1f") kg")
                    }
                }

                Section("Feedback") {
                    Toggle("Vibrate on each rep", isOn: $haptics)
                }

                Section("Clip") {
                    LabeledContent("Status", value: ble.state.rawValue.capitalized)
                    if let b = ble.battery {
                        LabeledContent("Battery", value: "\(b)%")
                    }
                    if let r = ble.rssi {
                        LabeledContent("Signal", value: "\(r) dBm")
                    }
                    Button("Find my clip") { showingFind = true }
                }

                Section("Data") {
                    LabeledContent("Workouts saved", value: "\(store.workouts.count)")
                    LabeledContent("Sets logged", value: "\(history.sets.count)")
                    Button("Clear all history", role: .destructive) { confirmClear = true }
                        .disabled(history.sets.isEmpty)
                }

                Section("About") {
                    LabeledContent("App", value: "The Clip")
                    LabeledContent("Version", value: version)
                    Link("Project on GitHub", destination: URL(string: "https://github.com/toothbrushtoo/the-clip")!)
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Delete every logged set?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete all history", role: .destructive) { history.clear() }
            }
            .fullScreenCover(isPresented: $showingFind) { FindClipView() }
        }
    }
}
