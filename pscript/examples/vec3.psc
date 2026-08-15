"""3D vector algebra for smallpt.

`Vec` is a record — a VALUE type (52.1/56): lives on the stack, copies on
assignment, no header. The radiance loop creates millions of these per second
and allocates nothing.

Operations are METHODS on the record (57.1, revising 21.3): a method on a
value type takes `in self` — reads without copying and never mutates the
receiver; producing a new value returns one. Operator overloading stays out
(52.2); method chaining is the algebra idiom: `x.sub(c).norm()`.
"""

include <math.h>            # sqrt straight from libc: pointer-free signature = safe (45.5)


record Vec:
    """Point/direction/color. Record: primitives only (21.1)."""
    x: float
    y: float
    z: float

    def add(in self, b: Vec) -> Vec:
        return Vec(self.x + b.x, self.y + b.y, self.z + b.z)

    def sub(in self, b: Vec) -> Vec:
        return Vec(self.x - b.x, self.y - b.y, self.z - b.z)

    def scale(in self, s: float) -> Vec:
        return Vec(self.x * s, self.y * s, self.z * s)

    def mul(in self, b: Vec) -> Vec:
        """Component-wise product (color filtering)."""
        return Vec(self.x * b.x, self.y * b.y, self.z * b.z)

    def dot(in self, b: Vec) -> float:
        return self.x * b.x + self.y * b.y + self.z * b.z

    def cross(in self, b: Vec) -> Vec:
        return Vec(self.y * b.z - self.z * b.y,
                   self.z * b.x - self.x * b.z,
                   self.x * b.y - self.y * b.x)

    def norm(in self) -> Vec:
        return self.scale(1.0 / sqrt(len2(self)))

    def clamped(in self) -> Vec:
        return Vec(clamp01(self.x), clamp01(self.y), clamp01(self.z))


const BLACK = Vec(0.0, 0.0, 0.0)


def clamp01(x: float) -> float:
    if x < 0.0:
        return 0.0
    if x > 1.0:
        return 1.0
    return x


# static = module-private (44.4): `import vec3` does not see this
static def len2(in v: Vec) -> float:
    return v.dot(v)
