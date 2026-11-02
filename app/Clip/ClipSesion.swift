import Foundation
import Combine

final class ClipSession: ObservableObject {
      enum Source: String, CaseIterable { case fake, phone }

      @Published var reps = 0
      @Published var connected = false
      @Published var inSet = false
      @Published var source: Source = .fake
      @Published var sets: [WorkoutSet] = []

      let motion = MotionCounter()
      private var timer: Timer?
      private var setStart: Date?
      private var bag = Set<AnyCancellable>()

      func connectFake() { connected = true }

      func startSet() {
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
                }
      }

      func endSet() {
                inSet = false
                timer?.invalidate(); timer = nil
                motion.stop(); bag.removeAll()
                recordSet()
      }

      func clearHistory() { sets.removeAll() }

      private func recordSet() {
                guard let start = setStart, reps > 0 else { return }
                sets.insert(WorkoutSet(reps: reps, seconds: Date().timeIntervalSince(start), date: start), at: 0)
                setStart = nil
      }

      deinit { timer?.invalidate(); motion.stop() }
}
