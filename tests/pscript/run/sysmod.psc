"""`sys` (48.3): the program's own surroundings.

The one module with no file behind it — what it names is what only the runtime
can answer: what the program was called with, what the environment says, what
time it is, and how to stop.
"""

import sys

args = sys.argv
print(f"argv {len(args) > 0}")

env = sys.env
print(f"env has PATH {'PATH' in env}")
print(f"home is a string {len(env.get('HOME', '?')) > 0}")

t0 = sys.time()
i = 0
total = 0
while i < 100000:
    total += i
    i += 1
t1 = sys.time()
print(f"sum {total} took a moment {t1 >= t0}")
