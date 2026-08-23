/* the C interface, found through `-Iinclude` — which is relative to the PACKAGE
   and not to whoever builds it. It is this line that `package_cflags` exists to
   rewrite. */
unsigned crc32_bytes(const char *data, unsigned n);
