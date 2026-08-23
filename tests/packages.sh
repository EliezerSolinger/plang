#!/usr/bin/env bash
# packages.sh — `import <pkg/mod.ph>`: o pacote como CAMINHO DE BUSCA (F1).
#
# O que se prende aqui é a fronteira decidida em `pbuild/ARQUITETURA.md`: o
# compilador NÃO sabe o que é um pacote. Ele recebe raízes de busca
# (`--pkg-path`, repetível) e procura nelas, na ordem — a mesma regra do `-I` do
# C, e pela mesma razão: é a única que dá para explicar numa linha. Quem sabe o
# que é versão, dependência e resolução é o `ppack`.
#
# Três formas, sem ambiguidade nenhuma entre elas:
#
#   include <stdio.h>        header de C do sistema
#   import <stl/vec.ph>      módulo de um PACOTE, procurado nas raízes
#   import "vizinho.ph"      módulo ao lado do arquivo, como sempre
#
# E NÃO há recuo de uma para a outra: um `<>` que não é achado é erro, e não
# vira uma tentativa relativa. Um recuo silencioso faria um programa compilar
# por acidente com o arquivo errado.
set -u
cd "$(dirname "$0")/.."

PLANGC=${PLANGC:-build/bin/plangc_s2}
CC=${CC:-cc}
OUT=${OUT:-tests/out/packages}
PKG=tests/pkg
PSDEFS="-D_POSIX_C_SOURCE=200112L -D_DEFAULT_SOURCE"
rm -rf "$OUT"; mkdir -p "$OUT"
pass=0; fail=0

ok()   { pass=$((pass+1)); }
bad()  { echo "  FAIL $1"; fail=$((fail+1)); }
# igualdade com mensagem: o que se esperava e o que veio, sem o leitor ter de
# adivinhar qual é qual
check() {
    if [ "$2" = "$3" ]; then pass=$((pass+1))
    else echo "  FAIL $1: esperava '$2', veio '$3'"; fail=$((fail+1)); fi
}

# ---- 1. P: um programa que usa dois pacotes, um deles dependendo do outro ----
cat > "$OUT/prog.p" <<'EOP'
include <stdio.h>
import <txt/txt.ph>

def main() -> int:
    printf("%lld %lld %lld\n", geo_area(3, 4), geo_perim(3, 4), txt_dobro_area(3, 4))
    return 0
EOP
if $PLANGC --pkg-path "$PKG" --out-dir "$OUT/o" "$OUT/prog.p" 2>"$OUT/p.err"; then
    if $CC -O2 -w -o "$OUT/prog" $(find "$OUT/o" -name '*.c') 2>>"$OUT/p.err"; then
        got=$("$OUT/prog")
        [ "$got" = "12 14 24" ] && ok || bad "P: saída '$got', esperava '12 14 24'"
    else
        bad "P: não linka"; head -3 "$OUT/p.err"
    fi
else
    bad "P: não compila"; head -3 "$OUT/p.err"
fi

# o `.p` do pacote foi PUXADO sem ser nomeado: é o que faz um pacote ser uma
# unidade em vez de uma lista de arquivos que quem usa tem de conhecer
find "$OUT/o" -name 'geo.c' | grep -q . && ok || bad "P: o .p do pacote não foi compilado"
find "$OUT/o" -name 'txt.c' | grep -q . && ok || bad "P: o .p do pacote de segundo nível não foi compilado"

# ---- 2. as respostas do protocolo enxergam o pacote ----
deps=$($PLANGC --pkg-path "$PKG" --deps "$OUT/prog.p" 2>&1)
echo "$deps" | grep -q "$PKG/geo/geo.ph" && ok || bad "--deps não lista o header do pacote"
echo "$deps" | grep -q "$PKG/geo/geo.p"  && ok || bad "--deps não lista o código do pacote"
outs=$($PLANGC --pkg-path "$PKG" --outputs --out-dir "$OUT/o" "$OUT/prog.p" 2>&1)
echo "$outs" | grep -q "geo.c" && ok || bad "--outputs não lista o .c do pacote"
echo "$outs" | grep -q "geo.h" && ok || bad "--outputs não lista o .h do pacote"

