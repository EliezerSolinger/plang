#!/bin/bash
# reseed.sh — regenera o seed a partir dos fontes e re-verifica.
# Usado pelo PLAN.md; ver a receita lá.
set -e
cd "$(dirname "$0")"
V=.verify; CC=${CC:-cc}; CFLAGS="-O2 -std=c11 -w"
rm -rf $V; mkdir -p $V/out1 $V/out2 $V/out3 $V/stl
gen() { local bin=$1 out=$2 f b
  for f in stl/*.ph;      do $bin "$f" -o $V/stl/$(basename "${f%.ph}").h || return 1; done
  for f in selfhost/*.ph; do b=$(basename "${f%.ph}"); $bin "$f" -o $out/$b.h || return 1; done
  for f in selfhost/*.p;  do b=$(basename "${f%.p}");  $bin "$f" -o $out/$b.c || return 1; done; }
$CC $CFLAGS -o $V/seed bootstrap/selfhost/*.c
gen $V/seed $V/out1 && $CC $CFLAGS -o $V/s1 $V/out1/*.c
gen $V/s1   $V/out2 && $CC $CFLAGS -o $V/s2 $V/out2/*.c
gen $V/s2   $V/out3
diff -rq $V/out2 $V/out3 >/dev/null || { echo "FIXED POINT FAILED"; exit 1; }
cp $V/out2/*.c $V/out2/*.h bootstrap/selfhost/
cp $V/stl/*.h bootstrap/stl/
rm -rf $V
make plangc >/dev/null
echo "SEED UPDATED"
