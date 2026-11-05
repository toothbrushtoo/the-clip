import Foundation
import Combine

// One counting session: picks where the motion comes from (fake timer, the phone's sensors or
// the clip), runs the RepEngine on it, and keeps the reps, tempo and set history.
final class ClipSession: ObservableObject {
    enum Source: String, CaseIterable { case fake, phone, clip }

    // What is producing the count for the current set.
    enum Counter: String {
        case fake = "Fake"
        case phone = "Phone"
        case clipStream = "Clip"
        case clipOnboard = "Clip (on-board count)"
    }

    @Published var reps = 0 {
        didSet { if reps > oldValue { noteRep() } }
    }
    @Published var tempo: Double = 0
    @Published var connected = false
    @Published var inSet = false
    @Published var source: Source = .fake {
        didSet { if oldValue != source { disconnect() } }
    }
    @Published var sets: [WorkoutSet] = []
    @Published private(set) var counter: Counter?
    @Published private(set) var detector: ExerciseProfile.Detector?

    // The learned profile for the exercise being done. Set it before `startSet()`.
    var profile: ExerciseProfile?

    let phone = PhoneMotion()
    let ble = ClipBLE.shared
    private var engine: RepEngine?
    private var timer: Timer?
    private var streamWatchdog: Timer?
    private var setStart: Date?
    private var bag = Set<AnyCancellable>()
    private var linkBag = Set<AnyCancellable>()
    private var repTimes: [Date] = []
    private var recording: [MotionSample]?

    var isTeaching: Bool { recording != nil }

    func connect() {
        switch source {
        case .fake, .phone:
            connected = true
        case .clip:
            ble.connect()
            ble.$state
                .receive(on: RunLoop.main)
                .sink { [weak self] s in self?.connected = (s == .connected) }
                .store(in: &linkBag)
        }
    }

    func connectFake() { connect() }

    func disconnect() {
        if inSet { endSet() }
        if source != .clip { ble.disconnect() }
        linkBag.removeAll()
        connected = false
    }

    func startSet() {
        repTimes.removeAll()
        tempo = 0
        reps = 0
        inSet = true
        setStart = Date()
        timer?.invalidate()
        timer = nil
        streamWatchdog?.invalidate()
        streamWatchdog = nil
        bag.removeAll()
        let engine = RepEngine(profile: profile)
        self.engine = engine
        detector = engine.chosen

        switch source {
        case .fake:
            counter = .fake
            timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                reps += 1
            }
        case .phone:
            counter = .phone
            phone.start { [weak self] s in self?.feed(s) }
        case .clip:
            ble.startSet()
            if ble.streamSupported {
                counter = .clipStream
                ble.onSample = { [weak self] s in self?.feed(s) }
                ble.streaming = true
                // If the stream never shows up (old firmware, tiny MTU), use the clip's own count.
                streamWatchdog = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                    guard let self, inSet, ble.streamSamples == 0 else { return }
                    useOnboardCount()
                }
            } else {
                useOnboardCount()
            }
        }
    }

    func endSet(record: Bool = true) {
        inSet = false
        timer?.invalidate()
        timer = nil
        streamWatchdog?.invalidate()
        streamWatchdog = nil
        phone.stop()
        if source == .clip {
            ble.streaming = false
            ble.onSample = nil
            ble.endSet()
        }
        bag.removeAll()
        if record { recordSet() }
    }

    // Teaching: count generically while recording every sample, so the learner can work on them.
    func startTeaching() {
        let saved = profile
        profile = nil
        recording = []
        startSet()
        profile = saved
    }

    func finishTeaching() -> [MotionSample] {
        let samples = recording ?? []
        recording = nil
        endSet(record: false)
        return samples
    }

    func clearHistory() { sets.removeAll() }

    private func useOnboardCount() {
        ble.streaming = false
        ble.onSample = nil
        counter = .clipOnboard
        ble.$reps
            .receive(on: RunLoop.main)
            .sink { [weak self] r in self?.reps = r }
            .store(in: &bag)
    }

    private func feed(_ sample: MotionSample) {
        guard inSet, let engine else { return }
        recording?.append(sample)
        if let d = engine.push(sample) {
            detector = d
            reps = engine.reps
            if source == .clip { ble.flashRep() }
        }
    }

    private func noteRep() {
        repTimes.append(Date())
        guard let first = repTimes.first, let last = repTimes.last, repTimes.count >= 2 else { return }
        tempo = last.timeIntervalSince(first) / Double(repTimes.count - 1)
    }

    private func recordSet() {
        guard let start = setStart, reps > 0 else { return }
        sets.insert(WorkoutSet(reps: reps, seconds: Date().timeIntervalSince(start), date: start), at: 0)
        setStart = nil
    }

    deinit {
        timer?.invalidate()
        streamWatchdog?.invalidate()
        phone.stop()
    }
}
