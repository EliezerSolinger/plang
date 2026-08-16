# pmod_geom.ph — a P module whose TYPE crosses to pscript (72.6).
#
# The record is declared HERE, in P, and the pscript program that imports this
# header uses it. One declaration, so the two languages cannot disagree about
# the layout — which is the thing that makes passing one by reference safe.
#
# The parameter is `in`, which in P is a const pointer: the other side reads
# and cannot write.
record Rect:
    w: i32
    h: i32

def rect_area(in r: Rect) -> i64
def rect_wider(in a: Rect, in b: Rect) -> bool
