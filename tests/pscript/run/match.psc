"""`match` and `enum`, both inherited from P (65).

Over an enum the match is EXHAUSTIVE without `case _` (29.2): adding an
enumerator turns every match into a compile error instead of a silent
fallthrough. P's own -Wswitch-enum then checks the same thing on the lowered
code, so the guarantee is stated twice and verified twice.

String match comes from P as well.
"""

enum Shade:
    DARK = 0
    LIGHT
    NEON


record Sphere:
    radius: float
    kind: Shade


def name_of(s: Shade) -> str:
    match s:
        case DARK:
            return "dark"
        case LIGHT:
            return "light"
        case NEON:
            return "neon"
    return "?"


def bounce(s: Shade) -> int:
    match s:
        case DARK, LIGHT:
            return 1
        case _:
            return 3


print(name_of(DARK) + " " + name_of(LIGHT) + " " + name_of(NEON))
print(str(bounce(DARK)) + str(bounce(LIGHT)) + str(bounce(NEON)))

ball = Sphere(1.5, NEON)
print("ball is " + name_of(ball.kind))

# strings
def kind_of(flag: str) -> int:
    match flag:
        case "--dim":
            return 1
        case "--out", "--output":
            return 2
        case _:
            return 0


print(str(kind_of("--dim")) + str(kind_of("--out")) + str(kind_of("--output")) + str(kind_of("zzz")))

# ints
def small(n: int) -> str:
    match n:
        case 0:
            return "zero"
        case 1, 2, 3:
            return "few"
        case _:
            return "many"


print(small(0) + " " + small(2) + " " + small(99))
