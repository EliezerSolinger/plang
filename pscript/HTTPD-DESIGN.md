# httpd — um servidor HTTP/WebSocket no nosso modelo

> **Estado:** desenho fechado, implementação por fazer. As decisões abaixo foram
> tomadas pelo dono, uma a uma. O que está escrito aqui não se repropõe — a forma
> do DESIGN.md.

## A régua: é uma BIBLIOTECA, e o jogo é um utilizador dela

> Correção do dono, a meio do desenho, e ela reordena tudo o que vem abaixo:
> **"não pense no jogo primeiramente — pense na lib. E se está a falar da lib,
> faça o que a melhor lib das linguagens faz."**

Os primeiros números deste documento vinham do caso do Desbravacraft. Foram
refeitos a partir das referências, LIDAS e não recordadas: o `websockets` do
Python (a fonte está em `ref/websockets-17.1`), o nginx, o `net/http` do Go, o
Bun. Onde uma escolha nossa divergir de todas elas, tem de haver uma razão
escrita — e o jogo não é razão suficiente.

## Por que, e por que agora

O Bun tem um webserver embutido; nós não temos. Mas a razão para construir um não
é paridade — é que **temos o modelo de concorrência para fazer melhor**, e o
Desbravacraft precisa de WebSocket para ser portado.

O quadro, medido e não afirmado:

| | núcleos | heaps | partilha entre threads | uma pausa de GC atinge |
|---|---|---|---|---|
| Python + asyncio | 1 (GIL) | 1 | — | tudo |
| Node / Bun | 1 por loop; cluster = N **processos** | 1 / processo | só `SharedArrayBuffer` cru | o processo |
| Go | N | **1 partilhado** | tudo (e por isso o race detector existe) | todos os cores |
| Erlang / BEAM | N | 1 / processo | ETS (sempre copia) | um processo |
| **pscript** | N | **1 / worker** | `shared dict` + `Buffer` com vistas tipadas + mensagens | **um worker** |

O lugar que ninguém ocupa é o nosso: **o isolamento do Erlang com a velocidade do
C, os núcleos do Go sem o heap partilhado que lhe dá races, e o `async` do Node em
cada worker.** O Python não tem núcleos — o seu `http.server` é reconhecidamente
não-produtivo, e é por isso que todo servidor Python real é um processo C
(uvicorn/gunicorn) por baixo. Nós não precisamos desse truque.

E há um fato que dispensa adivinhação: **o Desbravacraft em JavaScript já usa este
modelo** — `client/shared-memory.js`, o slab de `game-server/world-voxels.js`,
workers sobre `SharedArrayBuffer`. O jogo já provou em produção que "payload grande
em memória partilhada, notificação pequena por mensagem" é a arquitetura certa. O
nosso trabalho não é imitar o Bun; é dar um NOME ao que o jogo já faz, dentro da
linguagem em vez de à mão.

## O que já existe, e não se reescreve

- `packages/http` — o parser HTTP/1.1 incremental, conferido contra o llhttp (as
  doze portas de request-smuggling fechadas), e o HTTP/2 + HPACK conferidos contra
  **47 142 vetores**. O servidor CONSOME isto; não o reimplementa.
- `tests/pscript/run/http_server.psc` — um servidor e clientes numa thread, sobre
  um socket real. É o embrião do v1: prova que `accept`/`read`/`write` estacionam,
  que um servidor async de uma thread já funciona.
- O modelo de concorrência inteiro: `spawn`, worker com heap e coletor próprios,
  `shared dict`, `shared Buffer` com `view_*`, mensagem que acorda um scheduler
  estacionado (`recv_parks`), `Channel` entre tasks, `taskgroup`, `timeout`/`race`.

## As decisões (a bateria)

### D1 — Biblioteca, não runtime. `packages/httpd`.
A régua é a mesma que separa o compilador do build system: *"o compilador responde;
o build system decide"*. O servidor é política — rotas, handlers, ciclo de vida —
e política mora numa biblioteca. O runtime ganha só o que uma biblioteca **não
pode** fazer, e isso é um conjunto pequeno e nomeado (D2, D6, D11).

### D2 — Núcleos por `SO_REUSEPORT`.
Cada worker faz `net.listen(porta, reuse=True)` e **o kernel balanceia os
accepts** — o modelo do nginx e do uWebSockets. Cada worker é um servidor async
completo de uma thread (o `http_server.psc` que já existe). `workers=1` é o modo
dev. Zero lock de accept, zero thundering herd, escala linear.

