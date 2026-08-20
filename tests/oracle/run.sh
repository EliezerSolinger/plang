#!/usr/bin/env bash
# tests/oracle/run.sh — the reference implementations as ORACLES.
#
#   bash tests/oracle/run.sh          # both
#   bash tests/oracle/run.sh py       # just python3
#
# The corpora in tests/conformance/ are files somebody else wrote. This is the
# other half of the same idea and it measures what no downloadable corpus can:
# our own programs, run twice — once here and once by the implementation whose
# behaviour we said we would copy — with the outputs diffed.
#
#   py/  python3 is the oracle for the LANGUAGE. The design says "as Python
#        does" in dozens of places (-7//2 = -4, -7%3 = 2, repr of a float, the
#        slice, the order of a dict, a stable sort, the str methods). Until now
#        every one of those was checked BY HAND, once, by the person who wrote
#        the rule. Here they are checked by Python, every run.
#
#   js/  node is the oracle for the RUNTIME MODEL. `await` yields even when the
#        task is already finished (78.4), `gather` answers in the order the
#        tasks were given, `race` cancels the losers, a timer of 0 still goes
#        after the microtasks. Those are promises about ORDER, and the only way
#        to check a promise about order against JS is to ask JS.
#
# A pair is `<name>.psc` next to `<name>.py` (or `<name>.mjs`), written to print
# exactly the same lines. Where the two languages genuinely differ, the program
# says so in a comment and prints the difference on purpose — a silent skip is
# how a divergence becomes a feature nobody chose.
set -u
cd "$(dirname "$0")/../.."

OUT=tests/out/oracle
FAIL=0
mkdir -p "$OUT"

have() { command -v "$1" >/dev/null 2>&1; }

# node paints numbers in `console.log` when it decides the output is a terminal,
# and whether it decides that depends on how this script was invoked — so the
# same pair agreed by hand and differed under `verify-all`. Turned off here
# rather than filtered afterwards: a colour code in the middle of a diff is a
# difference nobody meant to test.
export NO_COLOR=1 FORCE_COLOR=0

run_side() { # run_side <dir> <ext> <cmd...>
    local dir=$1 ext=$2; shift 2
    local pass=0 fail=0 src name ref
    for src in tests/oracle/$dir/*.psc; do
        [ -f "$src" ] || continue
        name=$(basename "$src" .psc)
        ref="tests/oracle/$dir/$name.$ext"
        [ -f "$ref" ] || { echo "  FAIL $name: no $ext reference next to it"; fail=$((fail+1)); continue; }
        if ! PSBUILD_RT="$OUT/rt" bash tests/psbuild.sh "$src" "$OUT/$name" >"$OUT/$name.build" 2>&1; then
            echo "  FAIL $name (build) — see $OUT/$name.build"; fail=$((fail+1)); continue
        fi
        ( cd "$OUT" && "./$name" >"$name.ours" 2>&1 )
        "$@" "$ref" > "$OUT/$name.theirs" 2>&1
        if diff -u "$OUT/$name.theirs" "$OUT/$name.ours" > "$OUT/$name.diff"; then
            pass=$((pass+1))
        else
            echo "  FAIL $name — $(grep -c '^[+-][^+-]' "$OUT/$name.diff") lines differ:"
            sed -n '4,14p' "$OUT/$name.diff" | sed 's/^/      /'
            fail=$((fail+1))
        fi
    done
    echo "   $dir: $pass agree, $fail differ"
    [ $fail = 0 ] || FAIL=1
}

for s in ${*:-py js}; do
    case $s in
        py) printf '\n\033[1m== python3 as the oracle for the language ==\033[0m\n'
            have python3 && run_side py py python3 || echo "   -- no python3" ;;
        js) printf '\n\033[1m== node as the oracle for the runtime model ==\033[0m\n'
            have node && run_side js mjs node || echo "   -- no node" ;;
        *) echo "unknown oracle '$s' (py|js)"; exit 2 ;;
    esac
done

echo
[ $FAIL = 0 ] && printf '\033[1;32m✔ oracles agree\033[0m\n' || printf '\033[1;31m✘ an oracle disagrees\033[0m\n'
exit $FAIL
