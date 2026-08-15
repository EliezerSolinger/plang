# writing a `shared` from a function without `global` would make a LOCAL, and
# the shared one would never change — silently
shared total: int = 0


def add(n: int) -> int:
    total = n
    return total
