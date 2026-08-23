import "crc.ph"
include <string.h>
include "crc32.h"

def crc32_de(s: const *char) -> u32:
    """O CRC-32 de uma string C. A conta acontece no C do pacote."""
    return u32(crc32_bytes(s, u32(strlen(s))))
