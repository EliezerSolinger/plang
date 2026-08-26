#!/usr/bin/env bash
# packages.sh — `import <pkg/mod.ph>`: the package as a SEARCH PATH (F1).
#
# What is pinned down here is the boundary decided in `pforge/ARQUITETURA.md`:
# the compiler does NOT know what a package is. It receives search roots
# (`--pkg-path`, repeatable) and looks in them, in order — the same rule as C's
# `-I`, and for the same reason: it is the only one you can explain in one line.
# Who knows what a version, a dependency and a resolution are is `pforge`.
#
# Three forms, with no ambiguity at all between them:
#
#   include <stdio.h>        a system C header
#   import <stl/vec.ph>      a module of a PACKAGE, looked up in the roots
#   import "neighbour.ph"    a module next to the file, as always
#
# And there is NO fallback from one to the other: a `<>` that is not found is an
# error, and does not become a relative attempt. A silent fallback would make a
# program compile by accident against the wrong file.
set -u
cd "$(dirname "$0")/.."

PLANGC=${PLANGC:-build/bin/plangc_s2}
CC=${CC:-cc}
OUT=${OUT:-tests/out/packages}
PKG=tests/pkg
PSDEFS="-D_POSIX_C_SOURCE=200112L -D_DEFAULT_SOURCE -D_DARWIN_C_SOURCE"   # macOS's equivalent of _DEFAULT_SOURCE (tests/psbuild.sh)
rm -rf "$OUT"; mkdir -p "$OUT"
pass=0; fail=0

ok()   { pass=$((pass+1)); }
bad()  { echo "  FAIL $1"; fail=$((fail+1)); }
# equality with a message: what was expected and what came out, without the
# reader having to guess which is which
check() {
    if [ "$2" = "$3" ]; then pass=$((pass+1))
    else echo "  FAIL $1: expected '$2', got '$3'"; fail=$((fail+1)); fi
}

# ---- 1. P: a program using two packages, one of them depending on the other ----
cat > "$OUT/prog.p" <<'EOP'
include <stdio.h>
import <txt/txt.ph>

def main() -> int:
    printf("%lld %lld %lld\n", geo_area(3, 4), geo_perim(3, 4), txt_double_area(3, 4))
    return 0
EOP
if $PLANGC --pkg-path "$PKG" --out-dir "$OUT/o" "$OUT/prog.p" 2>"$OUT/p.err"; then
    if $CC -O2 -w -o "$OUT/prog" $(find "$OUT/o" -name '*.c') 2>>"$OUT/p.err"; then
        got=$("$OUT/prog")
        [ "$got" = "12 14 24" ] && ok || bad "P: output '$got', expected '12 14 24'"
    else
        bad "P: does not link"; head -3 "$OUT/p.err"
    fi
else
    bad "P: does not compile"; head -3 "$OUT/p.err"
fi

# the package's `.p` was PULLED IN without being named: that is what makes a
# package a unit instead of a list of files its user has to know
find "$OUT/o" -name 'geo.c' | grep -q . && ok || bad "P: the package's .p was not compiled"
find "$OUT/o" -name 'txt.c' | grep -q . && ok || bad "P: the second-level package's .p was not compiled"

# ---- 2. the protocol's answers can see the package ----
deps=$($PLANGC --pkg-path "$PKG" --deps "$OUT/prog.p" 2>&1)
echo "$deps" | grep -q "$PKG/geo/geo.ph" && ok || bad "--deps does not list the package's header"
echo "$deps" | grep -q "$PKG/geo/geo.p"  && ok || bad "--deps does not list the package's code"
outs=$($PLANGC --pkg-path "$PKG" --outputs --out-dir "$OUT/o" "$OUT/prog.p" 2>&1)
echo "$outs" | grep -q "geo.c" && ok || bad "--outputs does not list the package's .c"
echo "$outs" | grep -q "geo.h" && ok || bad "--outputs does not list the package's .h"

