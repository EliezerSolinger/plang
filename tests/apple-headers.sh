#!/usr/bin/env bash
# apple-headers.sh — runs the REAL macOS libc headers through plangc's C front
# end, on any machine, without a Mac.
#
# Why this exists: every macOS build failure so far came from a header shape that
# is invisible on Linux, and each one cost a round trip to the user's Mac. The
# headers themselves are open source (Apple's Libc, APSL 2.0), so they can be
# fetched and parsed here. They are NOT vendored into this repo — this script
# downloads them into tests/external/apple/ (gitignored), like fetch-external.sh.
#
# What it cannot do: link or run anything, and it does not have the real SDK's
# sys/cdefs.h or Availability.h. `prelude.h` below supplies those macros with the
# expansions clang produces on macOS, and empty stubs stand in for the SDK-only
# headers. So this tests the FRONT END against real declaration text, which is
# exactly where the failures have been. Preprocessing needs clang: Apple's
# headers gate constructs on __has_feature (`enumerator_attributes` decides
# whether clockid_t carries attributes at all), which gcc does not implement.
#
# The headers are ingested through a P `include`, not fed in as .c — that is the
# NON-STRICT path a real build uses, where an unknown type from an unstubbed
# header degrades to int instead of erroring.
#
#   bash tests/apple-headers.sh
set -eu
cd "$(dirname "$0")/.."
PLANGC=${PLANGC:-./plangc}
D=tests/external/apple
CPPBIN=${CPPBIN:-clang}

command -v "$CPPBIN" >/dev/null 2>&1 || { echo "skip: needs $CPPBIN (Apple headers gate on __has_feature)"; exit 0; }
[ -x "$PLANGC" ] || { echo "error: $PLANGC not built"; exit 1; }

mkdir -p "$D/stub"
BASE=https://raw.githubusercontent.com/apple-oss-distributions/Libc/main/include
HDRS="_time.h _stdlib.h _stdio.h _string.h _strings.h _locale.h _wchar.h _ctype.h"
for h in $HDRS; do
    [ -s "$D/$h" ] || curl -fsSL "$BASE/$h" -o "$D/$h" || { echo "skip: cannot fetch $h (offline?)"; exit 0; }
done

# The macros the SDK's sys/cdefs.h + Availability.h define, with the expansions
# clang uses on macOS. Anything wrong HERE shows up as a bogus parse failure, so
# when a header fails, check this file before blaming the front end.
cat > "$D/prelude.h" <<'PRELUDE'
#define __BEGIN_DECLS
#define __END_DECLS
#define __DARWIN_ALIAS(sym)                    __asm("_" #sym)
#define __DARWIN_ALIAS_C(sym)                  __asm("_" #sym)
#define __DARWIN_ALIAS_I(sym)                  __asm("_" #sym)
#define __DARWIN_EXTSN(sym)                    __asm("_" #sym "$DARWIN_EXTSN")
#define __DARWIN_ALIAS_STARTING(m,i,x)
#define __DARWIN_1050(x)
#define __API_AVAILABLE(...)                   __attribute__((availability(macos,introduced=10.12)))
#define __API_DEPRECATED(...)                  __attribute__((availability(macos,deprecated=10.12)))
#define __API_DEPRECATED_WITH_REPLACEMENT(...) __attribute__((availability(macos,deprecated=10.12)))
#define __API_UNAVAILABLE(...)
#define __OSX_AVAILABLE(v)                     __attribute__((availability(macos,introduced=10.13.4)))
#define __OSX_AVAILABLE_STARTING(m,i)          __attribute__((availability(macos,introduced=10.13.4)))
#define __OSX_AVAILABLE_BUT_DEPRECATED(a,b,c,d)       __attribute__((availability(macos,deprecated=10.12)))
#define __OSX_AVAILABLE_BUT_DEPRECATED_MSG(a,b,c,d,m) __attribute__((availability(macos,deprecated=10.12,message=m)))
#define __OSX_DEPRECATED(a,b,c)                __attribute__((availability(macos,deprecated=10.12)))
#define __POSIX_C_DEPRECATED(v)                __attribute__((deprecated))
#define __deprecated_msg(s)                    __attribute__((deprecated(s)))
#define __deprecated                           __attribute__((deprecated))
#define __printflike(a,b)                      __attribute__((format(printf,a,b)))
#define __scanflike(a,b)                       __attribute__((format(scanf,a,b)))
#define __header_always_inline static __inline __attribute__((__always_inline__))
#define __header_inline  static __inline
#define __IOS_PROHIBITED
#define __TVOS_PROHIBITED
#define __WATCHOS_PROHIBITED
#define __IOS_AVAILABLE(v)
#define __TVOS_AVAILABLE(v)
#define __WATCHOS_AVAILABLE(v)
#define __IOS_DEPRECATED(a,b,c)
#define __TVOS_DEPRECATED(a,b,c)
#define __WATCHOS_DEPRECATED(a,b,c)
#define __dead2                                __attribute__((noreturn))
#define __pure2                                __attribute__((const))
#define __pure                                 __attribute__((pure))
#define __unused                               __attribute__((unused))
#define __result_use_check                     __attribute__((warn_unused_result))
#define __alloc_size(...)
#define __swift_unavailable(m)
#define __swift_name(x)
#define __swift_nonisolated_unsafe
#define __cold
#define __disable_tail_calls
#define __not_tail_called
#define __const const
#define __volatile volatile
#define __signed signed
/* -fbounds-safety annotations (_bounds.h): empty unless __has_ptrcheck */
#define __has_ptrcheck 0
#define __unsafe_indexable
#define __null_terminated
#define __counted_by(x)
#define __sized_by(x)
#define _LIBC_SINGLE_BY_DEFAULT(...)
#define _LIBC_PTRCHECK_REPLACED(x)
#define _LIBC_COUNT(n)
#define _LIBC_COUNT_OR_NULL(n)
#define _LIBC_COUNT__L_CTERMID
#define _LIBC_COUNT__MB_LEN_MAX
#define _LIBC_COUNT__PATH_MAX
#define _LIBC_CSTR
#define _LIBC_NULL_TERMINATED
#define _LIBC_SIZE(n)
#define _LIBC_STAGED_BOUNDS_SAFETY_ATTRIBUTES
#define _LIBC_UNSAFE_INDEXABLE
#define __DARWIN_C_LEVEL 900000L
#define __DARWIN_C_FULL 900000L
#define __DARWIN_UNIX03 1
#define __DARWIN_NO_LONG_LONG 0
#define __DARWIN_CLK_TCK 100
#define __DARWIN_ONLY_64_BIT_INO_T 1
#define _DARWIN_C_SOURCE 1
#define SEEK_SET 0
#define NULL ((void*)0)
typedef unsigned long size_t;      typedef long ssize_t;
typedef long time_t;               typedef long clock_t;
typedef int errno_t;               typedef long rsize_t;
typedef long off_t;                typedef long fpos_t;
typedef int wint_t;                typedef int __darwin_wchar_t;
typedef __darwin_wchar_t wchar_t;  typedef unsigned short __darwin_wctype_t;
typedef unsigned int uid_t;        typedef unsigned int gid_t;
typedef int pid_t;                 typedef unsigned int mode_t;
typedef int dev_t;                 typedef unsigned int useconds_t;
typedef unsigned long ino_t;       typedef long __darwin_time_t;
typedef long __darwin_suseconds_t; typedef struct __locale_s *locale_t;
typedef unsigned char __uint8_t;   typedef unsigned short __uint16_t;
typedef unsigned int __uint32_t;   typedef unsigned long long __uint64_t;
typedef int __int32_t;             typedef long long __int64_t;
typedef long __intmax_t;           typedef unsigned long __uintmax_t;
typedef unsigned int uint32_t;     typedef unsigned long long uint64_t;
struct timeval { time_t tv_sec; int tv_usec; };
PRELUDE

