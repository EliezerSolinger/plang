#!/usr/bin/env bash
# httpd.sh — o servidor HTTP/1.1 do `packages/httpd`, batido POR FORA.
#
# Um `.expected` não serve para isto. O que se quer provar não é o que uma função
# devolve — é o que sai NO FIO quando um cliente de verdade bate à porta, e as
# perguntas interessantes são justamente as que só um cliente faz: reusa ele a
# conexão? o 204 vem sem `content-length`? um pedido sem `Host` é recusado? o
# servidor sobrevive a um handler que rebenta?
#
# O cliente é o `curl`, e é de propósito: ele é o oráculo. Se o `curl` diz que
# houve UMA conexão para três pedidos, houve — é ele que conta, não nós.
#
# O PORTO vem do sistema (`listen(0)`) e o servidor escreve-o num ficheiro. Não
# se imprime: o `stdout` de quem escreve para um cano é tamponado por blocos, e a
# linha ficaria retida até o tampão encher — quem lesse ficaria à espera de um
# servidor que já está de pé. Um ficheiro só aparece depois de fechado, o que faz
# dele um sinal em vez de uma adivinha.
set -u
cd "$(dirname "$0")/.."

PLANGC=${PLANGC:-build/bin/plangc_s2}
OUT=${OUT:-tests/out/httpd}
rm -rf "$OUT"; mkdir -p "$OUT"
pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass+1))
    else echo "  FAIL $1: esperado '$2', veio '$3'"; fail=$((fail+1)); fi
}

command -v curl >/dev/null || { echo "   httpd: sem curl, saltado"; exit 0; }

if ! PSBUILD_RT="$OUT/rt" bash tests/psbuild.sh packages/httpd/test/server.psc "$OUT/srv" >"$OUT/build.log" 2>&1; then
    echo "  FAIL o servidor de teste não compila"; tail -5 "$OUT/build.log"; exit 1
fi

PORTFILE="$OUT/porto"
"$OUT/srv" "$PORTFILE" >"$OUT/srv.log" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
for _ in $(seq 1 100); do [ -s "$PORTFILE" ] && break; sleep 0.05; done
[ -s "$PORTFILE" ] || { echo "  FAIL o servidor não abriu porto nenhum"; exit 1; }
B="http://127.0.0.1:$(cat "$PORTFILE")"

# ---- o caso de todos os dias ----
check "hello"        "ola do pscript" "$(curl -s $B/)"
check "404"          "404"            "$(curl -s -o /dev/null -w '%{http_code}' $B/nao-existe)"
check "POST e corpo" "0123456789"     "$(curl -s -X POST --data-binary '0123456789' $B/eco)"
check "json"         '{"quem":"pscript","quantos":3}' "$(curl -s $B/json)"
check "tipo do html" "text/html; charset=utf-8" "$(curl -s -o /dev/null -w '%{content_type}' $B/html)"
check "redirect"     "302"            "$(curl -s -o /dev/null -w '%{http_code}' $B/parati)"

# ---- D3c: nomes repetidos continuam separados, que é o que um Dict perderia ----
check "cabecalhos repetidos" "um|dois" \
      "$(curl -s -H 'x-nota: um' -H 'x-nota: dois' $B/cabecalhos)"

# ---- RFC 9110 §8.6: um 204 não leva `content-length`, nem sequer zero ----
check "204 sem content-length" "0" \
      "$(curl -s -i $B/vazio | tr -d '\r' | grep -c '^content-length')"

# ---- D3e: o handler rebenta, o cliente leva 500, e o SERVIDOR CONTINUA ----
check "500 do handler" "500" "$(curl -s -o /dev/null -w '%{http_code}' $B/rebenta)"
check "e continua vivo" "ola do pscript" "$(curl -s $B/)"

