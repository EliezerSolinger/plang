#!/usr/bin/env bash
# tests/protocol.sh — the compiler's answers to the build system (F0).
#
# `pbuild` decides what to recompile, and to decide it ASKS. There are four
# questions, and each one exists because the alternative is worse:
#
#   --version   who are you? The LANGUAGE's version (a package's manifest
#               declares the range it requires) and the hash of its own bytes (it
#               is that hash that decides dirtiness: another compiler, another C).
#   --deps      what did you read? Without this, whoever assembles the graph has
#               to reimplement import resolution — and a second implementation
#               that diverges gives you a stale build after an edit, the only way
#               of failing that matters.
#   --outputs   what are you GOING to emit? The graph needs the edges BEFORE the
#               tool runs (it is ninja's `dyndep`, with no file at all).
#   --api       what is your public interface? It serves the docs, the semver
#               check on publication, and the QBE path, which has no header.
#
# What these checks PIN DOWN, and it is the point of the whole thing: the API's
# hash cannot change when a comment or a parameter's name changes (otherwise
# editing docs recompiles the world), and it HAS to change when a type, a field
# or an enum's value changes (otherwise the build is left holding a stale
# interface).
set -u
cd "$(dirname "$0")/.."

PLANGC=${PLANGC:-build/bin/plangc_s2}

# the hash comes on a line of ITS OWN (`#hash ...`), and the docstrings come
# AFTER it — so it is that line you look for, and not the report's last one
apihash() { $PLANGC --api "$1" 2>&1 | grep '^#hash '; }
OUT=tests/out/protocol
rm -rf "$OUT"; mkdir -p "$OUT"
fail=0
ok=0

check() { # check <what> <expected> <got>
    if [ "$2" = "$3" ]; then ok=$((ok+1)); else
        echo "  FAIL $1: expected '$2', got '$3'"; fail=$((fail+1))
    fi
}
checkne() { # checkne <what> <not expected> <got>
    if [ "$2" != "$3" ]; then ok=$((ok+1)); else
        echo "  FAIL $1: should NOT be '$2'"; fail=$((fail+1))
    fi
}

# a fake P module, with a `.ph` that is the interface and a `.p` that implements it
cat > "$OUT/geom.ph" <<'EOF'
import "vecs.ph"

const GEOM_MAX: i32 = 64

enum Shape:
    SH_DOT = 0
    SH_LINE
    SH_BOX = 7

struct Point:
    x: i32
    y: i32

def area(w: i32, h: i32) -> i64
def scale(p: *Point, by: i32)
EOF
cat > "$OUT/geom.p" <<'EOF'
import "geom.ph"

def area(w: i32, h: i32) -> i64:
    return i64(w) * i64(h)

def scale(p: *Point, by: i32):
    p->x *= by
    p->y *= by

private def helper_that_is_not_interface(n: i32) -> i32:
    return n + 1
EOF
cat > "$OUT/vecs.ph" <<'EOF'
def vecs_marker() -> i32
EOF

# ---- --version: the language's version and the hash of the bytes ----
ver=$($PLANGC --version 2>&1)
case $ver in
    "plangc "*" ("*")") ok=$((ok+1)) ;;
    *) echo "  FAIL --version: unexpected format: '$ver'"; fail=$((fail+1)) ;;
esac
# the hash is of the compiler's BYTES: the same binary always answers the same
check "--version is stable" "$ver" "$($PLANGC --version 2>&1)"

# ---- --deps: transitive, normalized, without repeating ----
deps=$($PLANGC --deps "$OUT/geom.p" 2>&1)
check "--deps: the file itself" "1" "$(echo "$deps" | grep -c "geom\.p$")"
check "--deps: the header it imports" "1" "$(echo "$deps" | grep -c "geom\.ph$")"
check "--deps: transitive (the header's import)" "1" "$(echo "$deps" | grep -c "vecs\.ph$")"
check "--deps: no repetition" "$(echo "$deps" | wc -l)" "$(echo "$deps" | sort -u | wc -l)"
# a path with `..` in the middle is the SAME file: a graph that saw them as two
# nodes would recompile for nothing
deps2=$($PLANGC --deps "$OUT/../protocol/geom.p" 2>&1)
check "--deps: normalized path" "$deps" "$deps2"

# ---- --outputs: what would come out, without coming out ----
# Since 1.5(a) the answer is the CLOSURE's, not the file's: naming `geom.p` with
# `--out-dir` builds what it imports, so the imported header's `vecs.h` enters
# the list. It is the whole change from the point of view of whoever consumes it
# — and it is what lets a build system name one file instead of forty.
outs=$($PLANGC --outputs --out-dir "$OUT/build" "$OUT/geom.p" "$OUT/geom.ph" 2>&1)
check "--outputs: the .c, the .h and the imported header's" \
      "$OUT/build/$OUT/geom.c $OUT/build/$OUT/geom.h $OUT/build/$OUT/vecs.h" "$(echo $outs)"
