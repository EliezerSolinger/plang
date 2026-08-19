"""Arithmetic, against the Python that the design keeps naming.

Every line here is a rule the document states as "as Python does" and that was,
until this file existed, verified once by hand: `7/2` is a float even between
ints (39.1), `//` floors toward negative infinity, `%` takes the sign of the
DIVISOR, `**` is a real power, and the repr of a float is the shortest text that
reads back identical.
"""

print(7 / 2)
print(-7 / 2)
print(7 // 2)
print(-7 // 2)
print(7 % 3)
print(-7 % 3)
print(7 % -3)
print(-7 % -3)
print(2 ** 10)
print(2 ** 0)
print(-2 ** 2 if False else 0 - 2 ** 2)
print(0.1 + 0.2)
print(1 / 3)
print(1e16 + 1.0)
print(2.0 ** 0.5)
print(float(1))
print(int(2.9))
print(int(-2.9))
print(abs(-5), abs(5))
print(min(3, 7), max(3, 7))
print(10 // 3, 10 % 3, -10 // 3, -10 % 3)
print(1000000007 * 1000000009)
print(5 // -2, 5 % -2)