# ---- D3d: keep-alive. Quem conta é o curl. ----
check "uma conexao para tres pedidos" "1" \
      "$(curl -s -o /dev/null -w '%{num_connects}' $B/ $B/json $B/html | head -c 1)"

# ---- D41: sem `Host` num HTTP/1.1 é 400, como o RFC manda ----
if command -v nc >/dev/null; then
    got=$(printf 'GET / HTTP/1.1\r\n\r\n' | timeout 5 nc 127.0.0.1 "$(cat "$PORTFILE")" | head -1 | tr -d '\r')
    check "sem Host da 400" "HTTP/1.1 400 Bad Request" "$got"
fi

# ---- D3f: o tecto do corpo é um número, e acima dele é 413 ----
check "corpo acima do tecto da 413" "413" \
      "$(head -c 2000000 /dev/zero | tr '\0' 'x' | curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary @- $B/eco)"

# ---- D42: o `Date` está lá, e o `Server` só porque este servidor o pediu ----
check "tem Date" "1" "$(curl -s -i $B/ | tr -d '\r' | grep -c '^date: ')"

# ============================================================================
# F1b/F1c — as ROTAS, a query e o JSON. Outro servidor, porque o mapa de rotas é
# o que está a ser provado e um servidor com um `if` por caminho não o prova.
# ============================================================================
if ! PSBUILD_RT="$OUT/rt" bash tests/psbuild.sh packages/httpd/test/routes.psc "$OUT/rotas" >>"$OUT/build.log" 2>&1; then
    echo "  FAIL o servidor de rotas não compila"; tail -5 "$OUT/build.log"; exit 1
fi
PF2="$OUT/porto2"
"$OUT/rotas" "$PF2" >"$OUT/rotas.log" 2>&1 &
R=$!
trap 'kill $SRV $R 2>/dev/null' EXIT
for _ in $(seq 1 100); do [ -s "$PF2" ] && break; sleep 0.05; done
[ -s "$PF2" ] || { echo "  FAIL o servidor de rotas não abriu porto"; exit 1; }
C="http://127.0.0.1:$(cat "$PF2")"

check "rota raiz"        "raiz"                 "$(curl -s $C/)"
check "rota literal"     "lista de jogadores"   "$(curl -s $C/jogadores)"
check "rota :param"      "jogador 42"           "$(curl -s $C/jogadores/42)"
check "rota aninhada"    "inventario de 42"     "$(curl -s $C/jogadores/42/inventario)"

# A ESPECIFICIDADE, e não a ordem: `/jogadores/eu` está registado DEPOIS do
# `/jogadores/:id` no ficheiro, e ganha na mesma. Com a ordem a decidir, esta
# linha devolveria "jogador eu".
check "literal ganha a :param" "sou eu" "$(curl -s $C/jogadores/eu)"

# um `%20` no segmento chega decodificado, e um `%2F` NÃO volta a partir o caminho
check "percent no segmento" "jogador a b" "$(curl -s $C/jogadores/a%20b)"
check "o resto com *"       "resto=a/b/c.txt" "$(curl -s $C/ficheiros/a/b/c.txt)"
check "POST na mesma rota"  "criado"        "$(curl -s -X POST $C/jogadores)"

# D34: existe com outro método -> 405 com Allow, e não 404
check "405 e nao 404"  "405" "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE $C/jogadores)"
check "o Allow do 405" "allow: GET, POST, HEAD, OPTIONS"       "$(curl -s -i -X DELETE $C/jogadores | tr -d '\r' | grep -i '^allow')"
check "OPTIONS responde 204" "204" "$(curl -s -o /dev/null -w '%{http_code}' -X OPTIONS $C/jogadores)"
check "HEAD sai do GET" "HTTP/1.1 200 OK" "$(curl -s -I $C/jogadores | head -1 | tr -d '\r')"
check "sem rota da 404" "404" "$(curl -s -o /dev/null -w '%{http_code}' $C/nada)"

