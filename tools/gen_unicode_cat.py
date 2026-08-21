#!/usr/bin/env python3
"""Generate the Unicode CATEGORY table that `pscript/runtime/psrt.p` embeds.

    python3 tools/gen_unicode_cat.py > pscript/runtime/unicat.bin

WHY IT IS GENERATED AND NOT WRITTEN, again. `tools/gen_unicode_case.py` next
door already made this argument for case mapping; this is the other half of the
same problem. `"3".isdigit()` is True and so is `"٣".isdigit()` (Arabic-Indic
three) and `"³".isdigit()` (superscript); `"三".isnumeric()` is True but
`"三".isdecimal()` is False. None of that follows from a rule you can write —
it is the Unicode character database, which changes once a year.

Doing HALF of it is what this file exists to prevent. A predicate that answers
for ASCII and silently disagrees with Python on the first non-ASCII digit is
worse than one that does not exist: the program looks right and the answer is
wrong, in the one place nobody tests.

WHERE THE DATA COMES FROM. Python's own `str.isalpha()`, `str.isdigit()`,
`str.isdecimal()`, `str.isnumeric()`, `str.isupper()`, `str.islower()` and
`str.title()`, asked once per code point over the whole range. Python IS the
behaviour being copied (pscript is a compiled copy of it), so it is also the
right source — and `tests/oracle/py/unicat.psc` compares the two afterwards,
every run, which is what keeps this file honest.

THE TITLE MAPPING is here and not in the case table because it is a THIRD
mapping, not upper and not lower: `ǳ` uppercases to `Ǳ` and titlecases to `ǲ`,
and `ß` titlecases to `Ss` — one character in, two out. `str.title()` on a
single character gives exactly the mapping Unicode calls Titlecase_Mapping, so
that is what is asked.

NOT COVERED, on purpose: `isprintable` (711 ranges for a predicate nobody has
needed yet — it can join later, the format has room), `isidentifier` (a
grammar, not a set), and the locale-sensitive case rules, which the case table
already declined for the same reason.

FORMAT — every number big-endian, so the reader does not depend on the machine:

    magic   "PSCA"                        4 bytes
    unidata version, as text, NUL-padded  8 bytes  (e.g. "15.0.0\0\0")
    ntab                                  u32
    ntab × (count:u32, esize:u32)         the DIRECTORY (bateria 108)
    then the tables, in this order:
      0..6  the predicate SETS       lo:u32 hi:u32
      7     title ranges             lo:u32 hi:u32 delta:i32
      8     title multi              lo:u32 hi:u32 out0 out1 out2   (lo == hi)

The directory is what lets ONE reader in the runtime serve this file and
`unicase.bin` both: it computes every offset from the file instead of carrying
each table's entry size in its own code. And every entry starting with lo AND hi
— a one-to-many mapping repeating the code point — is what lets ONE binary
search serve all nine tables. See the note in `gen_unicode_case.py`.

The sets are sorted and disjoint, so the reader is a binary search.
"""
import sys
import unicodedata


def ranges_of(pred):
    """The code points satisfying `pred`, as sorted disjoint [lo, hi] ranges."""
    out = []
    start = None
    for cp in range(0x110000):
        if pred(cp):
            if start is None:
                start = cp
        elif start is not None:
            out.append((start, cp - 1))
            start = None
    if start is not None:
        out.append((start, 0x10FFFF))
    return out


def title_tables():
    """The Titlecase_Mapping, split into constant-delta ranges and the rest.

    Most of it is "add a constant to the code point" over a run — the Latin and
    Greek blocks alternate upper/lower, so the delta is +1 or -1 for long
    stretches. What is left is the one-to-many mappings (`ß` -> `Ss`), which get
    a table of their own.
    """
    rng = []
    multi = []
    for cp in range(0x110000):
        t = chr(cp).title()
        if t == chr(cp):
            continue
        if len(t) == 1:
            d = ord(t) - cp
            if rng and rng[-1][1] == cp - 1 and rng[-1][2] == d:
                rng[-1][1] = cp
            else:
                rng.append([cp, cp, d])
        else:
            if len(t) > 3:
                raise SystemExit(f"U+{cp:04X} titlecases to {len(t)} characters, "
                                 f"and the table holds three")
            multi.append((cp, [ord(c) for c in t]))
    return rng, multi


def be32(v):
    return int(v & 0xFFFFFFFF).to_bytes(4, "big")


def main():
    sets = [
        ranges_of(lambda cp: chr(cp).isalpha()),
        ranges_of(lambda cp: chr(cp).isdigit()),
        ranges_of(lambda cp: chr(cp).isdecimal()),
        ranges_of(lambda cp: chr(cp).isnumeric()),
        ranges_of(lambda cp: chr(cp).isupper()),
        ranges_of(lambda cp: chr(cp).islower()),
        # The TITLECASE characters (category Lt): `ǅ`, and about thirty others,
        # which are neither upper nor lower. They earn a set of their own
        # because `isupper` has to REJECT them and `istitle` has to ACCEPT them
        # — found by the exhaustive sweep in tests/oracle/py/unicat.psc, which
        # is exactly the kind of thing a hand-picked example misses.
        ranges_of(lambda cp: unicodedata.category(chr(cp)) == "Lt"),
    ]
    ti_rng, ti_multi = title_tables()

    out = bytearray(b"PSCA")
    ver = unicodedata.unidata_version.encode()
    if len(ver) > 8:
        raise SystemExit("the Unicode version does not fit in eight bytes")
    out += ver + b"\0" * (8 - len(ver))
    # o diretório (108): o leitor calcula os offsets a partir do ARQUIVO
    out += be32(len(sets) + 2)
    for s in sets:
        out += be32(len(s)) + be32(8)
    out += be32(len(ti_rng)) + be32(12)
    out += be32(len(ti_multi)) + be32(20)
    for s in sets:
        for lo, hi in s:
            out += be32(lo) + be32(hi)
    for lo, hi, d in ti_rng:
        out += be32(lo) + be32(hi) + be32(d)
    for cp, outs in ti_multi:
        out += be32(cp) + be32(cp)
        for k in range(3):
            out += be32(outs[k] if k < len(outs) else 0)

    sys.stdout.buffer.write(bytes(out))
    names = ["alpha", "digit", "decimal", "numeric", "upper", "lower", "titlechar"]
    for n, s in zip(names, sets):
        print(f"{n}: {len(s)} ranges", file=sys.stderr)
    print(f"title: {len(ti_rng)} ranges, {len(ti_multi)} multi", file=sys.stderr)
    print(f"unicode {unicodedata.unidata_version}, {len(out)} bytes", file=sys.stderr)


if __name__ == "__main__":
    main()
