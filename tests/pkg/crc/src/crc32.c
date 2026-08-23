/* CRC-32 (zip's and PNG's), with no table: a package can bring C, and this is
   the simplest C that still proves something — it depends on a `-D` the manifest
   declares (CRC_POLY) and on an `-I` the manifest declares. */
#include "crc32.h"

#ifndef CRC_POLY
#error "CRC_POLY had to come from the manifest"
#endif

unsigned crc32_bytes(const char *data, unsigned n) {
    unsigned c = 0xFFFFFFFFu;
    unsigned i, k;
    for (i = 0; i < n; i++) {
        c ^= (unsigned char)data[i];
        for (k = 0; k < 8; k++)
            c = (c >> 1) ^ (CRC_POLY & (unsigned)(-(int)(c & 1u)));
    }
    return c ^ 0xFFFFFFFFu;
}