# F1c/D29: `+` é espaço numa query (e seria um `+` literal num caminho), o
# percent-decoding é UTF-8, e uma chave ausente é ""
check "query com + e percent" "joão silva||0" "$(curl -s "$C/query?nome=jo%C3%A3o+silva&vazio=")"
check "query repetida"        "a,b,c"         "$(curl -s "$C/lista?t=a&t=b&t=c")"

# F1c/D30: o corpo como JSON, e o círculo fecha
check "corpo JSON" '{"recebi":{"x":[1,2],"y":"z"},"era_json":true}' \
      "$(curl -s -H 'content-type: application/json' -d '{"x":[1,2],"y":"z"}' $C/json)"

# ---- F2/D5: o corpo por CURSOR, em `chunked` ----
#
# O que interessa provar é que os pedaços chegam EM PEDAÇOS, e um `curl` normal
# não o prova: ele junta tudo e mostra o resultado, indistinguível de uma
# resposta comum. O script mede os TEMPOS de chegada.
check "o fluxo chega aos pedaços" "$(cat tests/httpd-stream.expected)" \
      "$(timeout 30 python3 tests/httpd-stream.py "$(cat "$PORTFILE")" 2>&1)"
check "sem content-length num fluxo" "0" \
      "$(curl -s -o /dev/null -D - $B/fluxo | tr -d '\r' | grep -ci '^content-length')"
check "keep-alive sobrevive a um fluxo" "1" \
      "$(curl -s -o /dev/null -w '%{num_connects}' $B/fluxo $B/ | head -c 1)"
# SSE: cada linha dos dados leva o seu `data:`, porque uma quebra de linha crua
# dentro do campo TERMINA o evento
check "o SSE emoldura cada linha" "3" \
      "$(curl -s -N $B/sse | grep -c '^event: tick$')"
check "e cada evento tem duas linhas de dados" "6" \
      "$(curl -s -N $B/sse | grep -c '^data: ')"

# ---- F8c/D30: MULTIPART, e F8c/D40: o `Expect: 100-continue` ----
printf 'conteudo do ficheiro\nsegunda linha\n' > "$OUT/anexo.txt"
printf '\x00\x01\xfe\xff binario'            > "$OUT/bin.dat"
check "multipart: campos e ficheiros" \
      "campo:nome:Ana
campo:idade:30
ficheiro:texto:anexo.txt:text/plain:35
ficheiro:cru:bin.dat:application/octet-stream:12" \
      "$(curl -s -F 'nome=Ana' -F 'idade=30' -F "texto=@$OUT/anexo.txt;type=text/plain" -F "cru=@$OUT/bin.dat" $B/upload)"

# D40, E É AQUI QUE ELE SE PAGA: um corpo acima do tecto é recusado com ZERO
# bytes subidos. Sem o `Expect`, os três megabytes subiam para serem deitados
# fora — e é exactamente para isto que o cabeçalho existe.
head -c 3000000 /dev/zero | tr '\0' 'y' > "$OUT/enorme.txt"
check "413 sem o corpo subir" "413 0" \
      "$(curl -s -H 'Expect: 100-continue' --data-binary @"$OUT/enorme.txt" -o /dev/null -w '%{http_code} %{size_upload}' $B/eco)"
# e um corpo aceitável passa, e passa DEPRESSA: sem a resposta 100 o cliente
# espera o tempo dele (um segundo, no curl) antes de enviar
head -c 5000 /dev/zero | tr '\0' 'y' > "$OUT/medio.txt"
check "100-continue: o corpo aceitável passa" "200" \
      "$(curl -s -H 'Expect: 100-continue' --data-binary @"$OUT/medio.txt" -o /dev/null -w '%{http_code}' $B/eco)"
check "e sem esperar um segundo" "sim" \
      "$(test "$(curl -s -H 'Expect: 100-continue' --data-binary @"$OUT/medio.txt" -o /dev/null -w '%{time_total}' $B/eco | cut -d. -f1)" -lt 1 && echo sim || echo nao)"

