import sys, os, pandas as pd, matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

os.makedirs('hardware/data/phyphox/plots', exist_ok=True)
for path in sys.argv[1:]:
    df = pd.read_csv(path)
    df.columns = [c.split(' (')[0].lower().replace('acceleration ', 'a') for c in df.columns]
    plt.figure(figsize=(11, 4))
    for axis in ['ax', 'ay', 'az']:
        plt.plot(df['time'], df[axis], label=axis, lw=0.8)
    plt.xlabel('s'); plt.ylabel('m/s^2'); plt.legend(); plt.title(path)
    name = os.path.splitext(os.path.basename(path))[0]
    out = f'hardware/data/phyphox/plots/{name}.png'
    plt.savefig(out, dpi=130); plt.close()
    print('saved', out)
