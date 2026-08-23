/* CRC-32 (o do zip e do PNG), sem tabela: um pacote pode trazer C, e este é o
   C mais simples que ainda prova alguma coisa — ele depende de um `-D` que o
   manifesto declara (CRC_POLY) e de um `-I` que o manifesto declara. */
#include "crc32.h"

#ifndef CRC_POLY
#error "CRC_POLY tinha de vir do manifesto"
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