# ---- 3. o erro DIZ ONDE PROCUROU ----
e=$($PLANGC --out-dir "$OUT/x" "$OUT/prog.p" 2>&1)
echo "$e" | grep -q "not found in any package root" && ok || bad "erro sem raiz: mensagem errada"
echo "$e" | grep -q -- "--pkg-path" && ok || bad "erro sem raiz: não diz como dar uma raiz"
e=$($PLANGC --pkg-path /nao/existe --pkg-path /outra --out-dir "$OUT/x" "$OUT/prog.p" 2>&1)
echo "$e" | grep -q "looked in: /nao/existe /outra" && ok || bad "erro: não lista as raízes procuradas"

# ---- 4. `<>` NÃO recua para relativo ----
mkdir -p "$OUT/vizinho"
cat > "$OUT/vizinho/lado.ph" <<'EOP'
def lado_um() -> i64
EOP
cat > "$OUT/vizinho/usa.p" <<'EOP'
import <lado.ph>
def main() -> int:
    return i32(lado_um())
EOP
e=$($PLANGC --out-dir "$OUT/x" "$OUT/vizinho/usa.p" 2>&1)
echo "$e" | grep -q "not found in any package root" && ok || bad "<> recuou para o caminho relativo"

# ---- 5. pscript: o mesmo pacote, do outro lado ----
cat > "$OUT/pprog.psc" <<'EOP'
import <geo/geo.ph>

