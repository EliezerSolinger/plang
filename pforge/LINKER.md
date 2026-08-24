# O linker — discussão antes de qualquer linha (2026-08-22)

Nada aqui está decidido. Este arquivo existe porque um fato que eu levantei
**corrige** uma coisa que eu te disse antes, e a correção muda a ordem do
trabalho.

## A correção

Eu disse que o linker interno se paga em **latência de invocação** (o "JIT").
Isso está errado sozinho, e o motivo é simples: **o QBE emite TEXTO de assembly**,
não código de máquina. A cadeia real é

```
plangc  ->  QBE  ->  .s (texto)  ->  as  ->  .o  ->  ld/cc  ->  binário
                                     ^^^^                ^^^^^^
                              o assembler          o linker
```

Então, com precisão:

| o que eu quero | o que preciso escrever |
|---|---|
| não depender do `cc` para linkar | **linker** |
| cruzar sem binutils do alvo | **linker + assembler** |
| **JIT em memória, sem arquivo nenhum** | **assembler + carregador em memória** — e aí o linker de ARQUIVO é dispensável |

Ou seja: há duas coisas diferentes chamadas "linker" — o que **escreve um
arquivo** (ELF/Mach-O) e o que **carrega na memória** do processo. O JIT quer o
segundo; a independência de toolchain quer o primeiro; e os dois querem o
assembler.

## O que precisa ser resolvido, medido neste repositório

- **todo o compilador precisa de 50 símbolos externos** — 44 são libc puro
  (`malloc`, `printf`, `strlen`, `popen`, `execv`…) e o resto é partida
  (`__libc_start_main`, `__cxa_finalize`, dois `_ITM_*` fracos, `__gmon_start__`).
  **Zero símbolo de `libgcc`** — o `-lgcc`/`-lgcc_s` que o `cc` passa não é para
  nós;
- **um programa pscript precisa de 91**, todos da glibc: além da libc, `pthread_*`
  (a glibc 2.34 fundiu a libpthread na libc), `epoll_*`, `socket`/`getaddrinfo`,
  `sqrt`/`pow`/`log` da libm e `regexec`;
- **a saída de hoje** é ELF **PIE dinâmico**, interpretador
  `/lib64/ld-linux-x86-64.so.2`, e o `cc` puxa
  `Scrt1.o crti.o crtbeginS.o … crtend.o crtn.o -lgcc -lgcc_s -lc`;
- **o repertório do QBE no amd64 são 86 mnemônicos** (medidos nos 19 módulos do
  compilador), e dez deles são ~95 % das instâncias:
  `movq movl callq cmpl jmp leaq movzbl jnz pushq jz`. A cauda é aritmética SSE
  (`subsd mulsd divsd cvtsi2sd xorpd`) com 1 ou 2 usos cada.

Esse último número é o que torna a conversa possível: **não precisamos de um
assembler de x86-64**, precisamos de um assembler para *o que o QBE emite* — 86
mnemônicos e um punhado de modos de endereçamento.

## Os três níveis de ambição

**(1) Carregador em memória (o JIT).** `mmap` de páginas executáveis, aplicar
relocações, resolver os 50–91 nomes contra a libc **já carregada** no processo
(`dlsym`), e chamar. Não escreve arquivo, não conhece ELF, não conhece crt. É o
menor dos três — e depende do assembler.

**(2) Linker estático.** O mais fácil de escrever (dois `PT_LOAD` e relocações) e
**o pior casado com a glibc**: `getaddrinfo` estático não funciona de verdade
(NSS precisa de `dlopen`), e o nosso runtime usa `getaddrinfo`. Com musl seria
limpo — mas escolher a libc do usuário contraria a decisão "libc é o runtime".

**(3) Linker dinâmico** — o único que substitui o `cc` de verdade: `.dynamic` com
`DT_NEEDED libc.so.6`, `.rela.dyn`/`.rela.plt`, GOT/PLT, e um `_start` nosso
chamando `__libc_start_main`. É o que o tcc faz num punhado de milhares de linhas,
e é o **único nível que consegue linkar o pstudio**, porque SDL2 é biblioteca
compartilhada.

## macOS, que é o elefante da sala

Você compila no macOS, então "o nosso linker" para a sua máquina principal não é
ELF: é **Mach-O**. E no arm64 a **assinatura de código é obrigatória** — binário
sem assinatura ad-hoc simplesmente não roda. Isso pede SHA-256, que o `pforge` vai
ter de todo jeito pela 2.9 (convergência real, não coincidência).

E há uma inversão curiosa entre as duas plataformas:

