import SwiftUI
import Combine
import UIKit

// MARK: - Signal model

// Turns Bluetooth signal strength into "Far / Near / Here", the way Find My does for
// AirPods without ultra-wideband. To keep it steady:
//  - the phone reads signal strength 5 times a second, and the clip reports its own reading
//    of the phone 5 times a second (two antennas see different fading)
//  - the clip's readings are shifted onto the phone's scale, everything from the last 2 s is
//    pooled, and the median is taken (one bad packet can't jump the needle)
//  - the median is then smoothed a little more, and mapped to distance with a log-distance
//    path-loss model around a 1 m reference you can calibrate in the app
final class FindClipModel: ObservableObject {
    enum Band { case searching, weak, far, near, here }

    @Published var band: Band = .searching
    @Published var proximity: Double = 0
    @Published var smoothedRssi: Double?
    @Published var distance: Double?
    @Published var flashing = false
    @Published var pulsePhase: Double = 0
    @Published var samplesPerSecond = 0
    @Published var calibrating = false
    @Published var rssiAt1m: Double = UserDefaults.standard.object(forKey: "rssiAt1m") as? Double ?? -55

    static let defaultRssiAt1m: Double = -55

    private let ble = ClipBLE.shared
    private var bag = Set<AnyCancellable>()
    private var phoneSamples: [(time: Date, rssi: Double)] = []
    private var clipSamples: [(time: Date, rssi: Double)] = []
    private var calibrationPool: [Double] = []
    private var frameTimer: Timer?
    private var hapticTimer: Timer?
    private var flashTimer: Timer?
    private var lastFrame = Date()
    private var lastSample: Date?
    private var startedConnection = false
    private var wasHere = false
    private let window: TimeInterval = 2.0
    private let pathLossExponent = 2.2

    // MARK: lifecycle

    func start() {
        ble.finding = true
        if ble.state == .idle || ble.state == .off || ble.state == .failed {
            startedConnection = true
            ble.connect()
        }

        ble.$rssi
            .compactMap { $0 }
            .sink { [weak self] r in self?.addPhone(r) }
            .store(in: &bag)
        ble.$clipRssi
            .compactMap { $0 }
            .sink { [weak self] r in self?.addClip(r) }
            .store(in: &bag)
        ble.$state
            .sink { [weak self] s in
                guard let self else { return }
                if s != .connected {
                    flashing = false
                    flashTimer?.invalidate()
                    setSearching()
                }
            }
            .store(in: &bag)

        lastFrame = Date()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.frame() }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    func stop() {
        frameTimer?.invalidate(); frameTimer = nil
        hapticTimer?.invalidate(); hapticTimer = nil
        flashTimer?.invalidate(); flashTimer = nil
        bag.removeAll()
        if flashing {
            ble.stopFind()
            flashing = false
        }
        ble.finding = false
        if startedConnection && ble.state != .connected { ble.disconnect() }
    }

