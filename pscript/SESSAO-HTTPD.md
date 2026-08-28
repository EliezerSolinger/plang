# O servidor, e o que ele encontrou na linguagem

Isto é o relatório de uma sessão: o `pscript/HTTPD-DESIGN.md` foi executado do
princípio ao fim, e o que ele encontrou pelo caminho está no
`pscript/ACHADOS-PORTE.md`.

## O que ficou feito

**Todas as fases do desenho menos uma.** As três coisas que ele reservou ao
runtime (D11) e as doze da biblioteca:

| | |
|---|---|
| **L1** | um `def` e uma lambda de capturas POD **atravessam** para um worker |
| **L2** | `SO_REUSEPORT` — N workers no mesmo porto, repartidos pelo kernel |
| **L3** | `SSL_accept` — o servidor nasce a falar `https` |
| **L4** | os **tópicos**: pub/sub entre contextos, sobre os canos que já havia |
| **L5** | `net.unix` (já existia; ganhou portão) |
| **F1** | o servidor HTTP/1.1, com keep-alive, o 500 que não mata o worker, o `Host` exigido e o `Date` por segundo |
| **F1b** | rotas com `:param` e `*`, decididas por **especificidade** e não por ordem |
| **F1c** | query (com o `+` que é espaço) e JSON |
| **F2** | streaming por cursor: chunked e SSE, com contrapressão de graça |
| **F3** | multi-worker: as três peças da linguagem a encaixar |
| **F4** | o httpd inteiro sobre TLS |
| **F5** | o WebSocket sans-io, com 25 recusas do RFC conferidas |
| **F6** | o aperto de mão e a `WsConn` sobre o socket |
| **F7** | os tópicos ligados às conexões, com a dessubscrição do fecho |
| **F8** | ficheiros estáticos: MIME, ETag, 304, Range, e a travessia fechada |
| **F8b** | cookies com os atributos seguros por omissão, e sessão assinada |
| **F8c** | multipart e `Expect: 100-continue` |
| **F8d** | proxies declarados e rate limit |
| **F9** | compressão — e o `deflate` do repositório passou a comprimer de verdade |
| **F10** | o cliente HTTP e WebSocket, sobre o mesmo parser |
| **F12** | o banco de ensaio, publicado com o que ele não mede |

Falta a **F11** (h2 atrás de ALPN), que o desenho já punha por último.

## Os pacotes novos

`packages/httpd` (servidor, rotas, estáticos, sessão, ws), `packages/ws`
(protocolo sans-io), `packages/httpc` (cliente), `packages/sha1` (promovido de
dentro do mysql, porque dois protocolos vivos precisam dele).

## Os portões

Nenhum deles se confere a si mesmo. O oráculo é sempre de fora:

| portão | oráculo | o que prende |
|---|---|---|
| `tests/httpd.sh` | **curl** | 76 verificações no fio |
| `tests/ws.sh` | **websockets** do Python | frames nos dois sentidos, 25 recusas, ponta a ponta |
| `tests/httpc.sh` | o nosso próprio servidor | o círculo fecha |
| `tests/compress.sh` | **zlib** do CPython e **gunzip** | o que escrevemos abre noutro lado |
| `tests/tls-server.sh` | **openssl s_client** e **curl** | o aperto de mão, e a recusa sem `-k` |
| corpus pscript | **Python** | linha a linha, onde ele sabe responder |

## O que a linguagem ganhou, e o que ela devolveu

Vinte e um achados, dos quais **catorze eram defeitos** — e cinco deles eram
corrupção de memória ou UB, não um erro de mensagem:

* um **`const` construído era `None` dentro de um worker**, o que quebrava
  qualquer pacote com uma tabela — o `datetime`, o `compress`, o próprio `httpd`.
  O sintoma era uma resposta em trinta a falhar;
* uma **ligação aceite nascia com o `ssl` por inicializar** e falava TLS por
  acidente. Encontrado pelo banco de ensaio, ao comparar a nossa coluna de erros
  com a do Bun;
* **EAGAIN num socket era lido como "a ligação partiu-se"**;
* a **mensagem vazia de um tipo que é referência** dava um ponteiro nulo, e o
  primeiro uso dele era um SIGSEGV numa thread sem pilha para ler;
* o **`sh_mangle` dava a mesma chave de descritor a espécies diferentes**, o que
  fazia o `json.stringify` recusar um dicionário válido por causa de um `bytes`
  mencionado noutro sítio do ficheiro;
* um **`def` de topo com nome de POSIX era capturado pela libc** — `def listen`
  *era* o `listen(2)`;
* **`with await open(...)` num `async def`** não compilava;
* o **construtor posicional não embrulhava um valor num campo `T?`**;
* **`str()` e f-string de um `T?`** não compilavam, e o mesmo valor tinha forma
  escrita dentro de uma lista e não tinha no topo.

E o que faltava e passou a existir: `bytes + bytes`, `remove()` num `shared
dict`, o endereço de quem ligou, um DEFLATE que comprime, e as quatro funções dos
tópicos.

## O que fica aberto

Está tudo listado no `ACHADOS-PORTE.md` com o número: um método ligado não é um
valor; `spawn` não aceita uma função de um módulo importado; percorrer um `shared
dict` é uma pergunta de desenho por responder; e `x[k] if k in x else 0` levanta
numa tabela partilhada porque a leitura é hasteada para fora do ternário.
