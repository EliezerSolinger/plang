#!/usr/bin/env bash
# tests/protocol.sh — as respostas do compilador ao sistema de build (F0).
#
# O `pbuild` decide o que recompilar, e para decidir ele PERGUNTA. São quatro
# perguntas, e cada uma existe porque a alternativa é pior:
#
#   --version   quem é você? A versão da LINGUAGEM (o manifesto de um pacote
#               declara a faixa que exige) e o hash dos próprios bytes (é ele
#               que decide sujeira: outro compilador, outro C).
#   --deps      o que você leu? Sem isto, quem monta o grafo tem de reimplementar
#               a resolução de import — e uma segunda implementação que diverge
#               dá build velho depois de editar, o único modo de falhar que
#               importa.
#   --outputs   o que você VAI emitir? O grafo precisa das arestas ANTES de a
#               ferramenta rodar (é o `dyndep` do ninja, sem arquivo nenhum).
#   --api       qual a sua interface pública? Serve a doc, a verificação de
#               semver na publicação, e o caminho QBE, que não tem header.
#
# O que estas checagens PRENDEM, e é o ponto da coisa toda: o hash da API não
# pode mudar quando muda um comentário ou o nome de um parâmetro (senão editar
# doc recompila o mundo), e TEM de mudar quando muda um tipo, um campo ou o
# valor de um enum (senão o build fica com uma interface velha na mão).
set -u
cd "$(dirname "$0")/.."

PLANGC=${PLANGC:-./plangc2}

# o hash sai numa linha PROPRIA (`#hash ...`), e as docstrings vem DEPOIS dela —
# entao e a linha que se procura, e nao a ultima do relatorio
apihash() { $PLANGC --api "$1" 2>&1 | grep '^#hash '; }
OUT=tests/out/protocol
rm -rf "$OUT"; mkdir -p "$OUT"
fail=0
ok=0

check() { # check <o quê> <esperado> <obtido>
    if [ "$2" = "$3" ]; then ok=$((ok+1)); else
        echo "  FAIL $1: esperava '$2', veio '$3'"; fail=$((fail+1))
    fi
}
checkne() { # checkne <o quê> <não esperado> <obtido>
    if [ "$2" != "$3" ]; then ok=$((ok+1)); else
        echo "  FAIL $1: NÃO devia ser '$2'"; fail=$((fail+1))
    fi
}

# um módulo P de mentira, com um `.ph` que é a interface e um `.p` que a implementa
cat > "$OUT/geom.ph" <<'EOF'
import "vecs.ph"

const GEOM_MAX: i32 = 64

enum Shape:
    SH_DOT = 0
    SH_LINE
    SH_BOX = 7

struct Point:
    x: i32
    y: i32

def area(w: i32, h: i32) -> i64
def scale(p: *Point, by: i32)
EOF
cat > "$OUT/geom.p" <<'EOF'
import "geom.ph"

def area(w: i32, h: i32) -> i64:
    return i64(w) * i64(h)

def scale(p: *Point, by: i32):
    p->x *= by
    p->y *= by

private def helper_that_is_not_interface(n: i32) -> i32:
    return n + 1
EOF
cat > "$OUT/vecs.ph" <<'EOF'
def vecs_marker() -> i32
EOF

# ---- --version: a versão da linguagem e o hash dos bytes ----
ver=$($PLANGC --version 2>&1)
case $ver in
    "plangc "*" ("*")") ok=$((ok+1)) ;;
    *) echo "  FAIL --version: formato inesperado: '$ver'"; fail=$((fail+1)) ;;
esac
# o hash é dos BYTES do compilador: o mesmo binário responde sempre o mesmo
check "--version estável" "$ver" "$($PLANGC --version 2>&1)"

# ---- --deps: transitivo, normalizado, sem repetir ----
deps=$($PLANGC --deps "$OUT/geom.p" 2>&1)
check "--deps: o próprio arquivo" "1" "$(echo "$deps" | grep -c "geom\.p$")"
check "--deps: o header que ele importa" "1" "$(echo "$deps" | grep -c "geom\.ph$")"
check "--deps: transitivo (o import do header)" "1" "$(echo "$deps" | grep -c "vecs\.ph$")"
check "--deps: sem repetição" "$(echo "$deps" | wc -l)" "$(echo "$deps" | sort -u | wc -l)"
# um caminho com `..` no meio é o MESMO arquivo: um grafo que os visse como dois
# nós recompilaria por nada
deps2=$($PLANGC --deps "$OUT/../protocol/geom.p" 2>&1)
check "--deps: caminho normalizado" "$deps" "$deps2"

# ---- --outputs: o que sairia, sem sair ----
outs=$($PLANGC --outputs --out-dir "$OUT/build" "$OUT/geom.p" "$OUT/geom.ph" 2>&1)
check "--outputs: o .c e o .h" "$OUT/build/$OUT/geom.c $OUT/build/$OUT/geom.h" "$(echo $outs)"
check "--outputs: não escreve nada" "0" "$(ls "$OUT/build" 2>/dev/null | wc -l)"

