# hash.ph — STL hash functions (ported from the jaketa runtime)
# FNV-1a for bytes/strings; splitmix64 for integers; combiner for composites.
# Deterministic, no HashDoS protection — do not use with adversarial keys.
#
# Header-only: static inline, nothing to link.

static inline def hash_bytes(data: const *char, len: usize) -> u64:
    h: u64 = 0xcbf29ce484222325
    i: usize = 0
    while i < len:
        h = (h ^ u64(data[i] & 0xFF)) * 0x100000001b3
        i += 1
    return h

static inline def hash_cstr(s: const *char) -> u64:
    h: u64 = 0xcbf29ce484222325
    while *s != '\0':
        h = (h ^ u64(*s & 0xFF)) * 0x100000001b3
        s += 1
    return h

static inline def hash_u64(x: u64) -> u64:
    x += 0x9e3779b97f4a7c15
    x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9
    x = (x ^ (x >> 27)) * 0x94d049bb133111eb
    return x ^ (x >> 31)

static inline def hash_combine(a: u64, b: u64) -> u64:
    return a ^ (b + 0x9e3779b97f4a7c15 + (a << 6) + (a >> 2))
