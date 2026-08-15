"""`pack` / `unpack<T>` (59, 62.4): the record as bytes, and back.

The format is DEFINED — fields in declaration order, little-endian, DENSE — so
the padding a record has in memory never reaches it, which is why nothing has
to be zeroed when one is built (59.2). The size is the whole contract: an
`unpack` whose bytes are the wrong length RAISES (59.3), and there is no header
in the format to say otherwise.
"""

enum Kind:
    DIFF
    SPEC

record V3:
    x: float
    y: float
    z: float

record Sphere:
    rad: float
    pos: V3
    kind: Kind
    id: i32
    on: bool

s = Sphere(2.5, V3(1.0, -2.0, 3.5), SPEC, 42, True)
b = pack(s)
print("bytes", len(b))

r = unpack<Sphere>(b)
print(r.rad, r.pos.x, r.pos.y, r.pos.z)
print(r.kind == SPEC, r.id, r.on)

# little-endian by default, and dense: the id sits right after the enum, at
# 8 + 24 + 4
print(int(b[36]), int(b[37]), int(b[40]))

# the ORDER is a parameter, because bytes that leave the process meet other
# people's rules. LE is the default; BE is the same bytes, the other way round.
bb = pack(s, BE)
print("big", len(bb), int(bb[36]), int(bb[39]))
rb = unpack<Sphere>(bb, BE)
print(rb.rad, rb.id, rb.kind == SPEC)
same = unpack<Sphere>(pack(s, LE), LE)
print(same.pos.z)

try:
    tiny: list<u8> = [1, 2, 3]
    bad = unpack<Sphere>(tiny)
    print("unreachable", bad.id)
catch e:
    print("caught:", e.message)
