# A arquitetura, de cima (proposta — 2026-08-22)

Este arquivo não decide nada: ele desenha o que as decisões de
`pbuild/DESIGN.md` e `ppack/DESIGN.md` já implicam, e isola o que **ainda não
está decidido** no fim. É o mapa para conversar sobre o todo em vez de sobre uma
peça.

## O princípio, numa frase

**Cada peça faz uma coisa, e a fronteira entre duas peças é uma pergunta.**

```
plangc  RESPONDE   o que li · o hash de cada interface · o que vou emitir · quem sou · a API pública
pbuild  DECIDE     o que está velho · em que ordem · com quantos processos · e roda
ppack   RESOLVE    que versão · de que repositório · com que hash · e materializa
```

E o transporte entre elas é o da 1.8: **chamada quando é o mesmo processo,
arquivo quando não é.** Nenhuma das três aprende o vocabulário da outra — o
compilador nunca ouve "versão", o executor nunca ouve "semver", o resolvedor
nunca ouve "mtime".

## As peças, a linguagem de cada uma, e por que isso importa

| peça | escrita em | tem runtime? | como nasce numa máquina limpa |
|---|---|---|---|
| **plangc** | P | **não** — zero runtime, é a promessa da linguagem | seed de C comitado: **50 773 linhas** em `bootstrap/` |
| **pbuild** | pscript | **sim** — 6 módulos e um coletor | ? (é a pergunta A) |
| **ppack** | pscript | sim (vive dentro do pbuild) | idem |
| **QBE** | C, ~18 mil linhas, de terceiro | não | hoje binário externo; a forma (2) o compila com o nosso front end |
| **linker** | P (seria) | não | junto do plangc |

O número que decide a pergunta A está aí: **o seed hoje são 50 773 linhas de C**,
e o C do runtime do pscript são 8 297. Enfiar o pbuild dentro do `plangc` levaria
o bootstrap para a casa das 75 mil linhas **e faria o compilador runtime-free
carregar um coletor de lixo**. Não é impossível; é caro no lugar mais sensível que
este projeto tem.

## O desenho em camadas

```
        você digita:  plang build | plang run x.psc | plang add json | plang publish
                                  │
        ┌─────────────────────────┴──────────────────────────┐
        │  a interface de linha de comando (uma, coerente)   │
        └─────────────────────────┬──────────────────────────┘
                  ┌───────────────┴───────────────┐
                  │                               │
            ppack (resolve)                 pbuild (decide)
         manifesto+lock, repos,        descritor: build.psc  ─┐
         SHA-256, índice assinado      executor: grafo, fila  │
                  │                               │           │
                  └────────► árvore de pacotes ───┘           │
                             + caminho de busca               │
                                                              ▼
                                        plangc (responde e compila)
                                        front ends: C · P · pscript
                                        back ends:  C · QBE (+linker, depois)
                                                              │
                                   ┌──────────────────────────┴─────────┐
                                   │  armazém endereçado por conteúdo   │
                                   │  pacotes · objetos · binários      │
                                   └────────────────────────────────────┘
```

## O arquivo de build, e quem constrói o construtor

O descritor é um **programa pscript** (`build.psc`) que usa a biblioteca do
pbuild — a forma do `build.zig`, e a que já decidimos. A pergunta óbvia
("compilar o build a cada build custa os 3,32 s do frio?") tem resposta que o
próprio Ninja já deu e que eu li no samurai: **o descritor é uma aresta do
grafo, marcada `generator`** — e uma aresta `generator` não fica suja quando o
comando muda, só quando a fonte muda. Então:

1. o `build.psc` é compilado **uma vez** e o binário dele fica no armazém;
2. builds seguintes reusam esse binário (0,006 s, medido no `run` quente);
3. mexer no `build.psc` reconstrói o construtor e depois o projeto — e é a mesma
   escada `seed → s1 → s2` que este repositório já sabe fazer com o compilador.

O ovo e a galinha se resolve com **uma receita fixa dentro do pbuild** para
construir o descritor (compilar com o `plangc`, linkar, rodar). É o que o meson e
o cargo fazem, e é a única parte do sistema que não é um grafo.

## O ciclo completo de `plang build`

