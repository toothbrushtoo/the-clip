import Foundation

struct WorkoutSet: Identifiable {
    let id: UUID
    let reps: Int
    let seconds: TimeInterval
    let date: Date

    init(id: UUID = UUID(), reps: Int, seconds: TimeInterval, date: Date) {
        self.id = id
        self.reps = reps
        self.seconds = seconds
        self.date = date
    }
}
