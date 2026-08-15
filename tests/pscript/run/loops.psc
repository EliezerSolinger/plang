"""`for x in range(...)` — the same statement P already has, so the lowering is
a rename rather than a translation (65).

Iterating a COLLECTION needs the protocol of 40.3, which needs a mutable
cursor, which needs a collected `struct` — so it arrives with the collector.
"""

total = 0
for i in range(5):
    total += i
print("sum 0..4 = " + str(total))

acc = 0
for i in range(2, 8):
    acc += i
print("sum 2..7 = " + str(acc))

step = 0
for i in range(0, 10, 3):
    step += i
print("step 3 = " + str(step))

# the loop variable belongs to the loop (64.1: block scope in both languages)
found = -1
for i in range(100):
    if i * i > 50:
        found = i
        break
print("first square over 50 = " + str(found))

n = 0
for i in range(10):
    if i % 2 == 0:
        continue
    n += 1
print("odd count = " + str(n))

# nested
grid = 0
for y in range(3):
    for x in range(3):
        grid += y * 3 + x
print("grid = " + str(grid))
