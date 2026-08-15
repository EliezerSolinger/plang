struct Pt:
    x: i32
def f(p: *Pt) -> i32:
    if p == None:
        return p->x
    return 0
