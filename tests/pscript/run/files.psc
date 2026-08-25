"""Files (48.1/76.2): Python's shape over stdio, because libc IS the runtime —
and every one of them is AWAITED, because every one of them can take a while.

A file operation goes to the thread pool (76.3): the call describes the job and
hands back a task, and the waiting happens in the scheduler, next to the clock
and the message queues. That is what keeps one slow read from stopping every
other task in this context — and `read(2)` really does block, always, which is
why a thread is the only honest answer for a file.

`with await open(path, mode) as f:` acquires, runs the block and releases at the
end — including when an error leaves through the middle, because the release
lowers to P's `defer`. The release calls the BLOCKING close (80.2): cleanup also
runs while an exception is unwinding, and waiting in the middle of an unwind
would make the cleanup itself a state of the machine. `close(2)` only takes long
in pathological cases, so the price is about zero.

Failure RAISES with the `io` category, so a program that ignores the
possibility stops instead of writing into nothing.
"""

# a relative name: the suite runs each program in its own working directory
path = "psc_files_demo.txt"

with await open(path, "w") as f:
    n = await f.write("first\n")
    n += await f.write("second\n")
    print(f"wrote {n}")

# a block is a SCOPE in both languages (64.1), `with` included — so a name the
# block needs afterwards is lifted with the opt-in P already had
nonlocal body
with await open(path, "r") as f:
    body = await f.text()
print(f"read {len(body)}")

nonlocal lines
with await open(path, "r") as f:
    lines = await f.readlines()
print(f"lines {len(lines)} first {lines[0]}")

try:
    with await open("no/such/place/at/all.txt", "r") as f:
        print("unreachable")
catch e:
    print(f"caught {e.message}")

# the byte side (79.1/79.2/135.2): `read_into` fills memory you already have and
# says how many bytes landed; zero is the end, which is the semantics of `recv`
# and what an incremental parser wants. `text()` is the whole thing decoded;
# `read_all()` the whole thing as `bytes`.
nonlocal head
with Buffer(16) as rb:
    with await open(path, "r") as f:
        n1 = await f.read_into(rb, 0, 5)
        head = bytes(rb[0:n1])
        rest = await f.read_all()
        n3 = await f.read_into(rb, 0, 4)
        print(f"head {n1} first {head[0]} rest {len(rest)} eof {n3}")

# and bytes go out the same door
with await open(path, "w") as f:
    print(f"wrote bytes {await f.write(head)}")
