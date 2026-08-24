"""The gate that matters: the system's `tar` opens ours.

An envelope only our own tool can read is not an envelope, it is a private format
with a borrowed extension. This test writes a tarball, asks the system's `tar` to
list it and to EXTRACT it, and checks the bytes that came out.

If there is no `tar` on the machine, the test says so and passes — refusing to
build for want of a tool that is not a dependency would be worse than what it
protects against.
"""

import os
import sys
import path
import <tar/tar.psc> as tar

e: List<int> = [0, 0]
DIR = "build/t/tarsys"


def check(name: str, cond: bool):
    if cond:
        e[0] += 1
    else:
        e[1] += 1
        print("  FAILED: " + name)


async def main() -> int:
    r0 = await os.run(["tar", "--version"])
    if r0.status() != 0:
        print("tar: no `tar` on the system — 0 ok, 0 failed")
        return 0

    if not path.isdir(DIR):
        os.makedirs(DIR)
    target = path.join(DIR, "p.tar")
    content = "line one\nline two\n"
    bs = tar.write([
        tar.directory("box", 0o755, 1700000000),
        tar.file("box/a.txt", tar.bytes_of(content), 0o644, 1700000001),
        tar.file("box/b.bin", tar.bytes_of("x" * 1000), 0o600, 1700000002),
    ])
    f = await open(target, "w")
    await f.write(bs)
    await f.close()

    # 1) it LISTS what we put in there
    r = await os.run(["tar", "tf", target])
    check("tar tf returns 0", r.status() == 0)
    names: List<str> = []
    for ln in r.output().split("\n"):
        if len(ln) > 0:
            names.append(ln)
    check("tar tf lists the three members", len(names) == 3)
    check("the directory shows up", "box/" in names)
    check("the file shows up", "box/a.txt" in names)

    # 2) it EXTRACTS, and what comes out is what went in
    r2 = await os.run(["tar", "xf", target, "-C", DIR])
    check("tar xf returns 0", r2.status() == 0)
    g = await open(path.join(DIR, "box/a.txt"), "r")
    got = await g.text()
    await g.close()
    check("the content survived the round trip", got == content)

    # 3) and the mode we declared is the mode that landed on disk
    r3 = await os.run(["stat", "-c", "%a", path.join(DIR, "box/b.bin")])
    check("mode 600 reached the disk", r3.status() != 0 or r3.output().strip() == "600")

    print(f"tar/system: {e[0]} ok, {e[1]} failed")
    return 1 if e[1] > 0 else 0

sys.exit(await main())
