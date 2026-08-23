/* a interface do C, achada por `-Iinclude` — que é relativo ao PACOTE e não a
   quem o constrói. É esta linha que o `cflags_do_pacote` existe para reescrever. */
unsigned crc32_bytes(const char *data, unsigned n);