# ---- F9/D16: a COMPRESSÃO ----
#
# Três condições, e o portão bate nas três recusas: o cliente tem de pedir, o
# tipo tem de ganhar com isso, e o corpo tem de passar o mínimo. Comprimir um
# JPEG gasta CPU e CRESCE; comprimir 400 bytes não poupa uma viagem, porque um
# pacote TCP leva mil e quinhentos.
check "comprime o que vale a pena" "1" \
      "$(curl -s -H 'Accept-Encoding: gzip' -o /dev/null -D - $B/grande | tr -d '\r' | grep -ci '^content-encoding: gzip')"
check "e o Vary sai com ele" "1" \
      "$(curl -s -H 'Accept-Encoding: gzip' -o /dev/null -D - $B/grande | tr -d '\r' | grep -ci '^vary')"
check "o corpo volta inteiro" "6000" "$(curl -s --compressed $B/grande | wc -c | tr -d ' ')"
check "e viaja MUITO menos" "sim" \
      "$(test "$(curl -s -H 'Accept-Encoding: gzip' -o /dev/null -w '%{size_download}' $B/grande)" -lt 500 && echo sim || echo nao)"
check "não comprime o que é pequeno" "0" \
      "$(curl -s -H 'Accept-Encoding: gzip' -o /dev/null -D - $B/pequeno | tr -d '\r' | grep -ci content-encoding)"
check "não comprime um JPEG" "0" \
      "$(curl -s -H 'Accept-Encoding: gzip' -o /dev/null -D - $B/jpeg | tr -d '\r' | grep -ci content-encoding)"
check "gzip;q=0 é uma recusa" "0" \
      "$(curl -s -H 'Accept-Encoding: gzip;q=0' -o /dev/null -D - $B/grande | tr -d '\r' | grep -ci content-encoding)"
check "sem pedir, não comprime" "0" \
      "$(curl -s -o /dev/null -D - $B/grande | tr -d '\r' | grep -ci content-encoding)"

# ============================================================================
# F8 — os ESTÁTICOS. A metade que interessa é a última: as tentativas de sair do
# directório, em todas as grafias que um atacante tenta. Nenhuma pode devolver o
# ficheiro que está FORA da raiz, e o portão prova-o procurando o conteúdo dele.
# ============================================================================
WWW="$OUT/www"
mkdir -p "$WWW/sub"
printf '<h1>indice</h1>' > "$WWW/index.html"
printf 'corpo do a'      > "$WWW/a.txt"
printf '0123456789abcdefghij' > "$WWW/dez.bin"
printf 'sub-indice'      > "$WWW/sub/index.html"
# o ficheiro que NÃO pode ser servido: fica ao lado da raiz, não dentro
printf 'SEGREDO'         > "$OUT/segredo.txt"

if ! PSBUILD_RT="$OUT/rt" bash tests/psbuild.sh packages/httpd/test/static.psc "$OUT/est" >>"$OUT/build.log" 2>&1; then
    echo "  FAIL o servidor de estáticos não compila"; tail -5 "$OUT/build.log"; exit 1
fi
PF3="$OUT/porto3"
"$OUT/est" "$PF3" "$WWW" >"$OUT/est.log" 2>&1 &
E=$!
trap 'kill $SRV $R $E 2>/dev/null' EXIT
for _ in $(seq 1 100); do [ -s "$PF3" ] && break; sleep 0.05; done
[ -s "$PF3" ] || { echo "  FAIL o servidor de estáticos não abriu porto"; exit 1; }
S="http://127.0.0.1:$(cat "$PF3")"

