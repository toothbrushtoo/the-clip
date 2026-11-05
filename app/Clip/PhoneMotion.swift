import Foundation
import CoreMotion

// The phone's own motion sensors as a 100 Hz MotionSample stream, in the same units the clip
// streams: accel in m/s² including gravity, gyro in deg/s. Lets the whole counting pipeline
// run without a clip, which is handy for testing and for the demo.
final class PhoneMotion {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start(_ handler: @escaping (MotionSample) -> Void) {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = RepConstants.dt
        queue.maxConcurrentOperationCount = 1
        manager.startDeviceMotionUpdates(to: queue) { motion, _ in
            guard let m = motion else { return }
            let g = 9.81
            let d = 180.0 / Double.pi
            let sample = MotionSample(t: m.timestamp,
                                      ax: (m.gravity.x + m.userAcceleration.x) * g,
                                      ay: (m.gravity.y + m.userAcceleration.y) * g,
                                      az: (m.gravity.z + m.userAcceleration.z) * g,
                                      gx: m.rotationRate.x * d,
                                      gy: m.rotationRate.y * d,
                                      gz: m.rotationRate.z * d)
            DispatchQueue.main.async { handler(sample) }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