O runtime ganha uma coisa: o `SO_REUSEPORT` no `listen` (hoje há só
`SO_REUSEADDR`). Uma linha.

**Limite honesto:** uma conexão viva não migra de worker — um WebSocket de longa
duração pode desequilibrar a carga. É o mesmo limite do Node cluster e do uWS; o
kernel balanceia a ACEITAÇÃO, não as conexões já aceitas.

### D3 — API: handler tipo Bun, com o laço exponível por baixo.
```python
httpd.serve(3335, handle, workers=os.nproc())
```
onde `handle` é `async def(Request) -> Response`. Por baixo, o laço
accept/parse/respond é uma função PÚBLICA — quem quer controlo total (o próprio
jogo pode querer) escreve o seu e usa o parser à mão.

> **Correção medida.** O primeiro rascunho dizia que `Request`/`Response` seriam
> `record` (valores) e que por isso a race não compilaria. **Está errado, e o
> compilador diz porquê:** um `record` só guarda números, bools, enums e arrays
> deles (58.2) — com um `str` ou `bytes` dentro, o tipo tem de ser `struct`
> (coletado, referência).
>
> A promessa de segurança continua de pé, por uma razão mais forte: **cada worker
> tem o seu heap**. Não há estado partilhado entre requisições de workers
> diferentes para haver race — o que se partilha é explícito (`shared dict`,
> `shared Buffer`) e nomeado. A armadilha do JavaScript (capturar estado mutável
> num closure e ter corrida entre requisições) continua a não existir, mas por
> isolamento e não por imutabilidade.

### D3b — O handler chega aos workers porque um `def` passa a atravessar.
O desenho original não podia funcionar, e medi:
```
error: an argument to a worker is def(int) -> int, and a message crosses heaps
as BYTES (34.3): numbers, bools, enums and `record` do; anything the collector
owns does not (yet)
```
`spawn(fn, args)` aceita a função de ENTRADA, mas não uma função nos ARGUMENTOS —
logo `serve(porta, handle, workers=N)` não tinha como repassar o `handle`.

**A decisão é mudar a linguagem, e é uma melhoria geral e não um remendo:** um
`def` de topo é um SÍMBOLO — o mesmo endereço em todas as threads do mesmo
binário, e nada dele mora no heap. Atravessa. Uma **lambda cujas capturas são
todas POD** (números, bools, records — e a captura é por valor, 19.2) também
atravessa: o ambiente é bytes, e copia-se como qualquer mensagem. O que continua
recusado é a lambda que captura algo coletado, com a mensagem a dizer isso.

Vale **no `spawn` e no `send`** — uma regra sem excepção é mais fácil de ensinar
que uma com, e destrava mandar uma estratégia a um worker já a correr.

### D3c — Cabeçalhos são uma LISTA de pares, não um dicionário.
O HTTP permite nomes repetidos (`Set-Cookie` é o caso de todos os dias) e a ordem
importa. `req.header("host")` dá o primeiro; `req.headers_all("set-cookie")` dá a
lista. Um `Dict<str,str>` obrigaria a um caminho especial só para o `Set-Cookie` —
exactamente a gambiarra que as bibliotecas de JavaScript carregam.

### D3d — Keep-alive no v1.
É o padrão do HTTP/1.1 e todo cliente moderno assume. Sem ele cada requisição paga
um handshake TCP (e um TLS!), e o benchmark contra o Bun seria uma derrota
autoinfligida. O laço é: aceita → enquanto a conexão viver, parseia e responde.

### D3e — Uma exceção no handler vira 500, e o worker vive.
A conexão recebe um 500; a exceção completa vai para o stderr com a posição (o
`print` atómico da 107.2 garante que a linha sai inteira com N workers); o worker
continua servindo. Com `debug=True` a mensagem e a posição vão também NO CORPO —
o que um servidor de desenvolvimento faz, e o que ajuda ao portar o jogo.

### D3f — O corpo da requisição: dois acessores, um botão.
Sem tipo-união e sem escolha escondida:
- `req.body` lê o corpo inteiro (`bytes`), até ao tecto; acima dele, 413;
- `req.stream()` dá o cursor, para o que não cabe.

Os dois existem sempre; o handler escolhe. A configuração é **um número**:
```python
httpd.serve(porta, handle, max_body=1 << 20)
```

