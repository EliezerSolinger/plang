"""`record` in pscript: a VALUE type (52.1/56), pure bytes (58.2).

It lowers to P's `record`, which the compiler already checks and already knows
how to compare and construct (65.1) — so this file is also the proof that
taking a feature to P makes the lowering smaller, not bigger.
"""

record Vec:
    """Point, direction or colour. No header, no allocation, copies on assignment."""
    x: float
    y: float

    def add(in self, b: Vec) -> Vec:
        return Vec(self.x + b.x, self.y + b.y)

    def scale(in self, s: float) -> Vec:
        return Vec(self.x * s, self.y * s)

    def dot(in self, b: Vec) -> float:
        return self.x * b.x + self.y * b.y


record Ray:
    org: Vec           # a record inside a record is still pure bytes
    dir: Vec


def show(label: str, v: Vec):
    print(label + " (" + str(v.x) + ", " + str(v.y) + ")")


a = Vec(1.0, 2.0)
b = Vec(y=4.0, x=3.0)          # named form names every field
show("a", a)
show("b", b)
show("a+b", a.add(b))          # chaining is the algebra idiom (52.2 keeps
show("scaled", a.add(b).scale(2.0))   # operator overloading out)
print("dot " + str(a.dot(b)))

# value semantics: assignment COPIES, so touching the copy leaves the original
c = a
c = Vec(9.0, 9.0)
show("a after", a)

# `==` compares content, field by field (inherited from P's record)
print(str(a == Vec(1.0, 2.0)))
print(str(a == b))

r = Ray(Vec(0.0, 0.0), Vec(1.0, 0.0))
show("origin", r.org)
show("direction", r.dir)
