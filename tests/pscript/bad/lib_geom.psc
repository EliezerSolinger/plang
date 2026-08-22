# an import fixture (`lib_*.psc` is never a test on its own)
record Point:
    x: float
    y: float


const ORIGIN = Point(0.0, 0.0)


def area(w: float, h: float) -> float:
    return w * h


private def hidden() -> int:
    return 1
