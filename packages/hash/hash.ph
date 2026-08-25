"""`hash` — the digests that are NOT SHA-2, and the checksum that is not a hash.

Three things live here, and the doc says out loud which of them you may trust:

* **CRC32** (IEEE, the one in gzip, zlib, PNG and `tar`) — a CHECKSUM. It catches
  a flipped bit on a wire or a disk, and it catches nothing at all from someone
  who is trying. Forging a CRC32 collision is arithmetic you can do by hand.
* **SHA-1** and **MD5** — cryptographic hashes that are **BROKEN**, both of them,
  with published collisions. They are here for one reason: **reading what already
  exists.** Git object ids are SHA-1; a great many HTTP and package indexes still
  publish MD5. A library that cannot read them cannot read the world.

> **Nothing here decides whether to trust something.** That is `sha2`, and the
> package manager already uses it (`pforge` verifies every download with SHA-256).
> If you are choosing, you are not choosing from this file.

**In P, and one-shot.** The boundary of 45.5 carries scalars, and the `CStr` /
`CBytes` of 84.1 carry a pointer with its length — which is what lets pscript call
straight into this without a second implementation. What does NOT cross is a P
struct, so the streaming trio (`init`/`update`/`final`) stays on the P side; that
is the `Foreign` case battery 141.6 parked on purpose.
"""

import <stl/cstr.ph>

# ---------- CRC32 (IEEE 802.3, the gzip/zlib/PNG one) ----------

def crc32_of(in data: CBytes) -> u32:
    """The CRC32 of the bytes. Reflected input and output, initial and final
    complement — the exact combination gzip uses, which is the whole reason this
    exists rather than one of the other CRC32s."""

def crc32_update(seed: u32, in data: CBytes) -> u32:
    """More bytes over a running CRC. `crc32_update(0, b)` is `crc32_of(b)`, and
    the pieces give the same answer as the whole — that is what lets a stream be
    checked without holding it."""

def crc32_hex(in data: CBytes) -> CStr:
    """The CRC32 as eight lowercase hex characters."""

# ---------- SHA-1 (FIPS 180-4 §6.1) — BROKEN, and here to READ ----------

def sha1_of(in data: CBytes) -> CStr:
    """SHA-1 as forty lowercase hex characters. **Not for deciding trust** — see
    the top of this file. For reading a git id, this is the function."""

# ---------- MD5 (RFC 1321) — BROKEN, and here to READ ----------

def md5_of(in data: CBytes) -> CStr:
    """MD5 as thirty-two lowercase hex characters. **Not for deciding trust.**"""
