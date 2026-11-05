import Foundation
import Combine

final class ClipSession: ObservableObject {
    enum Source: String, CaseIterable { case fake, phone, clip }

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

    let motion = MotionCounter()
    let ble = ClipBLE.shared
    private var timer: Timer?
    private var setStart: Date?
    private var bag = Set<AnyCancellable>()
    private var linkBag = Set<AnyCancellable>()
    private var repTimes: [Date] = []

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
        switch source {
        case .fake:
            timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.reps += 1
            }
        case .phone:
            motion.start()
            motion.$reps
                .receive(on: RunLoop.main)
                .sink { [weak self] r in self?.reps = r }
                .store(in: &bag)
        case .clip:
            ble.startSet()
            ble.$reps
                .receive(on: RunLoop.main)
                .sink { [weak self] r in self?.reps = r }
                .store(in: &bag)
        }
    }

    func endSet() {
        inSet = false
        timer?.invalidate(); timer = nil
        motion.stop()
        if source == .clip { ble.endSet() }
        bag.removeAll()
        recordSet()
    }

    func clearHistory() { sets.removeAll() }

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

    deinit { timer?.invalidate(); motion.stop() }
}