print("area:", geo_area(3, 4))
print("perim:", geo_perim(3, 4))
EOP
RT="$OUT/rt"
mkdir -p "$RT"
# 1.5(a): o guarda-chuva basta (ver a checagem 8, que é sobre isto mesmo)
RTSRC="pscript/runtime/psrt.ph"
if $PLANGC --out-dir "$RT" $RTSRC 2>"$OUT/rt.err" &&
   $PLANGC --pkg-path "$PKG" --out-dir "$RT" "$OUT/pprog.psc" 2>"$OUT/ps.err"; then
    if $CC -std=c11 -O0 $PSDEFS -w -o "$OUT/pprog" "$RT/$OUT/pprog.c" \
           "$RT"/pscript/runtime/psrt_*.c $(find "$RT/$PKG" -name '*.c') \
           -lm -pthread 2>>"$OUT/ps.err"; then
        got=$("$OUT/pprog")
        [ "$got" = "area: 12
perim: 14" ] && ok || bad "pscript: saída '$got'"
    else
        bad "pscript: não linka"; head -3 "$OUT/ps.err"
    fi
else
    bad "pscript: não compila"; head -3 "$OUT/ps.err"
fi
deps=$($PLANGC --pkg-path "$PKG" --deps "$OUT/pprog.psc" 2>&1)
echo "$deps" | grep -q "$PKG/geo/geo.p" && ok || bad "pscript --deps não lista o código do pacote"

# ---- 6. raiz e fontes em espaços diferentes: erro CLARO, não include quebrado ----
e=$($PLANGC --pkg-path "$PWD/$PKG" --out-dir "$OUT/x" "$OUT/prog.p" 2>&1)
echo "$e" | grep -q "named the same way" && ok || bad "espaços misturados: devia recusar com mensagem"

# (o `pack.json` de workspace e a raiz que sai dele têm portão próprio na suíte
# do motor — `caso_manifesto` em `pbuild/ps/engine_test.psc` —, porque quem os lê
# é pscript e o portão vive junto do código que testa)

# ---- 7. um pacote PSCRIPT: as duas grafias ----
# `<cor>` é a raiz do pacote (o módulo com o nome dele); `<cor/tons.psc>` é um
# módulo interno. O nome do espaço é o último pedaço sem extensão, nos dois.
cat > "$OUT/usa.psc" <<'EOP'
import <cor>
import <cor/tons.psc>
import <cor/tons.psc> as t2

print(cor.nome(), cor.clarear(10))
print(tons.escuro(), t2.escuro())
EOP
RT2="$OUT/rt2"
mkdir -p "$RT2"
if $PLANGC --pkg-path packages --out-dir "$RT2" pscript/runtime/psrt.ph 2>"$OUT/rt2.err" &&
   $PLANGC --pkg-path "$PKG" --out-dir "$RT2" "$OUT/usa.psc" 2>"$OUT/usa.err"; then
    if $CC -std=c11 -O0 $PSDEFS -w -o "$OUT/usa" "$RT2/$OUT/usa.c" \
           "$RT2"/pscript/runtime/psrt_*.c -lm -pthread 2>>"$OUT/usa.err"; then
        got=$("$OUT/usa")
        [ "$got" = "cor 26
32 32" ] && ok || bad "pacote pscript: saída '$got'"
    else
        bad "pacote pscript: não linka"; head -3 "$OUT/usa.err"
    fi
else
    bad "pacote pscript: não compila"; head -3 "$OUT/usa.err"
fi

# `<pkg>` sem o pacote na raiz é erro, e não uma tentativa relativa
e=$($PLANGC --out-dir "$OUT/x" "$OUT/usa.psc" 2>&1)
echo "$e" | grep -q "not found in any package root" && ok || bad "<pkg> pscript recuou para relativo"

# ---- 8. a 1.5(a): nomear UM arquivo constrói o fecho dele ----
# É o que faz as seis listas de módulos espalhadas pelos arreios ficarem
# redundantes: o runtime inteiro do pscript sai de nomear o guarda-chuva dele.
rm -rf "$OUT/fecho"
$PLANGC --pkg-path packages --out-dir "$OUT/fecho" pscript/runtime/psrt.ph 2>"$OUT/fecho.err"
n=$(ls "$OUT/fecho"/pscript/runtime/*.c 2>/dev/null | wc -l)
check "1.5(a): o runtime inteiro vem de um arquivo" "6" "$n"

# e com `-o` o contrato antigo continua: UM artefato
rm -rf "$OUT/um"; mkdir -p "$OUT/um"
$PLANGC -o "$OUT/um/geom.c" "$PKG/geo/geo.p" --pkg-path "$PKG" 2>/dev/null
n2=$(ls "$OUT/um"/*.c 2>/dev/null | wc -l)
check "1.5(a): com -o, um só arquivo" "1" "$n2"

# ---- 9. a docstring de um PROTÓTIPO ----
doc=$($PLANGC --api "$PKG/geo/geo.ph" 2>&1 | grep '^#doc geo_area ')
case $doc in
    "#doc geo_area A area do retangulo w x h.") ok ;;
    *) bad "doc de protótipo: veio '$doc'" ;;
esac

# ---- 2.13: um pacote que traz C ESCRITO À MÃO ----
#
# Aqui mede-se só a metade do COMPILADOR: que ele resolve `<crc/crc.ph>`, que o
# `include "crc32.h"` do `.p` atravessa para o C emitido, e que o `.c` do pacote
# passa pelo nosso front end com as flags que o manifesto declara. A outra
# metade — quem lê o manifesto, reescreve o `-I` contra o diretório do pacote e
# liga o objeto — é do sistema de build, e tem portão na suíte do motor.
cat > "$OUT/usa_crc.p" <<'EOP'
include <stdio.h>
import <crc/crc.ph>

def main() -> int:
    printf("%u\n", crc32_de("123456789"))
    return 0
EOP
CRCFLAGS="-DCRC_POLY=0xEDB88320 -I$PKG/crc/include"
if $PLANGC --pkg-path "$PKG" --cpp "$CC $CRCFLAGS" --out-dir "$OUT/oc" "$OUT/usa_crc.p" 2>"$OUT/crc.err"; then
    ok
    # e o `.c` do pacote pelo NOSSO front end, que é a decisão 2.13
    if $PLANGC --cpp "$CC $CRCFLAGS" --out-dir "$OUT/oc" "$PKG/crc/src/crc32.c" 2>>"$OUT/crc.err"; then
        ok
        if $CC -O2 -w $CRCFLAGS -o "$OUT/usa_crc" $(find "$OUT/oc" -name '*.c') 2>>"$OUT/crc.err"; then
            check "o CRC-32 de 123456789" "3421780262" "$("$OUT/usa_crc")"
        else bad "o C do pacote não linkou (veja $OUT/crc.err)"; fi
    else bad "o .c do pacote não passou pelo nosso front end (veja $OUT/crc.err)"; fi
else bad "um programa que importa <crc/crc.ph> não compilou (veja $OUT/crc.err)"; fi
# o `#error` do C do pacote é o portão pela negativa: sem o `-D` do manifesto,
# ele TEM de recusar — senão o teste acima passaria mesmo que as flags nunca
# tivessem chegado
if $PLANGC --out-dir "$OUT/oc2" "$PKG/crc/src/crc32.c" >/dev/null 2>&1; then
    bad "o .c do pacote devia recusar sem o -D que o manifesto declara"
else ok; fi

echo "   packages: $pass ok, $fail failed"
[ $fail = 0 ]