### D3g — Response: conveniências mais o construtor.
`httpd.text(s)`, `httpd.json(v)`, `httpd.html(s)`, `httpd.bytes(b, tipo)`,
`httpd.status(404)` para o comum; `Response(status, headers, body)` para o resto.
O caso de 90% é uma chamada, e nada fica escondido.

### D4 — Estado entre handlers: a tabela dos meios.
Onde o Bun responde "sobe um Redis", a nossa resposta está na linguagem:

| a necessidade | a primitiva | o custo |
|---|---|---|
| sessão, rate-limit, contador | `shared dict` | um lock por operação |
| estado grande de leitura (o mundo, cache de assets) | `shared Buffer` + vistas | **zero cópia** |
| comando/evento pequeno entre workers | mensagem (acorda o parked) | serializa |
| entre tasks do mesmo worker | `Channel` | zero serialização |

### D5 — Streaming no v1.
O corpo de uma `Response` é `bytes`/`str` **ou um cursor async** — o mesmo padrão
do `Cursor` do MySQL (`next_chunk()`). SSE é um cursor de eventos; chunked sai
disso. Backpressure vem de graça: `write` é `await`.

### D6 — `Topic` no runtime, desde já.
O pub/sub é a feature assassina do Bun (herdada do uWebSockets), e no nosso modelo
é onde ganhamos. Um `Topic` do runtime, em camadas:

- **dentro do worker:** tópico = conjunto de conexões, escrita direta, zero
  serialização;
- **entre workers:** o runtime rastreia quais WORKERS assinam cada tópico e escreve
  UMA vez no pipe de cada um (o pipe acorda o scheduler estacionado — medido em
  `recv_parks`); dentro do worker, a `httpd` distribui às conexões. O runtime fica
  pequeno e cego a HTTP; a biblioteca é dona da relação tópico→conexão (D7 rejeitou
  pôr framing de ws no runtime);
- **payload grande** (o snapshot do mundo, 60×/s): **não passa por mensagem
  nenhuma** — vive num `shared Buffer`, e o que viaja é um tick de 8 bytes. É o que
  o Desbravacraft já faz em JavaScript.

