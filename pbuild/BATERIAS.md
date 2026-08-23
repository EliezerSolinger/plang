# Baterias a dobrar em `pscript/DESIGN.md`

Este arquivo é TEMPORÁRIO e existe por uma razão de logística, não de desenho:
`pscript/DESIGN.md` carrega, neste momento, trabalho não comitado de outra
sessão (a bateria 119). Escrever aqui e dobrar depois é a única forma de não
comitar o trabalho inacabado de outro — e de não perder o registro.

**Quando o arquivo estiver livre**: mover cada secção abaixo para o fim de
`pscript/DESIGN.md`, com o número da bateria seguinte, e apagar este arquivo.

---

## O coletor: duas armadilhas da mesma família

As duas foram achadas rodando a suíte do motor do pbuild com
`PSCRIPT_GC_STRESS=1`, e as duas são do tipo pior: o programa está certo, o
relatório está certo, e o resultado está errado.

**(a) `ps_alloc` não zera, e quem constrói um objeto escreve TODOS os campos.**
A abertura de arquivo escrevia dois de três: `is_std` — o campo que diz "isto é
o stdout, fechar não faz nada" — ficava com o lixo do bloco que uma coleta tinha
reciclado. Quando o lixo era != 0, `close` saía cedo sem fechar nada: `write`
dizia ter gravado 144 bytes, `path.getsize` via 0, e os dados só apareciam
quando o processo saía e a libc esvaziava o que sobrara.

A regra, dita de forma que não se possa esquecer: **o construtor de um objeto do
runtime escreve todos os campos, sem exceção.** `ps_alloc` entrega memória crua
de propósito (zerar `sizeof(PsStr) + len` em toda string seria pagar duas vezes
pelo mesmo byte), e o preço disso é esta regra. Os 40 sítios foram varridos.

**(b) `__fr->x = f()` escreve no quadro VELHO.** Dentro de um `async def` todo
local mora no quadro, e o quadro é objeto do heap que o coletor MOVE. Em C a
ordem entre calcular o endereço da esquerda e chamar a direita não está
definida: o compilador carrega `__fr` num registrador, `f` aloca, a coleta
conserta a pilha de sombra, e a escrita — que já tinha o endereço — vai para o
lugar de antes.

A DECLARAÇÃO de um local já calculava o valor numa temporária primeiro; a
atribuição a um nome, o `+=`, o `:=` e o `return` não. A regra geral, agora
aplicada em todos: **quando o destino é um campo de um objeto do heap, o valor
vem primeiro.**

Portões: `tests/pscript/run/aio_close.psc` e `async_store.psc`, no corpo que o
`gc-stress.sh` roda com o coletor a cada ponto seguro.

---

## 1.5(d) — `import "x.ph"` dentro de um módulo importado

Até aqui, um `import "x.ph"` só era honrado por inteiro quando estava no arquivo
NOMEADO na linha de comando. Num módulo importado ele entrava pela metade: as
declarações valiam, o `#include` saía no C gerado, e o `.p` irmão não era
compilado. O link falhava, e quem construía compensava nomeando o arquivo à mão
— era o que o alvo `pstudio` do `Makefile` fazia com o `hl.p`.

Agora a varredura é do FECHAMENTO: o compilador segue os imports de módulo do
pscript, acha os `import "x.ph"` de cada um, e puxa o `.p` irmão quando ele
existe (um `.ph` sozinho continua sendo só declaração — o `stl` é assim).

**Onde ela mora, e por quê.** Em `main.p`, e não na sema. A sema do pscript
resolve o mesmo grafo de imports, mas ela não roda quando a pergunta é
`--outputs` — e a resposta 3 do protocolo tem de dizer o que vai ser emitido
**sem compilar nada**. Um sistema de build pergunta antes de mandar fazer.

**A medida.** O descritor do editor precisava nomear dezanove arquivos copiados
do `Makefile`; ficou com dois. E os dois que sobraram não são falha de
fechamento: `plang.ph` DECLARA `fatal_at` e quem o implementa é `util.p`, um
arquivo com outro nome e sem aresta de import ligando os dois. Nenhuma regra de
fechamento acharia isso, e nem devia — é conhecimento do repositório, e é para
carregar conhecimento do repositório que um descritor existe.

