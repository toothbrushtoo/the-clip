// Checks the Swift rep engine against the Python reference (tools/rep_engine.py).
// usage: repcheck <csv dir> <reference.json>
// Runs every recording through the generic engine and, for labelled files, through learn()
// and the learned profile, and compares counts and learned numbers to the reference.
import Foundation

struct Ref: Decodable {
    let file: String
    let `true`: Int
    let generic: Int
    let detector: String?
    let threshold: Double?
    let period: Double?
    let gap: Double?
    let width: Int?
    let selfCount: Int?

    enum CodingKeys: String, CodingKey {
        case file, `true`, generic, detector, threshold, period, gap, width
        case selfCount = "self"
    }
}

func loadCSV(_ path: String) -> [MotionSample] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    var out: [MotionSample] = []
    for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).dropFirst() {
        let cols = line.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard cols.count >= 4, let t = cols[0], let ax = cols[1], let ay = cols[2], let az = cols[3] else { continue }
        out.append(MotionSample(t: t, ax: ax, ay: ay, az: az, gx: 0, gy: 0, gz: 0))
    }
    return out
}

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: repcheck <csv dir> <reference.json>"); exit(2) }
let dir = args[1]
let refs = try! JSONDecoder().decode([Ref].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
var failures = 0
var genericError = 0
print(String(format: "%-22@ %5@ %8@ %6@ %10@ %6@ %6@", "file", "true", "generic", "ref", "learned", "self", "ref"))
for r in refs {
    let samples = loadCSV("\(dir)/\(r.file).csv")
    guard !samples.isEmpty else { print("\(r.file): missing"); failures += 1; continue }
    let engine = RepEngine()
    for s in samples { engine.push(s) }
    var line = String(format: "%-22@ %5d %8d %6d", r.file, r.true, engine.reps, r.generic)
    if engine.reps != r.generic { line += "  <-- generic mismatch"; failures += 1 }
    genericError += abs(engine.reps - r.true)
    if r.true > 0 {
        if let p = ProfileLearner.learn(samples: samples, targetReps: r.true) {
            let e2 = RepEngine(profile: p)
            for s in samples { e2.push(s) }
            line += String(format: " %10@ %6d %6d", p.detector.rawValue, e2.reps, r.selfCount ?? -1)
            if p.detector.rawValue != r.detector { line += "  <-- detector mismatch"; failures += 1 }
            if let rt = r.threshold, abs(p.threshold - rt) > 1e-3 * max(1, rt) { line += String(format: "  <-- threshold %.4f vs %.4f", p.threshold, rt); failures += 1 }
            if let rg = r.gap, abs(p.minGap - rg) > 2e-3 { line += "  <-- gap mismatch"; failures += 1 }
            if let rw = r.width, p.quality != rw { line += "  <-- width \(p.quality) vs \(rw)"; failures += 1 }
            if e2.reps != r.selfCount { line += "  <-- self count mismatch"; failures += 1 }
        } else {
            line += "  <-- learn failed"; failures += 1
        }
    }
    print(line)
}
print("generic total error \(genericError), mismatches \(failures)")
exit(failures == 0 ? 0 : 1)
