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

# ---- 8. O MODO SEGURO: as duas assinaturas ----
#
# São duas, com donos diferentes: o REPOSITÓRIO assina o índice (contra uma
# lista velha servida como se fosse a de agora) e o AUTOR assina cada versão
# (contra o próprio repositório servir um tarball que o autor não fez).
cd "$RAIZ"
rm -rf "$OUT/seguro" "$OUT/chaves" "$OUT/projs"
mkdir -p "$OUT/chaves"
"$PPACK" keygen "$OUT/chaves/k" >"$OUT/keygen.log" 2>&1 && ok || bad "keygen"
[ -f "$OUT/chaves/k.pub" ] && ok || bad "keygen não escreveu a pública"
# uma chave que se sobrescreve é uma chave perdida
"$PPACK" keygen "$OUT/chaves/k" >/dev/null 2>&1 && bad "keygen devia recusar sobrescrever" || ok

"$PPACK" publish stl  --to "$OUT/seguro" --key "$OUT/chaves/k" >"$OUT/ps1.log" 2>&1 || bad "publish assinado (stl)"
"$PPACK" publish sha2 --to "$OUT/seguro" --key "$OUT/chaves/k" >"$OUT/ps2.log" 2>&1 || bad "publish assinado (sha2)"
[ -f "$OUT/seguro/index.json.sig" ] && ok || bad "o índice não foi assinado"
[ -f "$OUT/seguro/pkg/sha2/sha2-0.1.0.tar.sig" ] && ok || bad "o tarball não foi assinado"

mkdir -p "$OUT/projs"
cd "$OUT/projs"
cat > pack.json <<EOF
{
  "members": ["nada"],
  "repos": ["file://$RAIZ/$OUT/seguro/"]
}
EOF
"$PPACK" update >update.log 2>&1 || bad "update em modo seguro"
grep -q "TOFU" update.log && ok || bad "a primeira vez devia aceitar a chave (TOFU)"
grep -q '"key": "[0-9a-f]\{64\}"' pack.lock && ok || bad "a chave devia ficar GRAVADA no lock"
"$PPACK" add sha2@0.1.0 >add.log 2>&1 && ok || bad "add em modo seguro"
grep -q '"unsafe": false' pack.lock && ok || bad "assinado não é unsafe"

# a chave já é conhecida: o índice não muda em silêncio
cp "$RAIZ/$OUT/seguro/index.json" "$RAIZ/$OUT/seguro/index.json.bak"
sed -i 's/"size": /"size": 1/' "$RAIZ/$OUT/seguro/index.json"
"$PPACK" update >u2.log 2>&1 && bad "um índice trocado devia ser recusado" || ok
grep -q "chave que este projeto aceitou" u2.log && ok || bad "a recusa não falou da chave (veja $OUT/projs/u2.log)"
mv "$RAIZ/$OUT/seguro/index.json.bak" "$RAIZ/$OUT/seguro/index.json"

# um tarball trocado, com a assinatura antiga: o hash pega primeiro
cd "$RAIZ"
cp "$OUT/seguro/pkg/sha2/sha2-0.1.0.tar" "$OUT/seguro/pkg/sha2/sha2-0.1.0.tar.bak"
printf 'x' | dd of="$OUT/seguro/pkg/sha2/sha2-0.1.0.tar" bs=1 seek=700 count=1 conv=notrunc status=none
cd "$OUT/projs"
rm -f pack.lock; rm -rf build
cat > pack.json <<EOF
{
  "members": ["nada"],
  "repos": ["file://$RAIZ/$OUT/seguro/"]
}
EOF
"$PPACK" update >/dev/null 2>&1
"$PPACK" add sha2@0.1.0 >add2.log 2>&1 && bad "um tarball trocado devia ser recusado" || ok
grep -q "hash NÃO bate" add2.log && ok || bad "a recusa não falou do hash"
cd "$RAIZ"
mv "$OUT/seguro/pkg/sha2/sha2-0.1.0.tar.bak" "$OUT/seguro/pkg/sha2/sha2-0.1.0.tar"