```
1. RESOLVER   ppack    manifesto + lock → repos (arquivo/http/ftp) → SHA-256 → índice assinado
                       → árvore de pacotes materializada + caminho de busca
                       ─────────── daqui para frente, ZERO rede ───────────
2. DESCREVER  pbuild   roda o build.psc (do armazém) → grafo em MEMÓRIA (1.8)
3. PLANEJAR   pbuild   pergunta ao plangc, por raiz: o que lê · o que emite ·
                       hash de cada interface · quem ele é → nós e arestas
4. DECIDIR    pbuild   os 6 testes do ninja · restat e poda · hash de comando+env
5. EXECUTAR   pbuild   fila por caminho crítico (com a duração da última vez, 1.7),
                       N processos, saída de cada job capturada e despejada inteira
6. GRAVAR     pbuild   log local (durações, hashes) — e o lock só muda na fase 1
```

## O que este desenho já garante, e não é pouco

- **build offline por construção** depois da fase 1;
- **um pacote nunca executa código** na sua máquina (2.11) — não por confinamento,
  por vocabulário;
- **o compilador não é um build system** (o erro do `ghc --make`/`go build`), e o
  build não é um compilador (o erro do `cmake`);
- **três consumidores, um mecanismo**: o hash de interface serve sujeira, semver e
  doc; o hash do compilador serve sujeira e trava de toolchain;
- **dois backends sem dois builds**: o grafo não tem pipeline embutido, então
  `.p→.c→.o→bin` e `.p→.ssa→.s→.o→bin` (e, depois, `.p→bin`) são o mesmo motor.

## Onde o desenho ainda pode quebrar — as perguntas abertas

**A. Quantos binários?** Um `plang` que contém tudo (o custo do seed medido
acima), três binários separados, ou um lançador fino que despacha para eles (o
modelo do `git`: UX de um, arquitetura de três).

**B. O `run` é o lugar onde a nossa própria regra já está quebrada.** Hoje
`plangc run` tem cache, manifest e política de sujeira **dentro do compilador** —
é exatamente o que dissemos que o compilador não faz. Ou ele fica lá como
conveniência (e a regra tem uma exceção nomeada), ou o `run` passa a ser um modo
do pbuild (e aí a pergunta A fica carregada: o caminho JIT precisa das duas peças
no mesmo processo).

**C. O armazém é global ou por projeto?** O `plangc run` já tem um global em
`~/.cache/pscript`. Global dá reuso entre projetos e um `run` quase instantâneo;
por projeto (`out/`) é mais fácil de raciocinar, de limpar e de auditar.

**D. As 1 941 linhas de shell de teste viram o quê?** Se um teste é uma **aresta**
(rodar o binário, comparar com o `.expected`), então a sujeira por conteúdo vale
para ele também: **só re-roda o teste que alguma mudança alcança** — coisa que
nenhum harness deste repositório sabe fazer hoje.

---

## As respostas (2026-08-22)

**A — DECIDIDA: o `ppack` orquestra.** Suas palavras: *"já que o ppack é o comando
que gerencia o pacote, faz ele orquestrar também"*. Então:

- **`ppack` é o comando de cima** (o papel que o `cargo` faz), e o **pbuild é o
  motor dentro dele** — o que já era a forma decidida no `pbuild/DESIGN.md` (um
  binário, dois modos, como o muon carrega o samurai). Agora o binário tem nome e
  os modos são três: **resolver, descrever, executar**;
- **`plangc` fica fora e intocado**: P puro, zero runtime, o seed de 50 773
  linhas. O preço de juntar estava medido: ~75 mil linhas de seed e um coletor de
  lixo dentro do compilador;
- **o `ppack` tem o seu próprio seed** — o C gerado dele, comitado — que é o
  padrão que o `bootstrap/` já é para o compilador (o "pacote zero");
- **o custo desse desenho é um `exec` a mais, e ele foi medido: 1,4 ms** (100
  invocações em 0,139 s). Contra os 6 ms de um `run` quente, é ruído.

**B — SIM, o pbuild pode e deve orquestrar o cache.** Sua pergunta: *"o pbuild não
pode orquestrar cache também? porque não?"* — pode, e a razão de estar hoje no
compilador é só cronológica: o pbuild não existia. Veja o que o `run` faz hoje:

1. hash de cada fonte que leu · 2. hash dos bytes do próprio compilador ·
3. chave → binário no armazém · 4. `exec`

