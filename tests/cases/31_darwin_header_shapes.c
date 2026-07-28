/* C-input shapes the macOS SDK headers are full of. Each one broke the C front
 * end on macOS while being invisible on Linux, so they are pinned here.
 *
 * 1. A PREPROCESSING-NUMBER that is not a valid numeric constant. C11 6.4.8
 *    lets a pp-number be `10.13.4`; it is ill-formed only when USED as a value.
 *    `__API_AVAILABLE(macos(10.13.4))` expands to the availability attribute
 *    below, so <stdlib.h> is full of them inside constructs we skip. Validating
 *    at tokenize time made the header unparseable:
 *      stdlib.h:750: malformed number constant '10.13.4'
 *    (tests/errors/lex_bad_suffix.c pins that a pp-number used AS A VALUE is
 *    still rejected — moving the check must not lose the diagnostic.)
 *
 * 2. clang's nullability qualifiers, which sit right after a '*' and mean
 *    nothing to codegen. Both the `_Nullable` and the older `__nullable`
 *    spellings appear depending on the SDK.
 *
 * 3. `__asm("_name")` renaming, which is what __DARWIN_ALIAS expands to.
 *
 * 4. C11 `_Alignas`, in both its integer and its type form.
 */
#include <stdio.h>

extern int mac_only(int x)
    __attribute__((availability(macos, introduced = 10.13.4)));

/* nullability, in every position the SDK uses it */
static int conta(const char *_Nonnull s, char *_Nullable out,
                 char *_Null_unspecified spare, char *__nullable velho) {
    int n = 0;
    while (s[n] != '\0') n++;
    if (out != ((void *)0)) out[0] = s[0];
    (void)spare;
    (void)velho;
    return n;
}

/* __asm rename + availability on the same declaration */
extern int nao_usada(void)
    __attribute__((availability(macos, introduced = 10.6))) __asm("_nao_usada");

_Alignas(16) static char alinhado[16];
_Alignas(long double) static char alinhado2[16];

int main(void) {
    char buf[4] = {0};
    printf("%d\n", conta("darwin", buf, buf, buf));
    printf("%c\n", buf[0]);
    printf("%d %d\n", (int)sizeof alinhado, (int)sizeof alinhado2);
    return 0;
}