check "index de um directório" "<h1>indice</h1>" "$(curl -s $S/)"
check "um ficheiro"            "corpo do a"     "$(curl -s $S/a.txt)"
check "o MIME pela extensão"   "text/html; charset=utf-8"       "$(curl -s -o /dev/null -w '%{content_type}' $S/index.html)"
check "index de um subdirectório" "sub-indice"  "$(curl -s $S/sub/)"
check "o que não existe"       "404" "$(curl -s -o /dev/null -w '%{http_code}' $S/nada)"

# o ETag e o 304: a conferência é ANTES de qualquer leitura, que é o ponto
ET=$(curl -s -i $S/a.txt | tr -d '\r' | grep -i '^etag' | cut -d' ' -f2)
check "If-None-Match dá 304" "304" \
      "$(curl -s -o /dev/null -w '%{http_code}' -H "If-None-Match: $ET" $S/a.txt)"

# o Range, que é o que faz um vídeo saltar em vez de descarregar tudo
check "range do princípio" "01234" "$(curl -s -H 'Range: bytes=0-4' $S/dez.bin)"
check "range do meio"      "56789" "$(curl -s -H 'Range: bytes=5-9' $S/dez.bin)"
check "range dos últimos"  "hij"   "$(curl -s -H 'Range: bytes=-3' $S/dez.bin)"
check "range aberto"       "fghij" "$(curl -s -H 'Range: bytes=15-' $S/dez.bin)"
check "o content-range"    "content-range: bytes 2-4/20" \
      "$(curl -s -o /dev/null -D - -H 'Range: bytes=2-4' $S/dez.bin | tr -d '\r' | grep -i content-range)"
check "range fora do fim dá 416" "416" \
      "$(curl -s -o /dev/null -w '%{http_code}' -H 'Range: bytes=999-' $S/dez.bin)"

# ---- E A PARTE QUE INTERESSA ----
#
# Doze grafias de "sai do directório". O que se afirma NÃO é o código de estado —
# um 403 e um 404 são os dois respostas certas, conforme o caminho normalizado
# saia da raiz ou simplesmente não exista lá dentro. O que se afirma é que o
# conteúdo do ficheiro de fora NUNCA aparece.
vazou=0
for p in "/../segredo.txt" "/..%2fsegredo.txt" "/%2e%2e/segredo.txt" \
         "/%2e%2e%2fsegredo.txt" "/.%2e/segredo.txt" "/sub/../../segredo.txt" \
         "/sub/%2e%2e/%2e%2e/segredo.txt" "/....//segredo.txt" \
         "/..%252fsegredo.txt" "/%252e%252e%252fsegredo.txt" \
         "//../segredo.txt" "/./../../segredo.txt"; do
    if curl -s --path-as-is "$S$p" | grep -q SEGREDO; then
        echo "  FAIL VAZOU por '$p'"; vazou=1
    fi
done
check "nenhuma travessia vazou" "0" "$vazou"

# ============================================================================
# F3/D12 — N WORKERS NO MESMO PORTO. É aqui que as três peças da linguagem se
# juntam: o handler ATRAVESSA (L1), os N escutam o mesmo porto (L2), e uma
# difusão alcança-os todos (L4).
#
# O portão bate com uma CONEXÃO NOVA de cada vez, porque é o accept que está a
# ser testado e o keep-alive esconde-o. O zero de falhas é a metade que
# interessa: foi ele que apanhou o `const` que era `None` dentro do worker.
# ============================================================================
if ! PSBUILD_RT="$OUT/rt" bash tests/psbuild.sh packages/httpd/test/multi.psc "$OUT/multi" >>"$OUT/build.log" 2>&1; then
    echo "  FAIL o servidor multi-worker não compila"; tail -5 "$OUT/build.log"; exit 1