| | assembler | formato do arquivo |
|---|---|---|
| **amd64** | difícil (ModRM/SIB/REX, instrução de tamanho variável) | ELF: documentado e regular |
| **arm64** | **fácil** (instrução de 32 bits, codificação regular) | Mach-O **+ assinatura obrigatória** |

## O que isto NÃO deve virar

Um linker de propósito geral. `mold` e `lld` são centenas de milhares de linhas
porque servem qualquer objeto de qualquer compilador, com LTO, ICF, seções de
depuração e scripts de linker. O nosso caso é o oposto de geral: **os nossos
próprios objetos, um punhado de símbolos externos, um formato de saída por
plataforma.** No dia em que alguém quiser linkar um objeto que não saiu daqui,
existe o `cc` — que continua na lista fixa de ferramentas.

---

## A sua stack do `qbux-os` (medida, 2026-08-22)

Você apontou `github.com/EliezerSolinger/qbux-os` — ucpp + cproc + qbe + minias +
neatld + neatlibc, integrados e **auto-hospedados** (a toolchain compila a si
mesma, e compila a neatlibc, o xv6 e o mrsh). Clonei e medi peça por peça:

| peça | linhas de C | o que é, e o que serve aqui |
|---|---|---|
| **neatld** | **860** (um arquivo, `nld.c`) | linker **ESTÁTICO** ELF, ARM e x86(-64), entrada `_start`, licença ISC (Ali Gholami Rudi). **Menor que o `psrt_std.p`** |
| **minias** | **5 462** | assembler x86-64 AT&T, saída **ELF relocável**, escrito **para assemblar saída de qbe/cproc** (e gcc/clang/chibicc); auto-hospeda o cproc |
| **neatlibc** | **4 441** | libc mínima: stdio, string, malloc, regex, qsort, time, signal, termios, dirent, syscalls crus de socket |
| **ucpp** | **11 462** | pré-processador C99 completo, e — o detalhe que importa — **feito para ser EMBUTIDO** como biblioteca |
| **cproc** | 10 212 | front end de C. **É a única peça que não nos serve**: nós já temos o nosso, com 220/220 na c-suite e paridade de diagnóstico com o clang |
| qbe | 18 220 | o mesmo que já usamos |

Duas medições cruzadas com os símbolos que os nossos binários pedem:

**O que falta na neatlibc para o COMPILADOR** (dos 44 nomes de libc que ele usa):
`popen`, `pclose`, `uname`, `ctime`, `mkdir`, `fseek`, `ftell`, `rewind`,
`strtod` — **nove**, e a maioria trivial (`strtod` é a chata).

**O que falta para um programa PSCRIPT**: `pthread_*`, `epoll_*`,
`getaddrinfo`, e a libm (`sqrt`/`pow`/`log`). Isso não é lacuna a preencher de
passagem: é **estrutural**. Um `spawn` de worker é uma thread (18.1), e o laço da
102 é epoll.

### A conclusão que essas duas medições impõem: são DUAS trilhas, não uma

| | **trilha sistema** | **trilha livre** |
|---|---|---|
| para quê | Linux/macOS de verdade, com glibc e SDL2 | metal, xv6, embarcado — o que o README do plang **já promete** |
| linka com | `cc` (dinâmico, PIE, `ld.so`) | **neatld** (estático) |
| assembla com | **minias** | **minias** |
| pré-processa com | **ucpp embutido** | **ucpp embutido** |
| libc | a do sistema | **neatlibc** |
| serve pscript? | **sim** | **não** — threads e epoll não estão lá |
| ferramentas externas | só o `cc`, e só no link | **nenhuma** |

E há uma convergência bonita nos dois lados: hoje o `plangc` chama `cc -E` por
`popen` para pré-processar `include <stdio.h>`. **Embutir o ucpp mata o `popen`
e a chamada ao `cc` de uma vez** — que é justamente um dos nove furos da
neatlibc. O furo existia *porque* nós chamávamos o `cc`.

### O que a stack NÃO cobre, e é preciso dizer

