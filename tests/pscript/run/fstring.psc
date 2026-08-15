"""f-strings, resolved ENTIRELY at compile time (45.1).

The literal is split by the parser into text and `{expr:spec}` holes, each
expression is parsed by the very same parser, and the whole thing becomes a `+`
chain. So the run time sees string concatenation and one formatting call per
hole — never a format string to interpret.

The spec pieces are constants by the time the runtime sees them, which is also
why `^` (centre) can exist at all: printf cannot centre, and there is no printf
here.
"""

name = "world"
n = 42
pct = 93.456
flag = True

print(f"hello, {name}!")
print(f"n = {n}, twice = {n * 2}")
print(f"[{n:6}]")
print(f"[{n:<6}]")
print(f"[{n:^6}]")
print(f"[{n:06}]")
print(f"[{-n:06}]")
print(f"hex {n:x} HEX {n:X} bin {n:b} oct {n:o}")
print(f"pct {pct:.1f}%")
print(f"[{pct:>10.2f}]")
print(f"[{name:>10}] [{name:<10}] [{name:^11}]")
print(f"flag {flag}")
print(f"braces {{literal}} and a hole {n}")
print(f"nested call {name}: {len(name)}")
