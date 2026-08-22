#!/usr/bin/env bash
# repo.sh — o REPOSITÓRIO inteiro, de ponta a ponta, sem rede.
#
# O que se prende aqui é a volta completa que `ppack/REPOSITORIO.md` desenha:
#
#     publish  ->  um `.tar` e uma entrada no índice, num diretório
#     update   ->  o índice guardado, e o repositório aceite no lock (TOFU)
#     search   ->  offline, por nome, descrição e SÍMBOLO
#     add      ->  o hash conferido, o lock escrito, as dependências junto
#     install  ->  a árvore aberta em build/pkg/<nome>-<versão>-<hash>/
#     compilar ->  um programa que usa o pacote instalado, e RODA
#
# Um repositório é um FORMATO, não um serviço: aqui ele é um diretório e o
# transporte é `file://`. Quando o HTTP entrar, entra por baixo de `buscar` e
# nada disto muda — é essa a propriedade que este teste fixa.
#
# E fixa também a que mais importa: o hash NUNCA é dispensado. O último caso
# estraga um byte do tarball no armazém e exige que o `install` recuse.
set -u
cd "$(dirname "$0")/.."

PPACK=${PPACK:-build/bin/ppack}
PLANGC=${PLANGC:-build/bin/plangc_s2}
CC=${CC:-cc}
OUT=${OUT:-tests/out/repo}
PSDEFS="-D_POSIX_C_SOURCE=200112L -D_DEFAULT_SOURCE"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); printf '   FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1: esperava '$2', veio '$3'"; fi; }

