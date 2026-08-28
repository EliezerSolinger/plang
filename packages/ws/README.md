# ws — WebSocket (RFC 6455), sans-io

Bytes entram, **eventos** saem. Não há socket nenhum neste pacote, e é de
propósito: um protocolo é uma máquina de estados sobre bytes, e quem lê e
escreve é outra camada.

```python
import <ws/ws.psc> as ws

pr = ws.proto(True)              # True = o lado do servidor
pr.feed(bytes_que_chegaram)
while True:
    ev = pr.next()
    if ev == None:
        break
    if ev.kind == ws.EV_TEXT:
        print(ev.text())
    elif ev.kind == ws.EV_CLOSE:
        print("fechou com", ev.code)
if pr.failed():
    # o código com que se deve fechar já está escolhido
    fechar(pr.close_code_out(), pr.problem())
```

## Porque é que isto é pequeno

A biblioteca `websockets` do Python tem ~21 mil linhas, e ~17 mil delas são a
mesma lógica quatro vezes — uma por modelo de I/O (asyncio, trio, síncrono, o
legado). Aqui o modelo de concorrência é um só, portanto a lógica é uma.

E há uma peça que não se escreve de todo: **a validação de UTF-8**. Um quadro de
texto tem de ser UTF-8 válido ou é 1007, e é o caso onde a suíte Autobahn mais
reprova implementações. Aqui é `str(bytes)`, que **já levanta** — porque uma
`str` promete codepoints (79.1). A promessa do tipo faz o trabalho.

## O que o portão prova

`bash tests/ws.sh`, em duas metades:

* **o oráculo, nos dois sentidos** — os quadros que a `websockets` serializa são
  lidos por nós, e os que nós serializamos são lidos por ela *e são byte a byte
  os mesmos que ela produziria*. Um oráculo só num sentido prova metade: um
  parser e um serializador que errassem da mesma maneira concordariam entre si e
  com mais ninguém;

* **as recusas**, que não têm oráculo possível — uma biblioteca correcta não
  produz um quadro mal formado. Os vectores são montados à mão a partir do RFC, e
  o que se compara é o **código de fecho** de cada recusa: recusar pelo motivo
  errado é meio defeito, e a Autobahn conta-o como falha.

25 recusas cobertas: bits RSV, opcodes reservados, controlo fragmentado ou grande
de mais, continuação sem princípio, mensagem nova a meio de outra, comprimento em
forma não mínima (16 e 64 bits), bit alto do comprimento de 64, máscara em falta
no servidor, UTF-8 inválido e truncado, corpo de fecho de um byte, e os códigos
de fecho que não podem viajar (1004, 1005, 1006, 1016, 2999, 999).

E 9 casos que TÊM de passar, para o portão não estar só a recusar tudo — entre
eles um `ping` no meio de uma mensagem fragmentada, e um caractere UTF-8 partido
ao meio entre dois fragmentos.

## A negociação, e o que ela custou ler a sério

`Sec-WebSocket-Extensions` e `Sec-WebSocket-Protocol` são a mesma forma do RFC
7230 §7 — uma lista de itens, cada um com parâmetros — e o `parse_list` lê-a como
gramática e não por busca de subcadeia. A diferença tem um caso que a explica:

    x; a="permessage-deflate"

Uma busca por `"permessage-deflate"` acerta aqui e conclui que o cliente ofereceu
a extensão. Não ofereceu: ofereceu uma extensão `x` cujo parâmetro `a` tem aquele
*valor*. Um valor entre aspas pode conter vírgulas e pontos e vírgulas, e é isso
que torna a busca de subcadeia insuficiente em vez de só imprecisa.

O que se negoceia, e o que se faz com cada coisa:

| parâmetro | o que se faz |
|---|---|
| `server_max_window_bits=N` | **honrado**: o LZ77 não emite um casamento a mais de 2^N bytes, e responde-se com o mesmo N |
| `client_max_window_bits=N` | ecoado; o nosso `inflate` usa a janela inteira, portanto qualquer N é seguro |
| `client_max_window_bits` sem valor | é "escolhe tu", e não se aperta o cliente por nada — não se responde valor nenhum |
| `*_no_context_takeover` | **exigido** dos dois lados, e a razão está abaixo |
| qualquer outro | a oferta é **recusada** (§7): responder a uma oferta que não se entendeu inteira é prometer o que ninguém definiu |

Honrar os bits de janela precisou de uma coisa que não existia: o `deflate_sync`
do `packages/compress` leva agora um limite de distância. E a promessa **não se
confere com o `zlib`** — um `decompressobj(wbits=-8)` do CPython aceita
alegremente um fluxo com casamentos a 400 bytes lido com uma janela de 256, e
portanto passaria tanto o código certo como o errado. Quem a confere é o
`tests/ws-window.py`, um leitor de DEFLATE escrito do RFC 1951 que olha para as
distâncias emitidas.

## Fragmentar o que sai

O `fragments(op, payload, size)` parte uma mensagem em quadros, e a ordem em
relação à compressão é obrigatória: **comprime-se a mensagem inteira e só depois
se parte**. O fluxo do DEFLATE atravessa a fragmentação (§7.2.1 do RFC 7692), e
comprimir cada fragmento por si daria N fluxos independentes que o outro lado não
consegue juntar. Pela mesma razão o **RSV1 vai só no primeiro quadro**: ele
descreve a mensagem, e repeti-lo nas continuações é um 1002.

Durante muito tempo só se sabia *receber* fragmentos, o que é a metade fácil: uma
mensagem grande num quadro único obriga o outro lado a ter tudo em memória antes
de olhar para o primeiro byte.

## O que ainda não está aqui

* **a janela partilhada** do permessage-deflate (`context takeover`). A extensão
  está feita e exige `no_context_takeover` dos dois lados; com a janela
  partilhada a mensagem N comprimiria contra o que a N-1 disse, e isso pede um
  LZ77 que guarde os últimos 32 KiB por conexão e dos dois lados. Medido: 888
  bytes no fio passam a 60 sem takeover; com ele passariam a menos, e a segunda
  mensagem a muito menos.
* **a fase de descarte** do §7.1.7 do lado do SERVIDOR. O cliente tem-na (o
  `discard()` do `packages/httpc`, com prazo); o servidor fecha o TCP logo depois
  de mandar o quadro de fecho, que é o que o §7.1.1 lhe manda fazer.
* **o aperto de mão HTTP**, que é da `packages/httpd` (F6) — aqui só entra o
  protocolo depois de a conexão já ser um WebSocket.

## Atribuição e licença

O desenho *sans-io* — a máquina de estados separada do I/O — segue o da
biblioteca [`websockets`](https://github.com/python-websockets/websockets) de
Aymeric Augustin e colaboradores, que é também o **oráculo** do portão. Nenhuma
linha foi copiada: o que está aqui vem do RFC 6455. A dívida é de desenho e de
verificação.

Ela é BSD de 3 cláusulas, e a licença exige que o aviso de copyright, as
condições e a isenção acompanhem qualquer redistribuição — estão em
[`ATRIBUICAO.md`](ATRIBUICAO.md), ao lado deste ficheiro. A terceira cláusula é a
que vale a pena ler: o nome dos autores não pode ser usado para endossar este
pacote, e ele não os invoca — o que ela é aqui é um oráculo.