    func toggleFlash() {
        guard ble.state == .connected else { return }
        flashing.toggle()
        flashTimer?.invalidate()
        if flashing {
            ble.find()
            flashTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
                self?.flashing = false
            }
        } else {
            ble.stopFind()
        }
    }

    // MARK: samples

    private func addPhone(_ r: Int) {
        guard r < 0, r > -120 else { return }
        let now = Date()
        phoneSamples.append((now, Double(r)))
        if calibrating { calibrationPool.append(Double(r)) }
        recompute(at: now)
    }

    private func addClip(_ r: Int) {
        guard r < 0, r > -120 else { return }
        let now = Date()
        clipSamples.append((now, Double(r)))
        recompute(at: now)
    }

    private func recompute(at now: Date) {
        phoneSamples.removeAll { now.timeIntervalSince($0.time) > window }
        clipSamples.removeAll { now.timeIntervalSince($0.time) > window }

        var pool = phoneSamples.map(\.rssi)
        if phoneSamples.count >= 3, clipSamples.count >= 3 {
            let offset = Self.mean(phoneSamples.map(\.rssi)) - Self.mean(clipSamples.map(\.rssi))
            pool += clipSamples.map { $0.rssi + offset }
        }
        guard !pool.isEmpty else { return }

        let median = Self.median(pool)
        let smoothed = smoothedRssi.map { $0 + 0.35 * (median - $0) } ?? median
        smoothedRssi = smoothed
        lastSample = now
        samplesPerSecond = phoneSamples.filter { now.timeIntervalSince($0.time) <= 1 }.count
            + clipSamples.filter { now.timeIntervalSince($0.time) <= 1 }.count

        let dbAboveReference = smoothed - rssiAt1m
        distance = pow(10, -dbAboveReference / (10 * pathLossExponent))
        let p = min(1, max(0, 0.5 + dbAboveReference / 40))
        let newBand: Band = p >= 0.75 ? .here : p >= 0.4 ? .near : p >= 0.07 ? .far : .weak

        withAnimation(.easeInOut(duration: 0.5)) {
            proximity = p
            band = newBand
        }
        if newBand == .here && !wasHere {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        wasHere = newBand == .here
        if hapticTimer == nil { scheduleHaptic() }
    }

    private func setSearching() {
        phoneSamples.removeAll()
        clipSamples.removeAll()
        smoothedRssi = nil
        distance = nil
        samplesPerSecond = 0
        lastSample = nil
        wasHere = false
        hapticTimer?.invalidate()
        hapticTimer = nil
        withAnimation(.easeInOut(duration: 0.6)) {
            band = .searching
            proximity = 0
        }
    }

    // 30 Hz: drives the pulse rings and notices when the signal has gone quiet.
    private func frame() {
        let now = Date()
        let dt = min(0.1, now.timeIntervalSince(lastFrame))
        lastFrame = now
        let period = 2.2 - 1.7 * proximity
        pulsePhase += dt / period
        if band != .searching, let last = lastSample, now.timeIntervalSince(last) > 3 {
            setSearching()
        }
    }

    // Taps that come faster and harder as you get closer.
    private func scheduleHaptic() {
        hapticTimer?.invalidate()
        guard band != .searching else { hapticTimer = nil; return }
        let interval = max(0.18, 1.3 - 1.1 * proximity)
        hapticTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            let style: UIImpactFeedbackGenerator.FeedbackStyle =
                proximity < 0.4 ? .light : (proximity < 0.75 ? .medium : .heavy)
            UIImpactFeedbackGenerator(style: style).impactOccurred(intensity: 0.5 + 0.5 * proximity)
            scheduleHaptic()
        }
    }

    // MARK: calibration

    func calibrate(completion: @escaping (Double?) -> Void) {
        calibrationPool = []
        calibrating = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            calibrating = false
            guard calibrationPool.count >= 5 else { completion(nil); return }
            let reference = Self.median(calibrationPool)
            rssiAt1m = reference
            UserDefaults.standard.set(reference, forKey: "rssiAt1m")
            completion(reference)
        }
    }

    func resetCalibration() {
        rssiAt1m = Self.defaultRssiAt1m
        UserDefaults.standard.removeObject(forKey: "rssiAt1m")
    }

    // MARK: text and colour

    var title: String {
        switch band {
        case .searching: return "Searching"
        case .weak: return "Weak Signal"
        case .far: return "Far"
        case .near: return "Near"
        case .here: return "Here"
        }
    }

    var subtitle: String {
        switch band {
        case .searching: return ble.state == .connected ? "Reading the signal…" : "Looking for your Clip…"
        case .weak: return "Walk around to pick up the signal"
        case .here: return "Right next to you"
        case .far, .near: return distanceText
        }
    }

    var distanceText: String {
        guard let d = distance else { return "" }
        if d < 0.5 { return "Less than half a metre away" }
        if d < 3 {
            let rounded = (d * 2).rounded() / 2
            let text = rounded == rounded.rounded() ? String(format: "%.0f", rounded) : String(format: "%.1f", rounded)
            return "About \(text) m away"
        }
        if d < 10 { return "About \(Int(d.rounded())) m away" }
        return "More than 10 m away"
    }

    var detail: String {
        guard let s = smoothedRssi else { return " " }
        return String(format: "%.0f dBm · %d samples/s", s, samplesPerSecond)
    }

    var color: Color {
        switch band {
        case .searching: return .gray
        case .weak: return .indigo
        case .far: return .blue
        case .near: return .mint
        case .here: return .green
        }
    }

    private static func mean(_ xs: [Double]) -> Double {
        xs.reduce(0, +) / Double(xs.count)
    }

    private static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}

// MARK: - Screen

