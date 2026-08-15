"""Files (48.1): Python's shape over stdio, because libc IS the runtime.

`with open(path, mode) as f:` acquires, runs the block and releases at the end —
including when an error leaves through the middle, because the release lowers to
P's `defer`. Failure RAISES with the `io` category, so a program that ignores
the possibility stops instead of writing into nothing.
"""

# a relative name: the suite runs each program in its own working directory
path = "psc_files_demo.txt"

with open(path, "w") as f:
    n = f.write("first\n")
    n += f.write("second\n")
    print(f"wrote {n}")

# a block is a SCOPE in both languages (64.1), `with` included — so a name the
# block needs afterwards is lifted with the opt-in P already had
nonlocal body
with open(path, "r") as f:
    body = f.read()
print(f"read {len(body)}")

nonlocal lines
with open(path, "r") as f:
    lines = f.readlines()
print(f"lines {len(lines)} first {lines[0]}")

try:
    with open("no/such/place/at/all.txt", "r") as f:
        print("unreachable")
catch e:
    print(f"caught {e.message}")
