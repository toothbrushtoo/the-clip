# phyphox recording

Phone accelerometer data recorded with the phyphox app ("Acceleration with g") ~100hz) before the real  board arrived. Used to build and test the rep counter. Columns: Time (s), Acceleration x/y/z (m/s^2). Absolute acceleration (m/s^2).

## Files

| file | true reps | duration | notes|
|---|---|---|---|
| curl_test_3.csv | 3 | 8s | first test, trimmed from a 91 s recording that was mostly the phone sitting still |
| curl_normal_10.csv | 7 | 35s | counted 7 outloud showed 7 clean cycles, 4.1 s apart, each with a double hump. |
| junk_walk.csv | 0 | 28 s | walking around holding the phone. Steps at ~1.5hz. Must count 0. |
| sideways_10.csv | 10 | 41 s | phone rotated 90 degrees, 10 curls, 3.4s per rep. Orientation test. Some small wiggles after 35s. |

## Results so far (counter v0, tools/count_reps.py)

| file | true | counted (thr 0.8) | counted (thr 0.5) |
|---|---|---|---|
| curl_normal_7.csv | 7 | 0 | 6 |
| junk_walk.csv | 0 | 0 | 0 |
| sideways_10.csv | 10 | 10 | 11 |

## What i learned

- A still phone has noise of about 0.01 m/s^2. A curl swings 2 to 5 m/s^2. Easy to tell apart.
- Walking never gets the velocity past +/-0.3 m/s. A curl gets past +/-1. So the threshold on velocity is the junk filter.
- The gravity trick works: rotating the phone 90 degrees moved gravity to a different axis and the counter still found all 10 reps with no code change.

## To do
- Re-record curl_normal with a rigid mount
- Add the minimum-swing rule so the small wiggles at the end of sideways_10 dont count

## Counter v0.1 results (threshold sweep, min swing 1.5)

| threshold | curl_test_3 (3) | curl_normal_7 (7) | junk_walk (0) | sideways_10 (10) |
|---|---|---|---|---|
| 0.4 | 2 | 0 | 0 | 3 |
| 0.6 | 2 | 0 | 0 | 7 |
| 0.8 | 2 | 0 | 0 | 10 |
| 1.0 | 2 | 0 | 0 | 3 |

Chose threshold 0.8, min swing 1.5. Sideways and walking are perfect.
curl_test_3 misses the first rep (file starts mid-motion).
curl_normal_7 counts 0: its swings are smaller than the min swing rule,
which supports the loose-phone theory. Re-record with a rigid mount.
