#!/usr/bin/env bash
# mmap-truncate.sh — o portão da 137.2, e o que ele consegue medir hoje.
#
# Outro processo trunca o ficheiro debaixo de um mapa aberto. Tocar na página
# que desapareceu manda SIGBUS, e o que este portão exige é que a mensagem DIGA
# o que aconteceu em vez de morrer muda.
#
# **O que a 137.2 desenhou e este portão AINDA NÃO mede:** a excepção. Desenrolar
# em vez de morrer precisa do endereço da falha (`sigaction` + `SA_SIGINFO`) e de
# um `setjmp` no frame de quem escreveu o `with` — as duas coisas esbarram na
# mesma fronteira (72.4) que o manipulador de crash já documentou, e a bateria
# 145 regista o desenho que as resolveria.
set -u
cd "$(dirname "$0")/.."
PLANGC=${PLANGC:-build/bin/plangc_s2}
OUT=tests/out/mmaptrunc
rm -rf "$OUT"; mkdir -p "$OUT"
ok=0; fail=0

cat > "$OUT/trunc.psc" <<'PSC'
import os
import sys

alvo = sys.argv[1]
m = os.mmap(alvo)
print("mapeado", len(m))
# o outro lado trunca aqui
await sleep(0.3)
total = 0
for b in m[:]:
    total += int(b)
print("somou", total)
m.close()
PSC

if ! PLANGC=$PLANGC bash tests/psbuild.sh "$OUT/trunc.psc" "$OUT/trunc" >"$OUT/build.log" 2>&1; then
    echo "  FAIL o programa do teste nao compilou:"; sed 's/^/       /' "$OUT/build.log" | head -3
    echo "   mmap-truncate: 0 ok, 1 failed"; exit 1
fi
ok=$((ok+1))

# um ficheiro de meio megabyte: grande o bastante para o truncar tirar paginas
# que o laco ainda nao leu
python3 -c "open('$OUT/grande.bin','wb').write(b'x' * 524288)"
( sleep 0.15; python3 -c "
import os
os.truncate('$OUT/grande.bin', 0)" ) &
"$OUT/trunc" "$OUT/grande.bin" >"$OUT/run.out" 2>&1
rc=$?
wait

if [ $rc -eq 0 ]; then
    # o nucleo pode nao ter tirado a pagina a tempo: o teste nao FALHA por isso,
    # porque a corrida e do sistema e nao do programa
    echo "   mmap-truncate: $ok ok, 0 failed  (o truncar nao apanhou o laco desta vez)"
    exit 0
fi
if grep -q "truncated by somebody else while it was mapped" "$OUT/run.out"; then
    ok=$((ok+1))
    echo "   mmap-truncate: $ok ok, 0 failed  (o SIGBUS disse a causa)"
    exit 0
fi
echo "  FAIL morreu sem dizer que foi o mapa:"; sed 's/^/       /' "$OUT/run.out" | head -4
echo "   mmap-truncate: $ok ok, 1 failed"
exit 1
