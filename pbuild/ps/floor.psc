"""A scoreboard's FLOOR, as a graph edge.

A suite that measures instead of passing or failing — the `c-suite` (220 C
programs written by other people) and the `wacct` corpus (1,630) — has no verdict
of its own: it prints a number. What makes that number a gate is the FLOOR:
falling below it is a regression, and raising it when the number improves is how
you never go backwards.

That used to live in `verify-all.sh`, in two shell variables at the top of the
file. The right place is here, next to the suite it measures: whoever reads the
descriptor sees what is required, and whoever raises the floor raises it where
the number is produced.

    floor <log> <prefix> <minimum> <stamp>

The `prefix` is the text that comes immediately before the number on the report's
line (`score: `, `wacct-valid: `). The LAST occurrence is the one taken, because a
report may mention the same prefix before saying it in earnest — and what counts
is what it said at the end.
"""
import os
import path
import sys


private def number_after(txt: str, prefix: str) -> int:
    """The last number that comes right after `prefix`, or -1 if there is none.

    No regular expression, on purpose: it is a text search and a digit read, and
    both fit in fifteen lines you read in one go."""
    found = -1
    i = 0
    while True:
        k = txt.find(prefix, i)
        if k < 0:
            break
        j = k + len(prefix)
        v = 0
        n = 0
        while j < len(txt) and txt[j] >= "0" and txt[j] <= "9":
            v = v * 10 + (ord(txt[j]) - ord("0"))
            n += 1
            j += 1
        if n > 0:
            found = v
        i = k + len(prefix)
    return found


async def main() -> int:
    args = sys.argv[1:]
    if len(args) != 4:
        print("usage: floor <log> <prefix> <minimum> <stamp>")
        return 2
    log = args[0]
    prefix = args[1]
    minimum = int(args[2])
    stamp = args[3]
    if not path.isfile(log):
        print("floor: I did not find the report " + log)
        return 1
    f = await open(log, "r")
    txt = await f.text()
    await f.close()
    v = number_after(txt, prefix)
    if v < 0:
        print("floor: the report " + log + " has no line with '" + prefix + "<number>'")
        return 1
    if v < minimum:
        print("REGRESSION: " + prefix + str(v) + ", and the floor is " + str(minimum))
        print("   the whole report is in " + log)
        return 1
    d = path.dirname(stamp)
    if len(d) > 0 and not path.isdir(d):
        os.makedirs(d)
    g = await open(stamp, "w")
    await g.write(prefix + str(v) + " (floor " + str(minimum) + ")\n")
    await g.close()
    print(prefix + str(v) + " >= " + str(minimum))
    return 0


sys.exit(await main())
