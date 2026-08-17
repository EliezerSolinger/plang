"""The loop drains at the end, and `await` always yields (77.3/78.4).

Two rules from JS that were missing, and now hold here:

  * a task NOBODY awaits used to finish halfway — the program left and it was
    abandoned. Now, on reaching the end, the scheduler runs until there is
    nothing ready, no deadline and no I/O in flight. That is what makes a loose
    `spawn` behave the way everyone expects;
  * `await` of a value that was ALREADY there yielded to nobody and carried
    straight on. Now the task goes to the back of the queue first — without
    that, a loop of awaits that always finds its answer ready would never let
    another one run, which is exactly what happens in a server with a fast
    client.
"""

async def orphan() -> int:
    print("orphan: started")
    await sleep(0.01)
    print("orphan: finished")
    return 1


async def ready(tag: str) -> int:
    print(tag)
    return 7


async def counter(n: int) -> int:
    # none of these awaits really waits: every one finds its answer ready.
    # Because each yields, the other task interleaves instead of being shut out
    total = 0
    for i in range(n):
        total += await ready("count " + str(i))
    return total


async def intruder() -> int:
    for i in range(3):
        print("intruder " + str(i))
        await ready("(the intruder's ready one)")
    return 0


loose = orphan()
a = counter(3)
b = intruder()
print("summed", await a)
print("the intruder gave", await b)
print("end of main — whatever comes after this is the drain")
