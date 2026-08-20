"""`:=` — the walrus of 45.2, which parsed and did not compile until now.

It binds a name and evaluates to the value, and the way it does both is the
device the comprehension already uses: the binding is hoisted in front of the
statement, and the expression becomes the name. Which is exactly why two places
had to be handled rather than allowed:

  * a LOOP condition, where hoisting in front of the loop would run the binding
    once and the condition every turn. So a `while` whose condition hoists
    becomes `while True:` with the binding and the test inside — which is what
    makes the classic `while (line := next()) != "":` mean what Python means.
  * a lazy operand (a ternary arm, the right of `and`/`or`), where hoisting
    would run it even when that side is not taken. That one is REFUSED, because
    there is no rewrite that keeps both the laziness and the binding.
"""

xs = [1, 2, 3, 4]

if (n := len(xs)) > 3:
    print(f"if {n}")

# the name outlives the statement that bound it: it belongs to the enclosing
# scope, which is what makes the idiom useful at all
print(f"after {n}")

# in a while condition — the binding runs every turn
left = [3, 2, 1]
while (k := len(left)) > 0:
    print(f"while {k}")
    left.remove_at(0)

# a comprehension in a while condition is the same problem and the same fix
i = 0
while len([v for v in xs if v > i]) > 2:
    print(f"comp {i}")
    i += 1

# nested: the inner binding is visible to the outer expression
if (a := len(xs)) > (b := 2):
    print(f"two {a} {b}")

# a str, so the binding is a COLLECTED value and the frame has to cover it
words = ["alpha", "be"]
if (w := words[0]) != "":
    print(f"str {w} {len(w)}")


async def work(v: int) -> int:
    await sleep(0)
    return v * 2


async def in_async() -> int:
    # the binding is a frame FIELD here, and the value comes from an await —
    # which is the case that silently bound nothing before, because the
    # hoisted assignment was dropped when the condition became a state
    if (r := await work(21)) > 0:
        print(f"async {r}")
    total = 0
    while (m := total) < 3:
        total += 1
    print(f"async while {m} {total}")
    return r


got = await in_async()
print(f"returned {got}")
