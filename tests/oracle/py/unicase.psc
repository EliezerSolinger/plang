"""Case mapping over the WHOLE code point space, against Python.

The pair next door does the same walk and the same arithmetic, so one number
compares 1.1 million mappings. A single wrong offset in the generated table
moves the hash; nothing else does.

Surrogates are skipped because a `str` here is valid UTF-8 by construction
(83.2) and a surrogate is not encodable — which is a property of the type, not
an omission.
"""

h_up = 0
h_lo = 0
n_up = 0
n_lo = 0
cp = 0
while cp < 1114112:
    if cp >= 55296 and cp <= 57343:
        cp += 1
        continue
    c = chr(cp)
    u = c.upper()
    l = c.lower()
    if u != c:
        n_up += 1
        for ch in u:
            h_up = (h_up %* 1000003 %+ ord(ch)) % 1000000007
    if l != c:
        n_lo += 1
        for ch in l:
            h_lo = (h_lo %* 1000003 %+ ord(ch)) % 1000000007
    cp += 1

print("upper", n_up, h_up)
print("lower", n_lo, h_lo)
