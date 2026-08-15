"""`json` (41.1): text in, `any` out.

An object becomes `dict<str, any>`, an array a `list<any>`, and the leaves are
str, int, float, bool and None. There is no schema to declare and no type to
write down — reading a value back is `as`, which CHECKS (55.2), and that is the
whole contract.

Numbers follow Python's rule (68.6): an INTEGRAL literal is an int, anything
with a point or an exponent is a float. The honest cost, taken with eyes open:
the type depends on the SPELLING in the text — `16` and `16.0` read back
differently. `as float` still accepts an int, because int promotes to float
everywhere (32.1).
"""

import json

doc = json.parse("{\"name\": \"smallpt\", \"samples\": 16, \"gamma\": 2.2, \"fast\": true}")
d = doc as dict<str, any>
print("name", d["name"] as str)
print("samples", d["samples"] as int)
print("gamma", d["gamma"] as float)
print("fast", d["fast"] as bool)

arr = json.parse("[1, 2, 3]") as list<any>
print("array", len(arr), arr[0] as int, arr[2] as float)

# the spelling decides: `16` is an int, `16.0` is a float
spelled = json.parse("[16, 16.0]") as list<any>
try:
    n = spelled[1] as int
    print("unreachable", n)
catch e:
    print("16.0 is not an int:", e.message)

nested = json.parse("{\"pos\": [1.0, 2.0, 3.0]}") as dict<str, any>
pos = nested["pos"] as list<any>
print("nested", len(pos), pos[1] as float)

try:
    bad = json.parse("{oops}")
    print("unreachable")
catch e:
    print("caught:", e.message)
