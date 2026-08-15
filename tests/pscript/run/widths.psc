"""Exact widths (68.2), the whole ladder: `i8`…`u64` and `f32` as real types.

The rules, each on show below:
  * a LITERAL adapts to the width the context asks, range checked at compile
    time — `x: u8 = 300` does not build;
  * a value WIDENS when nothing can be lost (i8→int, u8→u32, u32→int);
    everything else converts BY NAME, and the conversions check — out of range
    RAISES, in the same voice as every other overflow (53.1);
  * arithmetic needs a lossless COMMON type; overflow of a width raises;
    `%+ %- %*` are the intentional wrap, masked to the width;
  * u64 is the one integer i64 cannot carry: its own checked ops, its own
    formatter, and `>>` on it is LOGICAL by construction — which is what the
    xorshift RNG needed all along.
"""

# literals adapt; arithmetic stays in the width and CHECKS
a: u8 = 200
b: u8 = 55
print("u8", a + b)
try:
    c: u8 = a + 56
    print("unreachable", c)
catch e:
    print("caught:", e.message)

# the wrap is intentional and masked to the width
print("wrap", a %+ 56, (-128 if False else 0) %- 1)
w8: i8 = 127
print("i8 wrap", w8 %+ 1)

# widening is free; narrowing has a name and a check
small: i16 = -1234
wide: int = small
print("widened", wide)
back: i16 = i16(wide)
print("named", back)
try:
    tiny: i8 = i8(wide)
    print("unreachable", tiny)
catch e:
    print("caught:", e.message)

# u64: the RNG's home. >> is logical, %* wraps, and the value prints unsigned.
x: u64 = 88172645463325252
x ^= x >> 12
x ^= x << 25
x ^= x >> 27
r: u64 = x %* 2685821657736338717
print("rng", r)
print("as float", float(r) * (1.0 / 18446744073709551616.0) < 1.0)

# the crossings check
big: u64 = 18446744073709551615
try:
    n = int(big)
    print("unreachable", n)
catch e:
    print("caught:", e.message)
print("down", int(u64(42)))
try:
    neg: u64 = u64(0 - 1)
    print("unreachable", neg)
catch e:
    print("caught:", e.message)

# f32 is storage; float is the arithmetic
g: f32 = 2.5
h: float = g
print("f32", h + 0.25, f32(1.0 / 3.0) != 0.0)

# a record of exact widths is a LAYOUT — the interop case 65.14 named
record Pixel:
    r: u8
    g: u8
    b: u8
    a: u8


p = Pixel(255, 128, 0, 255)
print("pixel", p.r, p.g, p.b, p.a)
