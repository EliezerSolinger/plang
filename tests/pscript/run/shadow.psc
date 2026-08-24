"""Shadowing the prelude (68.3).

The program's own names WIN over the prelude's — the Python rule for builtins —
but not in silence: the compiler warns (-Wshadow-prelude). And the collision
drops only WHAT collided: declaring `TYPE` below takes `Category.TYPE` away,
and its siblings stay — `e.category == INDEX` still means the category.
"""

# this shadows the prelude's Category.TYPE (warning expected at build)
TYPE = "my own name now"


def classify(n: int) -> str:
    return TYPE


try:
    empty: List<int> = []
    print(empty[2])
catch e:
    # INDEX survived the sibling's shadowing
    print("still a category:", e.category == INDEX)

print("mine:", classify(1))