# ---- --api: a interface, e só ela ----
api=$($PLANGC --api "$OUT/geom.ph" 2>&1)
check "--api: a const pública com o VALOR" "1" "$(echo "$api" | grep -c 'const GEOM_MAX: i32 = 64')"
check "--api: o enum com os valores" "1" "$(echo "$api" | grep -c 'enum Shape {SH_DOT = 0, SH_LINE, SH_BOX = 7}')"
check "--api: o struct com o layout" "1" "$(echo "$api" | grep -c 'struct Point {x: i32, y: i32}')"
check "--api: a assinatura sem nome de parâmetro" "1" "$(echo "$api" | grep -c 'def area(i32, i32) -> i64')"
# num `.p`, o que é `private` não é interface de ninguém
apip=$($PLANGC --api "$OUT/geom.p" 2>&1)
check "--api: o público do .p" "1" "$(echo "$apip" | grep -c 'def area(i32, i32) -> i64')"
check "--api: o private fica de fora" "0" "$(echo "$apip" | grep -c 'helper_that_is_not_interface')"

h0=$(apihash "$OUT/geom.ph")

# ---- a INVARIÂNCIA: comentário e nome de parâmetro não são interface ----
cp "$OUT/geom.ph" "$OUT/geom.ph.orig"
python3 - "$OUT/geom.ph" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('def area(w: i32, h: i32) -> i64',
              '# um comentário que não muda interface nenhuma\ndef area(largura: i32, altura: i32) -> i64', 1)
open(p, 'w').write(s)
PY
check "hash: comentário e parâmetro renomeado NÃO mudam" "$h0" "$(apihash "$OUT/geom.ph")"

# ---- a SENSIBILIDADE: tipo, layout e valor SÃO interface ----
for mudanca in 's/def area(w: i32, h: i32) -> i64/def area(w: i32, h: i32) -> i32/' \
               's/    y: i32/    y: i64/' \
               's/    SH_BOX = 7/    SH_BOX = 8/' \
               's/const GEOM_MAX: i32 = 64/const GEOM_MAX: i32 = 65/' ; do
    cp "$OUT/geom.ph.orig" "$OUT/geom.ph"
    python3 - "$OUT/geom.ph" "$mudanca" <<'PY'
import sys, re
p, sed = sys.argv[1], sys.argv[2]
_, pat, rep, _ = sed.split('/')
s = open(p).read()
assert pat in s, "a mudança não achou o alvo: " + pat
open(p, 'w').write(s.replace(pat, rep, 1))
PY
    checkne "hash muda: $mudanca" "$h0" "$(apihash "$OUT/geom.ph")"
done

# ---- a resposta é estável entre execuções (é chave de cache) ----
cp "$OUT/geom.ph.orig" "$OUT/geom.ph"
check "hash: mesma entrada, mesma resposta" "$h0" "$(apihash "$OUT/geom.ph")"

# ---- a DOCSTRING: sai na resposta, e NÃO entra no hash ----
# É a decisão que faz `--api` servir para as duas perguntas ao mesmo tempo: "a
# interface mudou?" (o hash, que é estrutural) e "o que isto faz?" (a doc).
# Mudar um texto de documentação não pode acordar quem só depende da interface.
cp "$OUT/geom.ph.orig" "$OUT/geom.ph"
h0=$(apihash "$OUT/geom.ph")
printf '"""O pacote de geometria.\n\nCom uma segunda linha."""\n' > "$OUT/geom2.ph"
cat "$OUT/geom.ph" >> "$OUT/geom2.ph"
mv "$OUT/geom2.ph" "$OUT/geom.ph"
check "hash: a docstring do módulo NÃO muda a interface" "$h0" "$(apihash "$OUT/geom.ph")"

doc=$($PLANGC --api "$OUT/geom.ph" 2>&1 | grep '^#doc \. ')
esperado='#doc . O pacote de geometria.\n\nCom uma segunda linha.'
check "doc: sai na resposta, com a quebra escapada" "$esperado" "$doc"

# e ela vem DEPOIS do hash — é o que permite ler uma sem ler a outra
lh=$($PLANGC --api "$OUT/geom.ph" 2>&1 | grep -n '^#hash ' | cut -d: -f1)
ld=$($PLANGC --api "$OUT/geom.ph" 2>&1 | grep -n '^#doc ' | head -1 | cut -d: -f1)
if [ -n "$lh" ] && [ -n "$ld" ] && [ "$lh" -lt "$ld" ]; then
    ok=$((ok+1))
else
    echo "  FAIL doc: a doc não vem depois do hash ($lh vs $ld)"; fail=$((fail+1))
fi

echo "   protocol: $ok ok, $fail failed"
[ $fail = 0 ] || exit 1