Portão: `tests/pscript/run/import_fundo.psc` (com o compilador anterior:
`#include` órfão e o link falha).

---

## `import <pkg/mod.ph>` — o pacote como CAMINHO DE BUSCA

O compilador NÃO sabe o que é um pacote, e é essa a decisão que o resto depende.
Ele recebe raízes de busca (`--pkg-path`, repetível) e procura nelas, na ordem
em que foram dadas — a mesma regra do `-I` do C, e pela mesma razão: é a única
que dá para explicar numa linha. Quem sabe o que é versão, dependência e
resolução é o `ppack`, e a fronteira entre os dois é literalmente esta lista de
diretórios.

Três formas, e nenhuma ambiguidade entre elas:

| forma | significa |
|---|---|
| `include <stdio.h>` | header de C do sistema, pré-processado pelo `cc` |
| `import <stl/vec.ph>` | módulo de um **pacote**, procurado nas raízes |
| `import "vizinho.ph"` | módulo **ao lado do arquivo**, como sempre |

**Não há recuo de uma para a outra.** Um `<>` que não é achado é ERRO, e não
vira uma tentativa relativa: um recuo silencioso faria um programa compilar por
acidente com o arquivo errado, e é o tipo de conveniência que se paga uma vez e
se lamenta durante anos. O erro diz onde se procurou, porque "não achei" sozinho
deixa quem lê a adivinhar se o pacote não foi resolvido, se o nome está errado,
ou se o `--pkg-path` não chegou até ali.

**O pacote é uma UNIDADE, então o `<>` puxa o `.p` irmão.** É a 1.5(a) aplicada
só à forma com `<>`, e a diferença entre as duas formas é o que a justifica:
`"x.ph"` é um arquivo ao lado e quem compila diz o que compila (o contrato da
linha de comando); `<pkg/mod.ph>` é um pacote, e importar a interface e ter de
nomear a implementação à mão seria pedir que quem usa o pacote soubesse como ele
é feito por dentro. A 1.5(a) para a forma relativa continua ABERTA.

**Depois de resolvido, ele vira um import relativo comum.** É a única forma de o
header EMITIDO resolver: o `<>` é relativo a uma raiz que só o compilador
conhece, e o C gerado tem de incluir o header GERADO, que mora no espelho do
`--out-dir` no mesmo lugar relativo em que o fonte mora no disco. Reescrever na
sema faz todo o resto do compilador — back end, deps, espelho — não precisar
aprender nada sobre pacotes.

**O limite, dito de frente:** a raiz e os fontes têm de ser nomeados do mesmo
jeito — ambos relativos ao diretório de trabalho, ou ambos absolutos. Com um de
cada lado não existe caminho relativo entre eles que valha também dentro do
espelho, e o compilador RECUSA com uma mensagem que explica isso em vez de
emitir um `#include` que não resolve.

Portão: `tests/packages.sh`, 14 checagens — o programa que usa dois pacotes (um
deles dependendo do outro), as respostas 1 e 3 a enxergarem o pacote, as três
formas de erro, e o mesmo do lado do pscript.

---

## A docstring, agora nas duas linguagens

`"""..."""` passou a existir em P, e a regra é POSICIONAL — a mesma do pscript
(46.3), a mesma do Python, e sem palavra nova nenhuma: uma string sozinha como
primeira coisa de um MÓDULO, de um CORPO de função, de um `struct`/`record`/
`union`, de um `enum` ou de um `trait`. Em qualquer outro lugar `"""..."""` é só
uma string literal que atravessa linhas, o que também é novo em P.

**Ela não gera um byte.** Vai para a árvore, e o back end nunca a vê como
instrução — um binário não carrega documentação. Quem a lê é a resposta 5 do
protocolo e a IDE.

**No `--api` ela sai DEPOIS do hash**, e essa é a decisão que faz a resposta
servir para duas perguntas ao mesmo tempo:

  * *"a interface mudou?"* — o hash, que é estrutural, e que uma vírgula num
    texto de documentação não pode mudar. Quem só depende da interface não pode
    ser acordado por uma correção de português;
  * *"o que isto faz?"* — as linhas `#doc <símbolo> <texto>`, uma por símbolo,
    com a quebra de linha escapada porque o formato é de linhas e uma docstring
    de dez linhas não pode virar dez registros.

