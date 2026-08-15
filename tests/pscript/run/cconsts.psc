"""Constants a C header gives (72.4).

The boundary used to ingest FUNCTIONS only, so every `#define`, every `enum`
member and every `static const` of a real C library had to be retyped on this
side — which is where the error by staleness lives. They cross now, as the
numbers they are: the read becomes the literal, and nothing of the header
survives into the program.
"""

include <stdio.h>
include <limits.h>

print(EOF, SEEK_SET, SEEK_CUR, SEEK_END)
print(INT_MAX, CHAR_BIT)
n = EOF
print(n == -1, SEEK_END + 1)
