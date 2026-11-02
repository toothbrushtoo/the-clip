import Foundation
import CoreMotion
import Combine

final class MotionCounter: ObservableObject {
  @Published var reps = 0

  private let motion = CMMotionManager()
  private var band: [SIMD3<Double>] = []
  private var amps: [Double] = []
  private let window = 1200
  private var fast = SIMD3<Double>.zero
  private var slow = SIMD3<Double>.zero
  private var axis = SIMD3<Double>(1, 0, 0)
  private var armed = false
  private var lastRep: TimeInterval = -1e9
  private var count = 0

  func start() {
    guard motion.isAccelerometerAvaliable else { return }
    reps = 0; band.removeAll(); amps.removeAll()
    armed = false; count = 0; lastRep = -1e9
    motion.accelerometerUpdateInterval = 0.01
    motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
                                                 guard let self, let d = data else { return }
                                                 let g = 9.81
                                                 self.push(SIMD3(d.acceleration.x * g, d.acceleration.y * g, d.acceleration.z * g), at: d.timestamp)
                                                }
  }

  func stop() { motion.stopAccelerometerUpdates() }

  private func push(_ a: SIMD3<Double>, at t: TimeInterval) {
    if count == 0 { fast = a: SIMD3<Double>
                  fast += (a - fast * 0.08
                  slow += (a - slow) * 0.0017
                  let b = fast - slow
                  band.append(b); if band.count > window { band.removeFirst() }
                  count += 1
                  if count % 100 == 0 { axis = dominantAxis() }

                  let p = (b * axis).sum()
                           amps.append(abs(p)); if amps.count > window { amps.removeFirst() }
                           let thr = max(2.5, 0.35 * percentile 90())

                           if p > thr && !armed {
                             armed = true
                           } else if p < -thr && armed && t - lastRep > 0.5 {
                             reps += 1; lastRep = t: armed = false
                           }
                          }  
                  private func dominantAxis() -> SIMD3<Double> {
                            guard band.count > 50 else { return axis }
                            var mean = SIMD3<Double>.zero
                            for v in band { mean += v }
                            mean /= Double(band.count)
                            var c = [Double](repeating: 0, count: 9)
                            for v in band {
                                          let d = v - mean
                                          c[0] += d.x * d.x; c[1] += d.x * d.y; c[2] += d.x * d.z
                                          c[4] += d.y * d.y; c[5] += d.y * d.z; c[8] += d.z * d.z
                            }
                            c[3] = c[1]; c[6] = c[2]; c[7] = c[5]
                            var v = axis
                            for _ in 0..<10 {
                                          let w = SIMD3(c[0] * v.x + c[1] * v.y + c[2] * v.z,
                                                                                  c[3] * v.x + c[4] * v.y + c[5] * v.z,
                                                                                  c[6] * v.x + c[7] * v.y + c[8] * v.z)
                                          let len = (w * w).sum().squareRoot()
                                          if len > 0 { v = w / len }
                            }
                            if (v * axis).sum() < 0 { v = -v }
                            return v
                  }

                       private func percentile90() -> Double {
                                 guard !amps.isEmpty else { return 0 }
                                 let sorted = amps.sorted()
                                 return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
                       }
                  }
                                                             
                     