- **arm64 não existe nela**: o minias é x86-64 declaradamente ("Non Goals:
  assemble other architectures"), e o neatld fala ARM mas em ELF;
- **Mach-O não existe**, e sem Mach-O não há macOS — nem assinatura de código,
  que no arm64 é obrigatória. **A sua máquina principal continua no `cc`**;
- **link dinâmico não existe** no neatld: sem `.so`, o pstudio (SDL2) não linka
  por essa trilha, e `getaddrinfo` estático não funciona nem com glibc.

## O veredicto desta rodada (2026-08-22)

**Não se escreve assembler nem linker agora.** Suas decisões, com o motivo de
cada uma:

- **`minias` não entra por ora** — o `as` custa 0,356 s dos 4,50 s medidos, e
  funciona; trocá-lo é independência, não velocidade, e só no amd64;
- **`ucpp` não entra** — *"o `cc -E` da máquina é a verdade sobre os headers
  dela"*. É o argumento certo: os headers do sistema são cheios de `__builtin` e
  extensão do compilador local, e pré-processar com o próprio `cc` garante ver o
  que aquela máquina vê. Consequência anotada: **o `popen` continua sendo
  requisito do compilador** — e note que isso **não** atrapalha a trilha livre,
  porque num alvo sem sistema operacional não há header de sistema para
  pré-processar;
- **arm64/macOS fica no `cc` por tempo indeterminado**, e está dito: no macOS o
  `cc` é o assembler e o linker, e quem compila ali já tem o Xcode. A promessa de
  independência é do Linux/amd64 e da trilha livre; no macOS a promessa é
  "funciona".

## musl: a peça que faltava para a trilha livre servir PSCRIPT (medido)

Sua intuição: *"a gente pode incluir a musl talvez, faria mais sentido como
target"*. Medi, e ela está certa — a neatlibc não serve pscript e a musl serve:

| | linhas | pthread | epoll | getaddrinfo | libm | serve pscript? |
|---|---|---|---|---|---|---|
| **neatlibc** | 4 441 | ❌ | ❌ | ❌ | ❌ | **não** |
| **musl** | **89 723** (1 608 `.c`, MIT) | ✅ | ✅ | ✅ **e estático de verdade** | ✅ dentro do mesmo `libc.a` | **sim** |

Conferi **os 90 símbolos** que um binário pscript pede, um por um: a musl tem
todos — `pthread_create`, `eventfd`, `epoll`, `getaddrinfo`, `regcomp`/`regexec`,
`sincos`, `sqrt`/`pow`/`log`. Os únicos que desaparecem são os `__*_chk` da
glibc (o `_FORTIFY_SOURCE` que o gcc do Ubuntu liga por padrão) — some-se
compilando sem fortify.

Três fatos que fecham a conta:

1. **`getaddrinfo` estático é o problema que a musl existe para resolver.** Na
   glibc ele depende de NSS e portanto de `dlopen`; na musl o resolvedor é dela.
   Era exatamente o furo que matava a trilha estática para o nosso runtime;
2. **a libm está dentro do `libc.a`** — não há `-lm` para linkar;
3. **o `neatld` sabe ler arquivo `.a`** (`outelf_archive`, e a opção `-L`),
   conferido na fonte: ele consegue linkar a musl.

E o limite, dito com precisão: **nós não compilaríamos a musl.** Ela tem 264
arquivos com `__asm__` inline e 304 `.s` puros, e o nosso front end de C **erra
de propósito** em asm inline estendido (`cfront.p:2231`: *"an honest error beats
silently losing the asm in the round-trip"*). A musl é **alvo**, não dependência a
construir: entra como `libc.a` pronta (do sistema, do Alpine, ou construída uma
vez com o `cc`).

## Decidido (2026-08-22)

**A musl fica escrita e espera.** A medição acima é o registro: quando a trilha
livre virar prioridade, ela é a libc que a torna possível para as duas
linguagens, e nada precisa ser re-descoberto. Por ora, glibc dinâmica.

**Quando a vez chegar, o assembler e o linker são ESCRITOS EM P**, com o `minias`
e o `neatld` como referência — do mesmo jeito que o samurai e o ninja foram lidos
nesta investigação: lê-se para aprender o mecanismo, escreve-se o nosso.

Três consequências que essa escolha traz, e todas boas:

1. **Eles nascem no lugar certo.** Escritos em P, assembler e linker moram no
   `plangc` — zero runtime, sem coletor, sem pscript. Nada de arrastar o runtime
   para dentro do compilador (o custo que a pergunta A já mediu em ~75 mil linhas
   de seed);
2. **Os dois têm ORÁCULO PERFEITO**, que é o método desta casa (python3 e node
   para o pscript, clang para os diagnósticos): o oráculo do assembler é o `as` —
   compara-se byte a byte, instrução por instrução, para cada um dos 86
   mnemônicos que o QBE emite; o do linker é o `ld` mais o teste que importa ("o
   binário roda") e o ponto fixo da escada;
3. **O escopo é estreito e medido**, não aspiracional: 86 mnemônicos de x86-64
   AT&T, ELF relocável na saída do assembler, e no linker os ~50 símbolos do
   compilador ou os ~90 de um programa pscript, resolvidos contra um `libc.a`.

O que fica anotado como pré-requisito para começar: **um alvo por vez** (amd64/ELF
primeiro, porque é onde há oráculo e onde eu consigo medir), e o `cc` continuando
na lista fixa de ferramentas para todo o resto — inclusive para sempre no macOS.
