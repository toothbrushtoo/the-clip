import sys, pandas as pd, matplotlib.pyplot as plt

df = pd.read_csv(sys.argv[1])
df.columns = [c.split(' (')[0].lower().replace('acceleration ', 'a') for c in df.columns]
t = df['time']
for axis in ['ax', 'ay', 'az']:
    plt.plot(t, df[axis], label=axis)
plt.xlabel('s'); plt.ylabel('m/s^2'); plt.legend(); plt.title(sys.argv[1])
plt.show()
