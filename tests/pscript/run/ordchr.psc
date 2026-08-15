"""`ord` and `chr` — the door between text and number.

A character is a one-character STRING here (3.4), which is the right shape for
text and the wrong one for an interface that speaks scalars. These two are how
a program crosses that line: the codepoint of a character, and the character of
a codepoint, both UTF-8 all the way through.
"""

print(ord("A"), ord("á"), ord("→"))
print(chr(65), chr(225), chr(8594))
s = "héllo"
out = ""
for i in range(len(s)):
    out += chr(ord(s[i]))
print(out, out == s)
try:
    print(ord("ab"))
catch e:
    print("caught:", e.message)
