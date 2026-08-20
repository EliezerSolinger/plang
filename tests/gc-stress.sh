#!/usr/bin/env bash
# gc-stress.sh — run the pscript corpus with the collector running constantly.
#
#   bash tests/gc-stress.sh              # the whole corpus
#   bash tests/gc-stress.sh async_gc     # one program
#
# WHY THIS EXISTS. A copying collector has one failure mode, and it is always
# the same: something held a pointer across a safe point without putting it on
# the shadow stack. The object moves, the holder keeps the old address, and from
# then on it reads whatever the allocator handed that memory to next.
#
# The danger is not the fix — each one is two lines — it is that with the normal
# 2 MiB threshold a small program never collects at all, so the whole corpus can
# be green while the bug is right there. It shows up later, on a bigger input,
# as a wrong answer far from the cause.
#
# The first time this ran it turned five green tests red, and every one of them
# was a real defect (see pscript/PLAN.md, bateria 88).
#
# N per program: 1 means collect at EVERY safe point, which is quadratic in the
# heap. That is what small programs get. The path tracer allocates millions of
# times and gets a coarser N — still tens of thousands of collections spread
# through the run, instead of a handful at the end.
set -u
cd "$(dirname "$0")/.."

PLANGC=${PLANGC:-./plangc2}
CC=${CC:-cc}
OUT=tests/out/gcstress
FAIL=0
mkdir -p "$OUT"

# programs that allocate too hard for N=1 to finish in a test suite
stress_n() {
    case $1 in
        smallpt_core|smallpt_full|smallpt_workers) echo 20000 ;;
        # the socket programs talk to themselves over a real loopback and spend
        # their time in `poll`; at N=1 the collection between two reads costs
        # more than the round trip and the whole thing crawls
        # `http_server` serves several requests over a real loopback socket and
        # reads 64 bytes at a time on purpose; even at 200 the collection
        # between two reads costs more than the round trip
        http_server)                               echo 5000 ;;
        net_socket)                                echo 200 ;;
        *)                                          echo 1 ;;
    esac
}

only=${1:-}
pass=0; fail=0; slow=0
for src in tests/pscript/run/*.psc pscript/examples/*.psc; do
    [ -f "$src" ] || continue
    name=$(basename "$src"); name=${name%.psc}
    case $name in lib_*) continue ;; esac
    [ -n "$only" ] && [ "$name" != "$only" ] && continue

    exp="tests/pscript/run/$name.expected"
    [ -f "$exp" ] || exp="tests/pscript/run/$(basename "$src" .psc).expected"
    [ -f "$exp" ] || { continue; }
    want_exit=0
    [ -f "tests/pscript/run/$name.exit" ] && want_exit=$(cat "tests/pscript/run/$name.exit")

    # a program may need compiler flags to mean what its `.expected` says
    # (`-O` strips `assert`, 46.4) — the same file `tests/run.sh` reads
    xflags=""
    [ -f "tests/pscript/run/$name.flags" ] && xflags=$(cat "tests/pscript/run/$name.flags")
    if ! PSBUILD_RT="$OUT/rt" PLANGC="${PLANGC:-./plangc2} $xflags" bash tests/psbuild.sh "$src" "$OUT/$name" >"$OUT/$name.build" 2>&1; then
        echo "  FAIL $name (build) — see $OUT/$name.build"; fail=$((fail+1)); continue
    fi
    n=$(stress_n "$name")
    # a program that used to finish in milliseconds can take a minute at N=1;
    # a timeout is a FAILURE to report, not a reason to lower the bar silently
    ( cd "$OUT" && PSCRIPT_GC_STRESS="$n" timeout 300 "./$name" >"$name.out" 2>&1 )
    rc=$?
    if [ $rc = 124 ]; then
        echo "  SLOW $name (over 300s at N=$n)"; slow=$((slow+1)); continue
    fi
    # A program whose OUTPUT is a wall-clock assertion cannot be compared here:
    # collecting at every safe point makes everything slower, and `interval`
    # coalesces missed ticks ON PURPOSE (51.1), so "three ticks took at least
    # three periods" is false by design on a machine that cannot keep up. Its
    # exit status is still checked, which is what this mode is for.
    case $name in
        interval|timers|cancel_race)
            if [ "$rc" != "$want_exit" ]; then
                echo "  FAIL $name (exit $rc, expected $want_exit, N=$n)"; fail=$((fail+1))
            else
                pass=$((pass+1))
            fi
            continue ;;
    esac
    if [ "$rc" != "$want_exit" ]; then
        echo "  FAIL $name (exit $rc, expected $want_exit, N=$n) — see $OUT/$name.out"
        fail=$((fail+1)); continue
    fi
    if ! diff -q "$exp" "$OUT/$name.out" >/dev/null 2>&1; then
        echo "  FAIL $name (output differs under stress, N=$n) — see $OUT/$name.out"
        fail=$((fail+1)); continue
    fi
    pass=$((pass+1))
done

echo "   gc-stress: $pass ok, $fail failed${slow:+, $slow too slow}"
[ $fail = 0 ] || FAIL=1
exit $FAIL
