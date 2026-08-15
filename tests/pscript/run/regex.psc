"""`re` (41.2): POSIX ERE, straight from libc.

Zero dependency — "libc is the runtime" taken at its word. Classic ERE: groups
and alternation yes, no lookahead and no `\d`. A match answers the groups, with
[0] the whole match; no match is None, which is what makes `if not m:` read the
way it should (40.1).
"""

import re

m = re.match("^([0-9]+)x([0-9]+)$", "1024x768")
if m != None:
    print(f"groups {len(m)} whole {m[0]} w {m[1]} h {m[2]}")
else:
    print("no match")

miss = re.match("^[0-9]+$", "not a number")
print(f"miss is none {miss == None}")

alt = re.match("cat|dog", "the dog barks")
if alt != None:
    print(f"alt {alt[0]}")

try:
    bad = re.match("([unclosed", "x")
    print("unreachable")
catch e:
    print(f"caught a bad pattern {len(e.message) > 0}")