# and with `-o` the old contract still holds: ONE artifact, this name
outs1=$($PLANGC --outputs -o "$OUT/build/so.c" "$OUT/geom.p" 2>&1)
check "--outputs: with -o, just one" "$OUT/build/so.c" "$(echo $outs1)"
check "--outputs: writes nothing" "0" "$(ls "$OUT/build" 2>/dev/null | wc -l)"

# ---- --api: the interface, and only it ----
api=$($PLANGC --api "$OUT/geom.ph" 2>&1)
check "--api: the public const with its VALUE" "1" "$(echo "$api" | grep -c 'const GEOM_MAX: i32 = 64')"
check "--api: the enum with the values" "1" "$(echo "$api" | grep -c 'enum Shape {SH_DOT = 0, SH_LINE, SH_BOX = 7}')"
check "--api: the struct with its layout" "1" "$(echo "$api" | grep -c 'struct Point {x: i32, y: i32}')"
check "--api: the signature without parameter names" "1" "$(echo "$api" | grep -c 'def area(i32, i32) -> i64')"
# in a `.p`, what is `private` is nobody's interface
apip=$($PLANGC --api "$OUT/geom.p" 2>&1)
check "--api: the .p's public part" "1" "$(echo "$apip" | grep -c 'def area(i32, i32) -> i64')"
check "--api: the private stays out" "0" "$(echo "$apip" | grep -c 'helper_that_is_not_interface')"

h0=$(apihash "$OUT/geom.ph")

# ---- INVARIANCE: a comment and a parameter's name are not interface ----
cp "$OUT/geom.ph" "$OUT/geom.ph.orig"
python3 - "$OUT/geom.ph" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('def area(w: i32, h: i32) -> i64',
              '# a comment that changes no interface at all\ndef area(width: i32, height: i32) -> i64', 1)
open(p, 'w').write(s)
PY
check "hash: a comment and a renamed parameter do NOT change it" "$h0" "$(apihash "$OUT/geom.ph")"

# ---- SENSITIVITY: a type, a layout and a value ARE interface ----
for change in 's/def area(w: i32, h: i32) -> i64/def area(w: i32, h: i32) -> i32/' \
              's/    y: i32/    y: i64/' \
              's/    SH_BOX = 7/    SH_BOX = 8/' \
              's/const GEOM_MAX: i32 = 64/const GEOM_MAX: i32 = 65/' ; do
    cp "$OUT/geom.ph.orig" "$OUT/geom.ph"
    python3 - "$OUT/geom.ph" "$change" <<'PY'
import sys, re
p, sed = sys.argv[1], sys.argv[2]
_, pat, rep, _ = sed.split('/')
s = open(p).read()
assert pat in s, "the change did not find its target: " + pat
open(p, 'w').write(s.replace(pat, rep, 1))
PY
    checkne "the hash changes: $change" "$h0" "$(apihash "$OUT/geom.ph")"
done

# ---- the answer is stable across runs (it is a cache key) ----
cp "$OUT/geom.ph.orig" "$OUT/geom.ph"
check "hash: same input, same answer" "$h0" "$(apihash "$OUT/geom.ph")"

# ---- the DOCSTRING: it comes out in the answer, and does NOT enter the hash ----
# It is the decision that makes `--api` serve both questions at once: "did the
# interface change?" (the hash, which is structural) and "what does this do?"
# (the docs). Changing a documentation text cannot wake up whoever only depends
# on the interface.
cp "$OUT/geom.ph.orig" "$OUT/geom.ph"
h0=$(apihash "$OUT/geom.ph")
printf '"""The geometry package.\n\nWith a second line."""\n' > "$OUT/geom2.ph"
cat "$OUT/geom.ph" >> "$OUT/geom2.ph"
mv "$OUT/geom2.ph" "$OUT/geom.ph"
check "hash: the module's docstring does NOT change the interface" "$h0" "$(apihash "$OUT/geom.ph")"

doc=$($PLANGC --api "$OUT/geom.ph" 2>&1 | grep '^#doc \. ')
expected='#doc . The geometry package.\n\nWith a second line.'
check "doc: it comes out in the answer, with the break escaped" "$expected" "$doc"

# and it comes AFTER the hash — which is what lets you read one without the other
lh=$($PLANGC --api "$OUT/geom.ph" 2>&1 | grep -n '^#hash ' | cut -d: -f1)
ld=$($PLANGC --api "$OUT/geom.ph" 2>&1 | grep -n '^#doc ' | head -1 | cut -d: -f1)
if [ -n "$lh" ] && [ -n "$ld" ] && [ "$lh" -lt "$ld" ]; then
    ok=$((ok+1))
else
    echo "  FAIL doc: the docs do not come after the hash ($lh vs $ld)"; fail=$((fail+1))
fi

# ---- answer 6: the diagnostic as DATA ----
# The text on `stderr` is still the reference (there are 692 cases measuring it);
# what is added is a second destination for whoever CONSUMES instead of reading.
cat > "$OUT/warn.p" <<'EOP'
include <stdio.h>

def main() -> int:
    x: i32 = 1
    p: *char = None
    x = i32(p)
    printf("%d\n", x)
    return 0
