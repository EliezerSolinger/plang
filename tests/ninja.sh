#!/usr/bin/env bash
# ninja.sh — does the committed `build.ninja` still describe this graph?
#
# It is the BOOTSTRAP: on a machine with no `ppack`, `cc -O2 -o plangc
# bootstrap/selfhost/*.c && ninja` builds everything. And a generated file that
# stays committed has exactly one way to fail — ageing in silence — so this gate
# regenerates it and compares. If it diverges, the message says the command.
#
# What it does NOT do is run ninja: that is the whole `verify` by another route,
# and what is at stake here is the FIDELITY of the export.
set -u
cd "$(dirname "$0")/.."

PPACK=${PPACK:-build/bin/ppack}
case $PPACK in /*) ;; *) PPACK=$PWD/$PPACK;; esac
OUT=${OUT:-tests/out/ninja}
rm -rf "$OUT"; mkdir -p "$OUT"

"$PPACK" ninja "$OUT/build.ninja" >/dev/null 2>&1 || { echo "   ninja: the emitter failed"; exit 1; }
if cmp -s "$OUT/build.ninja" build.ninja; then
    echo "   ninja: the committed build.ninja is up to date ($(grep -c '^build ' build.ninja) edges)"
    exit 0
fi
echo "   ninja: the committed build.ninja NO LONGER describes this graph."
echo "          ppack ninja build.ninja"
diff "$OUT/build.ninja" build.ninja | head -6
exit 1