Uma consequência boa: `plangc --api` já é o alimento do `ppack doc` e do gerador
de site, sem nenhum formato novo.

**Uma coisa que ficou de fora, e é decisão sua:** um PROTÓTIPO não tem corpo,
então uma função declarada num `.ph` não tem onde pôr a docstring dela — e o
`.ph` é justamente onde a interface mora. A forma que caberia é um corpo com a
docstring e nada mais:

    def area(w: i32, h: i32) -> i64:
        """A área do retângulo."""

Ela é inequívoca num header (onde um corpo não faz sentido) e ambígua num `.p`
(onde seria uma função vazia). Está por decidir, e é o que falta para a regra de
precedência do plano (`a docstring do .ph vence na API`) ter o que comparar.

Portão: `tests/cases/docstring.p` (as cinco posições, e a string tripla que NÃO
é docstring) e três checagens novas em `tests/protocol.sh` — a doc sai, vem
depois do hash, e NÃO muda o hash.

---

## Resposta 6: o diagnóstico como DADO

O compilador já fala uma língua só de diagnóstico —
`arquivo:linha:coluna: gravidade: mensagem [-Wgrupo]` — e há 692 casos que medem
esse TEXTO. Ele fica exatamente como está: é a referência, e mexer nele seria
trocar a coisa medida.

O que se acrescenta é um SEGUNDO destino, ligado por `--diag-json <arquivo>`: os
mesmos diagnósticos, como dado, para quem os CONSOME em vez de os ler. A IDE
quer sublinhar a coluna certa sem reparsear texto; o `ppack` quer contar e
agrupar. Nenhum dos dois devia ter de escrever uma expressão regular para uma
informação que o compilador tem estruturada na mão.

Três detalhes decidem se isto serve ou não:

  * **o arquivo é escrito também antes de um `exit` por erro.** Um diagnóstico
    que mata a compilação é justamente o que a IDE mais quer, e perdê-lo por o
    processo ter saído seria o único caso que não pode falhar.
  * **sem diagnóstico nenhum sai uma lista VAZIA**, e não a ausência de arquivo.
    "Não houve aviso" é uma resposta, e quem consome tem de a distinguir de "o
    compilador nem chegou a correr".
  * **a mensagem é escapada de verdade.** Uma aspa dentro de uma mensagem de
    erro é comum (`'x' is not declared`), e um JSON que quebra na primeira delas
    seria pior que nenhum.

Uma consequência de forma: o texto passou a ser formatado num buffer antes de ir
para o `stderr`, para o MESMO texto poder ir aos dois destinos sem percorrer a
lista variádica duas vezes.

Portão: 7 checagens em `tests/protocol.sh`, e a paridade com o clang (155/155)
como prova de que o texto não se mexeu.

---

## A docstring de um PROTÓTIPO, e o `pass` que a torna inequívoca

Um `.ph` é feito de protótipos, e um protótipo não tem corpo onde pôr a
docstring — o que deixava a interface de um pacote sem forma de se documentar,
que é justamente onde a documentação mais serve.

A regra: **um corpo só com a docstring é um protótipo documentado**, em qualquer
arquivo. E ela não é ambígua, porque a linguagem já tem palavra para "função
vazia" — quem quer uma escreve `pass`, que é uma instrução, e por isso o corpo
deixa de estar vazio:

    def area(w: i32, h: i32) -> i64:
        """A área."""            # PROTÓTIPO documentado: não emite código

    def nada():
        pass                     # função VAZIA: emite

    def ainda_nada() -> int:
        """Por fazer."""
        pass                     # vazia e documentada (avisa -Wreturn-type)

Foi o usuário quem apontou o `pass` — e é o que transformou uma decisão travada
por ambiguidade numa regra de uma linha.

---

## `import <pui>` e `<pui/x.psc>`: o módulo pscript de um pacote

