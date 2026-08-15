"""`in` over a string is SUBSTRING, and `for ch in s` walks CHARACTERS (72.2/72.3).

Both are Python's, and both were written by hand in the editor port before they
existed. The loop matters twice: it reads right, and it walks the bytes ONCE —
reaching for `s[i]` each round recounts the UTF-8 offset from the start, which
made a loop over a string quadratic.
"""

s = "hello, world"
print("world" in s, "World" in s, "" in s, s in s)
print("x" not in s, "o, w" in s)
print("é" in "café", "z" in "café")
s = "café ☕!"
out = ""
n = 0
for ch in s:
    out += ch + "|"
    n += 1
print(n, len(s), out)
total = 0
for ch in "abc":
    total += ord(ch)
print(total)
for ch in "":
    print("never")
print("empty ok")
