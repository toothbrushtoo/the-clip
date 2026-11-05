import SwiftUI
import UIKit

// Teach the app a new exercise: name it, do a set of reps with the clip (or the phone), and the
// learner works out which signal and threshold count that exercise exactly. The result is an
// ExerciseProfile that the engine uses whenever this exercise comes up in a workout.
struct TeachExerciseView: View {
    var initialName: String = ""
    var onSaved: ((Exercise) -> Void)?

    @EnvironmentObject private var store: ExerciseStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var session = ClipSession()
    @ObservedObject private var ble = ClipBLE.shared

    private enum Phase { case name, ready, recording, confirm, learning, done, failed }

    static let targetReps = 20

    @State private var phase: Phase = .name
    @State private var name = ""
    @State private var actualReps = TeachExerciseView.targetReps
    @State private var samples: [MotionSample] = []
    @State private var profile: ExerciseProfile?
    @State private var led: XiaoBoard.LED = .off
    @State private var flashTask: Task<Void, Never>?
    @State private var shakes: CGFloat = 0
    @State private var reachedTarget = false
    @State private var suggestedReps: Int?
    @State private var recordingURL: URL?
    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()

            card
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
        .onAppear {
            name = initialName
            if !initialName.isEmpty { phase = .ready }
        }
        .onDisappear {
            flashTask?.cancel()
            if session.inSet { _ = session.finishTeaching() }
        }
        .onChange(of: session.reps) { _, r in
            guard phase == .recording, r > 0 else { return }
            flashGreen()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if r >= Self.targetReps && !reachedTarget {
                reachedTarget = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        }
        .modifier(Shake(animatableData: shakes))
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.82), value: phase)
    }

    private var header: some View {
        ZStack {
            Text(title)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 36)
            HStack {
                Spacer()
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
        }
    }

    private var title: String {
        switch phase {
        case .name: return "New exercise"
        case .ready, .recording, .confirm, .learning: return name.isEmpty ? "Teach" : name
        case .done: return "Learned"
        case .failed: return "Try again"
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .name: namePhase
        case .ready: readyPhase
        case .recording: recordingPhase
        case .confirm: confirmPhase
        case .learning: learningPhase
        case .done: donePhase
        case .failed: failedPhase
        }
    }

    // MARK: phases

    private var namePhase: some View {
        VStack(spacing: 18) {
            Text("What's the exercise called?")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            TextField("Exercise name", text: $name)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.next)
                .focused($nameFocused)
                .onSubmit { if canContinue { phase = .ready } }
                .padding(14)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if let existing = store.exercise(named: name), existing.profile != nil {
                Text("Teaching \(existing.name) again replaces what the app knows about it.")
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            PillButton(title: "Next") { phase = .ready }
                .opacity(canContinue ? 1 : 0.4)
                .disabled(!canContinue)
        }
        .padding(.top, 8)
        .onAppear { nameFocused = true }
    }

    private var canContinue: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var readyPhase: some View {
        VStack(spacing: 16) {
            XiaoBoard(led: .off)
                .frame(width: 150, height: 128)
                .padding(.vertical, 18)

            Picker("Source", selection: $session.source) {
                Text("Clip").tag(ClipSession.Source.clip)
                Text("Phone").tag(ClipSession.Source.phone)
            }
            .pickerStyle(.segmented)

            Text(readyHint)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(minHeight: 40)

            if session.source == .clip {
                ClipStatusView()
            }

            if session.connected {
                PillButton(title: "Start") { beginRecording() }
            } else {
                PillButton(title: session.source == .clip ? "Connect clip" : "Use phone") { session.connect() }
                    .opacity(session.source == .clip && (ble.state == .scanning || ble.state == .connecting) ? 0.5 : 1)
            }
        }
        .onAppear {
            if session.source == .fake { session.source = .clip }
        }
    }

    private var readyHint: String {
        if session.source == .phone {
            return "Hold the phone like it's the clip, then do \(Self.targetReps) reps at your normal pace."
        }
        return "Clip it on, get in position, then do \(Self.targetReps) reps at your normal pace."
    }

    private var recordingPhase: some View {
        VStack(spacing: 14) {
            ZStack {
                ProgressRing(progress: min(1, Double(session.reps) / Double(Self.targetReps)),
                             color: reachedTarget ? .green : .blue)
                    .frame(width: 200, height: 200)
                VStack(spacing: 2) {
                    Text("\(session.reps)")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("of \(Self.targetReps)")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                XiaoBoard(led: led)
                    .frame(width: 150, height: 128)
                    .scaleEffect(0.42)
                    .offset(y: 118)
            }
            .padding(.top, 8)

            Text(reachedTarget ? "That's \(Self.targetReps). Tap Done when you stop." : "Do \(Self.targetReps) reps, then tap Done")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 30)

            PillButton(title: "Done") { stopRecording() }
                .opacity(session.reps >= 3 ? 1 : 0.4)
                .disabled(session.reps < 3)
        }
        .animation(.easeInOut(duration: 0.3), value: session.reps)
    }

    private var confirmPhase: some View {
        VStack(spacing: 18) {
            Text("How many reps did you actually do?")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            HStack(spacing: 28) {
                stepButton("minus") { actualReps = max(3, actualReps - 1) }
                Text("\(actualReps)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 90)
                    .contentTransition(.numericText())
                stepButton("plus") { actualReps = min(60, actualReps + 1) }
            }
            .animation(.easeInOut(duration: 0.15), value: actualReps)
            Text("The app counted \(session.reps). Your own count is what it learns from.")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            PillButton(title: "Learn it") { learn() }
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .bold))
                .frame(width: 48, height: 48)
                .background(.quaternary, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var learningPhase: some View {
        VStack(spacing: 18) {
            XiaoBoard(led: .blue)
                .frame(width: 150, height: 128)
                .padding(.vertical, 18)
            ProgressView()
            Text("Learning your \(name.lowercased())…")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
            Color.clear.frame(height: 52)
        }
    }

    private var donePhase: some View {
        VStack(spacing: 14) {
            ZStack {
                XiaoBoard(led: .green)
                    .frame(width: 150, height: 128)
                    .shadow(color: .green.opacity(0.5), radius: 24)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .offset(x: 72, y: 52)
            }
            .padding(.vertical, 14)

            if let p = profile {
                TemplateGraph(points: p.template, color: .green)
                    .frame(height: 56)
                    .padding(.horizontal, 10)
                Text("\(p.detectorName) · \(p.qualityLabel) · 1 rep every \(String(format: "%.1f", p.period)) s")
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(.secondary)
                if !p.exact || p.quality < 3 {
                    Text("It learned, but only just. Teaching it again with steadier reps will make it more reliable.")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            PillButton(title: "Save") { save() }
            if let url = recordingURL {
                ShareLink(item: url) { Text("Share recording") }
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var failedPhase: some View {
        VStack(spacing: 14) {
            XiaoBoard(led: .off)
                .frame(width: 150, height: 128)
                .padding(.vertical, 10)
            Text("Couldn't match \(actualReps) reps")
                .font(.system(.headline, design: .rounded, weight: .semibold))
            if let n = suggestedReps {
                Text("You said \(actualReps), but the motion looks most like \(n) reps. If \(n) is right, learn it as \(n). Otherwise try again with bigger, steadier reps and the clip fixed to the weight.")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                PillButton(title: "Learn as \(n) reps") {
                    actualReps = n
                    learn()
                }
            } else {
                Text("No setting counted \(actualReps) reps cleanly. Do bigger, steadier reps with a short pause between them, and keep the clip fixed to the weight.")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 24) {
                Button("Try again") { phase = .ready }
                if let url = recordingURL {
                    ShareLink(item: url) { Text("Share recording") }
                }
            }
            .font(.system(.subheadline, design: .rounded, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
    }

    // MARK: actions

    private func beginRecording() {
        reachedTarget = false
        actualReps = Self.targetReps
        session.startTeaching()
        phase = .recording
    }

    private func stopRecording() {
        samples = session.finishTeaching()
        actualReps = Self.targetReps
        recordingURL = writeRecording(samples)
        phase = .confirm
    }

    // The teaching set as a CSV (t, ax, ay, az, gx, gy, gz), so a set that counted wrong can be
    // replayed and debugged with tools/rep_engine.py.
    private func writeRecording(_ samples: [MotionSample]) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let safe = name.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "_")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("teach_\(safe)_\(stamp).csv")
        var text = "t,ax,ay,az,gx,gy,gz\n"
        text.reserveCapacity(samples.count * 48)
        for s in samples {
            text += String(format: "%.3f,%.3f,%.3f,%.3f,%.2f,%.2f,%.2f\n", s.t, s.ax, s.ay, s.az, s.gx, s.gy, s.gz)
        }
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) == nil ? nil : url
    }

    private func learn() {
        phase = .learning
        let data = samples
        let target = actualReps
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = ProfileLearner.learnOutcome(samples: data, targetReps: target)
            DispatchQueue.main.async {
                switch outcome {
                case .learned(let result):
                    profile = result
                    phase = .done
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                case .failed(let suggestion):
                    suggestedReps = (suggestion != nil && suggestion != target) ? suggestion : nil
                    phase = .failed
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    if !reduceMotion {
                        withAnimation(.easeInOut(duration: 0.55)) { shakes += 1 }
                    }
                }
            }
        }
    }

    private func save() {
        guard let profile else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        store.setProfile(profile, for: trimmed)
        if let saved = store.exercise(named: trimmed) { onSaved?(saved) }
        dismiss()
    }

    private func close() {
        if session.inSet { _ = session.finishTeaching() }
        dismiss()
    }

    private func flashGreen() {
        flashTask?.cancel()
        flashTask = Task { @MainActor in
            led = .green
            try? await Task.sleep(for: .milliseconds(120))
            if !Task.isCancelled { led = .off }
        }
    }
}

struct ProgressRing: View {
    let progress: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 14)
            Circle()
                .trim(from: 0, to: max(0.005, progress))
                .stroke(color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: progress)
                .animation(.easeInOut(duration: 0.3), value: color)
        }
    }
}

// The learned shape of one rep, drawn as a small line.
struct TemplateGraph: View {
    let points: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            if points.count > 1 {
                Path { path in
                    let w = geo.size.width
                    let h = geo.size.height
                    for (i, y) in points.enumerated() {
                        let x = w * CGFloat(i) / CGFloat(points.count - 1)
                        let yy = h / 2 - CGFloat(y) * (h / 2 - 4)
                        if i == 0 { path.move(to: CGPoint(x: x, y: yy)) } else { path.addLine(to: CGPoint(x: x, y: yy)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            } else {
                Text("No shape yet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
