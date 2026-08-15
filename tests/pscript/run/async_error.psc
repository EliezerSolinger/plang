"""An error crosses an await (19.3).

A task that raises does not take the program with it: the task CAPTURES the
error and finishes failed, and the error is raised again where it is awaited.
That is what makes `try` around an `await` mean what it looks like.
"""


async def divide(a: int, b: int) -> int:
    return a // b


async def chain(a: int, b: int) -> int:
    v = await divide(a, b)
    return v + 1


try:
    x = await chain(10, 0)
    print(f"unreachable {x}")
catch e:
    print(f"caught: {e.message}")

ok = await chain(10, 2)
print(f"ok {ok}")
