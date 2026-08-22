"""An import fixture (`lib_*.psc` is never a program on its own): a module is a
set of DEFINITIONS, and this one also proves that a name is only visible where
it was imported — `secret` below is never imported by anyone."""

record Vec2:
    x: float
    y: float

    def add(in self, b: Vec2) -> Vec2:
        return Vec2(self.x + b.x, self.y + b.y)


const ORIGIN = Vec2(0.0, 0.0)


def area(w: float, h: float) -> float:
    return w * h


# private to this module (44.4) — nobody outside may name it, and the module's
# own code still calls it, which is what makes the rule mean something
private def secret() -> int:
    return 42


def with_secret() -> int:
    return secret() + 1
