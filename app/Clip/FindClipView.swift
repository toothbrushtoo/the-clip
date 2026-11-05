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
    @Published var samplesPerSecond = 0
    @Published var calibrating = false
    @Published var rssiAt1m: Double = UserDefaults.standard.object(forKey: "rssiAt1m") as? Double ?? -55

    static let defaultRssiAt1m: Double = -55

    private let ble = ClipBLE.shared
    private var bag = Set<AnyCancellable>()
    private var phoneSamples: [(time: Date, rssi: Double)] = []
    private var clipSamples: [(time: Date, rssi: Double)] = []
    private var calibrationPool: [Double] = []
    private var staleTimer: Timer?
    private var hapticTimer: Timer?
    private var flashTimer: Timer?
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

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkStale() }
        RunLoop.main.add(timer, forMode: .common)
        staleTimer = timer
    }

    func stop() {
        staleTimer?.invalidate(); staleTimer = nil
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

    private func checkStale() {
        if band != .searching, let last = lastSample, Date().timeIntervalSince(last) > 3 {
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
        case .weak: return "Weak signal"
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
        if d < 0.5 { return "Less than half a metre" }
        if d < 3 {
            let rounded = (d * 2).rounded() / 2
            let text = rounded == rounded.rounded() ? String(format: "%.0f", rounded) : String(format: "%.1f", rounded)
            return "About \(text) m"
        }
        if d < 10 { return "About \(Int(d.rounded())) m" }
        return "More than 10 m"
    }

    var detail: String {
        guard let s = smoothedRssi else { return " " }
        return String(format: "%.0f dBm · %d samples/s", s, samplesPerSecond)
    }

    // The ring's colour: red when far, through yellow, to blue when close, and green once you're there.
    var color: Color {
        switch band {
        case .searching: return .gray
        case .here: return .green
        default: return Self.ramp(proximity)
        }
    }

    private static let rampStops: [(at: Double, r: Double, g: Double, b: Double)] = [
        (0.0, 1.00, 0.23, 0.19),
        (0.4, 1.00, 0.80, 0.00),
        (0.75, 0.00, 0.48, 1.00)
    ]

    static func ramp(_ p: Double) -> Color {
        let stops = rampStops
        let x = min(max(p, stops.first!.at), stops.last!.at)
        for i in 1..<stops.count where x <= stops[i].at {
            let a = stops[i - 1], b = stops[i]
            let t = (x - a.at) / (b.at - a.at)
            return Color(red: a.r + (b.r - a.r) * t,
                         green: a.g + (b.g - a.g) * t,
                         blue: a.b + (b.b - a.b) * t)
        }
        let last = stops.last!
        return Color(red: last.r, green: last.g, blue: last.b)
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
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
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

                Spacer()

                ZStack {
                    FindRing(proximity: model.proximity,
                             color: model.color,
                             searching: model.band == .searching,
                             reduceMotion: reduceMotion)
                        .frame(width: 280, height: 280)

                    VStack(spacing: 6) {
                        Text(model.title)
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        Text(model.subtitle)
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 48)
                    .animation(.easeInOut(duration: 0.3), value: model.band)
                }

                Text(model.detail)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 28)

                Spacer()

                HStack(spacing: 32) {
                    Button(model.flashing ? "Stop flashing" : "Flash clip") { model.toggleFlash() }
                        .disabled(ble.state != .connected)
                    Button("Calibrate") { showingCalibrate = true }
                }
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            }
            .padding(24)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .sheet(isPresented: $showingCalibrate) {
            CalibrateView(model: model)
                .presentationDetents([.medium])
        }
    }
}

// One ring. It fills as you get closer; while searching a short grey segment slowly goes round.
struct FindRing: View {
    let proximity: Double
    let color: Color
    let searching: Bool
    let reduceMotion: Bool

    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 18)

            if searching {
                Circle()
                    .trim(from: 0, to: 0.18)
                    .stroke(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 18, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(reduceMotion ? nil : .linear(duration: 2.4).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
                    .onDisappear { spin = false }
                    .transition(.opacity)
            } else {
                Circle()
                    .trim(from: 0, to: max(0.01, proximity))
                    .stroke(color, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.7, dampingFraction: 0.9), value: proximity)
                    .animation(.easeInOut(duration: 0.4), value: color)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: searching)
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