**Os três primeiros são exatamente o que o pbuild vai fazer para toda aresta**, e
o quarto é trabalho do comando de cima. Não há mecanismo novo aqui: há mecanismo
**duplicado**, dentro do compilador. Passá-lo ao pbuild mata a sexta lista (o
`RT_SRCS` dentro do `main.p`) e custa 1,4 ms.

Fica um caso pendente, pequeno e real: `run` de um script que **não está dentro de
projeto nenhum** — sem manifesto e sem pasta de build. É a pergunta C′ abaixo.

**C — DECIDIDA: nada é global; a pasta de build é especificada.** Suas palavras:
*"lembra que o venv do python foi um problema? então acho que nada é global por
ora"* — e a pesquisa do ppack diz o mesmo no ponto 3 (*isolamento por projeto por
padrão, nunca opcional; o pip levou vinte anos*). Então pacotes baixados,
objetos, binários e veredictos vivem **na pasta de build do projeto**.

Medido para dimensionar a escolha: um build completo do compilador em disco são
**3,5 MB** no caminho C (**16 MB** no caminho QBE, por causa dos `.s`), e o cache
de um `hello.psc` são **716 KB** — porque leva o runtime inteiro junto. Por
projeto é barato. E um armazém compartilhado, se um dia fizer sentido, é
**comando explícito**, nunca padrão: é literalmente a lição que a pesquisa tira
do pip.

**D — não falta um orquestrador; falta um TIPO DE NÓ.** Sua pergunta: *"será que na
nossa stack falta alguém pra orquestrar testes?"*. Um executor de testes faz
quase exatamente o que o nosso já vai fazer — paralelismo, sujeira, captura de
saída, relatório. O que ele tem a mais são três coisas, e só **uma** é mecanismo:

| o que um test runner tem | é peça nova? |
|---|---|
| comparar a saída com o `.expected` | **é um nó de VEREDICTO**: um predicado sobre a saída, não um artefato. É o que falta |
| relatório agregado (passou/falhou, com diff) | não — é do comando de cima, como o placar de hoje |
| "rode mesmo sem mudança" (caçar teste intermitente) | não — é uma flag na aresta |

O nó de veredicto é o que destrava o ganho de verdade: **um veredicto é
cacheável** (o Bazel faz isso), então **só re-roda o teste que a mudança
alcança**. Hoje um comentário no `util.p` re-roda 113 programas `.psc`.

O que o nosso grafo não sabe, então, é uma coisa só: **ele só conhece arquivos.**
Acrescentar veredicto é o que falta na pilha — não um quarto binário.

## A′, C′, D′ e E — DECIDIDAS (2026-08-22)

**A′ — o comando é `ppack`**: `ppack build`, `ppack run`, `ppack add`,
`ppack test`. O nome da peça que orquestra é o nome que se digita.

**C′ — a pasta de build é local, e configurável na linha de comando.** Dentro de
projeto ela é a do projeto; para um script solto, ela nasce ao lado do script — e
quem não quiser isso passa a pasta por opção (num diretório somente-leitura, ou
para mandar tudo para `/tmp`, ou para compartilhar entre dois checkouts de
propósito). O padrão é local e explícito; o global só existe se alguém digitar.

**D′ — teste sempre roda; veredicto não é cacheado.** É a escolha que nunca
mente: um teste cujas entradas foram declaradas errado não passa a "passar por
cache". O que o grafo ainda dá para os testes, e é a maior parte do ganho:

- **ordem** (construir antes de testar, sem ninguém escrever isso à mão);
- **paralelismo** com o mesmo executor e o mesmo limite de processos;
- **saída capturada inteira** por teste — que é justo o que a 107 achou quebrado
  no `print` de workers concorrentes;
- e o relatório agregado no comando de cima.

O que se abre mão: a suíte continua proporcional ao tamanho do repositório, e não
à mudança. A porta fica aberta — cachear veredicto depois é uma **flag**, não um
redesenho, porque o nó de veredicto existe de todo jeito (é ele que sabe comparar
saída com `.expected`); ele só nasce sempre sujo.

