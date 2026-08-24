"""`bytes`: an immutable VALUE of bytes, and the four places one is born (135).

A `str` and a `bytes` are siblings that differ in exactly one thing — a `str`
promises to be text and counts codepoints, a `bytes` promises nothing and counts
bytes. Everything else follows from that, including the two places they answer
differently on purpose:

  * `s[i]` is a one-character STRING, because 3.4 says a character has no type
    of its own; `b[i]` is a NUMBER, because a byte does.
  * `s[a:b]` COPIES, because a string's bytes live inside the object and the
    collector moves it; `b[a:b]` is a WINDOW, because a `bytes` keeps its block
    outside the heap where nothing moves it (135.1).

And a `bytes` has no `close`. It is memory and nothing else, so its scarcity IS
the pressure on the heap — which is exactly the case 136.1 says belongs to the
collector rather than to `with`.
"""


def main():
    # ---- 1. the literal (135.7), which is the one that earns its keep on
    #         protocol constants: `b"\x7fELF"` and not `"\x7fELF".encode()`
    elf = b"\x7fELF"
    print(len(elf), elf[0], elf[1])

    # ---- 2. from a str: the UTF-8 it already holds, with the promise taken off
    s = "olá"
    b = s.encode()
    print(len(s), len(b))          # 3 codepoints, 4 bytes: that IS the difference

    # ---- 3. and back, which CHECKS (79.1)
    print(str(b))
    bad = bytes([0xFF, 0xFE])
    try:
        print(str(bad))
    catch e:
        print("refused:", e.message)

    # ---- 4. from a List<u8>, and back — explicit both ways because each copies
    xs: List<u8> = [104, 105]
    hi = bytes(xs)
    print(str(hi), len(hi))
    back = list(hi)
    back.append(33)
    print(len(back), back[2], len(hi))    # the copy did not touch the original

    # ---- 5. slicing is a WINDOW: no copy, and it composes
    src = b"\x7fELFhello world"
    head = src[0:4]
    print(len(head), head == b"\x7fELF", head == b"\x7fELG")
    tail = src[4:]
    print(str(tail))
    mid = tail[0:5]
    print(str(mid))
    # a slice of a slice points at the SAME block, not at a chain of headers
    print(str(mid[1:3]))
    # past the end trims instead of raising (17.3), like every other slice here
    print(len(src[100:200]))
    # a negative index counts back (31.4), and out of range RAISES (5.2)
    print(src[-1])
    try:
        print(src[999])
    catch e2:
        print("out of range:", e2.category == INDEX)

    # ---- 6. a step is the one slice that cannot be a window, so it copies
    print(str(b"abcdef"[0:6:2]))

    # ---- 7. equality is by CONTENT (22.2), like everything else
    print(b"abc" == b"abc", b"abc" == b"abd", b"abc" == b"ab")
    print(len(b""), b"" == b"")

    print("bytes-ok")


main()
