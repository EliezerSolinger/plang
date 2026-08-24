# a bare `def` cannot be called: narrow it first (29.4)
def f(a: int) -> int:
    return a
t: Dict<str, def> = {}
t["f"] = f
n = t["f"](1)
