"""`hmac` — RFC 2104, over SHA-256.

HMAC is what turns a hash into a signature: `H(key ⊕ opad ‖ H(key ⊕ ipad ‖ msg))`.
The nesting is not decoration — it is what stops the length-extension attack that
plain `H(key ‖ msg)` walks straight into with every Merkle–Damgård hash, SHA-256
included.

**Comparing two of these is `hmac_equal`, not `==`.** A comparison that stops at
the first differing byte tells an attacker how many bytes they got right, and
that is enough to find the rest one byte at a time. This one always looks at
every byte.

**Only SHA-256, and that is a decision with a date on it.** The plan wanted this
generic over a `Hash` trait, and it cannot be yet: a trait would have to name the
P `struct Sha256` from the pscript side, and battery **141.6** parked exactly
that — a P struct has no name up there, and giving it one is the `Foreign`
mechanism that is open on purpose. When 141.6 moves, this file gains a type
parameter and loses nothing else.
"""

import <stl/cstr.ph>

def hmac_sha256(in key: CBytes, in msg: CBytes) -> CStr:
    """The MAC as sixty-four lowercase hex characters. A key longer than the
    block (64 bytes) is hashed down first, and a shorter one is zero-padded up —
    both because RFC 2104 §2 says so, and because two keys that differ only in
    trailing zeros must not produce the same MAC."""

def hmac_sha256_raw(in key: CBytes, in msg: CBytes, out_digest: *char):
    """The same MAC as **32 raw bytes**, written into `out_digest`. This is the
    one to use when the MAC feeds something else — a key derivation, another
    MAC — because going through hex and back is two conversions that can only
    lose."""

def hmac_equal(in a: CStr, in b: CStr) -> bool:
    """True when the two MACs are the same, in time that does not depend on
    WHERE they differ. Length is compared first and openly: it is not a secret,
    and a MAC of the wrong length was never going to match."""
