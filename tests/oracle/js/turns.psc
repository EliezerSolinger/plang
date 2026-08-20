"""Whose turn it is — the part of the model that only another runtime can check.

test262 measures this with microtask counters and `Promise.resolve().then()`
chains; we measure it with the tasks and the yields we actually have. What is
being asked is the same in both places: does a yield give the OTHER tasks a
turn, in what order do several ready tasks run, and does a task started inside
another task begin before its parent's next yield.

A line here that differs between the two runtimes is not a bug in a test — it
is our scheduler making a promise JS does not, and it belongs in the design
document before it belongs in a fix.
"""

log: list<str> = []


async def chain(name: str, n: int) -> int:
    for i in range(n):
        log.append(name + str(i))
        await sleep(0)
    return n


async def child(name: str) -> int:
    log.append(name + "-started")
    await sleep(0)
    log.append(name + "-finished")
    return 0


async def parent() -> int:
    log.append("parent-before")
    c = child("kid")            # 35.1: creating it RUNS it up to its first await
    log.append("parent-after")
    await c
    log.append("parent-joined")
    return 0


# The cursor lives in a one-element list because a module-level `int` is not
# assignable from inside a function here, and the JS next door uses a plain
# `let` for the same job — what is compared is the lines, not the cell.
mark: list<int> = [0]


def show(label: str):
    out = ""
    i = mark[0]
    while i < len(log):
        out += log[i] + " "
        i += 1
    mark[0] = len(log)
    print(label, out)


async def main_task() -> int:
    # 1. Three ready tasks take turns, one step each, in the order they were
    #    created — a yield is a turn for everybody else, not just for one.
    await gather([chain("a", 3), chain("b", 3), chain("c", 3)])
    show("fair")

    # 2. A task made INSIDE a task is already running when the maker's next
    #    line executes, and the maker's await is what lets it finish.
    await parent()
    show("nested")

    # 3. `gather` of `gather`s keeps each list's order, and the outer one keeps
    #    the order of the inner ones.
    inner1 = gather([chain("x", 1), chain("y", 1)])
    inner2 = gather([chain("z", 1)])
    await gather([inner1, inner2])
    show("nested gather")

    # 4. A task that finished long before anyone awaited it still hands over
    #    its value, and awaiting it still costs a turn (78.4).
    t = chain("done", 1)
    await sleep(0.02)
    log.append("awaiting-late")
    await t
    log.append("awaited-late")
    show("late")
    return 0


rc = await main_task()
