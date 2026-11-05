import Foundation

// Rep counting engine. Same maths as tools/rep_engine.py (the reference), ported line for line.
//
// Feed it samples at 100 Hz: accel in m/s^2 including gravity, gyro in deg/s. Three detectors
// run side by side, each watching one signal:
//   rotation  - gyro integrated to an angle on its main axis (curls, raises, kickbacks)
//   motion    - band-passed accel projected on its main axis (gravity tilt and jolts)
//   velocity  - accel integrated to speed on its main axis (presses, squats, rows, stacks)
// Each one is a zig-zag peak detector with hysteresis: a rep is counted on the way down, once
// the signal has risen at least T from a trough and then dropped at least T from its peak.
//
// Without a profile, rotation decides when the clip is clearly turning, otherwise motion does.
// With a learned ExerciseProfile, the detector, threshold and rep gap come from the teaching
// session, which is what makes a taught exercise count better than a generic one.

struct MotionSample {
    var t: Double
    var ax: Double, ay: Double, az: Double
    var gx: Double, gy: Double, gz: Double

    var accel: [Double] { [ax, ay, az] }
    var gyro: [Double] { [gx, gy, gz] }
}

struct ExerciseProfile: Codable, Equatable {
    enum Detector: String, Codable { case rotation, motion, velocity }

    var detector: Detector
    var threshold: Double
    var frac: Double? = nil          // set for an adaptive threshold (frac × biggest recent swing)
    var amplitude: Double
    var period: Double
    var minGap: Double
    var template: [Double]
    var repsTaught: Int
    var quality: Int
    var exact: Bool
    var learnedAt: Date

    var detectorName: String {
        switch detector {
        case .rotation: return "Rotation"
        case .motion: return "Motion"
        case .velocity: return "Speed"
        }
    }

    var unit: String {
        switch detector {
        case .rotation: return "°"
        case .motion: return "m/s²"
        case .velocity: return "m/s"
        }
    }

    // How steady the learned threshold is: the number of sweep steps that gave the right count.
    var qualityLabel: String {
        if !exact { return "Rough" }
        if quality >= 6 { return "Solid" }
        if quality >= 3 { return "Good" }
        return "Fragile"
    }
}

enum RepConstants {
    static let rate = 100.0
    static let dt = 1.0 / rate
    static let accTmin = 2.5
    static let velTmin = 0.2
    static let rotTmin = 20.0
    static let velHighPass = 2.0
    static let velLeak = 2.0
    static let angleLeak = 8.0
    static let detectors: [ExerciseProfile.Detector] = [.rotation, .motion, .velocity]
}

