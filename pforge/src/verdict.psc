"""A test case's VERDICT, as a program.

A test case is not an ordinary edge, and there is one difference: its exit STATUS
is DATA, not a verdict. A program that has to exit with 1 exits with 1, and the
edge that runs it cannot call that a failure — while a program that exits with 0
and prints the wrong thing has failed, and the edge has to say so.

So what the edge runs is not the case: it is this. It runs the case, merges
standard error into standard output (the same decision as `os.run`'s, and how
`tests/run.sh` has always compared), checks the status against the expected one,
checks the text against the `.expected`, and only then decides. Whoever passes
leaves a STAMP, which is what the graph dates; whoever fails prints the first
lines of the difference and exits with a status != 0, which is what the engine
understands.

    verdict <binary> <expected> <expected-status> <cwd> <stamp>

The `cwd` exists because a case may write files, and it has to write them into the
build's output directory and not into the repository's root.
"""
import os
import sys
import path

const CONTEXT: int = 12


private def first_difference(expected: str, got: str) -> str:
    """The first line that differs, with what was expected and what came out. A
    whole diff in a build report is noise; the first divergence is almost always
    the only one that matters, and the others follow from it."""
    a = expected.split("\n")
    b = got.split("\n")
    n = len(a) if len(a) < len(b) else len(b)
    i = 0
    while i < n:
        if a[i] != b[i]:
            return ("line " + str(i + 1) + ":\n  expected: " + a[i] + "\n  got:      " + b[i])
        i += 1
    if len(a) != len(b):
        return ("the text has " + str(len(b)) + " line(s) and the expected one has " + str(len(a)))
    return "?"


async def main() -> int:
    args = sys.argv[1:]
    if len(args) != 5:
        print("usage: verdict <binary> <expected> <expected-status> <cwd> <stamp>")
        return 2
    binary = args[0]
    expected = args[1]
    wants = int(args[2])
    cwd = args[3]
    stamp = args[4]

    # the binary's path is relative to the ROOT; the process runs in the case's
    # `cwd`, so it has to become absolute first
    abs_bin = binary if binary.startswith("/") else path.join(os.getcwd(), binary)
    # each case has ITS OWN directory, and it is created here: a case that writes
    # files cannot write them into the repository's root, and two cases in
    # parallel cannot write into the same place
    if not path.isdir(cwd):
        os.makedirs(cwd)
    r = await os.run([abs_bin], cwd=cwd)

    f = await open(expected, "r")
    wants_txt = await f.text()
    await f.close()
    got = r.output()

    problems: list<str> = []
    if r.status() != wants:
        problems.append("status " + str(r.status()) + ", expected " + str(wants))
    if got != wants_txt:
        problems.append(first_difference(wants_txt, got))

    if len(problems) > 0:
        print(path.basename(binary) + ": FAILED")
        for p in problems:
            print("  " + p)
        return 1

    d = path.dirname(stamp)
    if len(d) > 0 and not path.isdir(d):
        os.makedirs(d)
    g = await open(stamp, "w")
    await g.write("ok\n")
    await g.close()
    return 0


sys.exit(await main())
