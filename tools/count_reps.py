import sys, os, numpy as np, pandas as pd

TRUE = {'curl_test_3': 3, 'curl_normal_7': 7, 'junk_walk': 0, 'sideways_10': 10}

def load(path):
    df = pd.read_csv(path)
    df.columns = [c.split(' (')[0].lower().replace('acceleration ', 'a') for c in df.columns]
    return df['time'].to_numpy(), df[['ax', 'ay', 'az']].to_numpy()

def count_reps(t, a, min_gap_s=0.6, threshold=0.8, min_swing=1.5):
    g = a.mean(axis=0)
    g /= np.linalg.norm(g)
    along = a @ g - np.linalg.norm(a.mean(axis=0))
    dt = np.median(np.diff(t))
    w = max(1, int(0.15 / dt))
    along = np.convolve(along, np.ones(w) / w, mode='same')
    v = np.cumsum(along) * dt
    W = int(2 / dt)
    v -= np.convolve(v, np.ones(W) / W, mode='same')
    reps, last, armed, peak = 0, -1e9, False, 0.0
    for i in range(len(v)):
        if v[i] > threshold and not armed:
            armed, peak = True, v[i]
        elif armed and v[i] > peak:
            peak = v[i]
        elif v[i] < -threshold and armed and t[i] - last > min_gap_s:
            if peak - v[i] > min_swing:
                reps += 1; last = t[i]
            armed = False
    return reps, v

if __name__ == '__main__':
    for thr in (0.4, 0.6, 0.8, 1.0):
        print(f'--- threshold {thr}')
        for path in sys.argv[1:]:
            name = os.path.splitext(os.path.basename(path))[0]
            t, a = load(path)
            reps, v = count_reps(t, a, threshold=thr)
            print(f'{name:16s} true {TRUE.get(name, "?"):>2}  counted {reps:>2}')
