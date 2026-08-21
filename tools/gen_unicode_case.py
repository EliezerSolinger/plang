#!/usr/bin/env python3
"""Generate the Unicode case-mapping table that `pscript/runtime/psrt.p` embeds.

    python3 tools/gen_unicode_case.py > pscript/runtime/unicase.bin

WHY IT IS GENERATED AND NOT WRITTEN. Case mapping is a table, not an algorithm:
`é` uppercases to `É` by an offset, `ß` uppercases to `SS` — two characters —
and no rule produces either. The table changes once a year, when the Consortium
ships a Unicode version. A generated file with a generator next to it is the
only arrangement where "which Unicode is this?" has an answer.

WHERE THE DATA COMES FROM. Python's own `str.upper()`/`str.lower()`, which are
the Unicode DEFAULT mappings — locale-independent, exactly as JavaScript's
`toUpperCase` is. That is the behaviour being copied, so it is also the right
source: the version stamped in the header is the Unicode version of the Python
that ran this, and `tests/oracle/py/strings.psc` compares the two afterwards.

FINAL SIGMA is here too, and that correction is worth recording: `Σ` lowercases
to `ς` at the end of a word and to `σ` anywhere else. It is CONDITIONAL but it is
not locale-dependent — it is part of the Unicode default mapping, and Python and
JavaScript both do it. Doing it needs two more sets, `Cased` and
`Case_Ignorable`, and those are DERIVED HERE BY ASKING PYTHON rather than by
reading a property file: whether a character counts as a following cased letter
is exactly whether it stops `Σ` from becoming final, so the oracle is asked that
question directly, once per code point. 4259 cased points in 150 ranges, 2707
ignorable in 437 — 4.6 KB.

Not covered, on purpose and stated rather than discovered: the LOCALE-sensitive
rules (Turkish dotless i, Lithuanian dot above). Python's `str.upper()` does not
do them either — they are what `toLocaleUpperCase` exists for — so the oracles
stay honest, and a program that needs them needs a locale, which is a different
decision.

FORMAT (bateria 108) — the file DESCRIBES ITSELF, and every number is
big-endian so the reader does not depend on the machine:

    magic   "PSUC"                       4 bytes
    unidata version, as text, NUL-padded 8 bytes  (e.g. "15.0.0\0\0")
    ntab                                 u32
    ntab × (count:u32, esize:u32)        the DIRECTORY
    the tables, in that order

    table 0  upper ranges   lo:u32 hi:u32 delta:i32
    table 1  upper multi    lo:u32 hi:u32 a:u32 b:u32 c:u32   (lo == hi)
    table 2  lower ranges   ...
    table 3  lower multi    ...
    table 4  Cased          lo:u32 hi:u32                     (a set, as ranges)
    table 5  Case_Ignorable lo:u32 hi:u32

WHY THE DIRECTORY, and why every entry starts with lo AND hi. There were two
generated tables (this one and `unicode_cat`), each with its own reader in the
runtime, and each reader had the entry size of every table WRITTEN INTO a chain
of ifs plus three near-identical binary searches. Two formats, two readers, six
searches — and I had to keep the offset arithmetic of both in step by hand.

With the directory the reader computes offsets from the FILE, and with `lo`/`hi`
first in every entry (a one-to-many mapping repeats the code point: `lo == hi`)
ONE binary search serves all six tables. The four bytes per multi entry that
this costs are 400 bytes in the whole file.

A RANGE is a run of consecutive code points whose mapping is the same offset,
which is what makes 1423 mappings fit in 678 records.
"""
import struct
import sys
import unicodedata


def build(fn):
    simple, multi = {}, {}
    for cp in range(0x110000):
        ch = chr(cp)
        m = fn(ch)
        if m == ch:
            continue
        if len(m) == 1:
            simple[cp] = ord(m)
        else:
            assert len(m) <= 3, (hex(cp), m)
            multi[cp] = [ord(c) for c in m] + [0] * (3 - len(m))
    ranges, items, i = [], sorted(simple.items()), 0
    while i < len(items):
        cp, to = items[i]
        d = to - cp
        j = i + 1
        while (j < len(items) and items[j][0] == items[j - 1][0] + 1
               and items[j][1] - items[j][0] == d):
            j += 1
        ranges.append((cp, items[j - 1][0], d))
        i = j
    return ranges, sorted(multi.items())


SIGMA = "\u03a3"


def sets():
    """`Cased` and `Case_Ignorable`, asked of the oracle instead of assumed.

    Final_Sigma says: `\u03a3` becomes `\u03c2` when a cased letter comes before
    it and none comes after, where case-ignorable characters in between do not
    count. So the two questions can be put to Python directly:

      * does `c` after the sigma STOP it from being final?  then `c` is cased;
      * does the sigma stay non-final when `c` is followed by a cased letter,
        even though `c` alone did not stop it?  then `c` is case-ignorable.
    """
    cased, ign = [], []
    for cp in range(0x110000):
        c = chr(cp)
        if ("a" + SIGMA + c).lower()[1] == "\u03c3":
            cased.append(cp)
        elif ("a" + SIGMA + c + "b").lower()[1] == "\u03c3":
            ign.append(cp)
    return as_ranges(cased), as_ranges(ign)


def as_ranges(xs):
    out, i = [], 0
    while i < len(xs):
        j = i + 1
        while j < len(xs) and xs[j] == xs[j - 1] + 1:
            j += 1
        out.append((xs[i], xs[j - 1]))
        i = j
    return out


def main():
    up_r, up_m = build(str.upper)
    lo_r, lo_m = build(str.lower)
    cased, ign = sets()
    # o diretório: quantas entradas e de que tamanho, tabela por tabela (108)
    tables = [(up_r, 12), (up_m, 20), (lo_r, 12), (lo_m, 20), (cased, 8), (ign, 8)]
    out = bytearray(b"PSUC")
    out += unicodedata.unidata_version.encode().ljust(8, b"\0")[:8]
    out += struct.pack(">I", len(tables))
    for rows, esize in tables:
        out += struct.pack(">II", len(rows), esize)
    for lo, hi, d in up_r:
        out += struct.pack(">IIi", lo, hi, d)
    for cp, v in up_m:
        out += struct.pack(">IIIII", cp, cp, v[0], v[1], v[2])
    for lo, hi, d in lo_r:
        out += struct.pack(">IIi", lo, hi, d)
    for cp, v in lo_m:
        out += struct.pack(">IIIII", cp, cp, v[0], v[1], v[2])
    for lo, hi in cased:
        out += struct.pack(">II", lo, hi)
    for lo, hi in ign:
        out += struct.pack(">II", lo, hi)
    sys.stdout.buffer.write(bytes(out))
    print("unicode %s: upper %d+%d, lower %d+%d, cased %d, ignorable %d, %d bytes"
          % (unicodedata.unidata_version, len(up_r), len(up_m), len(lo_r), len(lo_m),
             len(cased), len(ign), len(out)),
          file=sys.stderr)


main()
