include <stdio.h>
# `as geo` (42.4) is ADDITIVE: the qualified spelling appears below alongside
# the flat one, from this single import, and both name the same symbols.
import "geometria.ph" as geo

def main() -> int:
    a: geo.Point          # qualified type
    a.x = 0
    a.y = 0
    b: Point              # flat type — the alias took nothing away
    b.x = 3
    b.y = 4
    a.move(1, 1)          # method call on the value: still a method call
    printf("%d\n", geo.dist(&a, &b))   # qualified call
    printf("%d\n", dist(&a, &b))       # flat call
    return 0
