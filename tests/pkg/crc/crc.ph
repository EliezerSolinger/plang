"""CRC-32 — e a razão de este pacote existir.

Ele é o caso da 2.13: um pacote que traz **C escrito à mão**. O `.p` daqui não
implementa nada — ele DECLARA o que o C oferece (`include "crc32.h"`) e reexporta
com um nome de P. Quem constrói é que sabe compilar aquele `.c`, com as flags que
o manifesto declarou, e ligá-lo ao programa.
"""
def crc32_de(s: const *char) -> u32
