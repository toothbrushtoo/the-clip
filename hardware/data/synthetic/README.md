# Synthetic recordings

Made by `tools/synth_curls.py`, not recorded. Each is 20 curls with the clip's gyro and
accelerometer simulated from an angle profile (noise and gyro bias added), so the gyro part of
the rep engine can be checked before real clip recordings exist. Columns: t, ax, ay, az (m/s²),
gx, gy, gz (°/s), same as the files the app exports.

| file | what |
|---|---|
| synth_curl_20 | normal pace, 3 s per rep |
| synth_curl_flipped_20 | clip mounted the other way round, rotating about another axis |
| synth_curl_holdtop_20 | 2 s hold at the top, 3 s rest at the bottom |
| synth_curl_slow_20 | 4 s up, 4 s down |
