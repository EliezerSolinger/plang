"""JSONTestSuite driver: one process, the whole corpus.

Reads a MANIFEST (one path per line) and answers, for each file, whether
`json.parse` took it. The corpus is nst/JSONTestSuite (MIT), whose file names
carry the verdict: `y_` must be accepted, `n_` must be refused, `i_` is left to
the implementation but has to be RECORDED so a change of mind is visible.

One process for all 318 because the alternative — a process per file — spends
more time in `execve` than in the parser, and the parser is what is on trial.

A file that is not valid UTF-8 is a REFUSAL, not a crash: JSON is UTF-8 by
definition (RFC 8259 §8.1), and `str(bytes)` is where that gets checked (83.2).
"""

import sys
import json


async def verdict(path: str) -> str:
    # 64.1: a block is a scope here, so what has to outlive the `try` is
    # announced with `nonlocal` — the same opt-in P has
    nonlocal raw
    try:
        f = await open(path, "r")
        raw = await f.read_all()
        await f.close()
    catch e:
        return "ERROR " + e.message
    nonlocal text
    try:
        text = str(raw)
    catch e:
        # not UTF-8 — refused before the parser ever sees it
        return "REJECT"
    try:
        v = json.parse(text)
        return "ACCEPT"
    catch e:
        return "REJECT"


async def main_task() -> int:
    args = sys.argv
    if len(args) < 2:
        print("usage: json_conform <manifest>")
        return 1
    f = await open(args[1], "r")
    manifest = await f.text()
    await f.close()
    n = 0
    for line in manifest.split("\n"):
        if len(line) == 0:
            continue
        print(await verdict(line) + " " + line)
        n += 1
    return n


count = await main_task()
