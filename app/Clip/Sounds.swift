import Foundation
import AVFoundation
import UIKit

// Little bell sounds for finished sets, exercises and workouts. Generated on the fly, so there
// are no sound files to ship. Respects the silent switch; the haptic still plays either way.
enum Ding {
    enum Kind { case set, exercise, workout }

    private static var player: AVAudioPlayer?
    private static var cache: [String: Data] = [:]

    static func play(_ kind: Kind) {
        let notes: [(f: Double, at: Double)]
        switch kind {
        case .set: notes = [(1046.5, 0), (1318.5, 0.14)]
        case .exercise: notes = [(1046.5, 0), (1318.5, 0.14), (1568.0, 0.28)]
        case .workout: notes = [(1046.5, 0), (1318.5, 0.14), (1568.0, 0.28), (2093.0, 0.46)]
        }
        let key = "\(kind)"
        let data = cache[key] ?? wav(notes: notes)
        cache[key] = data

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, options: [.mixWithOthers])
        try? session.setActive(true)
        player = try? AVAudioPlayer(data: data)
        player?.play()

        switch kind {
        case .set: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .exercise, .workout:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            }
        }
    }

    // 16-bit mono PCM. Each note is a sine with a touch of second harmonic and an exponential decay.
    private static func wav(notes: [(f: Double, at: Double)], rate: Int = 22050) -> Data {
        let duration = (notes.map(\.at).max() ?? 0) + 0.9
        let n = Int(Double(rate) * duration)
        var samples = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / Double(rate)
            var v = 0.0
            for note in notes where t >= note.at {
                let dt = t - note.at
                let env = exp(-dt / 0.3) * min(1.0, dt / 0.004)
                v += (sin(2 * .pi * note.f * dt) + 0.25 * sin(4 * .pi * note.f * dt)) * env
            }
            samples[i] = Int16(max(-1.0, min(1.0, v * 0.3)) * 32767)
        }
        var data = Data()
        func put32(_ x: UInt32) { withUnsafeBytes(of: x.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ x: UInt16) { withUnsafeBytes(of: x.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(n * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        put32(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        put32(16)
        put16(1)
        put16(1)
        put32(UInt32(rate))
        put32(UInt32(rate * 2))
        put16(2)
        put16(16)
        data.append(contentsOf: Array("data".utf8))
        put32(byteCount)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
