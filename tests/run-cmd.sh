#!/usr/bin/env bash
# tests/run-cmd.sh — `plangc run` and the cache behind it (6.3/15.3/16.2/50.3).
#
# The `run` subcommand is the one thing in this repo that is not a compilation:
# it compiles, CACHES, and then execs. So what has to be gated is not an output
# but a set of behaviours — and each one of these was decided in a battery:
#
#   * it runs, and the program's arguments arrive (6.3);
#   * the second run does not call `cc` at all (15.3) — measured, not assumed;
#   * editing the source invalidates it;
#   * editing an IMPORTED module invalidates it too, which is the only failure
#     mode of a build cache that actually matters;
#   * the program's exit status is the process's, because `run` execs;
#   * `pscript f.psc` is the same thing under the alias of 50.3.
set -u
cd "$(dirname "$0")/.."

PLANGC=${PLANGC:-./plangc2}
OUT=tests/out/runcmd
CACHE=$OUT/cache
rm -rf "$OUT"; mkdir -p "$OUT"
export PSCRIPT_CACHE=$PWD/$CACHE
fail=0
ok=0

note() { printf '  %-46s %s\n' "$1" "$2"; }
check() { # check <what> <expected> <got>
    if [ "$2" = "$3" ]; then ok=$((ok+1)); else
        echo "  FAIL $1: expected '$2', got '$3'"; fail=$((fail+1))
    fi
}

cat > "$OUT/pmod_side.ph" <<'EOF'
def side_value() -> i64
EOF
cat > "$OUT/pmod_side.p" <<'EOF'
import "pmod_side.ph"

def side_value() -> i64:
    return 41
EOF
cat > "$OUT/prog.psc" <<'EOF'
import sys
import "pmod_side.ph"

n = side_value() + 1
print(f"answer {n}")
i = 1
while i < len(sys.argv):
    print(f"arg {sys.argv[i]}")
    i += 1
if n != 42:
    sys.exit(3)
EOF

# ---- it runs, and the arguments arrive ----
got=$($PLANGC run "$OUT/prog.psc" alpha beta 2>&1)
check "run + args" "answer 42
arg alpha
arg beta" "$got"

# ---- the second run does not compile: no `cc` process, and it is FAST ----
# a cold build is seconds (it compiles the whole runtime); a cached one is
# milliseconds, so the bar is deliberately loose and still unmistakable
t0=$(date +%s%N)
$PLANGC run "$OUT/prog.psc" >/dev/null 2>&1
t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 ))
if [ "$ms" -lt 400 ]; then ok=$((ok+1)); note "cached run" "${ms}ms"; else
    echo "  FAIL cached run took ${ms}ms (expected well under 400ms: the cache did not hit)"; fail=$((fail+1))
fi

# ---- editing the source invalidates ----
sed -i.bak 's/answer /ANSWER /' "$OUT/prog.psc"
got=$($PLANGC run "$OUT/prog.psc" 2>&1)
check "source edited" "ANSWER 42" "$got"

# ---- editing an IMPORTED module invalidates ----
sed -i.bak 's/return 41/return 100/' "$OUT/pmod_side.p"
got=$($PLANGC run "$OUT/prog.psc" 2>&1 | head -1)
check "imported module edited" "ANSWER 101" "$got"

# ---- the exit status is the program's ----
$PLANGC run "$OUT/prog.psc" >/dev/null 2>&1
check "exit status" "3" "$?"

# ---- the alias of 50.3 ----
# the symlink is made HERE, pointing at the compiler under test: `run` is what
# the binary does when it is called `pscript`, and that is a property of the
# binary, not of whichever copy happens to be installed
mkdir -p "$OUT/bin"
case $PLANGC in /*) target=$PLANGC ;; *) target=$PWD/${PLANGC#./} ;; esac
ln -sf "$target" "$OUT/bin/pscript"
sed -i.bak 's/return 100/return 41/' "$OUT/pmod_side.p"
got=$("$OUT/bin/pscript" "$OUT/prog.psc" 2>&1 | head -1)
check "pscript alias" "ANSWER 42" "$got"

echo "   run-cmd: $ok ok, $fail failed"
[ $fail = 0 ] || exit 1
