"""Strings, against Python.

The `str` here indexes by CHARACTER (80.1b), which is what makes these lines
comparable at all: a language that indexed by byte would answer differently for
every one of them the moment a non-ASCII character appeared.
"""

s = "Hello, World"
print(len(s))
print(s[0], s[4], s[-1])
print(s[0:5])
print(s[7:])
print(s[:5])
print(s[-5:])
print(s.upper())
print(s.lower())
print(s.find("World"))
print(s.find("nope"))
print(s.startswith("Hello"), s.endswith("World"))
print("  padded  ".strip())
# a list has no `str()` yet, and what Python prints for one is a repr
# with quotes — a formatting DECISION, not a semantic one. What is on trial
# here is `split`, so the parts are spelled out.
parts = "a,b,,c".split(",")
print(len(parts), "|".join(parts))
print("-".join(["x", "y", "z"]))
print("ab" * 3)
print("abc" < "abd", "abc" == "abc", "b" > "a")
print("World" in s, "world" in s)
print(s.replace("World", "there"))

u = "héllo wörld ✓"
print(len(u))
print(u[1], u[7], u[-1])
print(u[0:5])
print(u.upper())
print(ord("é"), chr(233))
print(ord("✓"), chr(10003))

print(str(42), str(3.5), str(True))
print(f"{42:5d}|{3.14159:.2f}|{'hi':>6}|{255:x}")
print(f"{0.1+0.2}")

# the one-to-MANY mappings, which is the half no offset can do
print("straße".upper())
print("ﬁxup".upper())
print("İstanbul".lower())
print("ΣΟΦΟΣ".lower())
print("ǅungla".upper(), "ǅungla".lower())
print("ᾈ".lower(), "ᾀ".upper())