# empty stand-ins for the SDK-only headers Libc's sources include
for f in _types.h sys/cdefs.h _bounds.h Availability.h _abort.h _assert.h \
         _printf.h _ctermid.h alloca.h stdint.h stddef.h limits.h \
         machine/types.h machine/_types.h malloc/_malloc.h sys/stdio.h \
         sys/wait.h sys/signal.h sys/types.h \
         sys/_types/_clock_t.h sys/_types/_null.h sys/_types/_size_t.h \
         sys/_types/_time_t.h sys/_types/_ct_rune_t.h sys/_types/_rune_t.h \
         sys/_types/_wchar_t.h sys/_types/_mbstate_t.h sys/_types/_offsetof.h \
         sys/_types/_ssize_t.h sys/_types/_locale_t.h sys/_types/_rsize_t.h \
         sys/_types/_errno_t.h sys/_types/_dev_t.h sys/_types/_mode_t.h \
         sys/_types/_uid_t.h sys/_types/_gid_t.h sys/_types/_pid_t.h \
         sys/_types/_off_t.h sys/_types/_fpos_t.h sys/_types/_wint_t.h \
         sys/_types/_seek_set.h sys/_types/_blkcnt_t.h sys/_types/_ino_t.h \
         sys/_types/_ino64_t.h sys/_types/_useconds_t.h sys/_types/_uintptr_t.h \
         _types/_uint8_t.h _types/_uint16_t.h _types/_uint32_t.h \
         _types/_uint64_t.h _types/_int32_t.h _types/_int64_t.h \
         _types/_intmax_t.h _types/_uintmax_t.h \
         _ctype.h _wctype.h __wctype.h ___wctype.h _xlocale.h __xlocale.h \
         _mb_cur_max.h _static_assert.h runetype.h ctype.h wctype.h \
         _locale_posix2008.h _monetary.h _langinfo.h; do
    mkdir -p "$D/stub/$(dirname "$f")"; : > "$D/stub/$f"
done
printf 'typedef __builtin_va_list va_list;\n'                > "$D/stub/sys/_types/_va_list.h"
printf 'struct timespec { time_t tv_sec; long tv_nsec; };\n' > "$D/stub/sys/_types/_timespec.h"

CPP="$CPPBIN -nostdinc -I$D -I$D/stub -include $D/prelude.h -fblocks"
pass=0; fail=0; skip=0
for h in $HDRS; do
    [ -s "$D/$h" ] || continue
    printf 'include "%s"\n\ndef main() -> i32:\n    return 0\n' "$h" > "$D/use.p"
    err=$($PLANGC --cpp "$CPP" "$D/use.p" -o /dev/null 2>&1 | head -1 || true)
    case "$err" in
      "")
        printf '   \033[32mOK\033[0m   %s\n' "$h"; pass=$((pass+1)) ;;
      *"failed to preprocess"*)
        # the PRELUDE/stubs are incomplete for this header, not the front end.
        # Reported apart so harness gaps never masquerade as compiler failures.
        printf '   \033[33mSKIP\033[0m %s (harness: stub/prelude incompleto)\n' "$h"
        skip=$((skip+1)) ;;
      *)
        printf '   \033[31mFAIL\033[0m %s\n        %s\n' "$h" "$err"; fail=$((fail+1)) ;;
    esac
done
echo "   apple-headers: $pass ok, $fail failed, $skip skipped (harness)"
[ "$fail" = 0 ]