fi
PF4="$OUT/porto4"
"$OUT/multi" "$PF4" 4 >"$OUT/multi.log" 2>&1 &
M=$!
trap 'kill $SRV $R $E $M 2>/dev/null' EXIT
for _ in $(seq 1 100); do [ -s "$PF4" ] && break; sleep 0.05; done
if [ -s "$PF4" ]; then
    check "quatro workers no mesmo porto" "$(cat tests/httpd-multi.expected)" \
          "$(timeout 120 python3 tests/httpd-multi.py "$(cat "$PF4")" 4 2>&1)"
    # L4 ao lado: uma difusão de um worker alcança os OUTROS TRÊS
    check "a difusão alcança os outros workers" "3" \
          "$(curl -s "http://127.0.0.1:$(cat "$PF4")/difunde")"
else
    echo "  FAIL o servidor multi-worker não abriu porto"; fail=$((fail+1))
fi

# ============================================================================
# F8b/F8d — SESSÃO, COOKIES, PROXY e RATE LIMIT, com DOIS workers.
#
# É onde a resposta da linguagem aparece: onde o Bun manda subir um Redis, a
# tabela partilhada está na linguagem — e o portão prova-o lendo uma sessão
# criada num worker a partir de conexões que caem noutros.
# ============================================================================
if ! PSBUILD_RT="$OUT/rt" bash tests/psbuild.sh packages/httpd/test/sessions.psc "$OUT/sess" >>"$OUT/build.log" 2>&1; then
    echo "  FAIL o servidor de sessões não compila"; tail -5 "$OUT/build.log"; exit 1
fi
PF5="$OUT/porto5"
"$OUT/sess" "$PF5" >"$OUT/sess.log" 2>&1 &
S5=$!
trap 'kill $SRV $R $E $M $S5 2>/dev/null' EXIT
for _ in $(seq 1 100); do [ -s "$PF5" ] && break; sleep 0.05; done
if [ -s "$PF5" ]; then
    D="http://127.0.0.1:$(cat "$PF5")"
    JAR="$OUT/jar"

    check "entra e recebe um cookie" "entrou" "$(curl -s -c "$JAR" "$D/entra?quem=ana")"
    check "o cookie ficou na jarra" "1" "$(grep -c sid "$JAR")"
    check "e a sessão lê-se com ele" "utilizador=ana" "$(curl -s -b "$JAR" $D/quem)"
    check "sem cookie é 401" "401" "$(curl -s -o /dev/null -w '%{http_code}' $D/quem)"
    # um sid FORJADO é recusado pela assinatura, ANTES de a tabela ser consultada
    check "um sid forjado é 401" "401" \
          "$(curl -s -o /dev/null -w '%{http_code}' -H 'Cookie: sid=abc.def' $D/quem)"

    # D33: os atributos de segurança são o PADRÃO e não a opção
    sc=$(curl -s -i "$D/entra?quem=x" | tr -d '\r' | grep -i '^set-cookie')
    check "o cookie leva HttpOnly" "1" "$(echo "$sc" | grep -c HttpOnly)"
    check "o cookie leva SameSite" "1" "$(echo "$sc" | grep -c SameSite)"

    # REVOGAR funciona, que é a coisa que um cookie assinado não sabe fazer
    check "revoga" "revogou=True" "$(curl -s -b "$JAR" $D/sai)"
    check "e a sessão morreu na hora" "401" \
          "$(curl -s -o /dev/null -w '%{http_code}' -b "$JAR" $D/quem)"

    # A TABELA É PARTILHADA: a sessão criada num worker lê-se de qualquer um.
    # Doze conexões NOVAS caem em workers diferentes, e as doze vêem o mesmo.
    JAR2="$OUT/jar2"
    curl -s -c "$JAR2" -H 'Connection: close' "$D/entra?quem=cruzada" >/dev/null
    vistos=$(for _ in $(seq 1 12); do curl -s -b "$JAR2" -H 'Connection: close' $D/quem; echo; done | sort -u | tr -d '\n')
    check "a sessão atravessa os workers" "utilizador=cruzada" "$vistos"

    # D32: o X-Forwarded-For só vale de um proxy DECLARADO
    check "de um proxy da lista, o cabeçalho vale" "9.9.9.9" \
          "$(curl -s -H 'X-Forwarded-For: 9.9.9.9' $D/ip)"
    check "sem lista, o cabeçalho é ignorado" "127.0.0.1" \
          "$(curl -s -H 'X-Forwarded-For: 9.9.9.9' $D/ip-estrito)"

    # D37: o rate limit, três por janela
    check "o rate limit trava ao quarto" "200 200 200 429 429" \
          "$(for _ in 1 2 3 4 5; do printf '%s ' "$(curl -s -o /dev/null -w '%{http_code}' $D/limitado)"; done | sed 's/ $//')"

    check "os cookies do pedido, todos" "a=1|b=2|c=3" \
          "$(curl -s -H 'Cookie: a=1; b=2; c=3' $D/cookies)"
