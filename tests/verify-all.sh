#!/bin/bash
# verify-all.sh — a bateria completa de verificação do plangc em UM comando.
#
#   bash tests/verify-all.sh          # bateria completa (~10 min)
#   bash tests/verify-all.sh quick    # pula os scoreboards (c-suite, wacct)
#
# Etapas (todas a partir dos FONTES atuais, nunca de binários velhos):
#   1. seed        bootstrap C -> plangc_seed
#   2. escada      seed compila selfhost -> s1; s1 -> s2; s2 -> out3
#   3. fixed point C      out2 == out3 (byte a byte)
#   4. suítes gating      cases/modules/stl/p-suite/errors em C, QBE e C89
#   5. fixed point QBE    ssa(s2) == ssa(compilador construído do próprio ssa)
#   6. scoreboards        c-suite e wacct-valid (informativos, com piso)
#   7. seed drift         bootstrap/ em dia com os fontes? (informativo)
#
# Sai com código != 0 em qualquer falha gating. Artefatos de falha ficam em
# .verify. Limpa artefatos STALE de execuções anteriores no início.
set -u
cd "$(dirname "$0")/.."
QUICK=${1:-}
V=.verify
CC=${CC:-cc}
CFLAGS="-O2 -std=c11 -w"
FAIL=0

# pisos dos scoreboards: cair abaixo é regressão (suba-os quando melhorarem)
CSUITE_FLOOR=220
WACCT_FLOOR=741

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
ok()   { printf '   \033[32mOK\033[0m %s\n' "${1:-}"; }
bad()  { printf '   \033[31mFAIL\033[0m %s\n' "${1:-}"; FAIL=1; }

rm -rf tests/out              # nunca deixar artefatos velhos enganarem o diagnóstico
mkdir -p $V/{out1,out2,out3,qb1,qb2,stl}

