# httpd — um servidor HTTP/WebSocket no nosso modelo

> **Estado:** desenho fechado, implementação por fazer. As decisões abaixo foram
> tomadas pelo dono, uma a uma. O que está escrito aqui não se repropõe — a forma
> do DESIGN.md.

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

### D3 — API: handler tipo Bun, com o loop exponível por baixo.
```python
httpd.serve(3335, handle, workers=os.nproc())
```
onde `handle` é `async def(Request) -> Response`. Por baixo, o laço
accept/parse/respond é uma função PÚBLICA — quem quer controlo total (o próprio
jogo pode querer) escreve `for conn in server:` e usa o parser à mão.

`Request` e `Response` são **valores** (`record`). Combinado com globals por-worker
(42.2), a armadilha clássica do JavaScript — capturar estado mutável num closure e
ter race entre requisições — **não compila**. Um handler não pode corromper a
conexão do vizinho nem querendo. Não é uma promessa num doc; é uma consequência do
sistema de tipos.

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
e o seed foi regenerado se o compilador/runtime mudou. A ordem é a das dependências.

- [ ] **F0 — `SO_REUSEPORT`.** `net.listen(porta, reuse=True)` no runtime. Portão:
      dois workers no mesmo porto, o kernel reparte os accepts, e uma bateria de N
      conexões chega repartida entre eles.

- [ ] **F1 — httpd v1, um worker.** `serve(porta, handle)` sobre o parser que
      existe: accept → parse incremental → `handle` → escreve a `Response`. O laço
      exponível (D3). Portão: hello-world, um POST com corpo, um 404, os erros do
      parser (as recusas do llhttp propagadas como 400).

- [ ] **F2 — Streaming.** Corpo de `Response` por cursor (D5): chunked e SSE.
      Portão: um SSE que emite N eventos e um download chunked, lidos por um cliente
      que acumula.

- [ ] **F3 — Multi-worker.** `workers=N` sobre F0. Cada worker um `serve` completo.
      Portão: sob carga concorrente, os N workers servem, e `sched.stats()` mostra a
      repartição.

- [ ] **F4 — TLS servidor.** `SSL_accept` + cert/chave no runtime (D8), e
      `serve(..., tls=...)`. Portão: um GET por `https` com um cert auto-assinado,
      conferido com `openssl s_client` e com o cliente HTTP que já temos.

- [ ] **F5 — ws core (sans-io).** `packages/ws`: frames + máquina de estados do RFC
      6455, cliente e servidor, sem I/O. Portão: o Autobahn testsuite e o
      `websockets` do Python como oráculo, frame a frame.

- [ ] **F6 — Upgrade + WsConn na httpd.** `httpd.upgrade(req)` faz o handshake
      (Sec-WebSocket-Accept), e `WsConn` liga o socket ao ws core. Portão: um eco de
      ws ponta a ponta, texto e binário, ping/pong, close limpo.

- [ ] **F7 — `Topic` no runtime + pub/sub na httpd.** As três operações do runtime
      (D11.3), a distribuição na biblioteca (D7), as duas portas de `publish` (D6).
      Portão: um broadcast a K conexões repartidas por W workers chega a todas, uma
      vez cada; e o caminho do `shared Buffer` (o payload grande não serializa).

- [ ] **F8 — h2 atrás de ALPN** (D10). Portão: o mesmo handler servido sobre h2,
      com o h2/hpack que já passa 47 mil vetores.

- [ ] **F9 — O benchmark, publicado.** Só quando o produto está completo (a escolha
      do dono): `wrk`/`hey` contra o nosso (workers=nproc), `Bun.serve`, `node http`
      e `python uvicorn` na MESMA VPS, no espírito do `bench.sh`. Números honestos,
      e onde perdermos, o número diz onde otimizar.

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
