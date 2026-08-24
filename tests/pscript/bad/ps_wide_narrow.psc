# narrowing goes to a SIGNATURE, not to another bare `def` (29.4)
def f(a: int) -> int:
    return a
t: Dict<str, def> = {}
t["f"] = f
g = t["f"] as def
