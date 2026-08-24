"""The editor's speed, with CEILINGS — the gate that did not exist.

Nothing measured time, and that is why `Buffer.text()` stayed quadratic until
somebody happened to look: it built the whole file with `+=` in a loop, and it is
called on EVERY save and on every rebuild of the completion index. Eight thousand
lines cost 672 ms that way, thirty-two thousand cost seventeen seconds, and the
biggest file in this repository has eleven thousand.

The ceilings are ABSOLUTE and they are round numbers, because what is being
defended is a promise — that the editor is fast — and not a historical
measurement. A relative gate ("no more than 20% worse than last time") would have
accepted the quadratic on the day it was written.

It is built with `-O2`, which is how the editor ships. Measuring speed on an
unoptimised build measures the wrong binary — the compiler's lexer alone costs
15 ms over eleven thousand lines at `-O0` and 9 ms at `-O2`, and one keystroke
has sixteen.

The buffer is GENERATED and not read from disk: a test that depends on a path
depends on the working directory, and this one has to give the same answer
wherever the harness runs it. Eleven thousand lines of plausible P, with the line
lengths a real file has.
"""
import time
import <pui> as pui
import codeview as cvm
import core


const LINES: int = 11000
const CEIL_LOAD: int = 200      # ms — opening a big file
const CEIL_TEXT: int = 50       # ms — every save goes through here
const CEIL_INDEX: int = 200     # ms — the completion index
const CEIL_KEY: int = 16        # ms — one keystroke, at 60 fps
const CEIL_SEARCH: int = 50     # ms — searching the open file


fails = 0


def took(t0: float, t1: float) -> int:
    return int((t1 - t0) * 1000.0)


def check(what: str, ms: int, ceiling: int):
    """Prints the VERDICT and not the time: a number in the expected output would
    make the gate fail on a slower machine for no reason. When it fails, though,
    the number is what the message is for."""
    global fails
    if ms <= ceiling:
        print(what + ": ok")
    else:
        print(what + ": " + str(ms) + " ms, ceiling " + str(ceiling) + " ms")
        fails += 1


def make_source(n: int) -> str:
    """Plausible P, with lines of varied length — a file of identical lines would
    measure the allocator and not the editor."""
    parts: list<str> = []
    i = 0
    while len(parts) < n:
        parts.append("")
        parts.append("# a comment explaining what the function below is for, " + str(i))
        parts.append("def handler_" + str(i) + "(input: *Buffer, count: i32) -> i32:")
        parts.append("    \"\"\"What this one does, said in a docstring.\"\"\"")
        parts.append("    total: i32 = 0")
        parts.append("    for k in range(count):")
        parts.append("        total += input->items[k].weight * " + str(i % 7 + 1))
        parts.append("        if total > 1000:")
        parts.append("            return total - 1000")
        parts.append("    return total")
        i += 1
    return "\n".join(parts[0:n])


src = make_source(LINES)
u = pui.new_ui(8, 17)
root = u.box(-1, True)
cv = cvm.cv_create(u, root)
u.layout(1200, 800)

# ---- opening: load, first layout, first relex ----
t0 = time.monotonic()
cv.load_text("big.p", src, 0)
cv.hl.update(cv.buf)
t1 = time.monotonic()
print("lines=" + str(cv.buf.nlines()))
check("open", took(t0, t1), CEIL_LOAD)

# ---- saving: this is the one that was quadratic ----
t0 = time.monotonic()
out = cv.buf.text()
t1 = time.monotonic()
check("save (text())", took(t0, t1), CEIL_TEXT)
print("round trip=" + ("1" if len(out) == len(src) else "0"))

# ---- the completion index, which goes through `text()` and then lexes ----
t0 = time.monotonic()
cv.index.build(cv.buf, [])
t1 = time.monotonic()
check("completion index", took(t0, t1), CEIL_INDEX)

# ---- one keystroke: the edit, plus the relex the editor does after it ----
cv.buf.move_to(LINES // 2, 0)
t0 = time.monotonic()
cv.buf.insert("x", 1000)
cv.hl.update(cv.buf)
t1 = time.monotonic()
check("one key", took(t0, t1), CEIL_KEY)

# ---- searching the open file, from the top, for something near the end ----
cv.buf.move_to(0, 0)
t0 = time.monotonic()
found = cv.search("handler_" + str(LINES // 10 - 2), True, False, True)
t1 = time.monotonic()
check("search", took(t0, t1), CEIL_SEARCH)
print("found=" + ("1" if found else "0"))

# ---- the same file with WINDOWS line endings: the CRLF strip walked every
# codepoint of the whole file, appending to a string as it went ----
crlf = src.replace("\n", "\r\n")
b2 = core.new_buffer()
t0 = time.monotonic()
b2.load(crlf)
t1 = time.monotonic()
check("open (CRLF)", took(t0, t1), CEIL_LOAD)
print("crlf=" + ("1" if b2.crlf and b2.nlines() == cv.buf.nlines() else "0"))

# ---- copying the WHOLE file, which took the same quadratic path ----
cv.buf.move_to(0, 0)
cv.buf.select_range(core.Span(0, 0, cv.buf.nlines() - 1, 0))
t0 = time.monotonic()
sel = cv.buf.sel_text(0)
t1 = time.monotonic()
check("copy all (range_text())", took(t0, t1), CEIL_TEXT)
print("copied=" + ("1" if len(sel) > 100000 else "0"))

print("perf-ok" if fails == 0 else "perf-FAILED " + str(fails))
