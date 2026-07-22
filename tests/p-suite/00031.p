def zero() -> int:
    return 0

def one() -> int:
    return 1

def main() -> int:
    x: int
    y: int

    x = zero()
    x += 1
    y = x
    if x != 1:
        return 1
    if y != 1:
        return 1

    x = one()
    x -= 1
    y = x
    if x != 0:
        return 1
    if y != 0:
        return 1

    x = zero()
    y = x
    x += 1
    if x != 1:
        return 1
    if y != 0:
        return 1

    x = one()
    y = x
    x -= 1
    if x != 0:
        return 1
    if y != 1:
        return 1

    return 0
