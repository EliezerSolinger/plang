# httpc — um cliente HTTP/1.1 e WebSocket

```python
import <httpc/httpc.psc> as hc

r = await hc.get("https://exemplo.pt/api")
print(r.status, r.text())

w = await hc.ws_connect("wss://exemplo.pt/ws")
await w.send_text("olá")
ev = await w.recv()
```

**O parser é o MESMO do servidor** — `packages/http`, incremental e conferido
contra o corpus do llhttp. Isso não é reaproveitamento por economia: é o que
garante que o que o nosso servidor escreve o nosso cliente lê, porque os dois têm
uma máquina de estados só. Duas implementações concordariam nos casos fáceis e
divergiriam exactamente onde interessa.

## As decisões que se notam

* **os redirects são contados.** Um `Location` seguido às cegas é um laço
  infinito à espera de acontecer, e um servidor hostil dá-lho de graça;

* **um 301/302/303 sobre um POST vira GET** e perde o corpo — é o que todo o
  cliente faz, e o RFC 9110 §15.4 acabou por o permitir por escrito. Um **307/308
  não muda nada**: esses códigos foram criados exactamente para dizer "segue, e
  NÃO mudes o método";

* **os cabeçalhos sensíveis caem ao mudar de origem.** Seguir um redirect para
  outro domínio a levar o `Authorization` é entregar a credencial a quem escreveu
  o `Location`. É a falha que os clientes de HTTP tapam um a um, e cada um dela
  demorou uma versão a aparecer;

* **`user:senha@host` num URL é RECUSADO.** A forma é da RFC 3986 e ninguém
  devia usá-la; ignorá-la em silêncio seria pior;

* **um IPv6 entre parênteses rectos** parte no `:` que vem DEPOIS deles. Sem essa
  distinção, `[::1]:8080` parte no primeiro dois-pontos e o host fica `[`;

* **o gzip é pedido e desfeito** sem que quem chama saiba. Foi este módulo que
  pôs o cabeçalho, portanto é ele que tem de desfazer o resultado;

* **a máscara do WebSocket vem do gerador criptográfico**, uma por quadro. Ela
  não é segurança e não vale a pena fingi-lo — a chave viaja no próprio quadro.
  Ela existe porque proxies antigos podiam ser enganados a tratar o corpo como uma
  requisição HTTP, e o que ela exige é que a chave seja **imprevisível**;

* **o `Sec-WebSocket-Accept` é CONFERIDO.** Não é cerimónia: é o que prova que do
  outro lado está um servidor que entendeu o pedido, e não um servidor HTTP
  qualquer a devolver 101 por acidente ou um intermediário a responder à toa;

* **e o SUBPROTOCOLO também.** Um servidor que responde `Sec-WebSocket-Protocol`
  com uma coisa que não estava na nossa oferta está a dizer que vai falar um
  dialecto que nunca oferecemos, e continuar seria falar línguas diferentes com os
  dois lados convencidos de que se entendem. O §4.1 manda tratar isso como aperto
  de mão falhado, e é o que se faz;

* **o fecho tem PRAZO.** O §7.1.1 diz que, depois do quadro de fecho, quem fecha o
  TCP é o servidor e o cliente espera por isso — e fechar o socket a martelo no
  instante seguinte faz o servidor ver um RST em vez de um fim ordenado. Esperar
  *sem* prazo seria dar a um servidor que ignora o fecho a maneira de segurar o
  nosso processo, portanto a espera é o `discard()` do §7.1.7 dentro de um
  `timeout` que cancela o perdedor;

* **o permessage-deflate é oferecido e a resposta é LIDA.** Uma resposta a que
  falte `no_context_takeover` num dos sentidos é recusada em vez de ignorada:
  significa que o servidor conta com uma janela que atravessa mensagens, e o nosso
  compressor não a tem — aceitar seria mandar-lhe quadros que ele lê mal. Numa
  *resposta*, o `client_max_window_bits` fala de NÓS, e é a janela que a nossa
  saída passa a respeitar; é o sítio onde os nomes do RFC se invertem em relação
  ao servidor, e é por isso que a `Deflate` guarda `out_bits`/`in_bits` e não os
  nomes da norma;

* **o keepalive é EXPLÍCITO, ao contrário do servidor.** Lá o laço de leitura é da
  biblioteca e o ping é automático; aqui quem chama `recv()` é o programa, e entre
  duas chamadas dele a biblioteca não tem onde correr. Portanto arranca-se como
  tarefa: `k = hc.ws_keepalive(cli, 20.0, 10.0)`.

## O portão

`bash tests/httpc.sh` arranca os NOSSOS dois servidores e fala com eles. O que os
outros dois portões provam é a outra metade: o `curl` como oráculo do servidor
(`tests/httpd.sh`) e a biblioteca `websockets` do Python como oráculo do ws
(`tests/ws.sh`). Se o nosso lado divergisse do RFC, divergiria junto — e são os
oráculos de fora que apanham isso. O `tests/ws-features.sh` cobre a negociação de
parâmetros, o subprotocolo, a fragmentação e o keepalive.

## O que ainda não está aqui

O **pool de conexões**: cada pedido liga e fecha. Para um cliente que fala com o
mesmo servidor mil vezes é a diferença toda (um aperto de mão TCP e um TLS por
pedido), e a `one_round` está escrita para que o pool lhe troque o "liga e fecha"
por "toma e devolve" sem mudar mais nada. Também não há **cookies automáticos**,
**proxy** (o `proxy.py` da `websockets` não tem equivalente aqui) nem **h2**
(F11).
