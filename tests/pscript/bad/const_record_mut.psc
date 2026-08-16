# a record crosses to P by REFERENCE, and only a module-level `const` may (72.6)
import "pmod_geom.ph"

r = Rect(2, 3)
print(rect_area(r))
