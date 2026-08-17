"""Asynchronous files: the thread pool (76.1/76.2/76.3).

A socket has a real non-blocking mode and lives in the `poll` that 74.1 already
built. A FILE does not — `read(2)` blocks, always — and that is why it needs a
thread. The split is libuv's, and it is not a matter of taste: it is what the
operating system offers.

So every file operation became a TASK: the call describes the work, hands it to
the pool and returns at once; the waiting happens in the scheduler, next to the
clock and the message queues. A pool thread never touches anyone's heap — it
works on malloc'd bytes and hands malloc'd bytes back, and the value is built
in the collected heap by the scheduler of the context that asked.

Three things this pins:

  * the I/O OVERLAPS with the rest — the file and the clock run together;
  * `read(n)` gives up to n bytes and the empty answer is the end (79.2), while
    `text()` gives the whole thing decoded and `read_all()` the whole thing raw
    (79.1);
  * `try`/`catch` works INSIDE an `async def`, including catching an error born
    after a suspension — which needs the exception guard to jump to the catch
    state instead of ending the task.
"""

import sys

PATH: str = "aio_files_demo.txt"


struct File:
    name: str
    read_bytes: int

    # a method may be an `async def` too (50.1): it is a function with a
    # receiver, and `self` lives in the frame like any other parameter
    async def write_lines(self, lines: int) -> int:
        f = await open(self.name, "w")
        total = 0
        for i in range(lines):
            total += await f.write("line " + str(i) + "\n")
        await f.close()
        return total

    async def read_all_text(self) -> str:
        f = await open(self.name, "r")
        t = await f.text()
        await f.close()
        self.read_bytes += len(t)
        return t

    async def read_or_empty(self, name: str) -> str:
        try:
            f = await open(name, "r")
            t = await f.text()
            await f.close()
            return t
        catch e:
            return "<" + e.message + ">"


async def clock(n: int) -> int:
    k = 0
    for i in range(n):
        await sleep(0.002)
        k += 1
    return k


a = File(PATH, 0)

# the file and the clock run TOGETHER: if the I/O blocked the thread, the two
# times would add up instead of overlapping
t0 = sys.time()
writing = a.write_lines(4)
tick = clock(5)
print("wrote", await writing, "bytes")
print("ticks", await tick)
print("overlapped", sys.time() - t0 < 0.05)

print("read", len(await a.read_all_text()), "bytes")
print("accumulated", a.read_bytes)

# what is missing does not blow up: the catch is inside the `async def`
print("missing", await a.read_or_empty("no/such/file.txt"))

# bytes: up to n, and the empty answer is the end
f = await open(PATH, "r")
first = await f.read(6)
rest = await f.read_all()
end = await f.read(8)
print("bytes", len(first), first[0], len(rest), len(end))
await f.close()

lines = await (await open(PATH, "r")).readlines()
print("lines", len(lines), lines[0])