**E — a árvore de pacotes é extraída uma vez no armazém da pasta de build**, em
`build/pkg/<nome>-<versão>-<hash>/`, e o caminho de busca do `plangc` aponta para
lá. Sem cópia por alvo, sem link simbólico (caminho relativo dentro de link é
fonte clássica de bug de `include`), e **o hash no nome torna "a mesma versão com
conteúdo diferente" impossível de confundir** — que é exatamente o furo que a
pesquisa aponta no `requirements.txt`.

---

## O pstudio por cima (2026-08-22)

Suas palavras: *"o pstudio vai ficar por cima (nada vai depender dele, mas ele vai
depender das outras ferramentas, talvez até compilando junto). Ele vai orquestrar
tudo, vai ter um botão de play (igual o NetBeans, que tem uma toolbar com um play e
uma vassoura), configuração de build etc — uma IDE integrada."* E: *"partes do
pstudio vão virar pacotes, como a lib de UI."*

Isso acrescenta uma camada e **fecha dois laços de uma vez**:

```
pstudio   (IDE: play, vassoura, configuração)   ← nada depende dele
   |
   v
ppack     (resolve, e é o comando de cima)
   |
   v
pbuild    (decide e executa)
   |
   v
plangc    (responde e compila)
```

**Laço 1 — o pstudio é o primeiro CONSUMIDOR e o primeiro PRODUTOR de pacotes.**
A lib de UI (`lib_pui.psc`, 1 145 linhas), o motor de texto (`lib_core.psc`,
1 136) e o realce (`lib_hl.psc` + `hl.p`) virando pacotes significa: um pacote
**pscript que depende de um pacote P** (o shim de SDL) — que é exatamente o caso
que eu medi quebrado (o `import "hl.ph"` dentro de um módulo pscript importado não
puxa nada). Ou seja: **a 1.5(d) não é higiene, é o que destrava a lib de UI virar
pacote.**

**Laço 2 — o `build.psc` ser um PROGRAMA e o manifesto ser DADO ganha o seu
melhor argumento agora.** A tela de "configuração de build" da IDE precisa
**editar** o que ela mostra. Um manifesto declarativo se lê e se reescreve sem
risco; um programa, não — nenhuma IDE do mundo edita um `build.zig` com
segurança. A decisão de dois arquivos passa a ter dois donos naturais: o
**manifesto é do painel**, o **descritor é do programador**.

**E "talvez até compilando junto" é o caso que a 1.8 já previu.** Se o pstudio e o
pbuild são os dois pscript e viram um binário, o botão de play não *invoca* um
build: ele **chama** o descritor e o executor no mesmo processo, e recebe o grafo
como `dict` — sem serializar, sem parsear texto, sem processo intermediário. Era
literalmente a opção (b) da 1.8: *memória quando é a mesma execução, arquivo
quando não é.*

Duas coisas que já estão decididas e que servem a IDE sem mudança:

- **a saída de cada aresta é capturada inteira** (1.2/1.6c) — para um painel de
  build isso é melhor que streaming: cada aresta chega completa, e nada se
  intercala com nada;
- **`ppack dev`** (reconstruir e reiniciar) é o botão de play com o programa
  rodando, e o `EVFILT_VNODE`/`inotify` entra no laço de eventos que o editor já
  tem girando para o teclado e a tela.

## As quatro da camada IDE — DECIDIDAS (2026-08-22)

**Em processo: um binário, o grafo como `dict`.** E isso força uma clarificação
que vale mais que a decisão em si:

> **O pbuild é uma BIBLIOTECA. O `ppack` e o `pstudio` são as suas duas frentes.**

Consequência dura e boa: **a biblioteca não pode imprimir.** Nada de `print` para
o terminal dentro do motor — ela **relata eventos** (aresta começou, terminou,
falhou, com a saída capturada) e quem decide o que fazer com eles é a frente: a
CLI imprime, a IDE pinta. É o que separa um motor reutilizável de um script com
`print` no meio, e é fácil errar isso na primeira linha.

**Diagnóstico estruturado: a SEXTA resposta do protocolo.** O `plangc` passa a
poder devolver diagnóstico como dado — arquivo, linha, coluna, gravidade,
mensagem, e o grupo `-W` que o sistema de avisos já calcula. A IDE sublinha sem
parsear texto, e o `--json` da CLI reusa a mesma coisa.

Com um limite explícito: **o TEXTO continua sendo a referência.** A paridade com o
clang (155/155, com portão em `tests/clang-compare.sh`) e os 692 casos de
`tests/errors` medem a mensagem impressa; o JSON é uma segunda renderização dos
mesmos dados, nunca a fonte da verdade.