RAIZ=$PWD
# as ferramentas viram ABSOLUTAS uma vez, aqui: este teste muda de diretório
# várias vezes de propósito (um projeto que só tem manifesto é o ponto), e um
# caminho relativo a `$PWD` deixaria de valer no primeiro `cd`. Foi o que
# aconteceu quando o `verify-all` as passou já absolutas e o script as prefixou
# outra vez.
case $PPACK in /*) ;; *) PPACK=$RAIZ/$PPACK;; esac
case $PLANGC in /*) ;; *) PLANGC=$RAIZ/$PLANGC;; esac
rm -rf "$OUT"; mkdir -p "$OUT/repo" "$OUT/proj"

# ---- 1. publish: dois pacotes deste repositório viram tarball ----
"$PPACK" publish stl  --to "$OUT/repo" >"$OUT/pub1.log" 2>&1 || bad "publish stl"
"$PPACK" publish sha2 --to "$OUT/repo" >"$OUT/pub2.log" 2>&1 || bad "publish sha2"
[ -f "$OUT/repo/index.json" ] && ok || bad "publish não escreveu o índice"
[ -f "$OUT/repo/pkg/sha2/sha2-0.1.0.tar" ] && ok || bad "publish não escreveu o tarball"

# o `tar` do sistema abre o nosso — a razão de ser tar de verdade
if command -v tar >/dev/null 2>&1; then
    n=$(tar tf "$OUT/repo/pkg/sha2/sha2-0.1.0.tar" | grep -c 'sha2-0.1.0/')
    [ "$n" -ge 4 ] && ok || bad "o tar do sistema listou $n membros"
fi

# uma versão publicada é IMUTÁVEL
if "$PPACK" publish sha2 --to "$OUT/repo" >"$OUT/pub3.log" 2>&1; then
    bad "republicar a mesma versão devia ser recusado"
else ok; fi

# ---- 2. um projeto que só tem manifesto ----
cd "$OUT/proj"
cat > pack.json <<EOF
{
  "members": ["nada"],
  "repos": [{"url": "file://$RAIZ/$OUT/repo/", "unsafe": true}]
}
EOF

"$PPACK" update >update.log 2>&1 || bad "update"
grep -q "TOFU" update.log && ok || bad "o primeiro update devia dizer que aceitou o repositório"
[ -f pack.lock ] && ok || bad "update não escreveu o lock"

# ---- 3. search, offline e por símbolo ----
"$PPACK" search sha256_hex >search.log 2>&1
grep -q '\[símbolo\]' search.log && ok || bad "search não achou por símbolo"
"$PPACK" search naoexisteisto >search2.log 2>&1 && bad "search de nada devia falhar" || ok

# ---- 4. add: o hash confere, e a dependência vem junto ----
"$PPACK" add sha2@0.1.0 >add.log 2>&1 || bad "add"
grep -q "^stl 0.1.0" add.log && ok || bad 'o stl devia vir como dependência do sha2'
grep -q '"unsafe": true' pack.lock && ok || bad "o lock devia gravar o modo unsafe"
grep -q '"sha2": "0.1.0"' pack.json && ok || bad "add devia escrever a dependência no manifesto"

# sem versão exata: mensagem, não busca
"$PPACK" add sha2 >add2.log 2>&1 && bad "add sem versão devia ser recusado" || ok

# ---- 5. install: a árvore aberta ----
"$PPACK" install >install.log 2>&1 || bad "install"
d=$(ls -d build/pkg/sha2-0.1.0-* 2>/dev/null | head -1)
[ -f "$d/sha2/sha2.ph" ] && ok || bad "install não abriu a árvore do sha2"
ls -d build/pkg/stl-0.1.0-* >/dev/null 2>&1 && ok || bad "install não abriu o stl"

# ---- 6. e um programa que o usa COMPILA e RODA ----
cat > uso.psc <<'EOF'
import <sha2/sha2.ph>
b: list<u8> = []
for ch in "abc":
    b.append(u8(ord(ch)))
print(sha256_of(b))
EOF
ROOTS=""
for x in build/pkg/*/; do case "$x" in build/pkg/.*) ;; *) ROOTS="$ROOTS --pkg-path ${x%/}";; esac; done
mkdir -p rt
# Daqui em diante o comando corre da RAIZ do plang, e tudo é nomeado relativo a
# ela — o programa, as raízes de pacote e o `--ps-runtime`. Não é conveniência:
# sob `--out-dir` todos estes caminhos são espelhados, e o `#include` que sai no
# C gerado é a relação ENTRE eles. Misturar absoluto com relativo não tem
# relação nenhuma dentro do espelho, e o compilador diz isso em vez de emitir um
# include que aponta para fora (é a mesma regra que os pacotes já tinham).
cd "$RAIZ"
PROJ=$OUT/proj
ROOTS=""
for x in "$PROJ"/build/pkg/*/; do case "$(basename "$x")" in .*) ;; *) ROOTS="$ROOTS --pkg-path ${x%/}";; esac; done
mkdir -p "$PROJ/rt"
if "$PLANGC" $ROOTS --ps-runtime pscript/runtime --out-dir "$PROJ/rt" pscript/runtime/psrt.ph >"$PROJ/gen.log" 2>&1 \
   && "$PLANGC" $ROOTS --ps-runtime pscript/runtime --out-dir "$PROJ/rt" "$PROJ/uso.psc" >>"$PROJ/gen.log" 2>&1; then ok; else bad "não compilou contra o pacote instalado (veja $PROJ/gen.log)"; fi
RT=$(find "$PROJ/rt" -name 'psrt_mem.c' | head -1); RTD=$(dirname "$RT")
if $CC -O1 -w $PSDEFS "$PROJ/rt/$PROJ/uso.c" "$RTD"/psrt_*.c $(find "$PROJ/rt" -path '*sha2/sha2.c') -o "$PROJ/uso" -lm -pthread >"$PROJ/cc.log" 2>&1; then ok; else bad "não linkou (veja $PROJ/cc.log)"; fi
saiu=$("$PROJ/uso" 2>&1)
check "o sha256 de abc, pelo pacote instalado" \
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "$saiu"

# ---- 7. o hash NUNCA é dispensado ----
cd "$RAIZ/$OUT/proj"
rm -rf build/pkg/sha2-0.1.0-*
pak=$(ls build/pkg/.pak/* | head -1)
printf 'x' | dd of="$pak" bs=1 seek=600 count=1 conv=notrunc status=none
if "$PPACK" install >install2.log 2>&1; then
    bad "install aceitou um tarball adulterado"
else
    grep -q "hash NÃO bate" install2.log && ok || bad "a recusa não disse que foi o hash"
fi

cd "$RAIZ"
echo "   repo: $pass ok, $fail failed"
[ $fail = 0 ]
