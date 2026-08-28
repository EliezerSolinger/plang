#!/usr/bin/env bash
# nocheck.sh — `nocheck:` não checa em release, e CHECA em depuração.
#
# Por que isto é um teste de shell e não um `.expected`: o que se verifica é a
# diferença entre DOIS modos de compilação do mesmo ficheiro, e um caso do corpus
# é compilado uma vez. É a mesma razão do `overflow-opt.sh`.
#
# O QUE `nocheck:` É. Açúcar sobre a 54.1: dentro do bloco, `+ - *` sobre int
# passam a ser `%+ %- %*`, que já existem e já dão a volta. Medido, 200 milhões
# de multiplicações a `-O2 -flto`:
#
#     checado          1128 ms
#     nocheck:          753 ms      1,50x
#     %* a mao          764 ms      (identico ao bloco, como se esperava)
#
# O QUE ELE NÃO É: a operação signed crua. Essa é a única que o alvo tem licença
# para assumir que nunca estoura, e foi assim que o `ps_mul` perdeu a checagem
# dele. Medido em C, as duas formas geram exactamente as MESMAS instruções —
#
#     raw:   movq %rdi,%rax ; imulq %rsi,%rax ; ret
#     wrap:  movq %rdi,%rax ; imulq %rsi,%rax ; ret
#
# — logo o UB não compra velocidade nenhuma; compra o direito de o compilador
# reescrever a guarda ao lado. `int guarda(int a) { return a*2 < 0; }` compila
# para `shrl $31` a -O2, ou seja "o bit de sinal de a", que é outra pergunta.
#
# `-g` (a metade de depuração dos dois modos da 100.1) mantém as checagens: um
# bloco que promete não levantar é exactamente o que se quer ver levantar num
# teste.
#
#   bash tests/nocheck.sh
set -u
cd "$(dirname "$0")/.."

PLANGC=${PLANGC:-build/bin/plangc_s2}
CC=${CC:-cc}
PSDEFS="-D_POSIX_C_SOURCE=200112L -D_DEFAULT_SOURCE -D_DARWIN_C_SOURCE"
OUT=tests/out/nocheck

rm -rf "$OUT"
mkdir -p "$OUT"

cat > "$OUT/nc.psc" <<'EOF'
MAX = 9223372036854775807
MIN = -9223372036854775807 - 1

def mul(a: int, b: int) -> int:
    return a * b

def mul_nc(a: int, b: int) -> int:
    nocheck:
        return a * b

def sum_nc(a: int, b: int) -> int:
    nocheck:
        return a + b

def sub_nc(a: int, b: int) -> int:
    nocheck:
        return a - b

def nested(a: int, b: int) -> int:
    nocheck:
        nocheck:
            return a * b

def show(name_s: str, f: def(int, int) -> int, a: int, b: int):
    try:
        print(f"{name_s} = {f(a, b)}")
    catch e:
        print(f"{name_s} levantou")

show("checado MAX*2", mul, MAX, 2)
show("checado MIN*-1", mul, MIN, -1)
show("nocheck MAX*2", mul_nc, MAX, 2)
show("nocheck MIN*-1", mul_nc, MIN, -1)
show("nocheck MAX+1", sum_nc, MAX, 1)
show("nocheck MIN-1", sub_nc, MIN, 1)
show("nocheck nested MAX*2", nested, MAX, 2)
show("nocheck 3*5", mul_nc, 3, 5)
show("nocheck -3*5", mul_nc, -3, 5)
show("nocheck -3*-5", mul_nc, -3, -5)
EOF

cat > "$OUT/release.txt" <<'EOF'
checado MAX*2 levantou
checado MIN*-1 levantou
nocheck MAX*2 = -2
nocheck MIN*-1 = -9223372036854775808
nocheck MAX+1 = -9223372036854775808
nocheck MIN-1 = 9223372036854775807
nocheck nested MAX*2 = -2
nocheck 3*5 = 15
nocheck -3*5 = -15
nocheck -3*-5 = 15
EOF

cat > "$OUT/debug.txt" <<'EOF'
checado MAX*2 levantou
checado MIN*-1 levantou
nocheck MAX*2 levantou
nocheck MIN*-1 levantou
nocheck MAX+1 levantou
nocheck MIN-1 levantou
nocheck nested MAX*2 levantou
nocheck 3*5 = 15
nocheck -3*5 = -15
nocheck -3*-5 = 15
EOF

# uma árvore de saída POR MODO, runtime incluído: o C gerado inclui
# `psrt.h` por caminho relativo ao espelho, então o programa e o runtime têm de
# sair na mesma árvore
for modo in release debug; do
    flag=""
    [ "$modo" = debug ] && flag="-g"
    d="$OUT/c-$modo"
    if ! $PLANGC $flag --out-dir "$d" pscript/runtime/psrt.ph 2>>"$OUT/err"; then
        echo "  FAIL nocheck [$modo]: o runtime não compilou"
        sed 's/^/      /' "$OUT/err" | tail -4
        exit 1
    fi
    if ! $PLANGC $flag --out-dir "$d" "$OUT/nc.psc" 2>>"$OUT/err"; then
        echo "  FAIL nocheck [$modo]: não compilou"
        sed 's/^/      /' "$OUT/err" | tail -4
        exit 1
    fi
    if ! $CC -O2 -w -o "$OUT/nc-$modo" "$d/$OUT/nc.c" \
            "$d/pscript/runtime/"psrt_*.c $PSDEFS -lm -pthread 2>>"$OUT/err"; then
        echo "  FAIL nocheck [$modo]: não ligou"
        sed 's/^/      /' "$OUT/err" | tail -4
        exit 1
    fi
    if ! "$OUT/nc-$modo" > "$OUT/saida-$modo" 2>&1; then
        echo "  FAIL nocheck [$modo]: o programa não terminou bem"
        sed 's/^/      /' "$OUT/saida-$modo" | head -4
        exit 1
    fi
    if ! diff -q "$OUT/$modo.txt" "$OUT/saida-$modo" >/dev/null; then
        echo "  FAIL nocheck [$modo]: a aritmética do bloco não é a esperada"
        diff "$OUT/$modo.txt" "$OUT/saida-$modo" | head -8 | sed 's/^/      /'
        exit 1
    fi
done
echo "   nocheck: 7 estouros dão a volta em release e levantam com -g, e 3 contas certas batem nos dois"
