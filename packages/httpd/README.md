# httpd — um servidor HTTP/1.1 e WebSocket

```python
import <httpd/httpd.psc> as httpd

async def handle(req: httpd.Request) -> httpd.Response:
    if req.path == "/":
        return httpd.text("olá")
    return httpd.status_code(404)

srv = httpd.listen(8080, httpd.config())
await httpd.run(srv, handle)
```

O parser não está aqui: está no `packages/http`, é incremental e é conferido
contra o corpus do próprio llhttp. O que este pacote acrescenta é tudo o que fica
**entre** o parser e quem escreve o programa.

## O modelo de concorrência é o argumento

Cada worker tem heap, coletor e escalonador **próprios**. N workers escutam o
mesmo porto com `SO_REUSEPORT` e o kernel reparte as conexões — ninguém passa
descritores a ninguém, e não há um aceitador único a ser o gargalo. Uma pausa do
coletor pára **um** worker, não o servidor.

E quando é preciso estado partilhado, há três degraus com custos diferentes e
visíveis:

| a necessidade | a primitiva | o custo |
|---|---|---|
| sessão, rate-limit, contador | `shared dict` | um lock por operação |
| estado grande de leitura | `shared Buffer` + vistas | **zero cópia** |
| evento entre workers | `topic.publish` | serializa, uma vez por worker |
| entre tarefas do mesmo worker | `Channel` | zero serialização |

## As decisões que se notam

* **os cabeçalhos são uma LISTA de pares**, não um dicionário. O HTTP permite
  nomes repetidos e a ordem importa; `Set-Cookie` é o caso de todos os dias.
  `req.header(n)` dá o primeiro e `req.headers_all(n)` dá todos. Um
  `Dict<str,str>` obrigaria a um caminho especial só para o `Set-Cookie`;

* **o `content-length` é de quem serve**, não de quem responde. Um handler que o
  escrevesse poderia discordar do corpo, e dois comprimentos que discordam é a
  porta do request smuggling. A excepção é o 101, onde a conexão deixa de ser
  HTTP e quem sabe o que ela passa a ser é quem respondeu;

* **um 204 não leva `content-length`**, nem sequer zero (RFC 9110 §8.6). A
  diferença entre "não levar" e "levar zero" parece de gosto e não é: um
  intermediário com duas leituras da mesma resposta é um cano dessincronizado;

* **a ordem de registo das rotas não decide** — decide a especificidade. Com a
  ordem a decidir, mudar duas linhas de sítio mudaria o que o servidor faz;

* **um caminho que existe com outro método dá 405 com `Allow`**, e não 404. Um
  404 diz "não há nada aqui" e o que se passa é "há, mas não assim";

* **o `Date` calcula-se uma vez por segundo**, e a memória vive na `Config` —
  portanto dois servidores no mesmo worker não a partilham;

* **uma excepção no handler é um 500 e o worker continua.** Com `debug=True` a
  mensagem vai também no corpo.

## O WebSocket

```python
import <httpd/ws.psc> as hws

PROTOCOLS = ["jogo.v2", "jogo.v1"]

async def message_h(c: hws.WsConn, ev: hws.Event) -> int:
    if ev.is_text():
        # `c.protocol` diz qual dialecto ficou combinado no aperto de mão
        n = await c.hub.broadcast("lobby", ev.data, False)
    return 1

async def handle(req: httpd.Request) -> httpd.Response:
    if req.path == "/ws":
        return hws.upgrade(req, PROTOCOLS)
    ...

# a lista vai só ao `upgrade`, que é quem escolhe — guardá-la também aqui seria
# um campo que ninguém lê
hs = hws.handlers(opened, message_h, None,
                  16384,          # fragment_size: 0 = uma mensagem por quadro
                  20.0, 10.0)     # ping a cada 20 s, 10 s para o pong
cfg.on_upgrade = hws.upgrader(hs)
```

