"""Rep counting engine, reference version.

Same maths as app/Clip/RepEngine.swift. Feed it samples one at a time
(accel in m/s^2 including gravity, gyro in deg/s) and it tells you when a rep
happened. Three detectors run side by side, each watching one signal:

  rotation  - gyro integrated to an angle on its main axis (curls, raises, kickbacks)
  motion    - band-passed accel projected on its main axis (gravity tilt and jolts)
  velocity  - accel integrated to speed on its main axis (presses, squats, rows, stacks)

Each one is a zig-zag peak detector with hysteresis: a rep is counted on the
way down, once the signal has risen at least T from a trough and then dropped
at least T from its peak. A pause at the top or bottom, or a rest position
that is not in the middle of the swing, does not confuse it.

Without a profile, rotation decides when the clip is clearly turning,
otherwise motion does. With a learned profile (from `learn`), the detector,
threshold and rep gap come from the teaching session: that is what makes a
taught exercise count better than a generic one.
"""
import math

RATE = 100.0
ACC_TMIN = 2.5     # m/s^2, smallest accel swing that can be a rep (generic mode)
VEL_TMIN = 0.2     # m/s, smallest velocity swing that can be a rep (generic mode)
ROT_TMIN = 20.0    # degrees, smallest rotation swing that can be a rep (generic mode)
VEL_HP = 2.0       # s, high-pass before integrating to velocity
VEL_LEAK = 2.0     # s, velocity drift leak
ANGLE_LEAK = 8.0   # s, angle drift leak
DETECTORS = ('rotation', 'motion', 'velocity')


class Axis:
    """Main direction of a 3-axis signal over the last `window` samples (power iteration)."""

    def __init__(self, window=600, prior=(1.0, 0.0, 0.0)):
        self.window = window
        self.reset(prior)

    def reset(self, prior):
        self.buf = []
        self.s = [0.0, 0.0, 0.0]
        self.p = [[0.0] * 3 for _ in range(3)]
        self.axis = list(prior)
        self.n = 0

    def push(self, v):
        self.buf.append(list(v))
        for i in range(3):
            self.s[i] += v[i]
            for j in range(3):
                self.p[i][j] += v[i] * v[j]
        if len(self.buf) > self.window:
            o = self.buf.pop(0)
            for i in range(3):
                self.s[i] -= o[i]
                for j in range(3):
                    self.p[i][j] -= o[i] * o[j]
        self.n += 1
        if self.n % 25 == 0 and len(self.buf) >= 50:
            self.update()

    def update(self):
        n = len(self.buf)
        m = [x / n for x in self.s]
        c = [[self.p[i][j] / n - m[i] * m[j] for j in range(3)] for i in range(3)]
        v = list(self.axis)
        for _ in range(10):
            w = [sum(c[r][k] * v[k] for k in range(3)) for r in range(3)]
            ln = math.sqrt(sum(x * x for x in w))
            if ln <= 1e-9:
                return
            v = [x / ln for x in w]
        if sum(v[k] * self.axis[k] for k in range(3)) < 0:
            v = [-x for x in v]
        self.axis = v

    def project(self, v):
        return sum(v[k] * self.axis[k] for k in range(3))


class ZigZag:
    """Peak detector with hysteresis. Threshold is fixed, or adapts to the
    biggest recent swing (frac * env, never below tmin)."""

    def __init__(self, tmin, frac, fixed_t=None):
        self.tmin = tmin
        self.frac = frac
        self.fixed_t = fixed_t
        self.reset()

    def reset(self):
        self.init = False
        self.extreme = 0.0
        self.trough = 0.0
        self.dir = 0
        self.env = 0.0
        self.last_swing = 0.0

    @property
    def threshold(self):
        if self.fixed_t is not None:
            return self.fixed_t
        return max(self.tmin, self.frac * self.env)

    def push(self, x, dt):
        if not self.init:
            self.init = True
            self.extreme = x
            self.trough = x
            return False
        self.env *= 1.0 - dt / 20.0
        t = self.threshold
        rep = False
        if self.dir >= 0:
            if x > self.extreme:
                self.extreme = x
            elif self.extreme - x > t:
                swing = self.extreme - self.trough
                if swing >= t:
                    rep = True
                    self.last_swing = swing
                    self.env = max(self.env, swing)
                self.dir = -1
                self.extreme = x
        else:
            if x < self.extreme:
                self.extreme = x
            elif x - self.extreme > t:
                self.trough = self.extreme
                self.dir = 1
                self.extreme = x
        return rep