EOP
$PLANGC --diag-json "$OUT/d1.json" "$OUT/warn.p" -o "$OUT/warn.c" >/dev/null 2>&1
if [ -f "$OUT/d1.json" ]; then ok=$((ok+1)); else echo "  FAIL diag-json: nothing was written"; fail=$((fail+1)); fi

# an ERROR kills the compilation, and it is precisely the diagnostic an IDE wants
# most: losing it because the process exited would be the one case that cannot
# fail
cat > "$OUT/bad.p" <<'EOP'
def main() -> int:
    return "this is not an int"
EOP
$PLANGC --diag-json "$OUT/d2.json" "$OUT/bad.p" -o "$OUT/bad.c" >/dev/null 2>&1
if [ -f "$OUT/d2.json" ]; then ok=$((ok+1)); else echo "  FAIL diag-json: the fatal error was not recorded"; fail=$((fail+1)); fi
sev=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d[0]['severity'] if d else 'empty')" "$OUT/d2.json" 2>/dev/null)
check "diag-json: the error comes out as error" "error" "$sev"
lin=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d[0]['line'] if d else 0)" "$OUT/d2.json" 2>/dev/null)
check "diag-json: with the right line" "2" "$lin"
grp=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d[0]['group'] if d else '')" "$OUT/d2.json" 2>/dev/null)
[ -n "$grp" ] && ok=$((ok+1)) || { echo "  FAIL diag-json: no -W group"; fail=$((fail+1)); }

# with no diagnostic at all, the answer is an EMPTY list — and not the absence of
# a file: "there was no warning" is an answer, and whoever consumes it has to
# tell it apart from "the compiler never even ran"
$PLANGC --diag-json "$OUT/d3.json" "$OUT/geom.ph.orig" -o "$OUT/geom.h" >/dev/null 2>&1
n=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "$OUT/d3.json" 2>/dev/null)
check "diag-json: no diagnostic, empty list" "0" "$n"

# and the JSON is JSON even with quotes and backslashes in the message
cat > "$OUT/q.p" <<'EOP'
def main() -> int:
    doesnotexist("a\"b")
    return 0
EOP
$PLANGC --diag-json "$OUT/d4.json" "$OUT/q.p" -o "$OUT/q.c" >/dev/null 2>&1
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$OUT/d4.json" 2>/dev/null; then
    ok=$((ok+1))
else
    echo "  FAIL diag-json: the message with quotes broke the JSON"; fail=$((fail+1))
fi

# ---- answer 5 for a PSCRIPT module comes from the LANGUAGE ITSELF ----
# The lowering is not the interface: it fuses the prelude and the imported
# modules, invents a frame `struct` per `async def`, swaps `str` for `*PsStr` and
# puts a `*PsCtx` in front of every signature. A hash over that would change when
# the RUNTIME changed — and the question "did MY interface change?" would answer
# wrong.
cat > "$OUT/mod.psc" <<'EOP'
"""A test module."""
import path

record Point:
    x: int
    y: int

def area(p: Point, scale: float) -> int:
    """The area."""
    return p.x * p.y

private def hidden() -> str:
    return "does not come out in the API"

async def later(n: int) -> list<str>:
    await sleep(0.0)
    return []
EOP
api=$($PLANGC --api "$OUT/mod.psc" 2>&1)
case $api in
    *"record Point {x: int, y: int}"*) ok=$((ok+1)) ;;
    *) echo "  FAIL pscript api: the record came out wrong"; echo "$api" | head -4; fail=$((fail+1)) ;;
esac
case $api in
    *"def area(Point, float) -> int"*) ok=$((ok+1)) ;;
    *) echo "  FAIL pscript api: the signature came out wrong"; fail=$((fail+1)) ;;
esac
case $api in
    *"async def later(int) -> list<str>"*) ok=$((ok+1)) ;;
    *) echo "  FAIL pscript api: the async came out wrong"; fail=$((fail+1)) ;;
esac
# `private` is not interface
case $api in
    *hidden*) echo "  FAIL pscript api: a \`private\` came out in the API"; fail=$((fail+1)) ;;
    *) ok=$((ok+1)) ;;
esac
# nor the prelude, nor the runtime, nor the frames the lowering invents
for noise in "Category" "PsCtx" "PsStr" "__frame"; do
    case $api in
        *"$noise"*) echo "  FAIL pscript api: '$noise' leaked into the interface"; fail=$((fail+1)) ;;
        *) ok=$((ok+1)) ;;
    esac
done
# and the docstring still comes out, after the hash
case $api in
    *"#doc area The area."*) ok=$((ok+1)) ;;
    *) echo "  FAIL pscript api: no docstring"; fail=$((fail+1)) ;;
esac
h1=$(echo "$api" | grep '^#hash ')
printf '\n# a comment at the end changes no interface at all\n' >> "$OUT/mod.psc"
check "pscript hash: a comment does NOT change it" "$h1" "$($PLANGC --api "$OUT/mod.psc" 2>&1 | grep '^#hash ')"

echo "   protocol: $ok ok, $fail failed"
[ $fail = 0 ] || exit 1
