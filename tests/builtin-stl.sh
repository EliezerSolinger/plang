#!/bin/sh
# builtin-stl.sh — a 142.0, medida: um recém-chegado compila um `.p` com um
# `Vec` SEM configurar nada.
#
# Antes disto ele batia em duas falésias antes de chegar ao programa dele:
#
#   error: import <stl/vec.ph>: not found in any package root
#          (none was given: `--pkg-path <dir>`, repeatable)
#   error: … the package root and the sources have to be named the same way …
#
# O portão corre FORA da árvore de propósito — num directório temporário, sem
# `--pkg-path`, sem `--out-dir` e com o compilador chamado pelo caminho absoluto.
# É a situação de quem acabou de instalar, e é a única em que a falésia aparecia.
set -u
cd "$(dirname "$0")/.."
ROOT=$PWD
PLANGC=${PLANGC:-$ROOT/build/bin/plangc_s2}
CC=${CC:-cc}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

cat > "$T/exemplo.p" <<'PP'
include <stdio.h>
import <stl/vec.ph>
import <stl/map.ph>

declare Vec<i32>
implement Vec<i32>
declare StrMap<i32>
implement StrMap<i32>

def main() -> int:
    v: Vec<i32>
    v.init()
    for i in range(5):
        v.push(i * i)
    for i in range(v.len):
        printf("%d ", v.get(i))
    printf("\n")
    m: StrMap<i32>
    m.init()
    m.put("dois", 2)
    printf("%d\n", m.get_or("dois", -1))
    return 0
PP
printf '0 1 4 9 16 \n2\n' > "$T/want"

ok=0
# 1. com `-o`: o espelho do embebido nasce ao lado do ficheiro nomeado
(cd "$T" && "$PLANGC" exemplo.p -o um.c) 2>"$T/e1" || { echo "   FAIL builtin-stl (-o): $(sed 's/.*error: //' "$T/e1" | head -1)"; exit 1; }
(cd "$T" && $CC -w -o um um.c) 2>>"$T/e1" || { echo "   FAIL builtin-stl (-o, cc): $(tail -1 "$T/e1")"; exit 1; }
"$T/um" > "$T/g1" 2>&1
diff -q "$T/want" "$T/g1" >/dev/null || { echo "   FAIL builtin-stl (-o, saída)"; diff "$T/want" "$T/g1"; exit 1; }
ok=$((ok+1))

# 2. com `--out-dir`: o espelho nasce lá dentro
(cd "$T" && "$PLANGC" --out-dir saida exemplo.p) 2>"$T/e2" || { echo "   FAIL builtin-stl (--out-dir): $(sed 's/.*error: //' "$T/e2" | head -1)"; exit 1; }
(cd "$T" && $CC -w -o dois saida/exemplo.c) 2>>"$T/e2" || { echo "   FAIL builtin-stl (--out-dir, cc): $(tail -1 "$T/e2")"; exit 1; }
"$T/dois" > "$T/g2" 2>&1
diff -q "$T/want" "$T/g2" >/dev/null || { echo "   FAIL builtin-stl (--out-dir, saída)"; diff "$T/want" "$T/g2"; exit 1; }
ok=$((ok+1))

# 3. 142.3: o EMBEBIDO ganha. Uma raiz com um `stl` que mente é ignorada — um
#    ficheiro que pudesse substituir o embebido em silêncio traz de volta a
#    classe de erro que o `embed` existe para matar.
mkdir -p "$T/falso/stl"
echo 'esta linha nao e P valido e ninguem a deve ler' > "$T/falso/stl/vec.ph"
(cd "$T" && "$PLANGC" --pkg-path falso exemplo.p -o tres.c) 2>"$T/e3" || { echo "   FAIL builtin-stl (embebido não ganhou): $(sed 's/.*error: //' "$T/e3" | head -1)"; exit 1; }
ok=$((ok+1))

# 4. ... e uma raiz que se CHAMA `packages` também não substitui: a raiz virtual
#    é a primeira que se procura, e ela é exactamente esse caminho (154.2).
mkdir -p "$T/packages/stl"
echo 'nem esta' > "$T/packages/stl/vec.ph"
(cd "$T" && "$PLANGC" exemplo.p -o quatro.c) 2>"$T/e4" || { echo "   FAIL builtin-stl (um packages/ local ganhou): $(sed 's/.*error: //' "$T/e4" | head -1)"; exit 1; }
ok=$((ok+1))

echo "   OK builtin-stl $ok ok (sem --pkg-path, e o embebido ganha de uma raiz que mente)"
