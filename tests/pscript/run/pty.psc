"""`os.spawn_pty` — a child with a real terminal on the other end.

`run` waits, `exec` becomes the child, `spawn` launches and moves on. This is the
fourth case, and it is the one an editor's terminal and a `dev` loop both need:
the program gets a TTY, so it behaves the way it behaves in a shell — it line
buffers, it colours, it prints a prompt, and a signal from the keyboard reaches
it.

What comes back is a `socket`, the same type `net.connect` returns. That is the
whole design: `read`, `write` and `close` on it were already written, already
awaitable, and already POLLED by the scheduler instead of blocking a thread. A
terminal is a descriptor with a child on the other end; a socket is a descriptor
with a machine on the other end. Nothing above this line has to tell them apart.

The proof that the child really has a terminal is `tty`, which prints the name of
one and fails when there is none — and `\r\n`, which is a line discipline
translating the `\n` the program wrote.
"""
import os


async def drain(c: Socket) -> str:
    """Everything until the other side closes. The empty answer is the end
    (79.2) — and on a terminal the end is the child exiting, because the last
    close of the slave hangs the master up."""
    out = ""
    while True:
        b = await c.read(4096)
        if len(b) == 0:
            break
        out += str(b)
    return out


async def main_test():
    # ---- it IS a terminal, and it has the size it was given ----
    c = os.spawn_pty(["/bin/sh", "-c", "tty >/dev/null && echo yes-a-tty; stty size"], 100, 40)
    print("pid>0", os.pty_pid(c) > 0)
    txt = await drain(c)
    c.close()
    for line in txt.replace("\r\n", "\n").strip().split("\n"):
        print("[" + line + "]")

    # ---- the line discipline is really there: \n comes back as \r\n ----
    c2 = os.spawn_pty(["/bin/sh", "-c", "printf 'a\\nb\\n'"], 80, 24)
    raw = await drain(c2)
    c2.close()
    print("crlf", "a\r\nb\r\n" == raw)

    # ---- and it is two-way: what is written reaches the child's stdin ----
    c3 = os.spawn_pty(["/bin/sh", "-c", "read x; echo got=$x"], 80, 24)
    await c3.write("world\n")
    got = await drain(c3)
    c3.close()
    print("stdin", "got=world" in got)

    # ---- resizing TELLS the program, which is the one thing a socket cannot ----
    c4 = os.spawn_pty(["/bin/sh", "-c", "read x; stty size"], 80, 24)
    os.pty_resize(c4, 133, 55)
    await c4.write("\n")
    sz = await drain(c4)
    c4.close()
    print("resized", "55 133" in sz)

    # ---- a program that does not exist is an exit status, not a crash ----
    c5 = os.spawn_pty(["./there-is-no-such-program"], 80, 24)
    await drain(c5)
    c5.close()
    print("missing program survived")

    # ---- and an empty command is refused, with the name of the call in it ----
    empty: List<str> = []
    try:
        os.spawn_pty(empty, 80, 24)
        print("empty NOT refused")
    catch e:
        print("empty refused:", "spawn_pty" in e.message)
    print("pty-ok")


await main_test()
