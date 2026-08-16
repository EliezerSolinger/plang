"""A `const` record crossing to P by reference (72.6).

The 45.5 boundary lets scalars across because a scalar is a copy and a copy
cannot alias anything. A record is bytes too, but copying it into a call would
mean C's struct-passing ABI — so what crosses instead is its ADDRESS, and the
address is only safe under two conditions the compiler can check: the P side
takes it `in` (a const pointer: it can read and cannot write), and the
argument is a module-level `const`, which lives in C's file scope and so has
an address that is stable and bytes that nothing changes.

The type itself is declared in the P header and imported (75.3): one
declaration, so there is no way for the two languages to disagree about the
layout of something they both name.
"""

import "pmod_geom.ph"

const SMALL: Rect = Rect(3, 4)
const WIDE: Rect = Rect(10, 1)

print("area", rect_area(SMALL))
print("area", rect_area(WIDE))
print("wider", rect_wider(WIDE, SMALL), rect_wider(SMALL, WIDE))
print("fields", SMALL.w, SMALL.h)