else
    echo "  FAIL o servidor de sessões não abriu porto"; fail=$((fail+1))
fi

# ============================================================================
# O EXEMPLO, ponta a ponta. É o portão que junta tudo: estáticos, API, o upgrade
# com autorização ANTES dele, e a difusão a atravessar os workers. Se este passa,
# a biblioteca faz o que o desenho prometeu.
# ============================================================================
if python3 -c "import websockets" 2>/dev/null; then
    WWW2="$OUT/jogo-publico"; mkdir -p "$WWW2"
    printf '<!doctype html><title>desbravacraft</title><h1>o mundo</h1>' > "$WWW2/index.html"
    printf 'console.log("cliente")' > "$WWW2/jogo.js"
    if ! PSBUILD_RT="$OUT/rt" bash tests/psbuild.sh packages/httpd/example/game.psc "$OUT/jogo" >>"$OUT/build.log" 2>&1; then
        echo "  FAIL o exemplo do jogo não compila"; tail -5 "$OUT/build.log"; fail=$((fail+1))
    else
        PJ=$((20000 + RANDOM % 20000))
        "$OUT/jogo" "$PJ" 3 "$WWW2" >"$OUT/jogo.log" 2>&1 &
        J=$!
        trap 'kill $SRV $R $E $M $S5 $J 2>/dev/null' EXIT
        for _ in $(seq 1 100); do curl -s -o /dev/null "http://127.0.0.1:$PJ/" && break; sleep 0.05; done
        check "o exemplo do jogo, ponta a ponta" "$(cat tests/httpd-jogo.expected)" \
              "$(timeout 60 python3 tests/httpd-jogo.py "$PJ" 2>&1)"
    fi
fi

# ---------- D3d/o `idle_timeout`: uma conexão calada é fechada ----------
#
# O `curl` não serve de oráculo aqui — ele fala sempre —, portanto é um socket cru
# que se cala de propósito. E prova as duas metades: a conexão calada fecha, e o
# pedido que chega depressa é servido, o que mostra que o prazo não está a matar
# tráfego legítimo.
PF6="$OUT/porto6"
"$OUT/srv" "$PF6" 1.0 >"$OUT/idle.log" 2>&1 &
S6=$!
trap 'kill $SRV $R $E $M $S5 ${J:-} $S6 2>/dev/null' EXIT
for _ in $(seq 1 100); do [ -s "$PF6" ] && break; sleep 0.05; done
if [ -s "$PF6" ]; then
    P6=$(cat "$PF6")
    check "uma conexão calada é fechada no prazo (idle_timeout)" \
          "$(printf 'calado desde o principio: fechou, no prazo=True\no pedido foi servido: HTTP/1.1 200 OK\ncalado depois de servir: fechou, no prazo=True')" \
          "$(timeout 60 python3 tests/httpd-idle.py "$P6" 1.0 2>&1)"
else
    echo "  FAIL o servidor do idle_timeout não abriu porto"; fail=$((fail+1))
fi

echo "   httpd: $pass ok, $fail failed"
[ $fail -eq 0 ]
