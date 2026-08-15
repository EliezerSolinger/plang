"""`gather` (35.3): composition over a list of tasks.

Calling an `async def` already STARTS it, so a list of calls is a list of things
already running; `gather` waits for all of them and hands the results back in
the order the TASKS were given — not the order they finished. A program that has
to care which finished first is a program that should not have used `gather`.
"""


async def square(n: int) -> int:
    return n * n


async def label(n: int) -> str:
    return f"#{n}"


ts: list<Task<int>> = []
i = 1
while i <= 5:
    ts.append(square(i))
    i += 1

nums = await gather(ts)
print("squares", len(nums), nums[0], nums[4])

ls: list<Task<str>> = [label(1), label(2)]
names = await gather(ls)
print("labels", names[0], names[1])
