"""Text crossing the P↔pscript boundary (81/83/84/85/86).

pscript's `str` and P's `const *char` never met: 45.5 only let scalars through.
Now there is a pair — `CStr` for text, `CBytes` for bytes — which is A POINTER
AND ITS LENGTH, as a value, and which allocates nothing.

On the WAY OUT it is a loan: the compiler builds the pair pointing at the
object's own bytes, and that is safe because a C call cannot collect (only
`ps_gc_poll` collects, and C never calls it), so nothing moves underneath it.

On the WAY BACK it is a copy, and for text a CHECKED copy: P never hands over
ownership — it returns something static or a buffer of its own — and a `str`
promises codepoints, so bytes that are not valid UTF-8 raise instead of
becoming a string that lies about itself.
"""

import "pmod_text.ph"

name = "olá mundo"
print("length in BYTES on the P side:", text_length(name))
print("length in CHARACTERS here:", len(name))

print("upper:", text_upper("plang and pscript"))
print("version:", version())

b: List<u8> = [1, 2, 3, 250]
print("sum of the bytes:", bytes_sum(b))

try:
    print(not_utf8())
catch e:
    print("refused:", e.message)