# ---- 3. the error SAYS WHERE IT LOOKED ----
e=$($PLANGC --out-dir "$OUT/x" "$OUT/prog.p" 2>&1)
echo "$e" | grep -q "not found in any package root" && ok || bad "error with no root: wrong message"
echo "$e" | grep -q -- "--pkg-path" && ok || bad "error with no root: does not say how to give one"
e=$($PLANGC --pkg-path /does/not/exist --pkg-path /another --out-dir "$OUT/x" "$OUT/prog.p" 2>&1)
echo "$e" | grep -q "looked in: /does/not/exist /another" && ok || bad "error: does not list the roots searched"

# ---- 4. `<>` does NOT fall back to relative ----
mkdir -p "$OUT/neighbour"
cat > "$OUT/neighbour/side.ph" <<'EOP'
def side_one() -> i64
EOP
cat > "$OUT/neighbour/uses.p" <<'EOP'
import <side.ph>
def main() -> int:
    return i32(side_one())
EOP
e=$($PLANGC --out-dir "$OUT/x" "$OUT/neighbour/uses.p" 2>&1)
echo "$e" | grep -q "not found in any package root" && ok || bad "<> fell back to the relative path"

# ---- 5. pscript: the same package, from the other side ----
cat > "$OUT/pprog.psc" <<'EOP'
import <geo/geo.ph>

