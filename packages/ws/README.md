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

## O que ainda não está aqui

* **permessage-deflate** (F9). O `packages/compress` já tem o DEFLATE inteiro; o
  que falta é a negociação e a janela partilhada entre quadros do RFC 7692, que é
  onde ele morde.
* **o aperto de mão HTTP**, que é da `packages/httpd` (F6) — aqui só entra o
  protocolo depois de a conexão já ser um WebSocket.

## Atribuição

O desenho *sans-io* — a máquina de estados separada do I/O — segue o da
biblioteca [`websockets`](https://github.com/python-websockets/websockets) de
Aymeric Augustin e colaboradores (BSD 3-Clause), que é também o **oráculo** do
portão. Nenhum código foi copiado: o que está aqui é escrito a partir do RFC
6455. A dívida é de desenho e de verificação, e fica dita.