O protocolo, agora completo:

| # | o pbuild/pstudio pergunta | o plangc responde |
|---|---|---|
| 1 | o que você leu? | as fontes, imports transitivos incluídos |
| 2 | qual o hash de cada interface? | um hash por `.h`, da **lista canónica da API** |
| 3 | o que você vai emitir? | as saídas, antes de rodar (o `dyndep` sem arquivo) |
| 4 | quem você é? | o hash dos próprios bytes |
| 5 | qual a API pública e a doc? | símbolos, assinaturas, docstrings (2.6) |
| 6 | **quais os diagnósticos?** | **arquivo, linha, coluna, gravidade, grupo `-W`** |

**Workspace: pacote local por caminho, sem publicar.** `pui = { path = "..." }`, e
o resolvedor trata o diretório como pacote resolvido. Duas consequências a
anotar: (a) o hash de um pacote por caminho é o **hash do conteúdo do diretório**
— lista ordenada de arquivos mais o hash de cada um, e o `os.listdir` da 111 já
ordena de propósito; (b) **publicar um pacote que tem dependência por caminho tem
de ser recusado** (ou reescrito para versão), senão publica-se algo que só compila
na máquina do autor — é o erro que o cargo trata como erro.

**A vassoura apaga saídas e mantém os pacotes.** `build/obj`, `build/bin` e o log
somem; `build/pkg` fica, porque foi verificado e está no lock — apagá-lo custa
rede para nada. É o que a vassoura do NetBeans faz: limpa o que o build produziu,
não o que você buscou.

## Mais quatro (2026-08-22)

**Eventos: ciclo de vida da aresta e o total, nada mais.** `plano_pronto(total)`,
`aresta_iniciou(id)`, `aresta_terminou(id, status, saída, duração)`, `fim(ok,
falhas)`. Contrato pequeno é contrato que dá para mudar. O motivo da sujeira e o
grafo a frente pede quando quiser (o `--explain` é consulta, não evento).

**`ppack publish` empacota, assina e RECUSA.** Tarball do fonte, SHA-256,
assinatura do autor, entrada de índice com a lista canónica da API — e recusa em
três casos, todos de graça porque o mecanismo já existe por outro motivo:
dependência por caminho, `.psc` dentro de pacote declarado P, e "minor" cujo hash
de API mudou.

**Doctest: sim, e os exemplos viram testes da suíte.** A docstring já vai para o
JSON (2.6) e um teste já é uma aresta do grafo — então "exemplo que não compila há
três versões" deixa de existir sem mecanismo novo.

**Paralelismo: número de núcleos.** Com a ressalva medida: aqui, com 8 núcleos, o
build satura em ~4 porque o caminho crítico é **um** arquivo (4,96 s de 5,0 s). O
padrão ótimo é do projeto, e núcleos é o chute honesto.

## pstudio como servidor, e se isso me serve (2026-08-22)

Sua pergunta: *"podemos usar o próprio pstudio como um servidor, até para você
mesmo depurar pacotes e código? Tem a http para fazer uma API. Não sei se seria
útil pra você."*

Resposta honesta: **o HTTP não é a parte útil para mim.** O que me custa tempo
neste repositório é medível e é outra coisa:

- **os 2,5–3,3 s de compilação fria** em cada sonda que eu escrevo (medido nesta
  investigação, várias vezes);
- e **ter de rodar três ou quatro comandos** para descobrir o que uma resposta
  estruturada diria de uma vez. O caso do `hl.h` foi exatamente isso: rodei o
  `plangc` duas vezes e um `find` para descobrir o que ele emitia — a **pergunta
  3 do protocolo** ("o que você vai emitir?") responde em uma chamada.

Ou seja: as duas coisas que me ajudam já estão decididas, por outros motivos — o
**armazém quente** e o **protocolo com `--json`**. E o meu API universal é o
**shell**: toda ferramenta que eu tenho é `bash`, então uma CLI que responde em
JSON vale mais para mim que um servidor que eu teria de subir, manter vivo entre
chamadas e checar se está de pé.

**Onde um servidor ganha o lugar dele** — e são três usos reais, só não são sobre
mim:

1. **Protocolo de DEPURAÇÃO.** Inspecionar um programa **parado**: ponto de
   parada, pilha, variáveis. A infraestrutura existe pela metade — o `-g` põe
   frame em toda função pscript e a shadow stack já carrega a pilha
   (`psrt_types.ph:194`). Isso serve o painel de debug da IDE **e** a linha de
   comando — e este é o único que eu usaria de verdade, porque hoje depurar
   pscript é acrescentar `print` e recompilar (3,3 s cada vez);
2. **pstudio no navegador.** A pilha HTTP daqui não é caseira no sentido ruim: foi
   conferida contra o llhttp (202/202) e o parser de URL contra o WPT (890/891).
   Uma IDE que abre no navegador é produto, não gambiarra;
3. **build remoto** para a IDE de outra máquina. Depois.

E uma cautela que vale escrever: **um servidor de vida longa segurando compilador
e coletor é uma classe nova de bug** (cache velho, memória crescendo, dois builds
no mesmo processo). Como o armazém torna um processo novo quase grátis, o servidor
deve ser **frente, nunca autoridade** — o mesmo princípio de "a biblioteca não
imprime".

## Reflexão em pscript (2026-08-22) — DECISÃO DE LINGUAGEM, a migrar para `pscript/DESIGN.md`

*Registro aqui porque nasceu desta investigação; o lugar definitivo é uma bateria
própria em `pscript/DESIGN.md`.*

Sua pergunta: *"se o compilador conhece o tipo em tempo de compilação e os membros
das estruturas, ele pode entregar a estrutura do dado para o runtime quando for
pedido — um record é grátis. Isso seria uma espécie de reflexão, e o json poderia
já ser parte do runtime para a maioria dos tipos. Aí qualquer saída em json vira
trivial, né?"*

**Sim — e o mecanismo já existe pela metade.** O runtime tem:

```
struct PsDesc:                       # psrt_types.ph
    name: const *char                # o NOME do tipo já está aqui
    trace: def(o: *void, to: *PsBlock)   # "o compilador escreve, porque só ele
                                         #  conhece os campos"
struct PsUser:                       # todo struct do usuário começa assim
    obj: PsObj
    desc: const *PsDesc              # e carrega o descritor
```

Medido no editor portado: **38 descritores, ~470 linhas de 24 601 (1,9 %)**.

**DECIDIDO: o `PsDesc` ganha tabela de campos** (nome, deslocamento, tipo), para
**todo** tipo — o compilador já calcula isso para poder emitir o `trace`.

**DECIDIDO: a tabela lista só o PÚBLICO.** E aqui está a convergência que fecha
três decisões numa:

> **a tabela de campos públicos = a lista canónica da API = o que entra no hash de
> interface.** Um artefato serve reflexão (json, repr, depuração), verificação de
> semver (o que mudou na API) e sujeira de build (recompilar só quando a interface
> muda). Uma noção de "público" para tudo.

O `trace` do coletor continua cobrindo **todos** os campos de referência,
inclusive privados — mecanismo separado, intocado.

E o seu "um record é grátis" tem uma precisão que vale registrar: um `record` é
**valor sem cabeçalho**, então não tem ponteiro para descritor. Para ele a
reflexão é **estática** (o compilador injeta o descritor no sítio da chamada,
onde ele sabe o tipo); para `struct` coletada é **dinâmica** (o descritor já está
alcançável pelo objeto). Dois caminhos, e é por isso que o record não paga nada.

**DECIDIDO: `--json` em todos os comandos que produzem informação** — se
serializar é uma chamada, cada comando não paga nada por isso, e a CLI passa a ser
a API da IDE, do CI e minha, sem servidor nenhum.

**DECIDIDO: o `repr` passa a ser dado** — uma implementação do runtime percorre a
tabela, em vez de uma função gerada por tipo.

Com uma ressalva que a evidência impõe, não o gosto: **o escape já existe e já tem
teste.** Em `tests/pscript/run/repr.psc` o `struct Money` define `to_str(self)` e
`print(Money(250))` imprime `$2` — está no `.expected`. Então "uma implementação lê
a tabela" tem de significar *derivado por padrão, `to_str` vence quando existe*,
senão o teste quebra. É o modelo do Python (`__repr__`) e do Rust (`Debug`
derivado ou manual), e aqui já está meio implementado.
