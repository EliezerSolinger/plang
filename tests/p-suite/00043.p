struct Nest:
    y: int
    z: int

struct S:
    x: int
    nest: Nest

def main() -> int:
    v: S
    v.x = 1
    v.nest.y = 2
    v.nest.z = 3
    if v.x + v.nest.y + v.nest.z != 6:
        return 1
    return 0
