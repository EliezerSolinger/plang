"""CRC-32 — and the reason this package exists.

It is 2.13's case: a package that brings **hand-written C**. The `.p` here
implements nothing — it DECLARES what the C offers (`include "crc32.h"`) and
re-exports it with a P name. Whoever builds is the one who knows how to compile
that `.c`, with the flags the manifest declared, and link it into the program.
"""
def crc32_of(s: const *char) -> u32
