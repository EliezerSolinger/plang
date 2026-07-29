/* The way macOS actually declares the standard streams: the objects carry
 * INTERNAL names and the public spellings are object-like macros.
 *   Libc/include/_stdio.h:  extern FILE *__stdinp;  ... #define stdin __stdinp
 * glibc instead declares `extern FILE *stderr;` outright, which is why P code
 * writing `stderr` built on Linux and died on macOS with
 *   pstudio/main.p:34:21: error: use of undeclared identifier 'stderr'
 * A P source is never run through cpp, so the macro cannot apply itself — sema
 * has to follow the rename. See Sema.macroalias / ingest_macros.
 */
#ifndef MACRO_ALIAS_H
#define MACRO_ALIAS_H

/* objects under internal names, public names as macros — the Darwin shape */
extern int ma_real_value;
extern int ma_real_fn(int x);
#define ma_value ma_real_value
#define ma_fn    ma_real_fn

/* a chain, which the alias passes already handled for constants */
#define ma_value2 ma_value

/* an alias to an integer constant must keep resolving as a CONSTANT, not as an
 * identifier rename — the two paths must not interfere */
#define MA_LIMIT 7
#define MA_LIMIT_ALIAS MA_LIMIT
#endif
