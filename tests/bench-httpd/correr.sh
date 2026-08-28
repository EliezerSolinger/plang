#!/usr/bin/env bash
# correr.sh — o banco de ensaio da F12, e o que ele mede e o que não mede.
#
# MEDE: quantas respostas completas por segundo cada servidor dá, com o MESMO
# gerador de carga (`carga.c`, aqui ao lado), as mesmas rotas e a mesma máquina,
# um servidor de cada vez.
#
# NÃO MEDE: percentis de latência (o gerador guarda a média e não as amostras),
# nem nada com o disco ou com uma base de dados. E não é um número que se possa
# comparar com o de outra máquina — o que se compara é a coluna ao lado.
#
# E há uma coisa que este ficheiro faz de propósito e que a maioria dos bancos de
# ensaio não faz: mede o nosso servidor com UM worker também. Com N ele usa a
# máquina inteira e o Bun usa um núcleo, e comparar assim seria escolher a
# comparação que nos favorece. As duas colunas estão lá.
set -u
cd "$(dirname "$0")/../.."

B=tests/bench-httpd
SEGS=${SEGS:-5}
THREADS=${THREADS:-4}
CONNS=${CONNS:-16}
NPROC=$(nproc 2>/dev/null || echo 4)

[ -x "$B/carga" ] || cc -O2 -o "$B/carga" "$B/carga.c" -lpthread || exit 1
[ -x "$B/pscript-srv" ] || bash tests/psbuild.sh "$B/servidor.psc" "$B/pscript-srv" -O2 || exit 1

medir() {  # medir <nome> <porto>
    sleep 0.5
    # uma volta de aquecimento, deitada fora: o primeiro segundo de qualquer
    # runtime com JIT é outra coisa, e medi-lo seria medir o arranque
    "$B/carga" "$2" "$THREADS" "$CONNS" 1 / >/dev/null 2>&1
    local r=$("$B/carga" "$2" "$THREADS" "$CONNS" "$SEGS" /)
    local j=$("$B/carga" "$2" "$THREADS" "$CONNS" "$SEGS" /json)
    printf "%-22s %10s %8s %9s   %10s\n" "$1" \
        "$(echo $r | cut -d' ' -f1)" "$(echo $r | cut -d' ' -f2)" \
        "$(echo $r | cut -d' ' -f3)" "$(echo $j | cut -d' ' -f1)"
}

echo "gerador: carga.c, $THREADS threads x $CONNS conexoes keep-alive, ${SEGS}s, nproc=$NPROC"
printf "%-22s %10s %8s %9s   %10s\n" "servidor" "req/s /" "erros" "lat(ms)" "req/s /json"
printf '%.0s-' $(seq 1 66); echo

# ---- o nosso, com UM worker ----
rm -f "$B/p1"; "$B/pscript-srv" "$B/p1" 1 >/dev/null 2>&1 &
S=$!; for _ in $(seq 1 60); do [ -s "$B/p1" ] && break; sleep 0.05; done
medir "pscript (1 worker)" "$(cat $B/p1)"; kill $S 2>/dev/null; wait $S 2>/dev/null

# ---- e com a máquina inteira, que é como ele nasce (D12) ----
rm -f "$B/pn"; "$B/pscript-srv" "$B/pn" "$NPROC" >/dev/null 2>&1 &
S=$!; for _ in $(seq 1 60); do [ -s "$B/pn" ] && break; sleep 0.05; done
medir "pscript ($NPROC workers)" "$(cat $B/pn)"; kill $S 2>/dev/null; wait $S 2>/dev/null

# ---- o Bun, como ele nasce (um processo) e com reusePort ----
if command -v bun >/dev/null; then
    bun "$B/bun.js" 0 > "$B/bp" 2>/dev/null &
    S=$!; for _ in $(seq 1 60); do [ -s "$B/bp" ] && break; sleep 0.05; done
    medir "bun (1 processo)" "$(cat $B/bp)"; kill $S 2>/dev/null; wait $S 2>/dev/null
fi

# ---- e o `http` do Node, que é a linha de base que todo o mundo conhece ----
if command -v node >/dev/null; then
    node "$B/node.js" 0 > "$B/np" 2>/dev/null &
    S=$!; for _ in $(seq 1 60); do [ -s "$B/np" ] && break; sleep 0.05; done
    medir "node http (1 processo)" "$(cat $B/np)"; kill $S 2>/dev/null; wait $S 2>/dev/null
fi