# um repositório SEM assinatura e sem se declarar `unsafe`: recusa
mkdir -p "$OUT/projn"
cd "$OUT/projn"
cat > pack.json <<EOF
{
  "members": ["nada"],
  "repos": ["file://$RAIZ/$OUT/repo/"]
}
EOF
"$PPACK" update >un.log 2>&1 && bad 'um repositório sem assinatura e sem unsafe devia ser recusado' || ok
grep -q "unsafe" un.log && ok || bad "a recusa não disse como se declara unsafe"
cd "$RAIZ"

# ---- 7b. `up`, o lock desencontrado e as invariantes ----
#
# Três coisas que o build não confere porque não são trabalho dele.
cd "$RAIZ"
"$PPACK" check >check.log 2>&1 && ok || bad "ppack check devia passar nesta árvore"
grep -q "nenhum problema" check.log && ok || bad "o check não disse que estava tudo bem"
rm -f check.log

# um pacote `lang: p` que dependa de um `pscript` tem de ser recusado: é a
# invariante que mantém P livre de runtime ATRAVÉS dos pacotes
cp packages/sha2/pack.json "$OUT/sha2-pack.bak"
python3 - <<'PYX'
import json
p = "packages/sha2/pack.json"
d = json.load(open(p))
d["deps"]["pui"] = "0.1.0"
open(p, "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PYX
"$PPACK" check >check2.log 2>&1 && bad "um pacote P que puxa um pscript devia ser recusado" || ok
grep -q "runtime a reboque" check2.log && ok || bad "a recusa não explicou porquê"
cp "$OUT/sha2-pack.bak" packages/sha2/pack.json
rm -f check2.log

# `up` sobe para a mais alta que o índice tem, e o manifesto continua JSON
cd "$RAIZ/$OUT"
rm -rf projup && mkdir projup && cd projup
cat > pack.json <<EOF
{
  "members": ["nada"],
  "repos": [{"url": "file://$RAIZ/$OUT/repo/", "unsafe": true}]
}
EOF
"$PPACK" update >/dev/null 2>&1
"$PPACK" add sha2@0.1.0 >/dev/null 2>&1 && ok || bad "add no projeto do up"
# DUAS versões do mesmo pacote no repositório: é isso que dá ao `up` o que
# escolher, e é a única forma de medir que ele escolhe a mais alta
cd "$RAIZ"
"$PPACK" publish tar --to "$OUT/repo" >/dev/null 2>&1
python3 - <<'PYX'
import json
p = "packages/tar/pack.json"
d = json.load(open(p))
d["version"] = "0.2.0"
open(p, "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PYX
"$PPACK" publish tar --to "$OUT/repo" >/dev/null 2>&1
python3 - <<'PYX'
import json
p = "packages/tar/pack.json"
d = json.load(open(p))
d["version"] = "0.1.0"
open(p, "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PYX
cd "$RAIZ/$OUT/projup"
"$PPACK" update >/dev/null 2>&1
"$PPACK" add tar@0.1.0 >addtar.log 2>&1 && ok || bad "add tar@0.1.0 (veja $OUT/projup/addtar.log)"
"$PPACK" up >up.log 2>&1 && ok || bad "ppack up"
grep -q "0.1.0 -> 0.2.0" up.log && ok || bad "o up não subiu a versão"
python3 -c "import json,sys; d=json.load(open('pack.json')); sys.exit(0 if d['deps']['tar']=='0.2.0' else 1)" && ok || bad "o manifesto não ficou com a versão nova (ou deixou de ser JSON)"

# a FAIXA DE TOOLCHAIN: conferida antes de gastar um segundo a compilar
cd "$RAIZ"
python3 - <<'PYX'
import json
p = "packages/tar/pack.json"
d = json.load(open(p))
d["toolchain"] = ">= 9.9.9"
d["version"] = "0.3.0"
open(p, "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PYX
"$PPACK" publish tar --to "$OUT/repo" >/dev/null 2>&1
python3 - <<'PYX'
import json
p = "packages/tar/pack.json"
d = json.load(open(p))
d["toolchain"] = ">= 0.1.0"
d["version"] = "0.1.0"
open(p, "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PYX
cd "$RAIZ/$OUT/projup"
"$PPACK" update >/dev/null 2>&1
"$PPACK" add tar@0.3.0 --query "$PLANGC" >tc.log 2>&1 && bad "um pacote que exige um compilador que não existe devia ser recusado" || ok
grep -q "exige plangc >= 9.9.9" tc.log && ok || bad "a recusa não disse a faixa e a versão"

# o lock desencontrado do manifesto: avisa, e com --frozen recusa
python3 - <<'PYX'
import json
d = json.load(open("pack.json"))
d["deps"]["naoexiste"] = "9.9.9"
open("pack.json", "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PYX
"$PPACK" install >inst.log 2>&1
grep -q "não corresponde ao pack.json" inst.log && ok || bad "install devia avisar do lock desencontrado"
"$PPACK" install --frozen >inst2.log 2>&1 && bad "--frozen devia recusar" || ok
cd "$RAIZ"

# ---- 8b. `--json`: os MESMOS dados, para quem não é uma pessoa ----
#
# A IDE e um script consomem isto; o escapador é o mesmo do grafo, para não
# haver um segundo sítio onde errar. O teste não confere o texto — confere que é
# JSON, e quem o diz é o `python3`.
cd "$RAIZ/$OUT/projs"
if command -v python3 >/dev/null 2>&1; then
    "$PPACK" search sha256 --json > s.json 2>/dev/null
    python3 -c "import json,sys; d=json.load(open('s.json')); sys.exit(0 if isinstance(d, list) and len(d) > 0 and 'name' in d[0] else 1)" && ok || bad "search --json não é uma lista de objetos"
    "$PPACK" install --json > i.json 2>/dev/null
    python3 -c "import json,sys; json.load(open('i.json'))" && ok || bad "install --json não é JSON"
fi
cd "$RAIZ"

# ---- 9. O MESMO CAMINHO, POR HTTP ----
#
# Nada acima muda: o transporte é um `if` dentro de `buscar`, e o resto do
# gerenciador não sabe de onde vieram os bytes. O servidor é o `http.server` do
# python, que é precisamente o ponto — um repositório é um diretório servido por
# qualquer coisa.
cd "$RAIZ"
if command -v python3 >/dev/null 2>&1; then
    # a porta é escolhida pelo sistema (bind em 0) e escrita num ficheiro: um
    # número fixo aqui faz duas árvores de teste servirem uma à outra, e o
    # engano só aparece como um 404 no sítio errado
    rm -f "$RAIZ/$OUT/httpd.port"
    ( cd "$OUT/repo" && exec python3 -c '
import http.server, socketserver, sys
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
srv = socketserver.TCPServer(("127.0.0.1", 0), H)
with open(sys.argv[1], "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
' "$RAIZ/$OUT/httpd.port" >/dev/null 2>&1 ) &
    echo $! > "$RAIZ/$OUT/httpd.pid"
    # espera o servidor atender, em vez de dormir um número mágico
    i=0
    while [ $i -lt 100 ] && [ ! -s "$RAIZ/$OUT/httpd.port" ]; do i=$((i+1)); sleep 0.1; done
    PORTA=$(cat "$RAIZ/$OUT/httpd.port" 2>/dev/null)
    if [ -z "$PORTA" ]; then bad "o servidor de HTTP não subiu"; PORTA=0; fi
    i=0
    while [ $i -lt 50 ] && ! (exec 3<>/dev/tcp/127.0.0.1/$PORTA) 2>/dev/null; do i=$((i+1)); sleep 0.1; done
    mkdir -p "$OUT/proj-http"
    cd "$OUT/proj-http"
    cat > pack.json <<EOF
{
  "members": ["nada"],
  "repos": [{"url": "http://127.0.0.1:$PORTA/", "unsafe": true}]
}
EOF
    "$PPACK" update >update.log 2>&1 && ok || bad "update por HTTP"
    "$PPACK" add sha2@0.1.0 >add.log 2>&1 && ok || bad "add por HTTP"
    "$PPACK" install >install.log 2>&1 && ok || bad "install por HTTP"
    ls -d build/pkg/sha2-0.1.0-* >/dev/null 2>&1 && ok || bad "a árvore não saiu do tarball baixado por HTTP"
    # e o hash é o MESMO que veio pelo file:// — é isso que faz o transporte não
    # importar
    h1=$(grep -o '"sha256": "[0-9a-f]*"' pack.lock | head -1)
    h2=$(grep -o '"sha256": "[0-9a-f]*"' "$RAIZ/$OUT/proj/pack.lock" | head -1)
    check "o mesmo pacote, o mesmo hash, outro transporte" "$h2" "$h1"
    # um caminho que não existe: HTTP 404, e a mensagem tem de o dizer
    "$PPACK" update >/dev/null 2>&1
    sed -i "s#127.0.0.1:$PORTA/#127.0.0.1:$PORTA/naoexiste/#" pack.json
    "$PPACK" update >u404.log 2>&1 && bad "um índice que não existe devia falhar" || ok
    grep -q "404" u404.log && ok || bad "a falha de HTTP não disse o estado (veja $OUT/proj-http/u404.log)"
    cd "$RAIZ"
    pkill -P "$(cat "$OUT/httpd.pid")" 2>/dev/null
    kill "$(cat "$OUT/httpd.pid")" 2>/dev/null
    rm -f "$OUT/httpd.pid" "$OUT/httpd.port"
fi

# ---- 10. AS RECUSAS DO PUBLISH ----
#
# Três casos em que publicar seria publicar uma coisa que não serve, e nenhum
# deles precisa de mecanismo novo: o índice já traz as dependências, o manifesto
# já diz a linguagem, e a lista canónica da API já está calculada para entrar no
# índice. Conferir é comparar.
cd "$RAIZ"
FAKE=$OUT/fake
rm -rf "$FAKE"; mkdir -p "$FAKE/vazio"

# (a) uma dependência que o repositório de destino não resolve. O `sha2` depende
# do `stl`; num repositório vazio ele não existe.
if "$PPACK" publish sha2 --to "$FAKE/vazio" >"$FAKE/dep.log" 2>&1; then
    bad "publicar com uma dependência que o destino não tem devia ser recusado"
else ok; fi
grep -q "publique-a primeiro" "$FAKE/dep.log" && ok || bad "a recusa da dependência não disse o que fazer"
[ -f "$FAKE/vazio/index.json" ] && bad "a recusa escreveu no repositório" || ok

# (b) um `.psc` dentro de um pacote declarado `p` — e o que está em `test/` NÃO
# conta, que é como o `sha2` prova a travessia da fronteira a partir do pscript
mkdir -p "$FAKE/pkg/pmod"
cat > "$FAKE/pkg/pack.json" <<'EOF'
{ "name": "pmisto", "version": "0.1.0", "lang": "p", "root": "pmisto.ph" }
EOF
cat > "$FAKE/pkg/pmisto.ph" <<'EOF'
def pmisto_dois() -> i32
EOF
cat > "$FAKE/pkg/pmisto.p" <<'EOF'
import "pmisto.ph"
def pmisto_dois() -> i32:
    return 2
EOF
mkdir -p "$FAKE/repo2"
"$PPACK" publish "$FAKE/pkg" --to "$FAKE/repo2" >"$FAKE/p1.log" 2>&1 && ok || bad "um pacote P simples devia publicar (veja $FAKE/p1.log)"
mkdir -p "$FAKE/pkg/test"
echo 'print("oi")' > "$FAKE/pkg/test/t.psc"
rm -rf "$FAKE/repo3"; mkdir -p "$FAKE/repo3"
"$PPACK" publish "$FAKE/pkg" --to "$FAKE/repo3" >"$FAKE/p2.log" 2>&1 && ok || bad "um .psc em test/ NÃO devia impedir (veja $FAKE/p2.log)"
echo 'x: int = 1' > "$FAKE/pkg/extra.psc"
rm -rf "$FAKE/repo4"; mkdir -p "$FAKE/repo4"
if "$PPACK" publish "$FAKE/pkg" --to "$FAKE/repo4" >"$FAKE/p3.log" 2>&1; then
    bad "um .psc FORA de test/ num pacote `lang: p` devia ser recusado"
else ok; fi
grep -q "extra.psc" "$FAKE/p3.log" && ok || bad "a recusa não nomeou o arquivo"
rm -f "$FAKE/pkg/extra.psc"

# (c) a versão sobe e a interface não bate com o que a subida promete. O `patch`
# diz "nada mudou"; o `minor` diz "só acrescentei".
sed -i 's/"version": "0.1.0"/"version": "0.1.1"/' "$FAKE/pkg/pack.json"
cat > "$FAKE/pkg/pmisto.ph" <<'EOF'
def pmisto_dois() -> i32
def pmisto_tres() -> i32
EOF
cat > "$FAKE/pkg/pmisto.p" <<'EOF'
import "pmisto.ph"
def pmisto_dois() -> i32:
    return 2
def pmisto_tres() -> i32:
    return 3
EOF
if "$PPACK" publish "$FAKE/pkg" --to "$FAKE/repo2" >"$FAKE/p4.log" 2>&1; then
    bad "um patch com a interface mudada devia ser recusado"
else ok; fi
grep -q "patch" "$FAKE/p4.log" && ok || bad "a recusa do patch não disse por quê"
# a mesma mudança como MINOR passa: acrescentar é o que um minor promete
sed -i 's/"version": "0.1.1"/"version": "0.2.0"/' "$FAKE/pkg/pack.json"
"$PPACK" publish "$FAKE/pkg" --to "$FAKE/repo2" >"$FAKE/p5.log" 2>&1 && ok || bad "um minor que ACRESCENTA devia publicar (veja $FAKE/p5.log)"
# e tirar num minor, não
sed -i 's/"version": "0.2.0"/"version": "0.3.0"/' "$FAKE/pkg/pack.json"
cat > "$FAKE/pkg/pmisto.ph" <<'EOF'
def pmisto_tres() -> i32
EOF
cat > "$FAKE/pkg/pmisto.p" <<'EOF'
import "pmisto.ph"
def pmisto_tres() -> i32:
    return 3
EOF
if "$PPACK" publish "$FAKE/pkg" --to "$FAKE/repo2" >"$FAKE/p6.log" 2>&1; then
    bad "um minor que TIRA da interface devia ser recusado"
else ok; fi
grep -q "acrescenta, não tira" "$FAKE/p6.log" && ok || bad "a recusa do minor não disse por quê"

# ---- 11. `ppack lock`: o lock a partir do manifesto, sem construir ----
cd "$RAIZ/$OUT/proj"
cp pack.lock lock.antes
# tirar uma linha do lock e mandar refazê-lo: ele volta ao que o manifesto pede
python3 - <<'PY2'
import json
d = json.load(open("pack.lock"))
d["packages"] = [p for p in d["packages"] if p["name"] != "stl"]
json.dump(d, open("pack.lock", "w"), indent=2)
PY2
"$PPACK" lock >lock.log 2>&1 && ok || bad "ppack lock (veja $OUT/proj/lock.log)"
grep -q '"name": "stl"' pack.lock && ok || bad "o lock refeito não trouxe o stl de volta"
# e agora ele já corresponde: `--frozen` aceita
"$PPACK" lock --frozen >lock2.log 2>&1 && ok || bad "--frozen devia aceitar um lock em dia"
# um manifesto que pede uma versão que o lock não tem: `--frozen` recusa
sed -i 's/"sha2": "0.1.0"/"sha2": "0.9.9"/' pack.json
"$PPACK" lock --frozen >lock3.log 2>&1 && bad "--frozen devia recusar um lock velho" || ok
grep -q "frozen" lock3.log && ok || bad "a recusa do --frozen não se explicou"
sed -i 's/"sha2": "0.9.9"/"sha2": "0.1.0"/' pack.json

cd "$RAIZ"
echo "   repo: $pass ok, $fail failed"
[ $fail = 0 ]
