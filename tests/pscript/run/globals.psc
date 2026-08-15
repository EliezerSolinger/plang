"""Module variables, and the block scope both languages share (64.1).

A name born inside a block dies with it, as in P and C. The Python if/else
idiom is still available, spelled with the opt-in P already had: `nonlocal`
says the next assignment declares at the FUNCTION's scope.
"""

const LIMIT = 10
counter = 0


def bump(by: int) -> int:
    return by + 1


counter = bump(counter)
counter = bump(counter)
print("counter " + str(counter))
print("limit " + str(LIMIT))

# `nonlocal` lifts the name out of the branches that assign it
nonlocal label
if counter < LIMIT:
    label = "small"
else:
    label = "big"
print(label)


# A top-level declaration is a MODULE variable, as in Python: every function
# sees it, and assigning it from inside one is opted into with `global` (55.3).
rng_state: int = 7
history: list<int> = []


def next_rand() -> int:
    global rng_state
    rng_state = (rng_state * 31 + 17) % 1000
    history.append(rng_state)
    return rng_state


print(f"rand {next_rand()} {next_rand()} {next_rand()}")
print(f"state {rng_state} history {len(history)} {history[0]}")
