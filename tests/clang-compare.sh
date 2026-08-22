#!/bin/bash
# clang-compare.sh — compara o veredito do plangc com o do clang da máquina,
# caso a caso, sob os MESMOS flags.
#
#   bash tests/clang-compare.sh              # todos os flag-sets
#   bash tests/clang-compare.sh -Werror      # um flag-set específico
#
# Corpus: tests/diag/*.c (um construto por arquivo). Veredito por compilador:
#   ok    compilou sem nada no stderr
#   warn  compilou com warnings (rc 0, stderr não vazio)
#   error rc != 0
# O placar conta MATCHES; divergências são listadas com os dois vereditos.
set -u
cd "$(dirname "$0")/.."
PLANGC=${PLANGC:-$PWD/build/bin/plangc_s2}
CLANG=${CLANG:-clang}
command -v "$CLANG" >/dev/null || { echo "clang não encontrado"; exit 2; }
[ -x "$PLANGC" ] || { echo "plangc não encontrado em $PLANGC (build primeiro ou PLANGC=...)"; exit 2; }

FLAGSETS=("${@:-}")
if [ -z "${1:-}" ]; then
  FLAGSETS=("" "-Werror" "-pedantic" "-pedantic-errors" "-Wall")
fi

verdict() { # rc stderr_file -> ok|warn|error
  local rc=$1 errf=$2
  if [ "$rc" -ne 0 ]; then echo error
  elif [ -s "$errf" ]; then echo warn
  else echo ok; fi
}

total_match=0; total_diff=0
for fs in "${FLAGSETS[@]}"; do
  match=0; diff=0
  printf '\n\033[1m== flags: %s ==\033[0m\n' "${fs:-'(default)'}"
  for f in tests/diag/*.c; do
    name=$(basename "$f" .c)
    $CLANG -std=c99 $fs -c "$f" -o /dev/null 2>/tmp/cc_clang.err; crc=$?
    cv=$(verdict $crc /tmp/cc_clang.err)
    timeout 10 "$PLANGC" $fs "$f" -o /dev/null 2>/tmp/cc_plang.err; prc=$?
    pv=$(verdict $prc /tmp/cc_plang.err)
    if [ "$cv" = "$pv" ]; then
      match=$((match+1))
    else
      diff=$((diff+1))
      printf '  \033[31mDIFF\033[0m %-28s clang=%-5s plangc=%-5s\n' "$name" "$cv" "$pv"
      sed 's/^/         clang: /'  /tmp/cc_clang.err | head -1
      sed 's/^/        plangc: /'  /tmp/cc_plang.err | head -1
    fi
  done
  printf '   match: %d, diff: %d\n' $match $diff
  total_match=$((total_match+match)); total_diff=$((total_diff+diff))
done
printf '\n\033[1mTOTAL: %d matches, %d diffs\033[0m\n' $total_match $total_diff
[ $total_diff -eq 0 ]
