import sys, numpy as np, pandas as pd

def load(path):
    df = pd.read_csv(path)
    df.columns = [c.split(' (')[0].lower().replace('acceleration ', 'a') for c in df.columns]
    return df['time'].to_numpy(), df[['ax', 'ay', 'az']].to_numpy()

def count_reps(t, a, min_gap_s=0.6, threshold=0.8):
    g = a.mean(axis=0)
    g /= np.linalg.norm(g)
    along = a @ g - np.linalg.norm(a.mean(axis=0))
    dt = np.median(np.diff(t))
    w = max(1, int(0.15 / dt))
    along = np.convolve(along, np.ones(w) / w, mode='same')
    v = np.cumsum(along) * dt
    W = int(2 / dt)
    v -= np.convolve(v, np.ones(W) / W, mode='same')
    reps, last, armed = 0, -1e9, False
    for i in range(len(v)):
        if v[i] > threshold and not armed:
            armed = True
        elif v[i] < -threshold and armed and t[i] - last > min_gap_s:
            reps += 1; last = t[i]; armed = False
    return reps, v

if __name__ == '__main__':
    for path in sys.argv[1:]:
        t, a = load(path)
        reps, v = count_reps(t, a)
        print(path, '->', reps, 'reps')