Duas grafias porque são duas perguntas: *"dá-me o pacote"* (a raiz dele, que é a
interface) e *"dá-me este módulo dele"*. A raiz é `<pacote>/<pacote>.psc` — o
módulo com o nome do pacote —, que é a mesma convenção que o nome do diretório
já usa.

O nome do espaço é o ÚLTIMO pedaço sem extensão nos dois casos: `<color>` dá
`color` e `<color/shades.psc>` dá `shades`. `as` continua a valer.

Resolução e recusa são as mesmas do `<pkg/mod.ph>`: procura nas raízes de
`--pkg-path`, na ordem, e um `<>` não achado é ERRO — nunca uma tentativa
relativa.

---

## 1.5(a): `import "x.ph"` puxa o `x.p` irmão

Nomear um arquivo passa a significar "construa o fecho dele". A regra vale para
`--out-dir` e **não** para `-o`: o contrato do `-o` é "um artefato, este nome", e
um comando que passasse a emitir vários arquivos ao lado dele estaria a quebrar o
que prometeu.

**A medida que a justifica**: `plangc --out-dir X pscript/runtime/psrt.ph` emite
os SEIS módulos do runtime. O guarda-chuva importa os sete headers das camadas, e
cada um tem o `.p` irmão. A lista de módulos do runtime que vivia dentro do
próprio compilador (a sexta cópia dela) morreu nesse mesmo dia — passou a ser uma
linha.

E uma coisa que ela NÃO resolve, dita para não se procurar em vão: o compilador
tem umbrellas cujas implementações têm outro nome (`plang.ph` declara o que
`util.p` implementa; `backend.ph` declara o que os quatro `backend_*.p`
implementam). Não há aresta de import entre eles, então nenhuma regra de fecho os
acha — e é para carregar esse tipo de conhecimento que um descritor existe.

---

## `sys.exit` com um erro pendente saía com ZERO

Um erro que ninguém apanha tinha DUAS portas para sair do programa, e só uma
delas o reportava.

`sys.exit(await f())` avalia o argumento e depois chama. Se a avaliação levantou,
o código que se ia devolver nem chegou a existir — e sair com ele era sair com
zero, isto é, com **sucesso**, sem uma linha de mensagem. Um `ppack` que morresse
a montar o grafo devolvia 0, e um arreio que só olhasse o status dizia que estava
tudo bem. Custou uma investigação nesta sessão, e teria custado muitas mais
depois.

O conserto mora no runtime, e o que ele tem de bom é ter **uma mensagem só**: o
relatório de um erro não apanhado saiu do epílogo para uma função própria
(`ps_report_exc`), e as duas portas — o fim normal e o `sys.exit` — chamam a
mesma. Duas portas, um relatório.

O caminho normal não muda: `sys.exit(0)` continua a devolver o número pedido, que
é o que faz uma ferramenta de linha de comando ser usável dentro de um script.

Portões: `tests/pscript/run/exit_erro.psc` (o caminho normal e o erro apanhado) e
`exit_erro_mata.psc` (o par: a mensagem com a pilha, e o status 1 — com um
arquivo `.exit` a cobrar o status).

---

## Os braços do executor: de uma CADEIA para um pool plano

A primeira forma tinha cada braço a multiplicar-se e depois a esperar pelos
filhos. Com `-j 8` isso não dava oito braços lado a lado: dava uma CADEIA de
esperas aninhadas — treze `pump` na pilha, cada um à espera do de baixo. E no
fundo dela alguém esperava por quem já tinha terminado: o programa morria com
"deadlock: awaiting a task that nothing can finish" **depois de imprimir todas
as arestas como verdes**.

O conserto de contar o braço ao ser CRIADO (e não quando ele começa a correr)
resolveu o limite, mas não a cadeia. A forma certa é a que todo executor usa: um
POOL PLANO. N braços iguais, criados de uma vez, cada um a tirar da fila até não
haver mais nada em voo.

Um braço que não acha trabalho tem de distinguir duas coisas que se parecem: o
build acabou, ou alguém ainda está a correr e vai destrancar mais arestas. É o
que o contador `rodando` responde. Quando há trabalho em voo, o braço ocioso
espera um milissegundo e olha de novo — é o preço de não ter sinalização, e ele
só se paga quando um braço está PARADO.

