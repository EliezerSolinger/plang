"""`sorted(xs, key=f)` (28.4): ordered by something computed, not by the value.

The key of each element is computed ONCE — n calls, not n log n — and what gets
sorted is the pairing. The adapter that lets the runtime call back into the
program is written by the compiler, because the call site is the only place that
knows what the elements are; the runtime only ever moves bytes.
"""


record Stat:
    wid: int
    seconds: float


stats: List<Stat> = [Stat(0, 3.5), Stat(1, 1.25), Stat(2, 9.0), Stat(3, 0.5)]

by_time = sorted(stats, key=lambda s: s.seconds)
print("fastest", by_time[0].wid, "slowest", by_time[3].wid)
print("original untouched", stats[0].wid, stats[0].seconds)

by_id_desc = sorted(stats, key=lambda s: 0.0 - float(s.wid))
print("by id desc", by_id_desc[0].wid, by_id_desc[3].wid)

# a named function works as a key too — a function IS a value (28.1)
def seconds_of(s: Stat) -> float:
    return s.seconds


again = sorted(stats, key=seconds_of)
print("named key", again[0].wid, again[1].wid)

nums: List<int> = [5, 3, 9]
print("plain", sorted(nums)[0], sorted(nums)[2])