A `httpd` é **cega** ao WebSocket: ela sabe que alguém pediu para tomar conta da
conexão e entrega-lha, com o pedido e com os bytes que já tinham chegado a seguir
ao aperto de mão. Esses bytes não são um pormenor — um cliente ansioso manda o
primeiro quadro colado ao pedido, no mesmo `read`.

O **subprotocolo** é escolhido pela ordem em que o programa o escreveu, e não
pela ordem do cliente: o cliente diz o que sabe falar, o servidor escolhe. Sem
nada em comum o cabeçalho é omitido, e isso é uma resposta válida — o §4.1 deixa
o cliente decidir se consegue seguir sem ele. A decisão fica guardada na
`Request` (`req.attrs`) em vez de ser refeita pelo laço da conexão: antes era
refeita, apoiada em a negociação ser determinística sobre os mesmos cabeçalhos —
verdade, e frágil, porque o dia em que os dois sítios discordassem o servidor
dizia uma coisa ao cliente e usava outra.

O **keepalive vem ligado**, com um ping a cada 20 segundos e 10 para a resposta.
Não é uma afinação: um cliente que desaparece sem FIN — um portátil que fecha uma
tampa, um NAT que esquece uma tradução — deixa uma conexão que este lado julga
viva para sempre, continua a receber as publicações do tópico, e um servidor de
jogo acumula fantasmas até reiniciar. O custo são dois bytes por conexão a cada
20 segundos, porque o `sleep` estaciona no mesmo `poll` que já espera pelos
sockets. `ping_interval = 0.0` desliga-o.

O **`fragment_size`** parte uma mensagem que sai em vários quadros. Fica em 0 por
omissão, e de propósito: um jogo manda mensagens pequenas sessenta vezes por
segundo e fragmentá-las seria pagar moldura por nada. Vale a pena para um
snapshot grande, onde um quadro único obriga o outro lado a ter tudo em memória
antes de olhar para o primeiro byte.

Os **tópicos** têm dois degraus com o custo separado: dentro do worker o quadro é
montado uma vez e escrito N, sem serializar nada; para os outros workers atravessa
como bytes, **uma vez por worker** e não uma vez por conexão. E fechar
dessubscreve de tudo, sempre — um servidor de jogo tem gente a entrar e a sair o
dia inteiro, e uma inscrição que sobrevivesse à conexão seria uma fuga que cresce
com o tempo de vida do processo.

## Um exemplo completo

[`example/game.psc`](example/game.psc) é um servidor de jogo em cinquenta linhas,
e não é um brinquedo com as arestas escondidas: serve os ficheiros do cliente com
ETag e `Range`, responde JSON numa rota de API, faz o upgrade para WebSocket
**depois** de verificar o token (a autorização é código normal, não um privilégio
do servidor), difunde cada mensagem a todos os workers, e usa a máquina inteira.

```
bash tests/psbuild.sh packages/httpd/example/game.psc /tmp/jogo
/tmp/jogo 3335 4 publico
```

O portão corre-o com três workers e três clientes, e exige que uma mensagem de um
deles chegue aos três — o que só é verdade se ela atravessar os workers.

## O que os portões provam

`bash tests/httpd.sh` (30 verificações) e `bash tests/ws.sh` (7). Nenhum deles tem
`.expected` para o servidor: o que se quer provar não é o que uma função devolve,
é o que sai **no fio** — e o oráculo é o `curl` e a biblioteca `websockets` do
Python, que são quem conta se houve uma conexão para três pedidos e se o aperto de
mão está certo.

## O que ainda não está aqui

Streaming e SSE (F2), ficheiros estáticos (F8), cookies e sessão (F8b), multipart
(F8c), limites e rate limit (F8d), compressão (F9), TLS servidor (F4), cliente
HTTP completo (F10), h2 (F11). Ver `pscript/HTTPD-DESIGN.md`.