Medido depois: `-j 8` e `-j 16` sem travar, `make build` em 70 s e
`make pverify` em 5m27 com `-j nproc`.

---

## A resposta 5 de um módulo pscript sai da PRÓPRIA linguagem

A API de um `.psc` era calculada sobre a árvore BAIXADA, e isso trazia três
coisas que não são a interface de ninguém: o prelúdio e os módulos importados
(que a baixa funde no módulo), um `struct` de quadro por `async def`, e toda
assinatura com um `*PsCtx` na frente e `*PsStr` no lugar de `str`.

Duas consequências, e a segunda é a séria:

  * `ppack doc` mostrava o C, e não o pscript — o que faz a documentação de um
    módulo pscript ser quase inútil;
  * **o hash de interface mudava quando o RUNTIME mudava.** A pergunta que a
    resposta 5 existe para responder — "a minha interface mudou?" — respondia
    errado, e um consumidor que dependesse dela seria acordado por uma edição
    no coletor.

Agora há um dumper por linguagem, e o do pscript lê a árvore da própria
linguagem: `record Rect {x: int, y: int, w: int, h: int}`,
`async def tarde(int) -> list<str>`, `private` fora. É uma cópia rasa do módulo
tirada ANTES da sema — a interface de um módulo é o que ELE declara, não o que
ele vê.

Portão: nove checagens em `tests/protocol.sh` — o record, a assinatura, o
`async`, o `private` que não sai, os quatro ruídos que não podem vazar
(`Category`, `PsCtx`, `PsStr`, `__frame`), a docstring, e a invariância do hash.

---

## A base escreve-se: `0o`, `0b`, `_`, e o zero à esquerda que sai

Em C um zero à esquerda é octal e ninguém o vê: `0755` vale 493 em silêncio.
Esta é uma linguagem de sintaxe Python, e o Python fechou essa armadilha por
uma razão. Então, nas duas linguagens (o lexer é partilhado por `LexSpec`):

  * `0o755` e `0b1010` existem;
  * `1_000_000` e `0xff_ff` também — o separador é do LEITOR;
  * `0755` é ERRO, e a mensagem diz como se escreve octal. `09` diz outra coisa,
    porque `0o9` não existe.

O texto do token é normalizado para DECIMAL na hora de lexar, e isso não é
arrumação: é o texto do token que sai no C gerado e que o back end QBE lê, e
`0b` não é C. Um só lugar converte, e os dois lados recebem um número que ambos
entendem.

## O prelúdio é da LINGUAGEM, logo é de todo MÓDULO

Ele é prependido ao módulo de cima, que é onde o shadowing da 68.3 se decide — e
isso punha os nomes dele só no namespace da raiz. Um módulo importado que
escrevesse `error(msg, VALUE)` ouvia que `VALUE` "pertence ao módulo sendo
compilado, que este não importa". Ninguém importa o prelúdio: era a mensagem
certa para a pergunta errada.

## O que levanta no meio de uma instrução não pode deixar rasto

`xs.append(item as str)` dentro de um `try`, com um `item` que não é `str`,
deixava a lista com um elemento a mais apontando para o que a chamada devolveu
DEPOIS de falhar. O segfault aparecia na leitura seguinte, longe do `catch`.

Duas coisas faltavam, e são a mesma ideia:

  * `value_first` só tirava o valor para fora quando ele ALOCAVA (por causa do
    coletor). Agora também quando ele pode LEVANTAR — em ambos os casos o lugar
    de destino só se pede depois de o valor existir;
  * o teste de exceção sai no fim da instrução (49.2), e dentro de um `try` ele
    só baixa a bandeira e cai para a frente. O que vem depois dele NA MESMA
    instrução tem de ficar debaixo da bandeira.

## `from <pkg/mod.psc> import x`

Faltava, e era assimetria sem razão: `import <pkg/mod.psc>` já existia, e um
pacote cujos nomes só se alcançam por um lado obriga a qualificar tudo. Um
módulo em P entra INTEIRO (`import <pkg/mod.ph>`), porque o que dele atravessa é
decidido pela 45.5 e não por uma lista de nomes.