struct FindClipView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model = FindClipModel()
    @ObservedObject private var ble = ClipBLE.shared
    @State private var showingCalibrate = false

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                header
                Spacer(minLength: 12)
                ProximityMeter(proximity: model.proximity,
                               phase: model.pulsePhase,
                               color: model.color,
                               active: model.band != .searching,
                               found: model.band == .here,
                               reduceMotion: reduceMotion)
                    .frame(width: 300, height: 300)
                VStack(spacing: 8) {
                    Text(model.title)
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Text(model.subtitle)
                        .font(.system(.title3, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text(model.detail)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 28)
                .animation(.easeInOut(duration: 0.3), value: model.band)
                Spacer(minLength: 12)
                buttons
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .preferredColorScheme(.dark)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .sheet(isPresented: $showingCalibrate) {
            CalibrateView(model: model)
                .presentationDetents([.medium])
        }
    }

    private var background: some View {
        ZStack {
            Color.black
            RadialGradient(colors: [model.color.opacity(0.35), .clear],
                           center: .center, startRadius: 40, endRadius: 420)
                .animation(.easeInOut(duration: 0.8), value: model.band)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack {
            Text("Find Clip")
                .font(.system(.title2, design: .rounded, weight: .bold))
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.top, 8)
    }

    private var buttons: some View {
        VStack(spacing: 14) {
            Button {
                model.toggleFlash()
            } label: {
                Label(model.flashing ? "Stop Flashing" : "Flash Clip",
                      systemImage: model.flashing ? "lightbulb.slash.fill" : "lightbulb.fill")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(model.flashing ? .orange : .white)
            .foregroundStyle(model.flashing ? .white : .black)
            .disabled(ble.state != .connected)
            .animation(.easeInOut(duration: 0.2), value: model.flashing)

            Button("Calibrate distance") { showingCalibrate = true }
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

struct ProximityMeter: View {
    let proximity: Double
    let phase: Double
    let color: Color
    let active: Bool
    let found: Bool
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            if !reduceMotion {
                ring(0)
                ring(1)
                ring(2)
            }

            Circle()
                .fill(color.opacity(0.18))
                .frame(width: 150 + 110 * proximity, height: 150 + 110 * proximity)
                .blur(radius: 22)
                .animation(.easeInOut(duration: 0.5), value: proximity)

            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 16)
                .padding(8)

            Circle()
                .trim(from: 0, to: max(0.015, proximity))
                .stroke(color, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(8)
                .shadow(color: color.opacity(0.6), radius: 10)
                .animation(.spring(response: 0.6, dampingFraction: 0.9), value: proximity)

            Circle()
                .fill(color)
                .frame(width: found ? 96 : 14 + 22 * proximity, height: found ? 96 : 14 + 22 * proximity)
                .shadow(color: color.opacity(0.9), radius: found ? 24 : 10)
                .overlay {
                    if found {
                        Image(systemName: "checkmark")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(.white)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.65), value: found)
                .animation(.easeInOut(duration: 0.5), value: proximity)
        }
    }

    private func ring(_ i: Int) -> some View {
        let q = (phase + Double(i) / 3).truncatingRemainder(dividingBy: 1)
        let strength = active ? 0.55 : 0.18
        return Circle()
            .stroke(color.opacity((1 - q) * strength), lineWidth: 2)
            .scaleEffect(0.5 + 0.8 * q)
    }
}

struct CalibrateView: View {
    @ObservedObject var model: FindClipModel
    @ObservedObject private var ble = ClipBLE.shared
    @Environment(\.dismiss) private var dismiss
    @State private var result: Double?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "ruler")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Put the clip 1 metre from your phone")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)
                Text("Open air, nothing in between, and hold still. The app listens for 4 seconds and uses that as its 1 metre reference.")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if model.calibrating {
                    ProgressView("Measuring…")
                } else if let r = result {
                    Label(String(format: "Saved: %.0f dBm at 1 m", r), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if failed {
                    Text("Not enough signal. Check the clip is connected and try again.")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Spacer(minLength: 0)

                Button {
                    failed = false
                    result = nil
                    model.calibrate { r in
                        if let r { result = r } else { failed = true }
                    }
                } label: {
                    Text("Measure")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(model.calibrating || ble.state != .connected)

                Button("Reset to default") {
                    model.resetCalibration()
                    result = nil
                }
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)

                Text(String(format: "Current reference: %.0f dBm", model.rssiAt1m))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
            .navigationTitle("Calibrate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
    }
}
