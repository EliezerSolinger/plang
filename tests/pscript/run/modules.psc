"""Modules with real namespaces (41.3).

Python's visibility rule, resolved at compile time: a name from another module
is reached by its QUALIFIER or brought over with `from`, and never by merely
existing. Both fixtures declare `area`; each call below picks one, and nothing
here can see `lib_geom.secret`, which no line imports.
"""

import lib_geom
import lib_shapes as shapes
from lib_geom import Vec2, area
from lib_geom import ORIGIN as ZERO

a = lib_geom.Vec2(1.0, 2.0)
b = Vec2(3.0, 4.0)
c = a.add(b)
print(f"sum ({c.x}, {c.y})")

# three spellings, two different functions
print(f"area {lib_geom.area(3.0, 4.0)} / {area(2.0, 5.0)} / {shapes.area(1.0)}")
print(f"unit {shapes.unit_area()}")
print(f"origin ({ZERO.x}, {ZERO.y})")
print(f"private {lib_geom.with_secret()}")

k: shapes.Kind = shapes.FLAT
print(f"kind {k == shapes.FLAT}")
