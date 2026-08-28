"""Ed25519 (RFC 8032): the signature that closes safe mode.

A repository is a format and trust comes from the CONTENT, not from the
connection. The hash already says "this is what they said it was"; the other half
is missing — "and whoever said it is who I think". There are two signatures, with
different owners and for different reasons:

  * the INDEX is signed by the REPOSITORY, and it is what stops somebody in the
    middle from answering with an old list (where the flawed version is still the
    latest);
  * each VERSION is signed by the AUTHOR, and it is what stops the repository
    itself from serving a tarball the author did not make.

Ed25519 was chosen over RSA and ECDSA for three reasons that each read in one
line: the public key is 32 bytes and the signature 64 (they fit in a JSON without
hurting); it needs no randomness at signing time (it is deterministic, and a bad
generator does not leak the key the way it does in ECDSA); and verification has no
special cases that can be silently implemented wrong.

**What this package does NOT promise: constant time.** The scalar multiplication
is double-and-add over the scalar's bits, and the time depends on them. For
VERIFYING that is irrelevant — there is no secret in verification at all. For
SIGNING, on a computer shared with an adversary able to measure, it is a real
weakness. It is written here instead of being hidden: whoever signs versions on
such a machine has a bigger problem than this package.

The arithmetic is deliberately the simplest that can be checked by reading:
256-bit integers in eight 32-bit words, schoolbook multiplication, and reduction
modulo 2^255 - 19 using 2^256 ≡ 38. There is no representation trick here
(`ref10` uses ten 25.5-bit limbs) because this signs half a dozen things per
publication, and what you would gain in speed you pay in who can review it.
"""

import <stl/cstr.ph>
include <string.h>

const ED25519_SEED_LEN: usize = 32
const ED25519_PUB_LEN: usize = 32
const ED25519_SIG_LEN: usize = 64

def ed25519_pubkey(seed: const *char, out_pub: *char):
    """The public key matching a 32-byte seed.

    The seed IS the private key: the rest (the scalar and the prefix) comes out of
    it through SHA-512, which makes a private key thirty-two bytes you keep and
    nothing else."""

def ed25519_sign(seed: const *char, pub: const *char, msg: const *char, n: usize, out_sig: *char):
    """Signs `n` bytes. The signature is 64 bytes and DETERMINISTIC: the same
    message with the same key always gives the same signature, which also means
    there is no random generator at all between the key and the result."""

def ed25519_verify(pub: const *char, msg: const *char, n: usize, sig: const *char) -> bool:
    """Verifies. Returns `False` for anything that is not a valid signature of
    this message by this key — including a key that is not a point on the curve, an
    `S` out of range, and the small-order points the RFC requires to be
    refused."""

# ---------- the crossing into pscript (45.5/84.1) ----------

def ed25519_pub_hex(in seed: CBytes) -> CStr:
    """The public key, in hexadecimal. It is the form that goes into `pack.lock`
    and into the index — text, because that is where it lives.

    The vector is the first in RFC 8032 §7.1: the same seed always gives the same
    key, because there is no randomness after the seed.

    >>> len(ed25519_pub_hex([u8(0) for _ in range(32)]))
    64
    """

def ed25519_password_hex(in password: CBytes, in scramble: CBytes) -> CStr
def ed25519_sign_hex(in seed: CBytes, in msg: CBytes) -> CStr:
    """The signature in hexadecimal (128 digits)."""

def ed25519_verify_hex(in pub_hex: CStr, in msg: CBytes, in sig_hex: CStr) -> bool:
    """Verifies, with the key and the signature as text. A hexadecimal of the
    wrong length or with a digit that is not a digit is `False`, and not an error:
    from the verifier's point of view, a damaged file and a wrong signature are
    the same answer.

    >>> ed25519_verify_hex("abc", [u8(1)], "def")
    False
    """