print("area:", geo_area(3, 4))
print("perim:", geo_perim(3, 4))
EOP
RT="$OUT/rt"
mkdir -p "$RT"
# 1.5(a): the umbrella is enough (see check 8, which is about exactly this)
RTSRC="pscript/runtime/psrt.ph"
if $PLANGC --out-dir "$RT" $RTSRC 2>"$OUT/rt.err" &&
   $PLANGC --pkg-path "$PKG" --out-dir "$RT" "$OUT/pprog.psc" 2>"$OUT/ps.err"; then
    if $CC -std=c11 -O0 $PSDEFS -w -o "$OUT/pprog" "$RT/$OUT/pprog.c" \
           "$RT"/pscript/runtime/psrt_*.c $(find "$RT/$PKG" -name '*.c') \
           -lm -pthread 2>>"$OUT/ps.err"; then
        got=$("$OUT/pprog")
        [ "$got" = "area: 12
perim: 14" ] && ok || bad "pscript: output '$got'"
    else
        bad "pscript: does not link"; head -3 "$OUT/ps.err"
    fi
else
    bad "pscript: does not compile"; head -3 "$OUT/ps.err"
fi
deps=$($PLANGC --pkg-path "$PKG" --deps "$OUT/pprog.psc" 2>&1)
echo "$deps" | grep -q "$PKG/geo/geo.p" && ok || bad "pscript --deps does not list the package's code"

# ---- 6. root and sources in different spaces: a CLEAR error, not a broken include ----
e=$($PLANGC --pkg-path "$PWD/$PKG" --out-dir "$OUT/x" "$OUT/prog.p" 2>&1)
echo "$e" | grep -q "named the same way" && ok || bad "mixed spaces: it should refuse with a message"

# (the workspace `pack.json` and the root that comes out of it have their own
# gate in the engine's suite — `case_manifest` in `pforge/src/engine_test.psc` —
# because whoever reads them is pscript, and the gate lives next to the code it
# tests)

# ---- 7. a PSCRIPT package: the two spellings ----
# `<color>` is the package's root (the module named after it); `<color/shades.psc>`
# is an internal module. The namespace's name is the last piece without the
# extension, in both.
cat > "$OUT/uses.psc" <<'EOP'
import <color>
import <color/shades.psc>
import <color/shades.psc> as s2

print(color.name(), color.lighten(10))
print(shades.dark(), s2.dark())
EOP
RT2="$OUT/rt2"
mkdir -p "$RT2"
if $PLANGC --pkg-path packages --out-dir "$RT2" pscript/runtime/psrt.ph 2>"$OUT/rt2.err" &&
   $PLANGC --pkg-path "$PKG" --out-dir "$RT2" "$OUT/uses.psc" 2>"$OUT/uses.err"; then
    if $CC -std=c11 -O0 $PSDEFS -w -o "$OUT/uses" "$RT2/$OUT/uses.c" \
           "$RT2"/pscript/runtime/psrt_*.c -lm -pthread 2>>"$OUT/uses.err"; then
        got=$("$OUT/uses")
        [ "$got" = "color 26
32 32" ] && ok || bad "pscript package: output '$got'"
    else
        bad "pscript package: does not link"; head -3 "$OUT/uses.err"
    fi
else
    bad "pscript package: does not compile"; head -3 "$OUT/uses.err"
fi

# `<pkg>` without the package in a root is an error, and not a relative attempt
e=$($PLANGC --out-dir "$OUT/x" "$OUT/uses.psc" 2>&1)
echo "$e" | grep -q "not found in any package root" && ok || bad "pscript <pkg> fell back to relative"

# ---- 8. 1.5(a): naming ONE file builds its closure ----
# It is what makes the six module lists scattered through the harnesses
# redundant: pscript's whole runtime comes out of naming its umbrella.
rm -rf "$OUT/closure"
$PLANGC --pkg-path packages --out-dir "$OUT/closure" pscript/runtime/psrt.ph 2>"$OUT/closure.err"
n=$(ls "$OUT/closure"/pscript/runtime/*.c 2>/dev/null | wc -l)
check "1.5(a): the whole runtime comes from one file" "6" "$n"

# and with `-o` the old contract still holds: ONE artifact
rm -rf "$OUT/one"; mkdir -p "$OUT/one"
$PLANGC -o "$OUT/one/geom.c" "$PKG/geo/geo.p" --pkg-path "$PKG" 2>/dev/null
n2=$(ls "$OUT/one"/*.c 2>/dev/null | wc -l)
check "1.5(a): with -o, a single file" "1" "$n2"

# ---- 9. a PROTOTYPE's docstring ----
doc=$($PLANGC --api "$PKG/geo/geo.ph" 2>&1 | grep '^#doc geo_area ')
case $doc in
    "#doc geo_area The area of the w x h rectangle.") ok ;;
    *) bad "prototype doc: got '$doc'" ;;
esac

# ---- 2.13: a package that brings HAND-WRITTEN C ----
#
# Here only the COMPILER's half is measured: that it resolves `<crc/crc.ph>`,
# that the `.p`'s `include "crc32.h"` crosses into the emitted C, and that the
# package's `.c` goes through our front end with the flags the manifest declares.
# The other half — whoever reads the manifest, rewrites the `-I` against the
# package's directory and links the object — belongs to the build system, and has
# a gate in the engine's suite.
cat > "$OUT/uses_crc.p" <<'EOP'
include <stdio.h>
import <crc/crc.ph>

def main() -> int:
    printf("%u\n", crc32_of("123456789"))
    return 0
EOP
CRCFLAGS="-DCRC_POLY=0xEDB88320 -I$PKG/crc/include"
if $PLANGC --pkg-path "$PKG" --cpp "$CC $CRCFLAGS" --out-dir "$OUT/oc" "$OUT/uses_crc.p" 2>"$OUT/crc.err"; then
    ok
    # and the package's `.c` through OUR front end, which is decision 2.13
    if $PLANGC --cpp "$CC $CRCFLAGS" --out-dir "$OUT/oc" "$PKG/crc/src/crc32.c" 2>>"$OUT/crc.err"; then
        ok
        if $CC -O2 -w $CRCFLAGS -o "$OUT/uses_crc" $(find "$OUT/oc" -name '*.c') 2>>"$OUT/crc.err"; then
            check "the CRC-32 of 123456789" "3421780262" "$("$OUT/uses_crc")"
        else bad "the package's C did not link (see $OUT/crc.err)"; fi
    else bad "the package's .c did not go through our front end (see $OUT/crc.err)"; fi
else bad "a program importing <crc/crc.ph> did not compile (see $OUT/crc.err)"; fi
# the package C's `#error` is the gate from the negative side: without the
# manifest's `-D`, it HAS to refuse — otherwise the test above would pass even if
# the flags had never arrived
if $PLANGC --out-dir "$OUT/oc2" "$PKG/crc/src/crc32.c" >/dev/null 2>&1; then
    bad "the package's .c should refuse without the -D the manifest declares"
else ok; fi

echo "   packages: $pass ok, $fail failed"
[ $fail = 0 ]
