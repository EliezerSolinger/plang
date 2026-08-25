#!/bin/bash
# reseed.sh — regenera o seed a partir dos fontes e re-verifica.
# Usado pelo PLAN.md; ver a receita lá.
set -e
cd "$(dirname "$0")"
V=.verify; CC=${CC:-cc}; CFLAGS="-O2 -std=c11 -w"
rm -rf $V; mkdir -p $V/out1 $V/out2 $V/out3 $V/packages/stl
gen() { local bin=$1 out=$2 f b
  # 142/154: o `stl` vem DENTRO do compilador — um `plangc foo.p` já não precisa
  # de `--pkg-path`, e o portão `tests/builtin-stl.sh` é quem o prova.
  #
  # Aqui ele fica na mesma, e a razão é o primeiro degrau: o seed comitado pode
  # ser ANTERIOR a esta mudança, e um `--pkg-path` a mais é ignorado por quem já
  # traz o `stl` dentro (a raiz virtual é a primeira que se procura). Sem ele,
  # regenerar a partir de um `bootstrap/` velho deixaria de funcionar — que é
  # exactamente a coisa que o seed existe para garantir.
  local P="--pkg-path packages"
  for f in packages/stl/*.ph; do $bin $P "$f" -o $V/packages/stl/$(basename "${f%.ph}").h || return 1; done
  for f in selfhost/*.ph; do b=$(basename "${f%.ph}"); $bin $P "$f" -o $out/$b.h || return 1; done
  for f in selfhost/*.p;  do b=$(basename "${f%.p}");  $bin $P "$f" -o $out/$b.c || return 1; done; }
$CC $CFLAGS -o $V/seed bootstrap/selfhost/*.c
gen $V/seed $V/out1 && $CC $CFLAGS -o $V/s1 $V/out1/*.c
gen $V/s1   $V/out2 && $CC $CFLAGS -o $V/s2 $V/out2/*.c
gen $V/s2   $V/out3
diff -rq $V/out2 $V/out3 >/dev/null || { echo "FIXED POINT FAILED"; exit 1; }
cp $V/out2/*.c $V/out2/*.h bootstrap/selfhost/
cp $V/packages/stl/*.h bootstrap/packages/stl/
rm -rf $V
make seed >/dev/null
echo "SEED UPDATED"
