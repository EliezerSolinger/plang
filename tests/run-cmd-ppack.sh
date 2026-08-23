#!/usr/bin/env bash
# tests/run-cmd-ppack.sh — `ppack run`, and the cache behind it (F7).
#
# It is `tests/run-cmd.sh` measured from the other side: the SAME behaviours, now
# that the decision has left the compiler. What is pinned down is not an output,
# it is a set of behaviours — and each one was decided in a battery:
#
#   * it runs, and the program's arguments arrive (6.3);
#   * the second run calls neither `cc` nor the compiler — MEASURED, not assumed;
#   * editing the source invalidates;
#   * editing an IMPORTED module invalidates too, which is the only way a build
#     cache can fail that really matters;
#   * editing the COMPILER invalidates, because the C it generates is different;
#   * the exit status is the PROCESS's, because `run` does `exec` — and that is
#     what makes a program that reads the keyboard or paints the screen work;
#   * and a program in P runs down the same path.
#
# The difference that gets stated: the binary comes out in `build/run/` — inside
# the PROJECT, where `make clean` reaches it — and not in a `~/.cache` nobody
# knows exists.
set -u
cd "$(dirname "$0")/.."

PPACK=${PPACK:-build/bin/ppack}
case $PPACK in /*) ;; *) PPACK=$PWD/$PPACK;; esac
OUT=tests/out/runppack
rm -rf "$OUT"; mkdir -p "$OUT"
fail=0
ok=0

check() { if [ "$2" = "$3" ]; then ok=$((ok+1)); else echo "  FAIL $1: expected '$2', got '$3'"; fail=$((fail+1)); fi; }

cat > "$OUT/lib.psc" <<'EOF'
def value() -> int:
    return 7
EOF
cat > "$OUT/prog.psc" <<'EOF'
import sys
import lib
print("value", lib.value(), sys.argv[1] if len(sys.argv) > 1 else "-")
sys.exit(len(sys.argv))
EOF

# 1. it runs, and the arguments arrive
got=$("$PPACK" run "$OUT/prog.psc" abc 2>/dev/null | tail -1)
check "it runs and receives the arguments" "value 7 abc" "$got"

# 2. the exit status is the PROGRAM's (2 = itself plus one argument)
"$PPACK" run "$OUT/prog.psc" abc >/dev/null 2>&1
check "the status is the program's" "2" "$?"

# 3. the second run builds NOTHING: no `cc`, no compiler. The proof is that it
#    prints no progress line at all.
lines=$("$PPACK" run "$OUT/prog.psc" abc 2>/dev/null | grep -c '^\[' || true)
check "the second run builds nothing" "0" "$lines"

# 4. editing the SOURCE invalidates
sleep 0.01
cat > "$OUT/prog.psc" <<'EOF'
import sys
import lib
print("other", lib.value())
EOF
got2=$("$PPACK" run "$OUT/prog.psc" 2>/dev/null | tail -1)
check "editing the source invalidates" "other 7" "$got2"

# 5. editing an IMPORTED MODULE invalidates
sleep 0.01
cat > "$OUT/lib.psc" <<'EOF'
def value() -> int:
    return 99
EOF
got3=$("$PPACK" run "$OUT/prog.psc" 2>/dev/null | tail -1)
check "editing the imported module invalidates" "other 99" "$got3"

# 6. editing the COMPILER invalidates
sleep 0.01
touch build/bin/plangc_s2
lines2=$("$PPACK" run "$OUT/prog.psc" 2>/dev/null | grep -c '^\[' || true)
if [ "$lines2" -gt 0 ]; then ok=$((ok+1)); else echo "  FAIL touching the compiler should rebuild"; fail=$((fail+1)); fi

# 7. a program in P down the same path
cat > "$OUT/inp.p" <<'EOF'
include <stdio.h>

def main() -> int:
    printf("in P\n")
    return 0
EOF
got4=$("$PPACK" run "$OUT/inp.p" 2>/dev/null | tail -1)
check "a program in P runs the same" "in P" "$got4"

# 8. a LOOSE script's binary is born NEXT TO IT (architecture C′): `ppack run
#    ../tools/x.psc` from inside another project has no business dirtying that
#    project's build with something that is not its own
if ls "$OUT"/build/run/bin/prog >/dev/null 2>&1; then ok=$((ok+1)); else echo "  FAIL the binary should be in $OUT/build/run/bin"; fail=$((fail+1)); fi

# 8b. ... and `--build-dir` sends it elsewhere
rm -rf "$OUT/elsewhere"
"$PPACK" run --build-dir "$OUT/elsewhere" "$OUT/prog.psc" >/dev/null 2>&1
if ls "$OUT"/elsewhere/run/bin/prog >/dev/null 2>&1; then ok=$((ok+1)); else echo "  FAIL --build-dir was not honoured"; fail=$((fail+1)); fi

# 9. a file that does not exist is a message, not a crash
"$PPACK" run "$OUT/doesnotexist.psc" >/dev/null 2>&1 && { echo "  FAIL a file that does not exist should fail"; fail=$((fail+1)); } || ok=$((ok+1))

echo "   run-ppack: $ok ok, $fail failed"
[ $fail = 0 ]
