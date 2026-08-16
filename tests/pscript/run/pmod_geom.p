import "pmod_geom.ph"

def rect_area(in r: Rect) -> i64:
    return i64(r.w) * i64(r.h)

def rect_wider(in a: Rect, in b: Rect) -> bool:
    return a.w > b.w
