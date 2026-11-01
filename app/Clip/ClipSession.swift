import Foundation
import Combine

final class ClipSession: ObservableObject {
    @Published var reps = 0
    @Published var connected = false
    @Published var inSet = false

    private var timer: Timer?

    func connectFake() {
        connected = true
    }

    func startSet() {
        reps = 0
        inSet = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.reps += 1
        }
    }

    func endSet() {
        inSet = false
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}