## A TABELA DE CAMPOS, e o que cai dela

O que o compilador sabe e o runtime não: os NOMES dos campos e o que cada um é.
Sem isso, cada `repr` é uma função gerada POR TIPO, e o C emitido cresce com o
número de tipos em vez de com o tamanho do programa.

O descritor de cada `struct` e de cada `record` passa a carregar
`fields`/`nfields`/`at`, e um `PsTy` estático descreve cada tipo distinto que
aparece num campo. Três decisões de implementação:

  * **o endereço de um campo vem de uma FUNÇÃO gerada** e não de um `offsetof`
    na tabela: `offsetof` num inicializador estático é das poucas coisas que o
    back end QBE não dobra (a mesma razão por que o `size` do `PsShape` é
    enchido no arranque), e uma função é expressável nos dois sem primitiva
    nova. É também o que faz um `record` — que não tem cabeçalho — andar pelo
    mesmo caminho;
  * **o par PsTy/PsDesc é um CICLO**, desfeito com uma atribuição no arranque em
    vez de uma declaração antecipada de um `const`;
  * **o `to_str()` do tipo mora no descritor**, num embrulho de duas linhas e
    não num ponteiro de função convertido.

Dela caem, sem gerador nenhum atrás:

  * **`repr` como dado** — saída IDÊNTICA AO BYTE à da forma gerada, que é a
    prova de que a troca não mudou a linguagem. O `to_str` do tipo ganha agora a
    QUALQUER profundidade (a forma gerada só sabia disso no topo). Uma tupla
    dentro de um contentor ainda usa o adaptador gerado, porque ela vira um
    `record` e imprime-se `(a, b)` e não `Nome(_0=...)`;
  * **`json.stringify`** — byte a byte igual ao `json.dumps(separators=(',',':'))`
    do python nos casos do teste. As diferenças em relação ao `repr` são
    decisões: um `to_str` NÃO manda aqui (JSON é dado), um enum viaja pelo NOME,
    um conjunto vira ARRAY, e o que não atravessa LEVANTA com o CAMINHO onde
    parou;
  * **o post-mortem** — com `-g`, cada moldura da pilha imprime o que estava em
    cada variável. Os valores são copiados no RAISE (no relatório a pilha já
    desenrolou) e como REFERÊNCIAS (renderizar no raise seria formatar um grafo
    a cada erro). O nome e o tipo são estáticos por moldura e só saem com `-g`.

Custo MEDIDO: +1,4 % no `ppack.c` e +2,6 % no `app.c` do editor, contra um alvo
de 5 %. gc-stress 128 ok.

## `os.exec`: o programa PASSA A SER o processo

`os.run` cria um filho e espera; `os.exec` não volta. A diferença importa numa
coisa só, e essa coisa é tudo: um filho tem a saída CAPTURADA, então não pinta a
tela, não lê o teclado, não sabe o tamanho do terminal e não recebe Ctrl-C.
Depois da troca não há "depois" — mesmo PID, mesmos descritores, mesmo terminal
—, e por isso o que estiver por escrever é esvaziado ANTES.

## Duas mensagens que diziam a verdade sobre nada

  * **faltar a palavra numa chamada byref** (`f(x)` onde o parâmetro é `in x`)
    dava "incompatible types in assignment (scalar from 'Fe')" — verdade, e
    inútil. Agora diz qual parâmetro e qual palavra, e passar `&x` à mão continua
    a valer;
  * **um `out` preenchido campo a campo** era avisado como "nunca atribuído": o
    analisador via `r = ...` e não via `f(out r.X)`.

## `implement X`: quem DECLARA o tipo é quem o materializa

`implement` emite os corpos que o `.ph` declarou, com ligação externa. Dois
pacotes que precisassem da fronteira do pscript ao mesmo tempo materializavam
ambos o `CStr`, e o linker queixava-se de `CStr_at`: uma mensagem sobre um
método de acesso, a falar de um problema de arquitetura. A regra é uma linha, e
a 1.5(a) faz o resto sozinha.

## `os.spawn` / `os.kill` / `os.alive`: o terceiro caso de correr um programa

