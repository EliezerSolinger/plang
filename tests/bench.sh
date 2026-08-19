#!/usr/bin/env bash
# tests/bench.sh — the same program, here and there, with the clock running.
#
#   bash tests/bench.sh
#
# Three numbers per program, and the third is the one that needs saying out loud:
#
#   compile   how long it takes to BUILD ours. It is long, and it is supposed to
#             be: pscript is ahead-of-time through C and the C is handed to the
#             system compiler at -O2. node and python do not compile at all, so
#             the column reads `-` for them. This is not a race we are in.
#   startup   an empty program, end to end. For us that is process start; for
#             node and python it is process start plus building a runtime.
#   run       the work itself, which is the only column that compares like with
#             like.
#
# The programs live in tests/bench/ as `<name>.psc` next to `<name>.py` and
# `<name>.mjs`, written to compute the same thing — and each prints its result,
# so a fast wrong answer cannot win.
set -u
cd "$(dirname "$0")/.."

OUT=tests/out/bench
mkdir -p "$OUT"
CCOPT=${CCOPT:--O2}

have() { command -v "$1" >/dev/null 2>&1; }

# seconds, three decimals, of one command
ms() { local t0 t1; t0=$(date +%s%N); "$@" >/dev/null 2>&1; t1=$(date +%s%N); echo "scale=3; ($t1 - $t0)/1000000000" | bc; }

# node paints numbers in `console.log`; the answer is the answer either way, so
# the colour comes off before anything is compared
plain() { sed 's/\x1b\[[0-9;]*m//g'; }

printf '%-14s %10s %10s %10s %10s %10s\n' program "compile" "ours" "python3" "node" "answer"
printf '%-14s %10s %10s %10s %10s %10s\n' -------------- ---------- ---------- ---------- ---------- ----------

# startup: the empty program, which is what "how long before my code runs" means
printf 'print("")\n' > "$OUT/empty.psc"
printf '\n' > "$OUT/empty.py"
printf '\n' > "$OUT/empty.mjs"
ct=$(ms env CCOPT="$CCOPT" PSBUILD_RT="$OUT/rt" bash tests/psbuild.sh "$OUT/empty.psc" "$OUT/empty")
o=$(ms "$OUT/empty"); p="-"; n="-"
have python3 && p=$(ms python3 "$OUT/empty.py")
have node && n=$(ms node "$OUT/empty.mjs")
printf '%-14s %10s %10s %10s %10s %10s\n' "(startup)" "$ct" "$o" "$p" "$n" "-"

for src in tests/bench/*.psc; do
    [ -f "$src" ] || continue
    name=$(basename "$src" .psc)
    ct=$(ms env CCOPT="$CCOPT" PSBUILD_RT="$OUT/rt" bash tests/psbuild.sh "$src" "$OUT/$name")
    [ -x "$OUT/$name" ] || { printf '%-14s %10s   (did not build)\n' "$name" "$ct"; continue; }
    ours=$(ms "$OUT/$name")
    ans=$("$OUT/$name" 2>&1 | tail -1 | plain)
    p="-"; n="-"
    if have python3 && [ -f "tests/bench/$name.py" ]; then
        p=$(ms python3 "tests/bench/$name.py")
        pa=$(python3 "tests/bench/$name.py" 2>&1 | tail -1 | plain)
        [ "$pa" = "$ans" ] || ans="$ans != py:$pa"
    fi
    if have node && [ -f "tests/bench/$name.mjs" ]; then
        n=$(ms node "tests/bench/$name.mjs")
        na=$(node "tests/bench/$name.mjs" 2>&1 | tail -1 | plain)
        [ "$na" = "$ans" ] || ans="$ans != js:$na"
    fi
    printf '%-14s %10s %10s %10s %10s %10s\n' "$name" "$ct" "$ours" "$p" "$n" "$ans"
done

echo
echo "compile = plangc + cc $CCOPT, from source to binary. node and python do not"
echo "compile; the column is theirs to not have. Times are wall clock, one run."
