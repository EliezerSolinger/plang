g: int

def effect() -> int:
    g = 1
    return 1

def main() -> int:
    x: int

    g = 0
    x = 0
    if x and effect():
        return 1
    if g:
        return 2
    x = 1
    if x and effect():
        if g != 1:
            return 3
    else:
        return 4
    g = 0
    x = 1
    if x or effect():
        if g:
            return 5
    else:
        return 6
    x = 0
    if x or effect():
        if g != 1:
            return 7
    else:
        return 8
    return 0
