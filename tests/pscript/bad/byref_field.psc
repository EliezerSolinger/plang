record Vec:
    x: float

struct Holder:
    v: Vec

def scale(ref v: Vec):
    v.x *= 2.0

h = Holder(Vec(1.0))
scale(ref h.v)