class RepEngine:
    def __init__(self, profile=None):
        self.profile = profile
        self.reset()

    def reset(self):
        self.reps = 0
        self.samples = 0
        self.last_rep_t = -1e9
        self.rep_times = []
        self.rep_swings = []
        self.rep_sources = []
        # accel: band-pass for motion, faster band-pass integrated for velocity
        self.fast = None
        self.slow = None
        self.slow2 = None
        self.vel = [0.0, 0.0, 0.0]
        self.axis_a = Axis(prior=(0.0, 0.0, 1.0))
        self.axis_v = Axis(prior=(0.0, 0.0, 1.0))
        # gyro: bias, main axis, leaky angle
        self.bias = [0.0, 0.0, 0.0]
        self.theta = 0.0
        self.omega_env = 0.0
        self.axis_g = Axis(prior=(1.0, 0.0, 0.0))
        self.zz = {'rotation': ZigZag(ROT_TMIN, 0.4),
                   'motion': ZigZag(ACC_TMIN, 0.55),
                   'velocity': ZigZag(VEL_TMIN, 0.35)}
        self.min_gap = 0.6
        p = self.profile
        if p is not None:
            self.zz[p['detector']].fixed_t = p['threshold']
            self.min_gap = p['min_gap']
        self.proj = {'rotation': 0.0, 'motion': 0.0, 'velocity': 0.0}

    def push(self, t, a, g, dt=1.0 / RATE):
        """a: accel m/s^2 (3), g: gyro deg/s (3). Returns the detector name when a rep is counted."""
        self.samples += 1
        if self.fast is None:
            self.fast = list(a)
            self.slow = list(a)
            self.slow2 = list(a)
            ln = math.sqrt(sum(x * x for x in a)) or 1.0
            self.axis_a.reset([x / ln for x in a])
            self.axis_v.reset([x / ln for x in a])
        band = [0.0] * 3
        for k in range(3):
            self.fast[k] += (a[k] - self.fast[k]) * 0.08
            self.slow[k] += (a[k] - self.slow[k]) * 0.0017
            self.slow2[k] += (a[k] - self.slow2[k]) * (dt / VEL_HP)
            band[k] = self.fast[k] - self.slow[k]
            self.vel[k] += (self.fast[k] - self.slow2[k]) * dt
            self.vel[k] -= self.vel[k] * dt / VEL_LEAK
        self.axis_a.push(band)
        self.axis_v.push(self.vel)
        self.proj['motion'] = self.axis_a.project(band)
        self.proj['velocity'] = self.axis_v.project(self.vel)

        wc = [0.0] * 3
        still = all(abs(g[k] - self.bias[k]) < 20.0 for k in range(3))
        alpha = 0.004 if still else 0.0002
        for k in range(3):
            self.bias[k] += (g[k] - self.bias[k]) * alpha
            wc[k] = g[k] - self.bias[k]
        self.axis_g.push(wc)
        omega = self.axis_g.project(wc)
        self.theta += omega * dt
        self.theta -= self.theta * dt / ANGLE_LEAK
        self.proj['rotation'] = self.theta
        mag = math.sqrt(sum(x * x for x in wc))
        self.omega_env = max(mag, self.omega_env * (1.0 - dt / 3.0))

        fired = {d: self.zz[d].push(self.proj[d], dt) for d in DETECTORS}

        if self.profile is not None:
            chosen = self.profile['detector']
        elif self.zz['rotation'].env >= 45.0 or self.omega_env >= 50.0:
            chosen = 'rotation'
        else:
            chosen = 'motion'

        if fired[chosen] and t - self.last_rep_t >= self.min_gap:
            self.reps += 1
            self.last_rep_t = t
            self.rep_times.append(t)
            self.rep_swings.append(self.zz[chosen].last_swing)
            self.rep_sources.append(chosen)
            return chosen
        return None


# ---------------------------------------------------------------- learning

def _grid(lo, hi, n=30):
    return [lo * (hi / lo) ** (i / (n - 1.0)) for i in range(n)]


# threshold sweep per detector: from the smallest swing worth counting to a huge one
GRIDS = {
    'rotation': _grid(12.0, 150.0),
    'motion': _grid(0.6, 20.0),
    'velocity': _grid(0.08, 3.0),
}