// Main direction of a 3-axis signal over the last `window` samples, by power iteration.
final class AxisTracker {
    private let window: Int
    private var buf: [[Double]] = []
    private var head = 0
    private var count = 0
    private var s = [0.0, 0.0, 0.0]
    private var p = [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
    private(set) var axis: [Double]
    private var n = 0

    init(window: Int = 600, prior: [Double]) {
        self.window = window
        self.axis = prior
        buf = Array(repeating: [0.0, 0.0, 0.0], count: window)
    }

    func reset(prior: [Double]) {
        head = 0
        count = 0
        s = [0.0, 0.0, 0.0]
        p = [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
        axis = prior
        n = 0
    }

    func push(_ v: [Double]) {
        if count == window {
            let o = buf[head]
            for i in 0..<3 {
                s[i] -= o[i]
                for j in 0..<3 { p[i][j] -= o[i] * o[j] }
            }
        } else {
            count += 1
        }
        buf[head] = v
        head = (head + 1) % window
        for i in 0..<3 {
            s[i] += v[i]
            for j in 0..<3 { p[i][j] += v[i] * v[j] }
        }
        n += 1
        if n % 25 == 0 && count >= 50 { update() }
    }

    private func update() {
        let nn = Double(count)
        let m = [s[0] / nn, s[1] / nn, s[2] / nn]
        var c = [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
        for i in 0..<3 {
            for j in 0..<3 { c[i][j] = p[i][j] / nn - m[i] * m[j] }
        }
        var v = axis
        for _ in 0..<10 {
            var w = [0.0, 0.0, 0.0]
            for r in 0..<3 { w[r] = c[r][0] * v[0] + c[r][1] * v[1] + c[r][2] * v[2] }
            let len = (w[0] * w[0] + w[1] * w[1] + w[2] * w[2]).squareRoot()
            if len <= 1e-9 { return }
            v = [w[0] / len, w[1] / len, w[2] / len]
        }
        if v[0] * axis[0] + v[1] * axis[1] + v[2] * axis[2] < 0 {
            v = [-v[0], -v[1], -v[2]]
        }
        axis = v
    }

    func project(_ v: [Double]) -> Double {
        v[0] * axis[0] + v[1] * axis[1] + v[2] * axis[2]
    }
}

// Peak detector with hysteresis. The threshold is fixed, or adapts to the biggest recent swing.
final class ZigZag {
    var tmin: Double
    var frac: Double
    var fixed: Double?
    private var initialised = false
    private var extreme = 0.0
    private var trough = 0.0
    private var dir = 0
    private(set) var env = 0.0
    private(set) var lastSwing = 0.0

    init(tmin: Double, frac: Double, fixed: Double? = nil) {
        self.tmin = tmin
        self.frac = frac
        self.fixed = fixed
    }

    var threshold: Double {
        if let fixed { return fixed }
        return max(tmin, frac * env)
    }

    func push(_ x: Double, dt: Double) -> Bool {
        if !initialised {
            initialised = true
            extreme = x
            trough = x
            return false
        }
        env *= 1.0 - dt / 20.0
        let t = threshold
        var rep = false
        if dir >= 0 {
            if x > extreme {
                extreme = x
            } else if extreme - x > t {
                let swing = extreme - trough
                if swing >= t {
                    rep = true
                    lastSwing = swing
                    env = max(env, swing)
                }
                dir = -1
                extreme = x
            }
        } else {
            if x < extreme {
                extreme = x
            } else if x - extreme > t {
                trough = extreme
                dir = 1
                extreme = x
            }
        }
        return rep
    }
}

final class RepEngine {
    let profile: ExerciseProfile?

    private(set) var reps = 0
    private(set) var samples = 0
    private(set) var lastRepTime = -1e9
    private(set) var repTimes: [Double] = []
    private(set) var repSwings: [Double] = []
    private(set) var lastSource: ExerciseProfile.Detector?

    private var fast: [Double]?
    private var slow = [0.0, 0.0, 0.0]
    private var slow2 = [0.0, 0.0, 0.0]
    private var vel = [0.0, 0.0, 0.0]
    private let axisA = AxisTracker(prior: [0.0, 0.0, 1.0])
    private let axisV = AxisTracker(prior: [0.0, 0.0, 1.0])
    private var bias = [0.0, 0.0, 0.0]
    private var theta = 0.0
    private(set) var omegaEnv = 0.0
    private let axisG = AxisTracker(prior: [1.0, 0.0, 0.0])
    private(set) var zigzags: [ExerciseProfile.Detector: ZigZag]
    private(set) var minGap = 0.6
    private(set) var projection: [ExerciseProfile.Detector: Double] = [.rotation: 0, .motion: 0, .velocity: 0]

    init(profile: ExerciseProfile? = nil) {
        self.profile = profile
        zigzags = [
            .rotation: ZigZag(tmin: RepConstants.rotTmin, frac: 0.4),
            .motion: ZigZag(tmin: RepConstants.accTmin, frac: 0.55),
            .velocity: ZigZag(tmin: RepConstants.velTmin, frac: 0.35)
        ]
        if let p = profile, let zz = zigzags[p.detector] {
            if let f = p.frac {
                zz.frac = f
                zz.fixed = nil
            } else {
                zz.fixed = p.threshold
            }
            minGap = p.minGap
        }
    }

    // Which detector is deciding right now.
    var chosen: ExerciseProfile.Detector {
        if let p = profile { return p.detector }
        if (zigzags[.rotation]?.env ?? 0) >= 45.0 || omegaEnv >= 50.0 { return .rotation }
        return .motion
    }

    // Returns the detector that counted a rep, or nil.
    @discardableResult
    func push(_ sample: MotionSample) -> ExerciseProfile.Detector? {
        let dt = RepConstants.dt
        let a = sample.accel
        let g = sample.gyro
        samples += 1

        if fast == nil {
            fast = a
            slow = a
            slow2 = a
            var len = (a[0] * a[0] + a[1] * a[1] + a[2] * a[2]).squareRoot()
            if len == 0 { len = 1 }
            axisA.reset(prior: [a[0] / len, a[1] / len, a[2] / len])
            axisV.reset(prior: [a[0] / len, a[1] / len, a[2] / len])
        }
        var band = [0.0, 0.0, 0.0]
        for k in 0..<3 {
            fast![k] += (a[k] - fast![k]) * 0.08
            slow[k] += (a[k] - slow[k]) * 0.0017
            slow2[k] += (a[k] - slow2[k]) * (dt / RepConstants.velHighPass)
            band[k] = fast![k] - slow[k]
            vel[k] += (fast![k] - slow2[k]) * dt
            vel[k] -= vel[k] * dt / RepConstants.velLeak
        }
        axisA.push(band)
        axisV.push(vel)
        projection[.motion] = axisA.project(band)
        projection[.velocity] = axisV.project(vel)

        var wc = [0.0, 0.0, 0.0]
        let still = abs(g[0] - bias[0]) < 20.0 && abs(g[1] - bias[1]) < 20.0 && abs(g[2] - bias[2]) < 20.0
        let alpha = still ? 0.004 : 0.0002
        for k in 0..<3 {
            bias[k] += (g[k] - bias[k]) * alpha
            wc[k] = g[k] - bias[k]
        }
        axisG.push(wc)
        let omega = axisG.project(wc)
        theta += omega * dt
        theta -= theta * dt / RepConstants.angleLeak
        projection[.rotation] = theta
        let mag = (wc[0] * wc[0] + wc[1] * wc[1] + wc[2] * wc[2]).squareRoot()
        omegaEnv = max(mag, omegaEnv * (1.0 - dt / 3.0))

        var fired: [ExerciseProfile.Detector: Bool] = [:]
        for d in RepConstants.detectors {
            fired[d] = zigzags[d]!.push(projection[d]!, dt: dt)
        }

        let d = chosen
        if fired[d] == true && sample.t - lastRepTime >= minGap {
            reps += 1
            lastRepTime = sample.t
            repTimes.append(sample.t)
            repSwings.append(zigzags[d]!.lastSwing)
            lastSource = d
            return d
        }
        return nil
    }
}

// MARK: - Learning from a teaching set

enum LearnOutcome {
    case learned(ExerciseProfile)
    case failed(suggestedReps: Int?)
}

enum ProfileLearner {
    // Threshold sweep per detector: from the smallest swing worth counting to a huge one.
    static func grid(_ lo: Double, _ hi: Double, _ n: Int = 30) -> [Double] {
        (0..<n).map { lo * pow(hi / lo, Double($0) / Double(n - 1)) }
    }

    static let grids: [ExerciseProfile.Detector: [Double]] = [
        .rotation: grid(12.0, 150.0),
        .motion: grid(0.6, 20.0),
        .velocity: grid(0.08, 3.0)
    ]

    // Adaptive-threshold sweep: 0.15 … 0.80 of the biggest recent swing.
    static let fracs: [Double] = (0..<14).map { 0.15 + 0.05 * Double($0) }

    static let tmins: [ExerciseProfile.Detector: Double] = [
        .rotation: RepConstants.rotTmin,
        .motion: RepConstants.accTmin,
        .velocity: RepConstants.velTmin
    ]

    private struct Candidate {
        var profile: ExerciseProfile
        var fixed: Bool
        var width: Int
        var margin: Double
        var exact: Bool

        // Rotation is the cleanest signal there is (it ignores gravity, grip and mounting), so when
        // it reproduces the count exactly with a decent margin it wins. Otherwise a fixed threshold
        // beats an adaptive one, because it generalises across tempo; adaptive is the fallback.
        var rank: (Int, Int, Int, Double) {
            (exact ? 1 : 0,
             (exact && profile.detector == .rotation && margin >= 0.3) ? 1 : 0,
             (fixed && width >= 2) ? 1 : 0,
             margin)
        }

        func beats(_ other: Candidate) -> Bool {
            let a = rank, b = other.rank
            if a.0 != b.0 { return a.0 > b.0 }
            if a.1 != b.1 { return a.1 > b.1 }
            if a.2 != b.2 { return a.2 > b.2 }
            return a.3 > b.3
        }
    }

    static func learn(samples: [MotionSample], targetReps: Int) -> ExerciseProfile? {
        if case .learned(let p) = learnOutcome(samples: samples, targetReps: targetReps) { return p }
        return nil
    }

    // Runs the engine once to get each detector's projected signal, then sweeps both a fixed
    // threshold and an adaptive fraction over it, and keeps the detector and setting that
    // reproduce the known count with the widest margin (margins compared as a fraction of each
    // sweep's length). The template is the average shape of one rep. When nothing matches, the
    // outcome carries the count the signal supports best, so the user can be asked about it.
    static func learnOutcome(samples: [MotionSample], targetReps: Int) -> LearnOutcome {
        guard samples.count > 100, targetReps >= 3 else { return .failed(suggestedReps: nil) }
        let signals = projectedSignals(samples)
        let times = samples.map(\.t)
        var best: Candidate?
        var stable: [Int: Double] = [:]

        for detector in RepConstants.detectors {
            let sig = signals[detector]!
            for fixedMode in [true, false] {
                let grid = fixedMode ? grids[detector]! : fracs
                func run(_ setting: Double, _ gap: Double) -> (times: [Double], swings: [Double]) {
                    fixedMode
                        ? replay(times, sig, gap: gap, fixed: setting)
                        : replay(times, sig, gap: gap, tmin: tmins[detector]!, frac: setting)
                }
                let counts = grid.map { run($0, 0.4).times.count }
                for (c, w) in runs(counts) {
                    stable[c] = max(stable[c] ?? 0, Double(w) / Double(grid.count))
                }
                guard let first = plateau(counts, target: targetReps) else { continue }
                let firstTimes = run(grid[first.centre], 0.4).times
                let firstPeriod = firstTimes.count > 1 ? median(zip(firstTimes, firstTimes.dropFirst()).map { $1 - $0 }) : 2.0
                let gap = min(1.2, max(0.4, 0.25 * firstPeriod))
                guard let pick = plateau(grid.map { run($0, gap).times.count }, target: targetReps) else { continue }
                let setting = grid[pick.centre]
                let result = run(setting, gap)
                let period = result.times.count > 1 ? median(zip(result.times, result.times.dropFirst()).map { $1 - $0 }) : 2.0
                let profile = ExerciseProfile(detector: detector,
                                              threshold: fixedMode ? setting : 0,
                                              frac: fixedMode ? nil : setting,
                                              amplitude: median(result.swings),
                                              period: period,
                                              minGap: gap,
                                              template: template(sig, times, repTimes: result.times, period: period),
                                              repsTaught: targetReps,
                                              quality: pick.width,
                                              exact: pick.exact,
                                              learnedAt: Date())
                let cand = Candidate(profile: profile, fixed: fixedMode, width: pick.width,
                                     margin: Double(pick.width) / Double(grid.count), exact: pick.exact)
                if best == nil || cand.beats(best!) { best = cand }
            }
        }
        if let best { return .learned(best.profile) }
        let good = stable.filter { $0.key >= 3 }
        let suggested = good.max { a, b in a.value < b.value || (a.value == b.value && a.key > b.key) }?.key
        return .failed(suggestedReps: suggested)
    }

    // Longest run of consecutive sweep steps for each count value.
    static func runs(_ counts: [Int]) -> [Int: Int] {
        var out: [Int: Int] = [:]
        var i = 0
        while i < counts.count {
            var j = i
            while j + 1 < counts.count && counts[j + 1] == counts[i] { j += 1 }
            out[counts[i]] = max(out[counts[i]] ?? 0, j - i + 1)
            i = j + 1
        }
        return out
    }

    static func projectedSignals(_ samples: [MotionSample]) -> [ExerciseProfile.Detector: [Double]] {
        let engine = RepEngine()
        var out: [ExerciseProfile.Detector: [Double]] = [.rotation: [], .motion: [], .velocity: []]
        for s in samples {
            engine.push(s)
            for d in RepConstants.detectors { out[d]!.append(engine.projection[d]!) }
        }
        return out
    }

    static func replay(_ times: [Double], _ sig: [Double], gap: Double,
                       fixed: Double? = nil, tmin: Double = 0, frac: Double = 0) -> (times: [Double], swings: [Double]) {
        let zz = ZigZag(tmin: tmin, frac: frac, fixed: fixed)
        var last = -1e9
        var repTimes: [Double] = []
        var swings: [Double] = []
        for (t, x) in zip(times, sig) {
            if zz.push(x, dt: RepConstants.dt) && t - last >= gap {
                repTimes.append(t)
                swings.append(zz.lastSwing)
                last = t
            }
        }
        return (repTimes, swings)
    }

    // Middle of the widest run of thresholds that give `target` (or target ± 1 if nothing gives
    // it exactly).
    static func plateau(_ counts: [Int], target: Int) -> (centre: Int, width: Int, exact: Bool)? {
        for exact in [true, false] {
            let hits = counts.indices.filter { exact ? counts[$0] == target : abs(counts[$0] - target) <= 1 }
            guard let firstHit = hits.first else { continue }
            var runs: [(Int, Int)] = []
            var start = firstHit
            var prev = firstHit
            for i in hits.dropFirst() {
                if i == prev + 1 {
                    prev = i
                } else {
                    runs.append((start, prev))
                    start = i
                    prev = i
                }
            }
            runs.append((start, prev))
            let (s, e) = runs.max { ($0.1 - $0.0) < ($1.1 - $1.0) }!
            return ((s + e) / 2, e - s + 1, exact)
        }
        return nil
    }

    // Average one-rep shape, from half a period before each rep to half after, 50 points, -1…1.
    static func template(_ sig: [Double], _ ts: [Double], repTimes: [Double], period: Double, points: Int = 50) -> [Double] {
        var acc = Array(repeating: 0.0, count: points)
        var n = 0
        for rt in repTimes {
            var seg: [Double] = []
            var ok = true
            for i in 0..<points {
                guard let j = nearest(ts, rt - period / 2.0 + period * Double(i) / Double(points - 1)) else { ok = false; break }
                seg.append(sig[j])
            }
            guard ok, let lo = seg.min(), let hi = seg.max(), hi - lo >= 1e-9 else { continue }
            let mid = (hi + lo) / 2.0
            for i in 0..<points { acc[i] += (seg[i] - mid) / ((hi - lo) / 2.0) }
            n += 1
        }
        if n == 0 { return [] }
        return acc.map { ($0 / Double(n) * 1000).rounded() / 1000 }
    }

    static func nearest(_ ts: [Double], _ t: Double) -> Int? {
        guard let first = ts.first, let last = ts.last, t >= first, t <= last else { return nil }
        var lo = 0
        var hi = ts.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if ts[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        let n = s.count
        if n == 0 { return 0 }
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
    }
}