step "1/7 seed: bootstrap C -> plangc_seed"
if $CC $CFLAGS -o $V/plangc_seed bootstrap/selfhost/*.c 2>$V/seed.err; then ok; else bad "$(head -2 $V/seed.err)"; exit 1; fi

gen() { # gen <plangc> <outdir>  — gera stl headers + selfhost C
  # os .c gerados incluem "../stl/x.h" relativo ao próprio diretório, então os
  # headers da stl vão para $V/stl (irmão dos outN) — o repo não é tocado
  local bin=$1 out=$2 f b
  for f in stl/*.ph; do $bin "$f" -o $V/stl/$(basename "${f%.ph}").h 2>/dev/null || return 1; done
  for f in selfhost/*.ph; do b=$(basename "${f%.ph}"); $bin "$f" -o $out/$b.h 2>$V/gen.err || { head -2 $V/gen.err; return 1; }; done
  for f in selfhost/*.p;  do b=$(basename "${f%.p}");  $bin "$f" -o $out/$b.c 2>$V/gen.err || { head -2 $V/gen.err; return 1; }; done
}

step "2/7 escada: seed -> s1 -> s2 -> out3"
if gen $V/plangc_seed $V/out1 && $CC $CFLAGS -o $V/plangc_s1 $V/out1/*.c 2>$V/s1.err; then ok "stage1"; else bad "stage1: $(head -2 $V/s1.err 2>/dev/null)"; exit 1; fi
if gen $V/plangc_s1 $V/out2 && $CC $CFLAGS -o $V/plangc_s2 $V/out2/*.c 2>$V/s2.err; then ok "stage2"; else bad "stage2: $(head -2 $V/s2.err 2>/dev/null)"; exit 1; fi
if gen $V/plangc_s2 $V/out3; then ok "stage3 (geração)"; else bad "stage3"; exit 1; fi

step "3/7 fixed point C: out2 == out3"
if diff -rq $V/out2 $V/out3 >/dev/null 2>&1; then ok; else bad "$(diff -rq $V/out2 $V/out3 | head -3)"; fi

step "4/7 suítes gating (C, QBE, C89) com o stage2"
for mode in "C:" "QBE:BACKEND=qbe" "C89:STD=c89"; do
  name=${mode%%:*}; env=${mode#*:}
  if env PLANGC=$PWD/$V/plangc_s2 $env bash tests/run.sh cases modules stl p-suite errors >$V/suite_$name.log 2>&1; then
    ok "$name"
  else
    bad "$name (tests/out + $V/suite_$name.log)"
  fi
done

step "5/7 fixed point QBE"
qfp=1
for f in selfhost/*.p; do b=$(basename "${f%.p}")
  $V/plangc_s2 --backend qbe "$f" -o $V/qb1/$b.ssa 2>/dev/null || qfp=0
  ./qbe/qbe $V/qb1/$b.ssa -o $V/qb1/$b.s 2>/dev/null || qfp=0
done
if [ $qfp = 1 ] && $CC $V/qb1/*.s -o $V/plangc_qbe 2>$V/qbe.err; then
  for f in selfhost/*.p; do b=$(basename "${f%.p}")
    $V/plangc_qbe --backend qbe "$f" -o $V/qb2/$b.ssa 2>/dev/null || qfp=0
    diff -q $V/qb1/$b.ssa $V/qb2/$b.ssa >/dev/null 2>&1 || { qfp=0; echo "   diverge: $b.ssa"; }
  done
else qfp=0; fi
[ $qfp = 1 ] && ok || bad "compilador QBE-built diverge do C-built"

if [ "$QUICK" != "quick" ]; then
  step "6/7 scoreboards (pisos: c-suite>=$CSUITE_FLOOR, wacct>=$WACCT_FLOOR)"
  cs=$(PLANGC=$PWD/$V/plangc_s2 bash tests/run.sh c-suite 2>/dev/null | grep -oE 'score: [0-9]+' | grep -oE '[0-9]+')
  [ "${cs:-0}" -ge $CSUITE_FLOOR ] && ok "c-suite $cs/220" || bad "c-suite caiu: ${cs:-?}/220 (piso $CSUITE_FLOOR)"
  wa=$(PLANGC=$PWD/$V/plangc_s2 bash tests/run.sh wacct-valid 2>/dev/null | grep -oE 'wacct-valid: [0-9]+' | grep -oE '[0-9]+')
  [ "${wa:-0}" -ge $WACCT_FLOOR ] && ok "wacct-valid $wa ok" || bad "wacct-valid caiu: ${wa:-?} (piso $WACCT_FLOOR)"
  # paridade de diagnósticos com o clang da máquina (gating quando clang existe)
  if command -v clang >/dev/null 2>&1; then
    if PLANGC=$PWD/$V/plangc_s2 bash tests/clang-compare.sh >$V/clangcmp.log 2>&1; then
      ok "clang-compare $(grep -oE '[0-9]+ matches' $V/clangcmp.log | tail -1)"
    else
      bad "clang-compare divergiu (veja $V/clangcmp.log)"
    fi
  fi
else
  step "6/7 scoreboards — pulados (quick)"
fi

step "7/7 seed drift (informativo)"
drift=0
for f in $V/out2/*.c $V/out2/*.h; do
  b=$(basename "$f")
  cmp -s "$f" "bootstrap/selfhost/$b" || { drift=1; break; }
done
for f in $V/stl/*.h; do
  b=$(basename "$f")
  cmp -s "$f" "bootstrap/stl/$b" || { drift=1; break; }
done
if [ $drift = 0 ]; then ok "bootstrap/ em dia com os fontes"
else printf '   \033[33mDRIFT\033[0m bootstrap/ difere dos fontes — regenere com: cp %s/out2/* bootstrap/selfhost/\n' "$V"; fi

echo
if [ $FAIL = 0 ]; then
  printf '\033[1;32m✔ VERIFY-ALL PASSED\033[0m\n'
  rm -rf $V tests/out 2>/dev/null
else
  printf '\033[1;31m✘ VERIFY-ALL FAILED — artefatos em %s\033[0m\n' "$V"
fi
exit $FAIL
