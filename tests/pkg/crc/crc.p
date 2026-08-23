import "crc.ph"
include <string.h>
include "crc32.h"

def crc32_of(s: const *char) -> u32:
    """The CRC-32 of a C string. The arithmetic happens in the package's C."""
    return u32(crc32_bytes(s, u32(strlen(s))))
