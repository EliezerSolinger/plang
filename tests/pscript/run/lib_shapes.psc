"""A second import fixture that declares `area` TOO. Two modules may each have
one: after the rename they are different global names, which is the whole point
of namespaces being real (41.3)."""

import lib_geom

enum Kind:
    ROUND
    FLAT


def area(r: float) -> float:
    return 3.14159 * r * r


def unit_area() -> float:
    return lib_geom.area(1.0, 1.0)
