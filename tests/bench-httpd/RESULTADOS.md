# O banco de ensaio do httpd (F12)

## O que saiu

Máquina: a VPS deste repositório, **4 núcleos**. Gerador: `carga.c` (aqui ao
lado), 4 threads × 16 conexões keep-alive, 6 segundos por medição, uma volta de
aquecimento deitada fora. Todos os servidores respondem as mesmas duas rotas.

| servidor | req/s `/` | erros | lat. média | req/s `/json` |
|---|---|---|---|---|
| pscript (1 worker) | 13 623 | 0 | 0,29 ms | 12 738 |
| pscript (4 workers) | 19 527 | 0 | 0,21 ms | 18 597 |
| **bun** (1 processo) | **24 016** | 0 | **0,17 ms** | **20 919** |
| node `http` (1 processo) | 8 082 | 0 | 0,50 ms | 7 874 |

## A leitura, sem retoques

**O Bun ganha, e ganha nas duas colunas.** 24 mil contra os nossos 19,5 mil com a
máquina inteira, e 24 mil contra 13,6 mil um-para-um. Não há como apresentar isto
de outra maneira, e apresentá-la de outra maneira seria a única coisa que tornaria
o número inútil.

**Ganhamos ao Node por 1,7×** com um worker só.

**E os quatro workers dão 1,43× sobre um**, não 4×. A razão está à vista e não é
do servidor: o gerador de carga tem quatro threads a disputar os mesmos quatro
núcleos. Com a máquina cheia dos dois lados, o que se mede é o mínimo entre os
dois — e para medir o teto do servidor faria falta gerar a carga de outra máquina.
O número honesto que este banco dá é "escala, e escala sublinearmente **nesta
medição**".

## O que este banco NÃO mede

* **percentis.** O gerador guarda a média e não as amostras. Uma cauda de 99,9%
  é o que decide se um servidor de jogo é jogável, e ela não está aqui.
* **carga de outra máquina.** Tudo em `127.0.0.1`, portanto sem a pilha de rede
  real, sem perda e sem latência.
* **TLS.** Os números acima são todos em claro.
* **nada com disco ou base de dados**, que é onde a maioria dos servidores reais
  passa o tempo.

E os números não se comparam com os de outra máquina — o que se compara é a coluna
ao lado.

## O que o banco encontrou, e vale mais do que a tabela

A primeira vez que isto correu, a coluna dos erros dizia **26** para os quatro
workers e **0** para o Bun. Vinte e seis respostas em cem mil a desaparecer, sem
uma linha de erro em sítio nenhum.

Eram quatro camadas de engano, e desmontá-las levou uma hora:

1. o meu **registo de erros não saía**, porque estava escrito com `aprint` sem
   `await` — e um `aprint` é uma tarefa. Passou a `sys.err.write`, que é onde o
   registo de um servidor pertence e não é tamponado;
2. o **`write` tratava EAGAIN como fatal**: um tampão de envio cheio, que é o
   normal sob carga, era lido como "a ligação partiu-se";
3. a minha **primeira correcção disso tinha uma corrida**: ela perguntava ao
   `poll` se o descritor estava pronto e, se estivesse, concluía "pronto e a
   falhar, logo é erro" — mas entre o `read` que devolveu EAGAIN e o `poll`, os
   dados chegam. Só POLLERR/POLLHUP/POLLNVAL são prova de fim;
4. e a causa de verdade: **uma ligação ACEITE nascia com o campo `ssl` por
   inicializar.** O `ps_alloc` não zera, o caminho do `accept` tinha uma segunda
   inicialização à mão ao lado da do `ps_conn_new`, e faltava-lhe um campo. Uma
   conexão em claro cujo `ssl` herdasse lixo não nulo entrava no caminho do
   `SSL_read`; o primeiro `read` falhava, o servidor fechava com o pedido ainda
   por ler, e do lado do cliente isso chegava como um RST.

O comentário que estava nessa lista já dizia que ela tinha custado o mesmo engano
duas vezes antes (`is_std`, `pty_slave_fd`). A correcção não foi acrescentar-lhe o
terceiro nome — foi **não haver lista**: o `accept` passou a chamar o
`ps_conn_new`, que é o construtor que já inicializava tudo.

Um banco de ensaio que só dissesse "somos 20% mais lentos que o Bun" teria valido
uma tarde. Este encontrou uma ligação que falava TLS por acidente.

## Como correr

```
bash tests/bench-httpd/correr.sh          # 5s por medição
SEGS=20 bash tests/bench-httpd/correr.sh  # mais tempo, menos ruído
```
