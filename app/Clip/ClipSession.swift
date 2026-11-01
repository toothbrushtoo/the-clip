import Foundation
import Combine

final class ClipSession: ObservableObject {
    @Published var reps = 0
    @Published var connected = false
    @Published var inSet = false
    @Published var sets: [WorkoutSet] = []

    private var timer: Timer?
    private var setStart: Date?

    func connectFake() {
        connected = true
    }

    func startSet() {
        reps = 0
        inSet = true
        setStart = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.reps += 1
        }
    }

    func endSet() {
        inSet = false
        timer?.invalidate()
        timer = nil
        recordSet()
    }

    func clearHistory() {
            sets.removeAll()
    }

    private func recordSet() {
        guard let start = setStart, reps > 0 else { return }
        let end = Date()
        let finished = WorkoutSet(
            reps: reps,
            seconds: end.timeIntervalSince(start),
            date: start
        )
        sets.insert(finished, at: 0)
        setStart = nil
    }

    deinit {
        timer?.invalidate()
    }
}
