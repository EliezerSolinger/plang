#!/usr/bin/env bash
# overflow-opt.sh — a aritmética checada continua checada COM otimização.
#
# Por que isto é um teste de shell e não um `.expected`: o corpus do pscript
# compila a `-O0` (só o `perf_test` do pstudio pede `-O2`), e o defeito que
# motivou este portão só existe a partir de `-O1`. Uma saída esperada no corpus
# passaria verde para sempre sem tocar no problema.
#
# O DEFEITO. A 7.2 promete que estouro de inteiro lança, e é um dos quatro eixos
# de segurança. `ps_mul` multiplicava e conferia depois, com a divisão:
#
#     r: i64 = a * b                      # estouro de signed: UB em C
#     if b != 0 and (r / a != b or ...):  # o compilador tem o direito de apagar
#
# A matemática do teste estava certa — conferida contra aritmética exacta, acerta
# todos os casos. O que a derrubava é que `a * b` de signed que estoura é
# comportamento indefinido, então o gcc assume que não estoura, prova que
# `r / a == b` sempre vale, e remove o `if`. Medido antes do conserto:
#
#     -O0          levanta          (correcto)
#     -O1          -2               EM SILÊNCIO
#     -O2          -2               EM SILÊNCIO
#     -O2 -flto    -2               EM SILÊNCIO
#     -O2 -fwrapv  levanta          (porque aí o estouro passa a ser definido)
#
# `MAX * MAX` dava 1 e `2 ** 100` dava 0. `ps_add` e `ps_sub` sempre perguntaram
# ANTES de somar, e por isso estavam certos; só a multiplicação não fazia.
#
# A LIÇÃO QUE ESTE PORTÃO GUARDA é mais larga do que a multiplicação: um teste
# que corre num modo de compilação diferente do que o utilizador usa não prova o
# que ele executa. O `run.sh` já diz isto sobre VELOCIDADE ("measuring speed on
# an unoptimised build measures the wrong binary"); vale igual para SEMÂNTICA.
# Por isso aqui a matriz é de níveis de otimização e não de casos.
#
#   bash tests/overflow-opt.sh
set -u
cd "$(dirname "$0")/.."

PLANGC=${PLANGC:-build/bin/plangc_s2}
CC=${CC:-cc}
PSDEFS="-D_POSIX_C_SOURCE=200112L -D_DEFAULT_SOURCE -D_DARWIN_C_SOURCE"
OUT=tests/out/overflowopt

rm -rf "$OUT"
mkdir -p "$OUT"

# Os operandos atravessam um valor de função para que nada possa ser dobrado em
# compilação: o que se mede é a checagem do RUNTIME, não a do front end.
cat > "$OUT/ovf.psc" <<'EOF'
def mul(a: int, b: int) -> int:
    return a * b

def sum_v(a: int, b: int) -> int:
    return a + b

def sub(a: int, b: int) -> int:
    return a - b

def pot(a: int, b: int) -> int:
    return a ** b

def expected(name_s: str, f: def(int, int) -> int, a: int, b: int):
    try:
        print(f"{name_s} NAO LEVANTOU: {f(a, b)}")
    catch e:
        print(f"{name_s} ok")

MAX = 9223372036854775807
MIN = -9223372036854775807 - 1

expected("MAX+1", sum_v, MAX, 1)
expected("MIN-1", sub, MIN, 1)
expected("MAX*2", mul, MAX, 2)
expected("MAX*MAX", mul, MAX, MAX)
expected("MIN*-1", mul, MIN, -1)
expected("-1*MIN", mul, -1, MIN)
expected("2**100", pot, 2, 100)

# e o que NAO estoura continua a passar, com o valor certo
print(f"3*5={mul(3, 5)}")
print(f"-3*5={mul(-3, 5)}")
print(f"3*-5={mul(3, -5)}")
print(f"-3*-5={mul(-3, -5)}")
print(f"MAX*1={mul(MAX, 1)}")
print(f"MIN*1={mul(MIN, 1)}")
print(f"MAX*0={mul(MAX, 0)}")
print(f"2**62={pot(2, 62)}")
EOF

cat > "$OUT/expected.txt" <<'EOF'
MAX+1 ok
MIN-1 ok
MAX*2 ok
MAX*MAX ok
MIN*-1 ok
-1*MIN ok
2**100 ok
3*5=15
-3*5=-15
3*-5=-15
-3*-5=15
MAX*1=9223372036854775807
MIN*1=-9223372036854775808
MAX*0=0
2**62=4611686018427387904
EOF

if ! $PLANGC --out-dir "$OUT/c" "$OUT/ovf.psc" 2>"$OUT/err" ; then
    echo "  FAIL overflow-opt: o programa não compilou"
    sed 's/^/      /' "$OUT/err" | head -5
    exit 1
fi
$PLANGC --out-dir "$OUT/c" pscript/runtime/psrt.ph 2>>"$OUT/err" || {
    echo "  FAIL overflow-opt: o runtime não compilou"; exit 1; }

nivel=0
for flags in "-O0" "-O1" "-O2" "-O3" "-O2 -flto" "-Os"; do
    bin="$OUT/ovf$nivel"
    if ! $CC $flags -w -o "$bin" "$OUT/c/$OUT/ovf.c" \
            "$OUT/c/pscript/runtime/"psrt_*.c $PSDEFS -lm -pthread 2>>"$OUT/err"; then
        echo "  FAIL overflow-opt: não ligou com '$flags'"
        sed 's/^/      /' "$OUT/err" | tail -5
        exit 1
    fi
    if ! "$bin" > "$OUT/saida$nivel" 2>&1; then
        echo "  FAIL overflow-opt [$flags]: o programa não terminou bem"
        sed 's/^/      /' "$OUT/saida$nivel" | head -5
        exit 1
    fi
    if ! diff -q "$OUT/expected.txt" "$OUT/saida$nivel" >/dev/null; then
        echo "  FAIL overflow-opt [$flags]: a aritmética checada mudou de resposta"
        diff "$OUT/expected.txt" "$OUT/saida$nivel" | head -8 | sed 's/^/      /'
        exit 1
    fi
    nivel=$((nivel + 1))
done
echo "   overflow-opt: 7 estouros levantam e 8 contas certas batem, em $nivel níveis de otimização"