`os.run` cria um filho e ESPERA; `os.exec` VIRA o filho. Faltava o do laço de
desenvolvimento: LANÇAR, deixar correr, e mais tarde matar para relançar.

O que volta é o **PID e não um objeto**, e isso é decisão: um objeto vivo num
runtime com coletor levanta a pergunta do que acontece quando ele é recolhido
com o filho ainda a correr, e a resposta certa para essa pergunta não é óbvia.
Três funções sobre um número não têm essa pergunta — e o número é o que o
sistema operativo já usa. O preço, dito: um PID é reutilizável, e depois de
`os.alive` devolver False o número não vale mais nada.

Duas coisas que a implementação tem de fazer e que não se veem na assinatura:

* o sinal é **SIGTERM**, que é um pedido. Um `SIGKILL` não deixa o programa
  fechar o que tinha aberto, e um laço que corrompe um arquivo a cada salvar é
  pior do que um que espera meio segundo;
* `os.alive` **COLHE** o que já morreu (`waitpid` com `WNOHANG`). Sem isso cada
  programa lançado deixava um zumbi, e um laço que relança de dez em dez
  segundos enche a tabela de processos numa tarde.

## Aspas triplas: o corpo é o corpo

`"""a "b c" d"""` saía como `a  d`, e a distância entre o defeito e o sítio onde
ele mora é o que o torna interessante.

O lexer estava certo desde o princípio: ele guarda as seis aspas e tudo o que
está entre elas, e é o único literal que pode conter uma quebra de linha crua.
Quem errava era o decodificador — `str_lit_decode`, o mesmo para as duas
linguagens e para o front end de C —, que implementa uma regra do C: **literais
adjacentes concatenam-se**, `"a" "b"` é `ab`, e portanto TODA aspa é uma
fronteira. Aplicada ao corpo de uma string tripla, essa regra corta-o em cada
aspa interna e cola os pedaços que sobram.

Duas coisas ficam ditas, porque a correção depende das duas:

* **a regra da concatenação é do C e só do C.** O pscript não a tem (`"a" "b"`
  é erro de sintaxe lá), e o P herda-a por escrever C. Uma string tripla nunca
  participou dela;
* **a tabela de escapes é UMA.** Ela saiu para uma função que os dois caminhos
  partilham — um literal do C pára na aspa dele, uma tripla pára onde o lexema
  acaba — porque duas tabelas separadas divergem no dia em que alguém
  acrescentar um escape a uma delas e esquecer a outra.

O defeito apareceu a escrever uma folha de estilo dentro de uma docstring:
`"Segoe UI"` chegava ao HTML como nada. Um lugar improvável, que é onde estes
costumam estar — o corpus de testes da linguagem não tem CSS.

## `os.run(console=True)`: a ausência de captura

O `pool = console` do ninja existia no nosso grafo como palavra: o campo estava
lá, a exportação para ninja escrevia-o, e o executor ignorava-o. Faltava a
metade de baixo, e ela não é "capturar de outro jeito" — é **não capturar**.

Sem cano: o filho herda os descritores deste processo. É a diferença entre um
programa que imprime e um programa que pinta a tela, lê o teclado, sabe o
tamanho da janela e recebe Ctrl-C — a mesma diferença que o `os.exec` já tinha
tornado nítida do outro lado.

Três decisões que a implementação obrigou a tomar, e que valem para quem
escrever a próxima:

* **`console=` e `stdout=` juntos são recusados na sema.** São duas ordens
  contrárias sobre o mesmo descritor, e escolher uma delas em silêncio é o tipo
  de gentileza que custa uma tarde;
* **o evento sai com a saída vazia**, e não com uma paráfrase. O que o programa
  imprimiu já foi visto por quem estava a olhar; inventar um texto aqui seria
  repetir o que o utilizador leu;
* **quem serializa é o EXECUTOR, não o runtime.** A captura existe no resto do
  build para impedir que dois trabalhos costurem as linhas um do outro (o achado
  da 107); sem captura, a única forma de manter essa propriedade é não haver
  dois ao mesmo tempo. São três linhas na função que escolhe a próxima aresta —
  e o runtime não precisa de saber que existe um grafo.