def learn(samples, target_reps):
    """samples: list of (t, a(3), g(3)) from one teaching set with a known rep
    count. Returns a profile dict or None.

    Runs the engine once to get each detector's projected signal, sweeps a fixed
    threshold over it, and keeps the detector and threshold that reproduce the
    known count with the widest margin. The template is the average rep shape."""
    signals = _signals(samples)
    best = None
    for detector in DETECTORS:
        times_all, sig = signals[detector]
        grid = GRIDS[detector]
        pick = _plateau([len(_replay(times_all, sig, t, 0.4)[0]) for t in grid], target_reps)
        if pick is None:
            continue
        times, _ = _replay(times_all, sig, grid[pick[0]], 0.4)
        period = _median([b - a for a, b in zip(times, times[1:])]) if len(times) > 1 else 2.0
        gap = min(1.2, max(0.4, 0.25 * period))
        pick = _plateau([len(_replay(times_all, sig, t, gap)[0]) for t in grid], target_reps)
        if pick is None:
            continue
        centre, width, exact = pick
        threshold = grid[centre]
        times, swings = _replay(times_all, sig, threshold, gap)
        period = _median([b - a for a, b in zip(times, times[1:])]) if len(times) > 1 else 2.0
        cand = {'detector': detector, 'threshold': threshold, 'amplitude': _median(swings),
                'period': period, 'min_gap': gap, 'width': width, 'exact': exact,
                'reps_found': len(times), 'template': _template(sig, times_all, times, period),
                'reps_taught': target_reps}
        if best is None or (cand['exact'], cand['width']) > (best['exact'], best['width']):
            best = cand
    return best


def _signals(samples):
    eng = RepEngine()
    out = {d: ([], []) for d in DETECTORS}
    for (t, a, g) in samples:
        eng.push(t, a, g)
        for d in DETECTORS:
            out[d][0].append(t)
            out[d][1].append(eng.proj[d])
    return out


def _replay(times, sig, threshold, gap):
    zz = ZigZag(0.0, 0.0, fixed_t=threshold)
    last = -1e9
    rep_times, swings = [], []
    for t, x in zip(times, sig):
        if zz.push(x, 1.0 / RATE) and t - last >= gap:
            rep_times.append(t)
            swings.append(zz.last_swing)
            last = t
    return rep_times, swings


def _plateau(counts, target):
    """Middle of the widest run of thresholds that give `target` (or target +/- 1
    if nothing gives it exactly). Returns (centre, width, exact) or None."""
    for exact, ok in ((True, lambda c: c == target), (False, lambda c: abs(c - target) <= 1)):
        hits = [i for i, c in enumerate(counts) if ok(c)]
        if not hits:
            continue
        runs, start, prev = [], hits[0], hits[0]
        for i in hits[1:]:
            if i == prev + 1:
                prev = i
            else:
                runs.append((start, prev))
                start = prev = i
        runs.append((start, prev))
        s, e = max(runs, key=lambda r: r[1] - r[0])
        return (s + e) // 2, e - s + 1, exact
    return None


def _template(sig, ts, rep_times, period, points=50):
    """Average one-rep shape, from half a period before each rep to half after,
    resampled to `points` and scaled to -1..1."""
    acc = [0.0] * points
    n = 0
    for rt in rep_times:
        seg = []
        for i in range(points):
            j = _nearest(ts, rt - period / 2.0 + period * i / (points - 1))
            if j is None:
                seg = None
                break
            seg.append(sig[j])
        if seg is None:
            continue
        lo, hi = min(seg), max(seg)
        if hi - lo < 1e-9:
            continue
        mid = (hi + lo) / 2.0
        for i in range(points):
            acc[i] += (seg[i] - mid) / ((hi - lo) / 2.0)
        n += 1
    if n == 0:
        return []
    return [round(x / n, 3) for x in acc]


def _nearest(ts, t):
    if t < ts[0] or t > ts[-1]:
        return None
    lo, hi = 0, len(ts) - 1
    while lo < hi:
        mid = (lo + hi) // 2
        if ts[mid] < t:
            lo = mid + 1
        else:
            hi = mid
    return lo


def _median(xs):
    s = sorted(xs)
    n = len(s)
    if n == 0:
        return 0.0
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2.0