**Duas portas, escolhidas por chamada** — a resolução do dono ("dá para ter os dois
e alternar"):
```python
topic.publish(frame_bytes)      # caminho quente: bytes, memcpy, zero PsShape
topic.publish_value(evento)     # conveniência: serializa PRA bytes aqui, chama o de cima
```
O runtime só vê bytes; a serialização acontece antes de entregar, então o custo
fica VISÍVEL na escolha do método (`_value` diz "isto serializa") em vez de
escondido por assinante.

### D7 — O `Topic` entrega a WORKERS; o worker distribui às conexões.
O runtime rastreia workers inscritos, não conexões, e nunca conhece framing de
WebSocket. A alternativa (o runtime escreve nos sockets, à uWebSockets) borraria a
fronteira protocolo/runtime por um salto a menos — não vale.

### D8 — TLS servidor no v1. O servidor nasce falando `https`.
O `starttls` de hoje é o lado CLIENTE (`SSL_connect`, consertado nesta sessão).
Servir precisa do irmão: `SSL_accept`, `SSL_CTX_use_certificate_chain_file`, a
chave, SNI opcional. É uma adição média ao runtime. O dono escolheu tê-la de
fábrica — o pitch contra o Bun inclui TLS nativo, e o cliente nativo do jogo fala
`wss://` direto em produção.

### D9 — WebSocket: núcleo sans-io, cliente E servidor. `packages/ws`.
O `websockets 17.1` (baixado) tem o núcleo perfeito para portar: `frames.py` +
`protocol.py` (~1 300 linhas) são a máquina de estados do RFC 6455 **sem I/O** —
bytes entram, frames saem, no estilo do parser HTTP que já temos. Um núcleo serve
os dois lados: o game-server precisa do SERVIDOR, o cliente nativo precisa do
CLIENTE. Portão: o **Autobahn testsuite** (a bateria oficial, ~500 casos) mais o
próprio `websockets` do Python, frame a frame.

### D9b — `upgrade(req)` devolve uma Response especial.
O handler continua a ser `async def(Request) -> Response` — uma função, um tipo de
retorno. `httpd.upgrade(req)` devolve o 101 já com o `Sec-WebSocket-Accept`
calculado, e o servidor reconhece esse marcador e entrega a conexão aos hooks de
ws. A decisão de aceitar (o token do jogador, a rota, a origem) é código normal
ANTES do upgrade — não um privilégio do servidor.

### D9c — A inscrição num tópico morre com a conexão.
Fechar dessubscreve de tudo, sempre. Nenhum `publish` tenta escrever num socket
morto, e um servidor de jogo com gente a entrar e a sair o dia inteiro não vaza
inscrições. É o que o `with`/`defer` já faz com recurso, aplicado ao tópico.

### D13 — O httpd serve estáticos: `httpd.files(dir)`.
Um handler pronto que serve uma árvore: MIME por extensão, ETag/If-None-Match
(304), `Range` para vídeo e áudio, e a recusa de `..` — que é a vulnerabilidade
clássica, e escrever isto à mão em cada projeto é onde nascem os path traversals.
Metade do que um servidor de jogo faz é isto.

### D14 — Observabilidade: hooks mais `stats()`, nada imposto.
`server.stats()` dá conexões vivas e requisições servidas por worker, somando o
`sched.stats()` que o runtime já tem (ready/parked e as quatro razões). Um hook
opcional `on_request(req, resp, dur)` deixa o programa escrever o log que quiser —
o pacote `log` já faz logfmt e JSON por linha. Nada de formato nosso imposto.

### D15 — TLS: caminhos de ficheiro E bytes.
`Tls("cert.pem", "key.pem")` é o caminho normal (é o que o certbot produz, e a
chave privada nunca passa pela memória do programa). `Tls.from_bytes(cert, key)`
serve quem guarda o certificado num cofre ou o recebe pela rede. Duas portas, e as
duas documentadas.

### D16 — Compressão: gzip no HTTP e permessage-deflate no ws.
O `packages/compress` já escreve gzip conferido contra o zlib do CPython. A
resposta comprime quando o cliente pede (`Accept-Encoding`) e o tipo compensa —
texto e JSON sim, imagem não. E o **permessage-deflate** (RFC 7692) no WebSocket,
que para os chunks do jogo pode valer muito.

> **O que isto custa, dito antes de começar:** o RFC 7692 tem a armadilha da
> janela PARTILHADA entre frames — o `context_takeover` — e um erro ali corrompe a
> stream inteira em vez de um frame. Por isso ele é uma fase própria, depois do ws
> core estar verde no Autobahn, e não misturado com ele.

### D17 — O lado cliente: ws de graça, HTTP completo como projeto próprio.
O ws core nasce com os dois lados (D9), então o **cliente ws** — que é o que o
cliente nativo do Desbravacraft mais usa — sai junto.

Para HTTP, a decisão foi um cliente **completo**: redirects, cookies, pool de
keep-alive, timeouts. Isso é útil muito além do jogo — mas é honestamente um
projeto do tamanho do servidor, então é **fase própria e tardia** (F10), e o
`GameApi` do jogo é servido antes por um `get`/`post` mínimo sobre o parser que já
existe.

### D18 — O mundo do jogo: o main cria o `Buffer`, os workers recebem-no.
O programa principal aloca o `shared Buffer` do mundo ANTES de subir os workers e
passa-o como argumento do `spawn` — um Buffer partilhado atravessa, e o cabeçalho
dele sai do heap coletado exactamente para isso (19.4/52.3). Todos vêem a mesma
memória, sem cópia, e a posse é clara: o main é dono, os workers são vistas.

### D19 — Rotas com `:param`, resolvidas pela biblioteca.
```python
httpd.routes({"GET /worlds/:id": ver_mundo, "POST /auth": entrar})
```
e o parâmetro chega em `req.param("id")`. O handler único continua por baixo — o
matcher é um handler que despacha. Adiei isto no primeiro round e o dono
revisitou: sem ele, todo projeto escreve o mesmo `if/elif` de vinte ramos, e o
Bun 1.2 tem-no exactamente por isso.

### D20 — Os limites de fábrica vêm das referências, não de nós.
| | valor | de onde |
|---|---|---|
| cabeçalho | 8 KiB | o `large_client_header_buffers` do nginx |
| prazo do cabeçalho | 10 s | contra slowloris |
| corpo (`max_body`) | 1 MiB | o `client_max_body_size` do nginx |
| conexão ociosa | 75 s | o `keepalive_timeout` do nginx |

O `net/http` do Go não limita o corpo por omissão e é criticado por isso; o Node
usa 16 KiB de cabeçalho. Ficamos com o nginx: são números que uma década de
internet exposta já validou. Todos são argumentos do `serve`.

### D21 — `files(dir)` serve `index.html` e NUNCA lista o directório.
Sem index, 404. A listagem é vazamento de informação por omissão, e quem a tem
costuma não saber que a tem — por isso nem como interruptor.

### D22 — `stats()` com N workers: um `shared dict`.
Cada worker publica os seus números na tabela partilhada (fora dos heaps, com
lock próprio) e `server.stats()` lê o conjunto de qualquer lado. Usa a primitiva
que a linguagem já tem — e é, ela própria, a demonstração do modelo que este
documento defende.

### D23 — O `on_message` recebe a MENSAGEM, remontada.
O core junta os frames de continuação até ao tecto. É o que o `websockets` faz por
omissão e o que quase todo o código quer; quem precisa dos frames crus tem um hook
à parte.

### D24 — Os padrões do WebSocket são os do `websockets`.
Lidos da fonte, não recordados:

| | valor |
|---|---|
| `ping_interval` | 20 s |
| `ping_timeout` | 20 s |
| `close_timeout` | 10 s |
| `max_size` (mensagem) | 1 MiB (2²⁰) |
| `max_queue` | 16 mensagens |

O ping automático não é conforto: sem ele, um cliente que perdeu a rede sem
fechar o socket fica "vivo" para sempre, a segurar estado e inscrições. Estes
números detectam-no em ~40 s. O Bun usa 120 s de ocioso e 16 MiB de payload —
escolhas de quem optimiza para o caso dele; dois minutos a segurar uma conexão
morta é muito para uma biblioteca genérica.

### D25 — Backpressure por fila limitada.
16 mensagens em fila; cheia, o `read` deixa de consumir do socket e o TCP faz a
pressão chegar ao emissor sozinho. A alternativa (fila sem tecto) é a falha
clássica de servidor ws: um cliente rápido com um handler lento faz a memória
crescer sem limite.

### D26 — Desligar drena, com prazo, e avisa o ws.
Fecha o listener, deixa terminar o que está em curso, manda `close` com o código
**1001 ("going away")** aos WebSockets — que é o sinal para o cliente reconectar —
e ao fim do prazo cancela o resto. O `taskgroup` faz isto: as três garantias dele
são sobre tempo de vida.

### D27 — O router do `Topic` decide-se MEDINDO, com as duas formas prontas.
Implemento a via simples (o main roteia) e a directa (o worker escreve nos pipes
dos outros) atrás da mesma API, e o portão da F7 mede qual ganha com K conexões e
W workers. É a lição que esta sessão já deu duas vezes — o `inline` que não era o
problema, o `%*` que valia 7%: medir, não adivinhar.

### D28 — Middleware não é um conceito: é composição de funções.
`serve(porta, com_log(com_auth(handle)))`. Um middleware é um handler que chama
outro handler — zero conceito novo, zero cadeia nossa para depurar, e a ordem é
visível na chamada. É o que o Go faz (`http.Handler` que embrulha outro) e
envelheceu bem: quinze anos depois ainda é assim.

### D29 — A query string sai do `packages/url`, que já passa 890/891 dos WPT.
`req.path` (sem a query) e `req.query("q")` / `req.query_all("tag")`. O
percent-decoding, o `+` como espaço, as chaves repetidas e o UTF-8 mal formado já
estão resolvidos e conferidos contra os web-platform-tests. Reusar o que está
provado é a regra da casa.

### D30 — Corpo estruturado: JSON e `multipart/form-data`, ambos no v1.
`req.json()` sai do `json` do runtime numa linha. O `multipart` é um parser
próprio — fronteiras, cabeçalhos por parte, e o ficheiro por streaming em vez de
inteiro na memória. É trabalho de uma fase inteira, e o dono escolheu tê-lo de
fábrica.

### D31 — Testar: primeiro na TEORIA, depois na PRÁTICA.
> Resolução do dono, e é melhor do que as opções que lhe dei: **as duas, nessa
> ordem.**

O núcleo é `handle_request(Request) -> Response` — sans-io, como o parser HTTP e
como o ws core. Um teste de unidade constrói uma `Request` e afirma sobre a
`Response`: sem porta, sem rede, sem flaky. **E** há um portão de ponta a ponta
sobre socket real, porque só ele prova que a casca também está certa. É o que o
repositório já faz com o parser (vetores) e o `http_server.psc` (socket) — e o
`pstudio-perf` desta VPS é o lembrete do que acontece quando um portão depende de
tempo real.

### D32 — O IP do cliente atrás de um proxy: só com proxies declarados.
`req.ip` é o IP do socket. Com `serve(..., trusted_proxies=["127.0.0.1"])`, o
`req.ip` passa a ler o `X-Forwarded-For` — **mas só quando a conexão vem de um
proxy da lista**. Confiar no cabeçalho sem isso deixa qualquer cliente forjar o
próprio IP, e aí o rate-limit e o ban por IP viram enfeite. É como o nginx e o
Rails fazem.

### D33 — Cookies com os atributos de segurança por PADRÃO, e sessão no servidor.
`req.cookie("sid")` lê; `resp.set_cookie(nome, valor, http_only=True,
secure=True, same_site="Lax")` escreve — e esses três são o padrão, não a opção.

A **sessão** é assinada e guardada **no servidor**, num `shared dict`: o cookie
leva só um ID assinado (HMAC, com o `hmac` que o repo já tem). Dá para REVOGAR —
apagar a entrada mata a sessão na hora —, o tamanho não é limitado pelos 4 KiB do
cookie, e nada sensível viaja. É a demonstração do modelo: onde o Bun manda subir
um Redis, a tabela está na linguagem. O custo, dito: a sessão morre com o
processo, a menos que o programa a persista.

### D34 — `HEAD`, `OPTIONS` e o 405 são automáticos.
`HEAD` responde como o `GET` da mesma rota, sem corpo. `OPTIONS` responde com o
`Allow` das rotas que casam o caminho. E um caminho que existe com outro método dá
**405 com `Allow`**, não 404 — a diferença entre "não existe" e "existe, mas não
assim" é o que faz um cliente saber o que corrigir.

### D35 — Escutar num socket UNIX: o runtime ganha `net.unix`.
`serve(httpd.unix("/run/app.sock"), handle)`. O `PLAN.md` do pscript já previa
`net.unix(path)` e `net.unix_listen(path)` (a F7 do plano NIO, por fazer) — esta é
a ocasião. Evita a pilha TCP inteira no loopback, e é como o nginx fala com um
backend.

### D36 — WebSocket: negociação de subprotocolo.
`upgrade(req, protocols=["jogo.v2", "jogo.v1"])` escolhe o primeiro que o cliente
também aceita e responde-o no handshake. É assim que um protocolo evolui sem
partir clientes antigos.

### D37 — Um rate limit básico, embutido.
`serve(..., rate_limit=httpd.PerIp(100, 60))` — cem pedidos por minuto por IP,
contados num `shared dict`, e portanto correto entre workers sem nada externo. A
política fica nossa para defender; em troca, a coisa mais fácil de esquecer passa
a estar a um argumento de distância. Sobre o `req.ip` da D32, que é o que a torna
confiável.

### D38 — `serve` devolve um `Server`, e o `with` desliga-o.
```python
with await httpd.serve(porta, handle) as s:
    ...
```
Sair do bloco desliga com a drenagem da D26. Fora dele, `s.stop()` e `s.stats()`.
Usa o `Closeable` que a linguagem já tem, e faz do desligar limpo o caminho
NORMAL em vez do cuidadoso.

### D39 — Páginas de erro: dois hooks, que são handlers como os outros.
`on_not_found(req)` e `on_error(req, err)` devolvem uma `Response` — então podem
renderizar HTML, JSON ou o que a aplicação for. Sem eles, a lib responde um texto
mínimo. Nenhum conceito novo.

### D40 — `Expect: 100-continue`: responde 100, ou recusa ANTES do corpo viajar.
O servidor confere o `Content-Length` contra o `max_body` e responde `100
Continue` ou **413 antes de o corpo subir**. É exactamente para isto que o
cabeçalho existe, e o `curl` manda-o sozinho acima de 1 KiB — com uploads no v1
(D30), ignorá-lo custaria a subida inteira de um ficheiro que ia ser recusado.

### D41 — O `Host` é exigido, e validá-lo é uma opção.
Sem `Host` num pedido HTTP/1.1 → 400, como o RFC manda. E
`serve(..., allowed_hosts=["exemplo.com"])` recusa com 400 um Host fora da lista —
quem constrói URLs a partir do Host (o link de um reset de senha, por exemplo)
precisa disto, e o Django tem `ALLOWED_HOSTS` por causa desta história.

### D42 — `Date` sim, `Server` só a pedido.
O `Date` é obrigatório no RFC e as caches dependem dele — e calcula-se **uma vez
por segundo**, não por resposta: formatar a data é caro e o valor muda uma vez por
segundo. O `Server` anuncia software e versão a quem procura alvos; sai por
omissão, e quem quiser põe.

### D10 — h2 entra depois do v1, atrás de ALPN.
Já está no repo, conferido contra 47 mil vetores. Mesma `Request`/`Response`.

### D11 — O que o runtime ganha, ao todo (a fronteira exata).
1. `SO_REUSEPORT` no `listen` (D2);
2. `SSL_accept` + carregar cert/chave (D8);
3. o `Topic`: subscrever/publicar/dessubscrever por worker, sobre os pipes (D6/D7).
Nada mais. Todo o resto é biblioteca.

### D12 — `workers=os.nproc()` por padrão.
O servidor nasce usando a máquina inteira — é o pitch. `workers=1` é o opt-in de
quem depura. O Bun usa 1 por padrão (cluster é opt-in); nascer multi-core é
exactamente o diferencial.

## A cara da API (rascunho, sujeito à implementação)

```python
import <httpd/httpd.psc> as httpd
import os

async def handle(req: httpd.Request) -> httpd.Response:
    if req.path == "/ws":
        return httpd.upgrade(req)
    if req.path == "/stream":
        return httpd.stream(sse_events())      # corpo por cursor (D5)
    return httpd.text("bem-vindo ao desbravacraft")

async def ws_open(ws: httpd.WsConn):
    ws.subscribe("lobby")

async def ws_message(ws: httpd.WsConn, data: bytes):
    ws.topic("lobby").publish(data)            # bytes, quente (D6)

httpd.serve(3335, handle,
            workers=os.nproc(),                # D12
            tls=httpd.Tls("cert.pem", "key.pem"),   # D8
            ws=httpd.Ws(ws_open, ws_message, None))
```

## As fases

Cada fase só está `[x]` quando o seu portão tem TESTE que prende, o `verify` passa,
e o seed foi regenerado se o compilador/runtime mudou.

**O caminho crítico do jogo é F0→F1→F5→F6** — servidor básico mais WebSocket. As
fases ambiciosas (cliente HTTP completo, permessage-deflate, h2) vêm depois de
propósito: são valiosas por si, e nenhuma delas deve prender o porte.

### O que a LINGUAGEM ganha (fases de compilador/runtime)

- [x] **L1 — `def` e lambda-POD atravessam para um worker** (D3b). No `spawn` e no
      `send`. Portão: um `def` de topo e uma lambda de captura POD atravessam e
      correm no worker; uma lambda que captura algo coletado é RECUSADA com a
      mensagem que diz porquê. *É a fase mais valiosa deste documento para a
      linguagem, e não depende de nada do servidor.*
- [x] **L2 — `SO_REUSEPORT`** no `listen` (D2). Portão: dois workers no mesmo
      porto, o kernel reparte os accepts.
- [x] **L3 — `SSL_accept`** e carregar cert/chave, por caminho e por bytes (D8/D15).
      Portão: um GET por `https` com cert auto-assinado, conferido com
      `openssl s_client`.
- [x] **L4 — `Topic`** no runtime (D6/D7): subscrever, publicar, dessubscrever, por
      worker, sobre os pipes. Portão: um broadcast a K conexões repartidas por W
      workers chega a todas, uma vez cada.
- [x] **L5 — `net.unix`** (D35): escutar e ligar por socket UNIX. Já estava
      previsto na F7 do plano NIO; esta é a ocasião. Portão: um servidor e um
      cliente sobre um caminho, no mesmo processo.

### O que a BIBLIOTECA ganha

- [x] **F1 — httpd v1, um worker.** `serve(porta, handle)` sobre o parser que
      existe, devolvendo um `Server` com `with` (D38): keep-alive (D3d), o 500 com
      `debug` (D3e), o corpo em dois acessores (D3f), as conveniências de Response
      (D3g), o `Host` exigido (D41), o `Date` por segundo (D42) e os hooks de erro
      (D39). Portão: **primeiro sans-io** (Request construída → Response afirmada),
      **depois socket real** (D31) — hello-world, POST com corpo, 404, 400 do
      parser.
- [x] **F1b — Rotas** (D19) com `:param`, e o `HEAD`/`OPTIONS`/405 automáticos
      (D34). Portão: cada um dos três, e um `:param` com percent-encoding.
- [x] **F1c — Query e JSON** (D29/D30): `req.query` sobre o `packages/url`, e
      `req.json()`. Portão: os casos de query dos WPT que o `url` já passa,
      atravessados pela httpd.
- [x] **F2 — Streaming** (D5): corpo por cursor, chunked e SSE.
- [x] **F3 — Multi-worker** sobre L1+L2. Portão: sob carga, os N workers servem e
      `sched.stats()` mostra a repartição.
- [x] **F4 — TLS servidor** sobre L3.
- [x] **F5 — ws core sans-io** (D9): frames e máquina de estados do RFC 6455,
      cliente E servidor. Portão: o **Autobahn testsuite** e o `websockets` do
      Python como oráculo, frame a frame.
- [x] **F6 — Upgrade e `WsConn`** (D9b). Portão: um eco ponta a ponta, texto e
      binário, ping/pong, close limpo.
- [x] **F7 — Pub/sub** sobre L4, com as duas portas de `publish` (D6) e a
      dessubscrição automática (D9c).
- [x] **F8 — Estáticos** (D13/D21): `httpd.files(dir)` com MIME, ETag/304, Range,
      `index.html` e a recusa de `..`. Portão: um `..` em todas as codificações que
      um atacante tenta, e um Range parcial conferido byte a byte.
- [x] **F8b — Cookies e sessão** (D33): ler, escrever com os atributos seguros por
      padrão, e a sessão assinada num `shared dict`. Portão: uma sessão sobrevive a
      pedidos servidos por workers DIFERENTES, e revogar mata-a na hora.
- [x] **F8c — `multipart/form-data`** (D30) com o ficheiro por streaming, e o
      `Expect: 100-continue` (D40). Portão: um upload maior que o teto é recusado
      com 413 ANTES de o corpo subir.
- [x] **F8d — Proxy e limites**: `trusted_proxies` (D32), `allowed_hosts` (D41) e o
      `rate_limit` (D37). Portão: um `X-Forwarded-For` forjado por um cliente que
      NÃO é proxy declarado é ignorado.
- [x] **F9 — Compressão** (só o gzip do HTTP; o permessage-deflate do ws continua a faltar) (D16): gzip no HTTP; e o permessage-deflate do ws numa
      fase à parte, depois do Autobahn verde — a janela partilhada do RFC 7692 é
      onde ele morde.
- [x] **F10 — Cliente HTTP completo** (D17): redirects, cookies, pool, timeouts. Um
      projeto do tamanho do servidor, e por isso tardio; o `GameApi` do jogo é
      servido antes por um `get`/`post` mínimo.
- [ ] **F11 — h2 atrás de ALPN** (D10).
- [x] **F12 — O benchmark, publicado.** Só com o produto completo: `wrk` contra o
      nosso (workers=nproc), `Bun.serve`, `node http` e `python uvicorn` na MESMA
      VPS, no espírito do `bench.sh`.

## Onde o modelo PERDE, dito em voz alta

1. **Conexão viva não migra de worker** (D2): um ws de longa duração pode
   desequilibrar. Mesmo limite do Node cluster e do uWS.
2. **Broadcast entre workers paga serialização** no salto do `Topic` — mitigado
   pelo `shared Buffer` para o que é grande (D6).
3. **Cada worker duplica caches de heap** — por design; o que deve ser um só vai
   para o `Buffer`. Quem vem do JavaScript estranha isto até entender que é
   exactamente o que mata as races.

## O que este documento NÃO decide (fica para a implementação medir)

- Se o `Topic` precisa mesmo de router no main ou se os workers se falam direto —
  F7 mede antes de escolher (a lição do `inline` e do `%*`: medir, não adivinhar).
- O formato exacto do matcher de rotas (`/api/:id`) — o dono adiou; o v1 é handler
  único, e rotas declarativas entram quando pedidas.
- RSA para o caching_sha2 sem TLS — hoje o caminho lento pede TLS; o RSA fica para
  quando alguém tiver um MySQL 8 sem TLS na frente.
