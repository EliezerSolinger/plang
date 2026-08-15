# `*xs` spreads into the collecting parameter, and nothing follows it (44.2)
def f(*xs: list<int>) -> int:
    return len(xs)
ys = [1, 2]
n = f(*ys, 3)
