"""SHA-256, the hash that answers "is this what they said it was?".

The `hash_bytes` this repository already had is FNV-1a: excellent for deciding
whether a build output changed, and **useless against an adversary** — anyone who
wants to forge an FNV collision can do it on a sheet of paper. A package manager
that downloads code needs the other thing, and this is it.

Written in P and with no dependencies at all, which makes it usable by the
compiler, by `ppack`, and by any program in either language (pscript reaches it
through `import <sha2/sha2.ph>`, which is the 45.5 boundary: signatures without
pointers cross, and these cross).

The implementation is FIPS 180-4 §6.2, with no cleverness whatsoever: the
constants are the cube roots of the first 64 primes, the message is padded with a
1 bit, zeros, and the length in bits as a big-endian 64-bit integer. There is no
optimization here to depend on; there is a test with the official vectors.
"""

import <stl/cstr.ph>

# The state of a hash in progress: whoever has all the bytes in hand uses
# `sha256_hex`, and whoever has them in pieces (a large file, a socket) uses the
# init/update/final trio.
struct Sha256:
    h: u32[8]
    buf: u8[64]
    nbuf: usize
    total: u64

def sha256_init(out s: Sha256):
    """Starts a hash. The state belongs to the caller — there is no allocation and
    no global state, so two hashes in progress at once do not see each other."""

def sha256_update(ref s: Sha256, data: const *char, n: usize):
    """More bytes. It can be called as many times as needed, and the result is the
    same as a single call with everything at once — that is what allows hashing a
    large file without holding it all in memory."""

def sha256_final(ref s: Sha256, out_digest: *char):
    """Closes the hash and writes **32 bytes** into `out_digest`. After this the
    state is good for nothing else."""

def sha256_hex(data: const *char, n: usize, out_hex: *char):
    """The short path: all the bytes, and sixty-four lowercase hexadecimal digits
    plus the terminator — `out_hex` has to hold 65 bytes.

    This is the one the package manager uses: a tarball's hash, compared with what
    the index declared."""

# ---------- the crossing into pscript (45.5/84.1) ----------
#
# The ONLY dependency of this package, and it is only a type one: `CStr`/`CBytes`
# are a pointer+length pair declared in `stl`, with no code behind them
# (`cstr.ph` has no `.p`). The core — init/update/final/hex — still depends on
# nothing at all.
#
# A `CBytes` is a pointer and its length as a VALUE: on the pscript side this is
# `list<u8>`, and what crosses is the pair, assembled at the call and valid for as
# long as it lasts. The answer comes back as a `CStr`, which on the other side is
# a `str`.
#
# It is the same implementation — there is no second copy of SHA-256 in pscript,
# and that is the reason the package is in P: the language without a runtime is
# the one both of them reach.
def sha256_of(in data: CBytes) -> CStr:
    """The hash of some bytes, as text.

    >>> sha256_of([u8(97), u8(98), u8(99)])
    ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
    >>> len(sha256_of([u8(0)]))
    64
    """


# ---------- SHA-512 (FIPS 180-4 §6.4) ----------
#
# It is the same design at twice the width: 64-bit words, 128-byte blocks, eighty
# rounds, and the length at the end takes 128 bits instead of 64. The rotations
# are different because the specification chose them for the new width.
#
# It exists because Ed25519 demands it (RFC 8032): the signature is defined over
# SHA-512 and not over any hash. An implementation that swapped the hash would not
# be Ed25519 — it would be something else with the same name, and keys from
# elsewhere would not work.

struct Sha512:
    h: u64[8]
    buf: u8[128]
    nbuf: usize
    total: u64        # bytes; the padding's 128-bit field has its high half zero

def sha512_init(out s: Sha512):
    """Starts a 512-bit hash. Like the 256-bit one: the state belongs to the
    caller."""

def sha512_update(ref s: Sha512, data: const *char, n: usize):
    """More bytes."""

def sha512_final(ref s: Sha512, out_digest: *char):
    """Closes and writes **64 bytes**."""

def sha512_hex(data: const *char, n: usize, out_hex: *char):
    """The short path: 128 hexadecimal digits plus the terminator (129 bytes)."""

def sha512_of(in data: CBytes) -> CStr:
    """The 512-bit one, as text — 128 digits.

    >>> len(sha512_of([u8(97)]))
    128
    """
