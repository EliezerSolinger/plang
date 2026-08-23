# pbuild / ppack / pstudio — plano de execução

**Este arquivo é o ponto de retomada** (o mesmo contrato do `pscript/PLAN.md`):
quem retomar lê ESTE arquivo primeiro, depois `pbuild/DECISOES.md` (uma linha
por decisão, com as medições) e só então os DESIGNs. As caixas se atualizam
AQUI, no mesmo commit lógico do trabalho.

Três regras que valem para o plano inteiro:

1. **Regra de pronto de toda fase**: `make verify` 8/8, seed regenerado quando o
   compilador mudou, este arquivo atualizado. Uma caixa só fecha com teste que
   prende o comportamento.
2. **Decisão nova é do usuário.** O plano implementa o que está em
   `DECISOES.md`. Cada fase tem uma tabela de **decisões finas** — miudezas que
   os documentos não fixaram (nome de flag, formato de arquivo). Elas são
   perguntadas (AskUserQuestion) **no início da fase**, em lote, nunca
   inventadas no meio do código.
3. **Enquanto `ppack verify` não der 8/8, o Makefile é a verdade.** As duas
   coisas convivem; a troca acontece de uma vez (F3), nunca aos poucos.

---

## DIÁRIO DE EXECUÇÃO (o que sobrevive à compactação)

**2026-08-22, madrugada — sessão autônoma.** O usuário mandou executar o plano
sozinho. Estado encontrado e restrição que ele impõe:

> **OUTRO AGENTE ESTÁ ATIVO NO REPOSITÓRIO.** Conferido por relógio e por
> processo: `backend_p.p` e `backend_c.p` modificados às 04:20, uma suíte
> completa rodando (`run.sh cases modules stl p-suite errors pscript roundtrip`)
> e um `plangc2` compilando. Arquivos que ELE está mexendo agora:
> `selfhost/{ast.ph, lexer.p, parser.p, sema.p, backend.p, backend_c.p,
> backend_p.p}` — o front/back end do P (parece f-string em P, 65.2, ainda
> incompleta: `printf(f"x={x}")` não parseia).
>
> **Regras que eu me imponho por causa disso** (e que valem para quem retomar
> enquanto os dois estiverem no mesmo repo):
> 1. **não editar arquivo que ele está mexendo** — conferir `git status` ANTES
>    de tocar em qualquer `selfhost/*`;
> 2. **não rodar a suíte inteira** — duas execuções brigam pelo `tests/out` e
>    corrompem o resultado das duas (aconteceu; o log ficou ilegível). Testar em
>    diretório de saída próprio;
> 3. **não regenerar o seed** — o `reseed.sh` pegaria o trabalho inacabado dele;
> 4. **não comitar com `git add -A`** — só caminhos explícitos dos MEUS arquivos;
> 5. **fixar uma cópia do compilador** (`plangc` copiado para a área de
>    trabalho) para que as reconstruções dele não mudem o binário debaixo de mim.
>
> **Consequência para a ordem do plano**: F1, F5 e F7 (que mexem em lexer,
> parser, sema e backends) ficam BLOQUEADAS enquanto ele estiver ativo. F0
> (main.p, util.p, plang.ph, api.p novo), F2 (runtime `os` + `pbuild/ps/*` novo)
> e F3 (`build.psc`, `ppack` — arquivos novos) são não-colidentes e é por onde eu
> vou.

## O estado (2026-08-22, depois das suas decisões)

Dezasseis commits. O repositório constrói-se, testa-se e verifica-se a si mesmo
pelo seu próprio sistema de build, e o `Makefile` é uma casca de sessenta linhas.
Numa máquina que só tem um compilador de C:

```
make            a escada com ponto fixo, o editor e as ferramentas    84 s
make test       o corpus em C mais a suíte caso a caso               4m21  (9 s sem mudança)
make verify     a bateria inteira, 495 arestas                       5m16  (8,7 s sem mudança)
make check      compila e roda um hello-world
make doc <mod>  a interface de um módulo, com a documentação
make ninja      o build.ninja do bootstrap
make clean      a árvore como o `git clone` a entrega
```

**As quatro decisões da manhã, todas implementadas:**

1. `import <pui>` e `<pui/x.psc>` para módulos pscript de pacote;
2. a docstring de PROTÓTIPO — um corpo só com a docstring, com o `pass` a
   desambiguar (a sua observação foi o que destravou);
3. o `stl` em `packages/stl`, com manifesto, e os 23 imports do compilador a
   passarem por `<stl/x.ph>`;
4. a TROCA do Makefile.

E com elas fechou a **F1** inteira (a 1.5(a) entrou junto) e **morreram as seis
listas de módulos do runtime** que viviam espalhadas pelos arreios e dentro do
compilador: nomear `pscript/runtime/psrt.ph` traz o runtime inteiro.

**Nove defeitos consertados**, todos achados por construir de verdade: dois do
coletor, o `-j` que não limitava, os braços que formavam uma cadeia e travavam,
o `restat` que não atravessava corridas (nas duas pontas), `sys.exit` a sair com
ZERO com um erro pendente, e `a/../b` a carregar o mesmo módulo duas vezes.

**Os dois primeiros pacotes existem**: `packages/stl` (dez headers, zero `.p`) e
`packages/pui` (o toolkit do editor, 1 145 linhas, zero import), com o teste do
`pui` a viajar COM ele em `packages/pui/test/` — um pacote carrega a prova de que
funciona, e quem o instala pode rodá-la.

**O que ainda espera decisão sua**: os campos do `pack.json`, que estão
implementados como a proposta e são baratos de mudar.

**A resposta 5 de um módulo pscript** passou a sair da árvore da própria
linguagem, e não da baixa. Além de fazer o `ppack doc` mostrar pscript em vez de
C, conserta uma coisa séria: o hash de interface de um `.psc` mudava quando o
RUNTIME mudava, o que fazia a pergunta "a minha interface mudou?" responder
errado.

**Progresso** (atualizar a cada passo):

- [x] tarefas do agente criadas (9, com dependências)
- [x] **F0 — o compilador RESPONDE** (2026-08-22): `--version` (semver da
      linguagem + hash dos bytes), `--deps` (transitivo, com caminho
      normalizado), `--outputs` (sem emitir nada) e `--api` (lista canónica +
      hash). `selfhost/api.p`+`.ph` novos; funil de leitura em `util.p`;
      `dest_for`/`deps_walk` em `main.p`. Portão: `tests/protocol.sh`, 21
      checagens — inclui a INVARIÂNCIA (comentário e nome de parâmetro não mudam
      o hash) e a SENSIBILIDADE (tipo, campo, valor de enum e de const mudam).
      Regressão conferida: o C gerado é **byte-idêntico** ao de antes; cases,
      modules, stl, errors (101), p-suite (192) e roundtrip (234) verdes.
      FALTA (bloqueado pelo outro agente): regenerar o seed e rodar `verify`
      inteiro, e ligar o `protocol.sh` ao `verify-all.sh`.
- [x] **F1 FECHADA** (2026-08-22, com as decisões da manhã seguinte): 1.5(d),
      `import <>` nas duas formas, a docstring (módulo, corpo, `struct`, `enum`,
      `trait` e **protótipo**) e a 1.5(a).

      **A docstring de protótipo** deixou de ser ambígua com uma observação sua:
      quem quer uma função vazia escreve `pass`. Um corpo só com a docstring é um
      protótipo documentado, em qualquer arquivo.

      **`import <pui>` e `<pui/x.psc>`**: duas grafias porque são duas perguntas
      — o pacote (a raiz dele) e um módulo dele. O nome do espaço é o último
      pedaço sem extensão nos dois.

      **A 1.5(a)** vale com `--out-dir` e não com `-o`. A medida:
      `plangc --out-dir X pscript/runtime/psrt.ph` emite os SEIS módulos do
      runtime, e a lista deles que vivia DENTRO do compilador virou uma linha.

      A docstring rendeu na hora: `ppack doc` (abaixo) lê a resposta 5 e mostra
      a documentação no terminal, sem um segundo leitor da linguagem.

      **A docstring** existe agora nas duas linguagens, com a regra posicional
      do Python e sem palavra nova. Não gera um byte, e no `--api` sai DEPOIS do
      hash — mudar um texto de documentação não pode acordar quem só depende da
      interface. Portão: `tests/cases/docstring.p` e três checagens novas no
      `protocol.sh`.

      **`import <pkg/mod.ph>`**: o compilador recebe raízes de busca
      (`--pkg-path`, repetível) e procura nelas, na ordem — e continua sem saber
      o que é versão, que é a fronteira que `pbuild/ARQUITETURA.md` desenhou. As
      três formas (`include <>` de C, `import <>` de pacote, `import "..."`
      relativo) não se misturam, e `<>` NÃO recua para relativo. O `<>` puxa o
      `.p` irmão (a 1.5a aplicada só a ele: um pacote é uma unidade), e depois de
      resolvido vira um import relativo comum, o que faz o back end, o espelho e
      as respostas do protocolo não precisarem aprender nada sobre pacotes.
      Vale nas duas linguagens. Portão: `tests/packages.sh`, 14 checagens.

      **1.5(d)** (a parte anterior): `import "x.ph"` dentro de um
      MÓDULO importado passou a valer por inteiro: a varredura é do FECHAMENTO,
      e o `.p` irmão entra na compilação. Mora em `main.p` e não na sema, porque
      `--outputs` não roda a sema — e a resposta 3 tem de dizer o que vai ser
      emitido sem compilar nada. Medida: o descritor do editor precisava nomear
      dezanove arquivos copiados do Makefile; ficou com dois, e os dois não são
      falha de fechamento (`plang.ph` declara o que `util.p` implementa — dois
      nomes sem aresta entre si). Portão: `tests/pscript/run/import_fundo.psc`.
      Seed regenerado. A bateria está em `pbuild/BATERIAS.md`, à espera de o
      `pscript/DESIGN.md` ficar livre.
- [x] **F2A — `os.run`, `os.nproc`, `path.getmtime_ns`** (2026-08-22, commit
      af97427): `await os.run(argv, env=, cwd=, stdout=) -> proc` com
      `status()`/`output()`; sem shell (`execvp` recebe o vetor); stderr junto;
      status != 0 é resultado; 128+sinal; `waitpid` no pool; tipo `proc` novo
      (PT_PROC) com nome escrevível. Portões: os_run.psc + 3 recusas + oráculo
      contra o `subprocess` do python3; pscript 279, gc-stress 115,
      print-atomic, net-late, cases 46, pstudio 7 — todos verdes.
      A bateria 118 ficou escrita em `pscript/DESIGN.md` mas NÃO comitada (o
      arquivo carrega trabalho de outra sessão).
- [x] **F2B — o MOTOR do pbuild** (2026-08-22): `pbuild/ps/lib_graph.psc`
      (aresta gorda, três faixas, hash FNV-1a de 64 bits sobre argv+env+cwd+
      stdout+alvo, JSON ida e volta), `lib_log.psc` (mtime ns, duração, hash do
      comando e hash do CONTEÚDO; parser de depfile) e `lib_build.psc` (os seis
      testes do ninja, restat POR CONTEÚDO com poda transitiva, caminho crítico
      pesado por duração, executor com braços que se multiplicam até o limite,
      higiene com três erros, quatro eventos, `--explain` como consulta).
      Portão: `tests/pbuild.sh` + `pbuild/ps/engine_test.psc`, **31 checagens**.
      Dois defeitos consertados no caminho: `const` negativo em módulo importado
      não compilava (`ps_lower`), e `os.run` tratava `cwd=""`/`env={}` como
      valores em vez de "não foi dado" (`psrt_os`), além de o filho morrer mudo
      quando o `chdir`/`exec` falhava (`psrt_rt`).
- [x] **Dois defeitos do COLETOR, achados pelo motor** (2026-08-22): rodar a
      suíte do motor com `PSCRIPT_GC_STRESS=1` derrubou duas checagens, e as
      duas eram defeitos de verdade — antigos, silenciosos, e do tipo que só
      aparece quando uma coleta cai no meio.
      1. **`ps_alloc` não zera, e o `PsFile` faltava um campo.** Quem constrói
         um objeto do runtime tem de escrever TODOS os campos dele; a abertura
         assíncrona escrevia dois de três, e o `is_std` — o campo que diz "isto
         é o stdout, fechar não faz nada" — ficava com o lixo do bloco
         reciclado. Quando o lixo era != 0, `close` saía cedo sem fechar coisa
         alguma: `write` dizia ter gravado 144 bytes, `path.getsize` via 0, e os
         dados só apareciam no `exit`. Consertado nos dois sítios que criam
         `PsFile` (mais o `etrace` de uma vista de `PsBuffer`, que era lixo sem
         consequência); varredura feita nos 40 sítios de `ps_alloc` do runtime.
         Portão: `tests/pscript/run/aio_close.psc`.
      2. **`__fr->x = f()` escrevia no quadro VELHO.** Dentro de um `async def`
         todo local mora no quadro, e o quadro é objeto do heap que o coletor
         MOVE. Em C a ordem entre calcular o endereço da esquerda e chamar a
         direita não está definida: o gcc carrega `__fr` num registrador, `f`
         aloca, a coleta conserta a pilha de sombra, e a escrita vai para o
         endereço antigo. A DECLARAÇÃO de um local já passava por `value_first`;
         a ATRIBUIÇÃO, o `+=`, o `:=` e o `return` não passavam. Foi assim que o
         `content_hash` do motor devolveu zero e o `restat` passou a comparar 0
         com 0 — recompilando tudo, em silêncio. Portão:
         `tests/pscript/run/async_store.psc` (com o compilador antigo: hash
         errado e SIGSEGV).
      Medida depois: motor 31/31 sob `GC_STRESS=1`, `gc-stress` 119/119,
      `verify-all quick` 8/8 (ladder, ponto fixo C e QBE, C/QBE/C89, conformidade,
      oráculos, pstudio). Seed regenerado no mesmo commit, como manda a regra.
      **A escrever em `pscript/DESIGN.md` quando o arquivo estiver livre** (ele
      carrega a bateria 119 de outra sessão).
- [x] **F3 — o DESCRITOR, a biblioteca de alvos, a CLI e o ninja** (2026-08-22):
      `lib_targets.psc` (as funções que devolvem arestas), `build_plang.psc` (o
      descritor deste repositório), `ppack.psc` (a CLI),
      `lib_ninja.psc` (a exportação) e `verdict.psc` (o juiz de um caso de
      teste). O que o descritor cobre hoje: a ESCADA inteira com ponto fixo, o
      runtime do pscript (a lista dos seis módulos passou a ter um dono), o
      `ppack` construído por ele mesmo, o `verdict`, a suíte do motor, o
      `pstudio` (as três linguagens num binário, SDL2 por `pkg-config`) e a
      suíte do pscript caso a caso.
      **Medido**: build limpo do padrão em 68 s com `-j 6`; a suíte inteira em
      585 arestas, 72 s do zero e 6,6 s quando nada mudou; `build.ninja`
      exportado com 639 regras, determinista. Portão: `tests/pbuild.sh` (44
      checagens do motor + o ensaio do descritor + a exportação).
      FALTA (e está dito na secção F3): o `exec` do `ppack run` (decisão de
      linguagem, do usuário), as suítes de placar com piso, o `build.ninja`
      comitado, e a **parte D — a TROCA**, que fica esperando o outro agente
      largar o Makefile.
- [x] **O motor cresceu três vezes construindo de verdade** (2026-08-22), e as
      três só apareceram porque o descritor passou a construir o repositório
      inteiro:
      1. **o `-j N` não limitava nada.** O contador de braços era incrementado
         quando o braço COMEÇAVA a rodar, e criar uma tarefa não a põe a correr:
         o laço que multiplica braços via sempre `alive == 1` e criava um braço
         POR ARESTA PRONTA. Num build limpo são centenas de processos ao mesmo
         tempo, mais canos do que o `poll` do runtime acompanha, e o build
         terminava em "deadlock: awaiting a task that nothing can finish".
         Passou a contar AO CRIAR. Portão: o relator conta quem começou e quem
         terminou, e o pico nunca passa do limite.
      2. **o `restat` não atravessava corridas.** Guardar a data ANTIGA (para
         não sujar quem lê) fazia o teste 5 responder "estou velho" em toda
         corrida seguinte — a aresta rodava para sempre, e o `ppack verify`
         refazia 296 arestas por nada. O log passou a guardar DUAS datas: quando
         o CONTEÚDO mudou (para quem lê) e quando a aresta foi CONFERIDA contra
         as entradas (para ela mesma). Formato v2.
      3. **e a poda passou a atravessar corridas**: no plano, uma saída de
         aresta `restat` cujo hash de conteúdo ainda bate com o do log vale pela
         data do LOG, não pela do disco. É ler as saídas do compilador uma vez
         por plano — o que o ninja não pode fazer (ele mede projetos com
         centenas de milhares de arestas) e nós podemos.
      **Medido**: `ppack build` do zero 71 s, sem mudança 7,3 s; tocar um fonte
      cujo C sai igual = 4 arestas e 7,7 s. `ppack verify` (o `verify-all`
      inteiro, como grafo) **5m48 do zero e 7,7 s sem mudança** — contra ~20 min
      em toda corrida do `verify-all.sh`.
- [x] **F5 e F7 FECHADAS, e a F6 só falta a tela** (2026-08-23). A reflexão
      (tabela de campos, `repr` como dado, `json.stringify`), o doctest, o
      `--json` em tudo, o `run` fora do compilador com `os.exec`, o post-mortem
      com VALORES e o `ppack dev`. O que resta da F6 precisa de janela: o motor
      em processo no editor, o painel, o play/vassoura e os erros sublinhados.
      A releitura das especificações no fim fechou mais quatro buracos: o
      `ppack check` (a promessa de P através dos pacotes), a faixa de toolchain
      conferida de verdade, o `up`/`--frozen`, e o `build.ninja` comitado com
      portão de frescura.
- [x] **F4 FECHADA** (2026-08-23): o repositório inteiro — `publish`, `keygen`,
      `update`, `search`, `add`, `install`, `up`, `check` — por `file://` e por
      `http://`, com as duas assinaturas Ed25519 e o TOFU gravado no
      `pack.lock`. Oito pacotes (`stl`, `pui`, `sha2`, `tar`, `http`, `url`,
      `ed25519`), e `pscript/lib/` deixou de existir. Portão: `tests/repo.sh`,
      55 verificações.
- [~] **F4 começou pelo que não depende de decisão sua** (2026-08-22): o
      MANIFESTO e o WORKSPACE. `pbuild/ps/lib_manifest.psc` lê e valida as duas
      formas de `pack.json` — a de pacote e a de workspace, que se distinguem
      por ter ou não `members`, sem campo `kind` e sem um terceiro arquivo — e
      o erro sai como `pack.json:4:12: error: ...`, clicável pelo mesmo caminho
      que um erro de compilação. O descritor lê o `pack.json` da raiz, deriva as
      RAÍZES de busca (o diretório que contém os membros) e as passa a TODA
      invocação do compilador, pergunta inclusive — `--deps` de um arquivo que
      importa de um pacote precisa achar o pacote para responder.
      Portão: `caso_manifesto` na suíte do motor (60 checagens agora).

      **O que falta em F4 depende de VOCÊ, e está listado aqui para a decisão
      ser fácil:**
      1. **como um módulo pscript de um pacote é importado.** `import <>` ficou
         decidido para `.ph` (módulo P); um pacote pscript como o `pui` precisa
         de uma forma para os `.psc` dele. Proposta: `import <pui/pui.psc>`,
         mesma regra de busca, e o nome do namespace é o último pedaço sem
         extensão. Sem isto o `pui` não pode virar pacote.
      2. **os campos do `pack.json`** estão implementados como a proposta de
         `packages/README.md`. Mudá-los é barato.
      3. **mover o `stl`** (41 referências, ciclo de seed) — a decisão de
         quando, não de se.

---

## Estado em que o plano parte (conferido, não suposto)

- Migração `static`→`private` TERMINADA (os `static` restantes no selfhost são
  comentários, mensagens e a keyword que o front end de C usa; `static def` em
  struct pscript segue sendo método estático — decidido).
- O editor é 100 % pscript (`pstudio/ps/lib_*.psc` + `app.psc`); em P ficou só
  o driver (`pgfx*`, `font_atlas`, `shim`, `hl`) — commits 4c5cdef/115.
- O compilador tem três front ends num binário (117: o fork fica; duplicação
  medida ~89 linhas recuperáveis) e **não tem**: `--version`, resposta de deps,
  hash de interface, `import <>`, docstring em P, `os.run`, reflexão.
- `path.getmtime` devolve **segundos** (`psrt_os.p:327` trunca o `tv_sec` do
  timespec que já leu) — o motor de build compara mtime em resolução de
  nanossegundos (ninja/samurai), então F2 precisa de `getmtime_ns`.
- O `import <...>` pode reusar a maquinaria do `include <...>` (contextual, o
  parser reconstrói o caminho de tokens — `parser.p:1284`).
- Diagnóstico já passa por um funil (`util.p`: `fatal_at`/`warn_at` +
  `diag_config`) — a resposta 6 (estruturada) pluga aí, sem caçar printf.
- As listas de módulos do runtime vivem em SEIS lugares (run.sh ×2 blocos,
  psbuild.sh, Makefile, verify-all, `RT_SRCS` em `main.p`).
- Medições que dimensionam tudo: ver a tabela final de `pbuild/DECISOES.md`.

## O mapa de dependências

```
F0 (compilador responde 1–4) ─┬─► F2 (motor consome as respostas)
                              └─► F4 (publish usa o hash de API)
F1 (linguagem p/ build)      ──┬─► F4 (import <>, 1.5d destravam pacotes)
                               └─► F5 (docstring alimenta doc/doctest)
F2 (os.run + motor)          ────► F3 (descritor roda no motor)
F3 (descritor + CLI + troca) ────► F4 (ppack resolve por cima do build)
F5 (reflexão + resposta 6)   ────► F6 (IDE consome diagnóstico e --json)
F3 + F4                      ────► F7 (run sai do compilador)
tudo                         ────► F8 (QBE embutido, linker, musl — sem data)
```

**Ciclos de seed previstos: dois.** O primeiro fecha F1 (toda a sintaxe nova de
uma vez: `import <>`, docstring, 1.5a/1.5d). O segundo fecha a primeira metade
de F4 (mover `stl/` → `packages/stl`, que reescreve os imports relativos do
próprio selfhost). Qualquer mudança de compilador regenera o seed normalmente
(`reseed.sh`); o que os DOIS ciclos marcam é *mudança de fontes em massa*, que
não se quer espalhada por vários commits.

---

# F0 — o compilador RESPONDE (perguntas 1–4 do protocolo)

**Objetivo.** O `plangc` passa a poder dizer o que leu, o que vai emitir, o
hash da interface de cada módulo e quem ele é. Nenhuma semântica muda; nenhum
comportamento existente muda. É a menor fase e destrava F2 e F4.

**Por que primeiro:** F2 (motor) monta o grafo com as respostas 1 e 3; F4
(publish/semver) usa a 2; e a fase não colide com nada — só acrescenta saídas.

### Entregas

- [x] **`--version`**
  - constante `PLANG_VERSION = "0.1.0"` em `selfhost/main.p` (semver da
    LINGUAGEM: menor = recurso novo, maior = quebra — decidido)
  - imprime `plangc 0.1.0 (<hash-dos-bytes>)`; o hash é o mesmo cálculo que o
    `run` já faz (`hash_file(argv[0])`, `main.p:551`) — extraí-lo para função
    reutilizável, porque F7 vai apagar o `run` e a função fica
  - `-h` menciona; sai com status 0
- [x] **Pergunta 1 — "o que você leu?"** (flag de deps)
  - lista, uma por linha, TODA fonte aberta na compilação: o arquivo pedido,
    imports transitivos (`.ph` e os `.p`/`pmod` que eles puxarem), `embed()`/
    `embed_bytes()`, e os headers de `include <h>` **depois** do preprocessador
    (o `.i` efetivo — o que o manifest do `run` já rastreia hoje; reusar esse
    caminho: a lista existe, falta a saída)
  - caminhos como foram resolvidos (relativos ao cwd), ordem estável
    (a ordem de descoberta é determinística — o laço de inputs de `main.p`)
  - combinável com `--parse-only` para custar só o front end
- [x] **Pergunta 3 — "o que você VAI emitir?"** (flag de outputs)
  - por entrada: os artefatos que aquela invocação produziria com os mesmos
    argumentos (`x.c`, `x.h` quando `.ph`+backend C, `pmod_*.c` de um `.psc`,
    `.ssa` no backend QBE), SEM rodar sema nem codegen além do necessário
    (front end + resolução de imports — medido: 0,12 s no maior arquivo)
  - o espelhamento do `--out-dir` aplicado aos nomes (o mesmo código de caminho
    que a emissão usa — extrair a função, não duplicar)
- [x] **Pergunta 2 — a LISTA CANÓNICA DA API + hash (1.5b)**
  - por módulo com interface (um `.ph`, ou um `.p` cujo `.ph` o descreve): a
    lista do que é PÚBLICO — funções (nome + assinatura completa com tipos
    normalizados), structs/records com **campos públicos e layout** (nome,
    tipo, ordem — o layout entra na interface, decidido), enums (nome +
    variantes + valores), consts públicas (nome + tipo + valor se comptime),
    generics declarados (`declare`/`implement` visíveis)
  - **normalização**: sem comentário, sem docstring, sem formatação, sem nomes
    de parâmetro (só tipos — renomear parâmetro não é quebra de ABI), ordem
    ESTÁVEL (a ordem de declaração, que é determinística)
  - o hash é `hash_bytes` da lista serializada (o rápido de 64 bits: aqui é
    chave de sujeira, não defesa contra adversário — o SHA-256 de F4 é outra
    coisa e outra função)
  - **teste que prende**: editar comentário/docstring/nome de parâmetro no
    `.ph` NÃO muda o hash; mudar um tipo, um campo, a ordem de campos MUDA
- [x] **Pergunta 4 — "quem é você?"**: já existe (hash dos bytes); ganha saída
      própria na flag de versão e na resposta 2 (o par versão+hash acompanha a
      lista, para o lock de F4 gravar)
- [x] formato de saída desta fase: **texto, uma informação por linha** com
      prefixo de seção. JSON entra em F5 (quando a serialização for de graça);
      desenhar as linhas para que a troca por JSON não mude o CONTEÚDO

### Decisões finas a confirmar no início da fase

| # | pergunta | proposta |
|---|---|---|
| f0.1 | nomes das flags | `--deps`, `--outputs`, `--api` (curtas, sem prefixo de subcomando) |
| f0.2 | a resposta 2 sai por módulo ou por invocação? | por módulo, cabeçalho `== <arquivo>` |
| f0.3 | assinatura na lista: com ou sem `out/ref/in`? | com — mudam a chamada, são interface |

### Verificação da fase

- casos novos `tests/cases/api_hash_*.p` + `.expected` (o texto da lista) e
  testes de invariância (comentário não muda hash) via harness
- rodar as 4 perguntas nos 34 fontes do selfhost e num `.psc` que importa
  `.ph` (o caso `pmod`) — sem crash, saída estável entre duas execuções
- `make verify` 8/8 + seed regenerado

**Pronto quando** tudo acima está verde e `pbuild/DECISOES.md` aponta as flags.

---

# F1 — a linguagem para o build (ciclo de seed nº 1)

**Objetivo.** As quatro mudanças de linguagem que o build e os pacotes pedem,
num único ciclo de seed. Cada uma ganha **bateria numerada** no
`pscript/DESIGN.md` (a decisão já está tomada; a bateria registra o desenho
fino e vira o lugar do teste).

**Ordem interna** (cada item verde antes do próximo): docstring → `import <>` →
1.5(a) → 1.5(d) → regenerar o seed uma vez no fim.

### Entregas

- [x] **Docstring `"""..."""` nas duas linguagens** (FEITA)
  - lexer: ligar `triple_str` no `P_LEXSPEC` (`lexer.p:33` — a máquina já
    existe, o pscript já a usa; conferir interação com f-string: em P não há
    prefixo de interpolação, então `"""` é sempre literal cru)
  - gramática: string sozinha como PRIMEIRA instrução de `def`/`struct`/
    `record`/módulo = docstring; em qualquer outro lugar, `"""` é só string
    multilinha (55.1 do pscript, agora também em P)
  - P: a docstring vai para o AST e **não gera código** (dropada no backend —
    zero byte no binário, decidido); pscript: mantém a 46.3 (acessível em
    runtime)
  - precedência: PENDENTE, e por um motivo concreto — um protótipo não tem
    corpo, então uma função declarada num `.ph` ainda não tem onde pôr a
    docstring dela. A forma que caberia (um corpo só com a docstring) é
    inequívoca num header e ambígua num `.p`, e é **decisão sua**; está escrita
    em `pbuild/BATERIAS.md`
  - **resposta 5 do protocolo**: a lista canónica da F0 ganha a docstring de
    cada símbolo (a doc NÃO entra no hash — teste de invariância já preso na F0)
- [x] **`import <pkg/mod.ph>`** (FEITA)
  - reusar o caminho do `include <...>` (contextual, reconstrução de tokens —
    `parser.p:1284`); vale em P e em pscript
  - resolução: procura em cada raiz de `--pkg-path` (repetível; o ppack passa
    `build/pkg/<nome>-<versão>-<hash>/` por pacote resolvido; para o workspace,
    o diretório do pacote local). SEM fallback para caminho relativo — `<>` e
    `"..."` não se misturam (a ambiguidade silenciosa foi explicitamente
    recusada)
  - erro quando não acha: listar as raízes procuradas (mensagem no padrão da
    casa: explica a decisão, não acusa o token)
  - `--out-dir`: o módulo de pacote espelha o CAMINHO REAL dele, como qualquer
    outro fonte — a proposta f1.2 (`<out>/pkg/<pacote>/...`) foi descartada na
    implementação: ela exigiria uma segunda regra de espelhamento e um mapa de
    caminhos, e o espelho normal já resolve, porque o import é reescrito para
    RELATIVO assim que é resolvido. O preço: a raiz e os fontes têm de ser
    nomeados do mesmo jeito (ambos relativos ou ambos absolutos), e o
    compilador recusa com mensagem quando não são
- [x] **1.5(a) — `import` implica o módulo (a regra do `.p` irmão)**
  - ao ler `x.ph` (por `"..."` ou `<>`): se `x.p` existe ao lado, ele entra na
    lista de compilação (o mecanismo é o MESMO do `.psc` que puxa `pmod_*.p`
    hoje — o laço `while` de inputs em `main.p:597`; generalizar, não duplicar)
  - dedup por caminho canónico (dois imports do mesmo módulo = uma entrada);
    ciclo de import já é detectado hoje — conferir que a regra nova não o fura
  - `.ph` SEM irmão continua sendo só declaração (stl hoje, headers de C
    embrulhados) — nada muda para eles
  - **modo `-o` (saída única) NÃO puxa**: o contrato de `-o` é um artefato; a
    regra vale para `--out-dir` e para quem consome a pergunta 3. Registrado
    como comportamento, com teste
  - prova da fase: compilar `tests/pscript/run/hello.psc` (ou equivalente)
    nomeando SÓ ele + `--pkg-path pscript/runtime` → o runtime inteiro vem por
    import. As seis listas ficam REDUNDANTES (removê-las é F3/F7)
- [x] **1.5(d) — `import "x.ph"` dentro de módulo pscript importado** (FEITA)
  - era: o import de `.ph` só era honrado quando estava no arquivo NOMEADO;
    num módulo importado, silêncio + `#include` órfão. Agora a varredura é do
    FECHAMENTO e o `.p` irmão entra na compilação e nas respostas 1/3
  - mora em `main.p`, e NÃO em `ps_sema`/`ps_lower` como este plano supunha: a
    sema resolve o mesmo grafo de imports, mas não roda quando a pergunta é
    `--outputs` — e a resposta 3 tem de valer sem compilar
  - o contorno do `hl` em `tests/run.sh` (compilar `hl.p`+lexer+util+utf8 à
    mão) vira o teste de regressão: apagar o contorno, o build do editor tem
    de continuar passando
- [x] **regenerar o seed** (reseed.sh) uma vez, com os quatro itens dentro
- [~] baterias registradas: em `pbuild/BATERIAS.md`, e não em
      `pscript/DESIGN.md`, porque esse arquivo carrega trabalho não comitado de
      outra sessão. Dobrar e apagar quando ele estiver livre.

### Decisões finas a confirmar

| # | pergunta | proposta |
|---|---|---|
| f1.1 | docstring de módulo em P: onde? | primeira instrução do arquivo, antes de imports |
| f1.2 | espelho do `--out-dir` p/ módulo de pacote | `<out>/pkg/<nome>/...` |
| f1.3 | `import <x.ph>` sem `.p` irmão dentro de pacote | permitido (pacote de só-interface existe: stl) |

### Verificação da fase

- baterias com casos `run/` e `bad/` (o erro de `<>` não achado; docstring em
  lugar errado; ciclo com a regra nova)
- o teste de regressão do `hl` sem contorno
- gc-stress + oracle + conformance intocados (nada de runtime mudou)
- `make verify` 8/8 + **seed do ciclo nº 1**

**Pronto quando**: os cinco blocos verdes, seed regenerado, e um `hello.psc`
compila nomeando só a si mesmo.

---

# F2 — `os.run` e o MOTOR do pbuild

**Objetivo.** A peça que falta na stdlib (rodar processo) e a biblioteca do
executor — o análogo das 1 546 linhas do samurai, com as nossas decisões.

### Parte A — `os.run` na stdlib (mexe no runtime; bateria própria)

- [x] **API**: `await os.run(argv: list<str>, env: dict<str,str>? = None,
      cwd: str? = None, stdout: str? = None) -> ProcResult`, com `ProcResult`
      um record `(status: int, output: str)`
  - `argv` executado DIRETO (`posix_spawn` ou fork+execv — sem `/bin/sh`,
    decidido 1.6); `argv[0]` resolvido via PATH pelo próprio spawn
  - `env=None` herda o ambiente; `env` dado SUBSTITUI (não mescla — mesclar é
    `dict` na mão do chamador; o hash de F2-B precisa do efetivo)
  - `cwd` aplicado NO FILHO (file_actions/chdir pós-fork — a proibição de
    `chdir` da 111 é para a thread do worker, não para o filho)
  - captura: stdout+stderr num pipe único (como o samurai), lidos até EOF pelo
    laço de eventos, `waitpid` ao fechar; a task resolve com o resultado inteiro
  - `stdout: caminho` = dup2 para o arquivo NO FILHO (a saída não passa pela
    memória); stderr continua capturado no pipe e vem em `output`
  - status: exit code; morte por sinal vira `128+sinal` (convenção de shell,
    documentada)
  - paralelismo: N `os.run` em voo = N fds no laço (nenhum mecanismo novo);
    o limite de concorrência é de quem chama (`gather_map(..., at_most=n)`)
- [x] **`path.getmtime_ns`**: o timespec já é lido (`psrt_os.p:326`); devolver
      `sec*1e9+nsec` numa função nova (não mudar a existente — oráculo python3
      confere `getmtime` em segundos)
- [x] armadilhas conhecidas (memória da 107): sondar SEMPRE com timeout;
      rodar `gc-stress`, `net-late`, `print-atomic` a cada passo; fork numa
      máquina com workers = threads → spawn só do laço principal, documentado
- [x] oráculo: casos comparados com `subprocess.run` do python3
      (`tests/oracle/py/`) — status, captura, env, cwd

### Parte B — a biblioteca do motor (pscript puro; **não imprime — relata**)

Módulos propostos (espelham o samurai lido): `lib_graph.psc` (nós/arestas),
`lib_dirty.psc` (sujeira+log), `lib_sched.psc` (fila+executor),
`lib_events.psc` (o contrato com as frentes). Moram em `pbuild/ps/` até
virarem pacote.

- [x] **grafo**: nó = arquivo (path canónico, mtime_ns com MISSING/UNKNOWN,
      hash do log, gerador, usos); aresta gorda = `argv`, entradas em TRÊS
      faixas (normais | implícitas | order-only), saídas (+ implícitas),
      `env`, `cwd`, `stdout`, `restat`, `generator`, `pool`, `console`;
      contadores `nblock`/`nprune`
  - construtores: de `dict` (a via em memória, 1.8) e de JSON (mesmo shape)
- [x] **sujeira**: os SEIS testes do ninja NA ORDEM (`graph.cc:222`, lidos):
      falta → restat-log → mais velha que entrada → hash do comando →
      mtime gravado < entrada → sem registro; o hash do comando cobre
      **argv + env efetivo + cwd + stdout + alvo** (as extensões decididas)
- [x] **restat e poda**: `shouldprune`/`nodedone(prune)` do samurai (~40
      linhas em cima dos contadores) — é o que transforma "regenerei C
      idêntico" em "não recompilo os 18 s"
- [x] **depfile do `cc -MD`** (o lado C continua estranho, decidido): parser do
      subset Makefile (alvo: os `.d` que gcc/clang emitem; ler o `depsparse`
      do samurai como referência), entradas viram implícitas + gravadas no log
      para a corrida seguinte
- [x] **log** em `build/log/build.log`, texto com versão no cabeçalho, uma
      linha por saída: `mtime_ns  duração_ms  hash_cmd  hash_env  caminho`
      (o samurai grava `0\t0` na duração; nós usamos — 1.7); releitura na
      carga, rewrite quando inchar (o mecanismo do `loginit` lido)
- [x] **fila**: caminho crítico com peso = **duração da última vez** (do log;
      1 s de chute na primeira vez), topo-sort + propagação reversa (o
      `ComputeCriticalPath` lido, trocando o peso-1); desempate por id
- [x] **executor**: N=`os.nproc` (precisa expor no `os` — item novo pequeno),
      `-k N` (padrão 1: para na primeira), pool `console` (sem captura,
      sozinho na vez), sinais (matar filhos e sair com 128+sig), saída de cada
      aresta despejada INTEIRA no evento
- [x] **higiene**: ERROS — saída declarada e não produzida (stat pós-aresta),
      ciclo (o marcador FLAG_CYCLE lido), entrada que não existe e ninguém
      produz; AVISOS — entrada declarada nunca lida (via resposta 1 quando a
      ferramenta é o plangc), aresta inalcançável, saída sem consumidor
- [x] **eventos**: `plano_pronto(total)`, `aresta_iniciou(id)`,
      `aresta_terminou(id, status, saída, duração)`, `fim(ok, falhas)` — e
      NADA mais (decidido); `--explain` é consulta sobre o plano, não evento
- [x] **suíte do motor** (`tests/pbuild/`, harness próprio no padrão da casa):
      diamante mínimo; restat que poda; generator; comando mudou (env mudou!);
      alvo mudou; pool serializa; `-k`; falha para; ciclo detectado; saída não
      produzida; entrada órfã; depfile; log sobrevive a rewrite; fila respeita
      duração (aresta lenta declarada primeiro no log sai primeiro)

### Decisões finas a confirmar

| # | pergunta | proposta |
|---|---|---|
| f2.1 | `ProcResult` com `output` único ou `out`/`err` separados? | único (modelo samurai); `stdout:` separa quando importa |
| f2.2 | nome e casa de `os.nproc` | `os.nproc()` no módulo os |
| f2.3 | formato do id de aresta nos eventos | índice denso + nome da 1ª saída |

**Pronto quando**: um grafo escrito à mão (JSON) constrói o compilador em ~5 s
nesta máquina; mexer numa linha de `util.p` recompila 1 TU + link; a suíte do
motor passa; verify 8/8.

---

# F3 — o DESCRITOR, a CLI, e a TROCA (o critério de pronto da v1)

**Objetivo.** O `build.psc` deste repositório, a CLI `ppack`, o `--emit-ninja`,
e a substituição do Makefile/psbuild.sh — que só acontece quando `ppack verify`
der 8/8.

### Parte A — a biblioteca de alvos (alto nível; o motor não aprende nada)

- [x] funções pscript que DEVOLVEM ARESTAS (`pbuild/ps/lib_targets.psc`, 470
      linhas — o guarda-corpo: conhecimento de toolchain nesta camada, nunca no
      motor, que é o erro das 1 679 linhas do muon):
  - `p_modules(fontes, out=, backend=, std=, flags=)` → arestas plangc
    (usando as respostas 1/3 para entradas/saídas implícitas)
  - `c_objects(fontes, cc=, flags=, depfile=True)` → arestas cc -c com -MD
  - `executable(nome, objetos, libs=, flags=)` → link
  - `psc_program(fonte, ...)` → plangc do fechamento + cc + link (o que o
    psbuild.sh faz hoje, agora derivado por import — 1.5a)
  - `suite(nome, casos, veredicto=, floor=None)` → arestas de teste + nós de
    VEREDICTO (rodar binário, comparar com `.expected`; piso de placar aqui —
    c-suite≥220, wacct≥741, decidido)
  - `command(argv, ins, outs, ...)` → a aresta crua, sempre disponível
  - **alvos nomeados**: o `Target` existe (nome, `cc`, `-t` do QBE) e o nome já
    entra no hash de toda aresta; só o `host` está preenchido. `musl` e
    `macos-arm64` ficam para quando houver máquina para os medir — inventar as
    flags sem poder rodá-las seria escrever o catálogo do muon às cegas.
- [x] `pkg-config` como resolvedor de dependência de sistema: `pkg_config()` e
      `tem_pkg()`, perguntados na MONTAGEM do grafo (o que ele responde entra no
      `argv`, logo no hash — uma aresta que o chamasse por dentro teria sempre o
      mesmo hash e reaproveitaria artefato de outra versão do SDL2 em silêncio).
      Os `-D` NOSIMD do Makefile são variáveis VAZIAS lá (medido); não há o que
      trazer.

**Três coisas que a biblioteca aprendeu construindo este repositório:**

  1. **a resposta tem de vir por ARQUIVO, não pelo cano.** O `os.run` junta a
     saída de erro com a de saída de propósito; uma RESPOSTA, não. Três avisos
     `-Wshadow-prelude` do corpus viraram três linhas de `--deps`, e o grafo
     inteiro foi recusado com "entrada que ninguém produz". Agora a pergunta usa
     `stdout=` e o `output()` fica só com o que o compilador tinha a dizer.
  2. **um arquivo tem UM produtor, e `plangc --out-dir` desafia isso.** Ele
     emite o header de todo `.ph` que leu, então dois programas que leem o mesmo
     `.ph` "produzem" o mesmo header. Quando a emissão é do MESMO compilador na
     MESMA árvore, o arquivo vira entrada implícita da segunda aresta em vez de
     saída — a ordem fica certa e a higiene continua recusando o caso de
     verdade (outro compilador, outra árvore, outra ferramenta).
  3. **o quinto evento.** O motor contava os problemas de higiene e não os
     dizia: "build falhou: 3 problema(s)" e mais nada. `on_error(str)` entrou no
     relator, e foi o que achou (1) em trinta segundos.

### Parte B — o `build.psc` deste repositório

Expressa TUDO que o Makefile + run.sh + psbuild.sh + verify-all constroem:

- [x] o compilador: seed (`cc bootstrap/*.c`) → **escada** s1 → s2 → out3, em
      que a saída de uma etapa é a FERRAMENTA da seguinte (a aresta de s2 usa
      como `argv[0]` um ARQUIVO produzido por outra aresta — o grafo já
      suporta: é entrada normal; risco nº 1 do plano, atacar primeiro)
  - [x] ponto fixo: nó de veredicto `s2 == s3` byte a byte (`diff -rq`, com a
        saída dele como carimbo — sem shell, porque a saída da aresta vai para
        arquivo por campo e quem decide é o STATUS)
  - [x] o gate de tag de libc: um portão pela NEGATIVA (`nao_acha`), que é o
        único lugar do descritor onde há um shell — inverter o status de um
        comando é o que o `!` faz, e o aspeamento é gerado por nós
- [x] o runtime do pscript, e a lista dos seis módulos em camadas passou a ter
      UM dono (`RT_MODULOS` em `lib_targets.psc`). Ele vira OBJETO uma vez por
      contexto: o `psbuild.sh` recompila os seis a partir do C em cada programa,
      e a suíte tem mais de cem — seiscentas compilações do mesmo texto viraram
      seis.
- [x] o pstudio (driver P + `app.psc` + SDL2 por `pkg-config`). Sem
      `PLANGC_CPP`: a variável de ambiente não serve porque o `env=` de uma
      aresta SUBSTITUI o ambiente e um comando sem `PATH` não acha o `cc` — o
      `--cpp` do compilador diz a mesma coisa dentro do `argv`, e de quebra
      entra no hash. Se a máquina não tem SDL2 o alvo simplesmente não existe,
      que não é erro.
- [x] a suíte do pscript: **uma aresta por caso**, cada um no diretório dele
      (o `run.sh` roda os cento e tantos no mesmo, um de cada vez; em paralelo
      eles se atropelariam), com `.expected`, `.exit` e `.flags` respeitados —
      as flags entram no `argv` do compilador, logo no hash, e trocar de flag
      refaz. Quem julga é o `verdict` (`pbuild/ps/verdict.psc`), porque o status
      de saída de um caso é DADO e não veredicto.
      **Medido: 585 arestas, 72 s do zero, 6,6 s quando nada mudou.**
- [x] as demais suítes como arestas `harness()` sobre os arreios existentes —
      `run.sh` nas três leituras (C, QBE, C89), `gc-stress`, `protocol`,
      `knobs`, `net-late`, `print-atomic`, `run-cmd`. Eles NÃO foram reescritos,
      e é decisão: funcionam, são lidos por gente que não vai ler pscript, e
      reescrevê-los seria trocar risco por nada. Cada um ganha o diretório de
      trabalho DELE (`OUT=`), porque duas corridas do `run.sh` no mesmo lugar se
      atropelam. A configuração vai por `/usr/bin/env K=V ...` como argv[0]:
      o `env=` de uma aresta SUBSTITUI o ambiente, e um arreio sem `PATH` não
      acha o `bash`.
      FALTA: os PISOS de placar (c-suite ≥ 220, wacct ≥ 741), que precisam de um
      veredicto que leia o número do placar.
- [x] `pack.json` de WORKSPACE na raiz, com `packages/stl` como membro. É de lá
      que sai a raiz de busca que TODA invocação do compilador recebe.

### Parte C — a CLI `ppack` (frente da biblioteca)

- [x] parsing de argumentos em pscript (com `--` separando o que é do
      programa); erros no formato
      `arquivo:linha:col: error:` quando têm posição (pack.json inválido),
      mesma forma sem números quando não têm
- [x] `ppack build [alvo]` — fases descrever→planejar→decidir→executar;
      imprime linha por aresta terminada (saída inteira em falha); `--explain`;
      `-k N`; `-j N` (padrão núcleos); exit 0/1
- [~] `ppack run prog [--] args` — constrói e roda, com o status DELE e 101 para
      falha de build (f3.2 confirmada na prática). O que falta é o `exec`: hoje
      o programa roda como FILHO e a saída volta capturada, o que serve para
      quem imprime e não serve para quem lê teclado ou pinta tela. `exec`
      precisa de uma função nova na camada de sistema do pscript (`os.exec`), e
      **isso é decisão de linguagem — fica para o usuário**.
- [x] `ppack test` — `-k` alto por padrão (quem roda teste quer o placar
      inteiro, não a primeira falha), veredicto SEMPRE roda, e o carimbo da
      suíte NÃO é alvo padrão: construir não é testar. Falta o placar por suíte
      e os pisos, que vêm com as outras suítes.
- [x] `ppack verify` — o `verify-all` inteiro, como GRAFO: o que não depende um
      do outro roda junto, e o que não mudou não roda
- [x] `ppack clean` — apaga o que o build produziu, MANTÉM `build/pkg`
- [x] `ppack explain <saída>` e `ppack graph` (JSON); `why`/`tree`/`lock` são
      de F4 e ficam com ela
- [x] **`ppack doc <arquivo|pacote> [símbolo]`** — a documentação no TERMINAL,
      do que já existe. Nada é construído e nada é gerado: a fonte é a resposta
      5 do compilador, que já traz a interface canónica e as docstrings, e
      `pbuild/ps/lib_api.psc` a lê de volta. É o que o `go doc` acertou —
      offline, sem site, sem serviço — e aqui saiu quase de graça porque o
      formato já estava lá. Um nome de PACOTE resolve pelo campo `root` do
      manifesto: quem quer a documentação de um pacote não tem de saber em que
      arquivo a interface dele mora. O `--html` para uma pasta fica para depois.
- [x] **`ppack ninja`**: desce a aresta gorda para texto ninja — aspeamento
      GERADO (nós sabemos onde cada argumento começa); `restat`/`generator`/
      `pool console` mapeiam 1:1; `env`/`cwd` viram wrapper explícito no
      comando (documentado no cabeçalho de `lib_ninja.psc`, com os quatro
      pontos em que a exportação é conservadora). O aspeamento é GERADO e tem
      caso próprio na suíte: caminho com espaço, argumento com `$`, aspa simples
      — e o comando exportado é RODADO por um shell para conferir que escreve o
      que a aresta prometia. Determinista, conferido duas vezes.
- [x] `build.ninja` COMITADO na raiz + bootstrap no README (2026-08-23), com um
      PORTÃO que o regenera e compara: um arquivo gerado que fica comitado tem
      exatamente um modo de falhar, que é envelhecer em silêncio.

### Parte D — a TROCA (um commit, repo verde antes e depois)

> **FEITA** (2026-08-22, por decisão sua). O `Makefile` é uma casca de sessenta
> linhas: ele nasce o compilador do C comitado, constrói o `ppack` com ele, e
> daí em diante quem manda é o grafo. `out/` desapareceu, `./plangc` e
> `./plangc2` desapareceram da raiz, e todo arreio aponta para
> `build/bin/plangc_s2`.
>
> Os nomes que as pessoas conhecem continuam a funcionar e a querer dizer a
> mesma coisa: `make` constrói, `make test` roda o corpus em C mais a suíte caso
> a caso, `make verify` roda a bateria inteira, `make check` compila um
> hello-world, `make selfhost` é a escada com ponto fixo, `make pstudio` é o
> editor. `make clean` deixa a árvore como o `git clone` a entrega.
>
> Medido numa árvore limpa: `make` 84 s · `make test` 4m29 (9 s sem mudança) ·
> `make verify` 5m16 (8,7 s sem mudança).

- [~] `tests/psbuild.sh` reimplementado como chamada de `ppack` (ou os
      harnesses que o usam passam a chamar `ppack` direto)
- [x] `Makefile` vira casca: `make` → build do seed + `ppack build`;
      `make verify` → `ppack verify`; alvos antigos apontam e avisam
- [x] `out/` → `build/{obj,bin,log,pkg}`; `.gitignore`; docs atualizados
- [x] **as SEIS listas de módulos do runtime morreram** — as cinco dos arreios e
      a que vivia dentro do compilador. Todas viraram `pscript/runtime/psrt.ph`:
      o guarda-chuva importa os headers das seis camadas e cada um tem o `.p`
      irmão, então nomear UM arquivo traz o runtime inteiro (1.5a). A única que
      resta é a do QBE, que não emite headers e por isso nomeia dois `.p` —
      e a razão está escrita ao lado dela.

### Decisões finas a confirmar

| # | pergunta | proposta |
|---|---|---|
| f3.1 | nome do descritor | `build.psc` na raiz |
| f3.2 | exit code de falha de build no `run` | 101 |
| f3.3 | `ppack build` sem argumento | constrói o alvo padrão do workspace |
| f3.4 | onde mora a lib de alvos | `pbuild/ps/lib_targets.psc` até virar pacote |

**Pronto quando** (o critério LITERAL do DESIGN): **`ppack verify` passa 8/8
construindo o que o Makefile e o psbuild.sh constroem hoje** — a escada com
ponto fixo inclusive. No dia em que passar, a Parte D entra; antes disso o
Makefile segue sendo a verdade.

---

# F4 — PACOTES (ciclo de seed nº 2)

**Objetivo.** O `ppack` resolve: manifesto, lock, workspace, os dois primeiros
pacotes, o formato de repositório, publish e a confiança.

### Parte A — manifesto, lock, workspace

- [x] **`pack.json` de pacote**: `name` (minúsculas, [a-z0-9_-]), `version`
      (semver estrito), `lang` (`p`|`pscript`), `root` (o módulo-interface),
      `deps` (nome → versão EXATA, ou `{path}` para workspace), `system`
      (nome → `{pkg-config}` ou flags literais por alvo), `toolchain`
      (faixa mínima), `description`
  - validação com erros posicionais (linha/coluna no JSON — o parser de json
    do pscript precisa expor posição de erro; item pequeno, conferir)
- [x] **tipos verificáveis** (2026-08-23): `ppack check`, e ele confere as duas
      metades — o manifesto (um `p` não depende de um `pscript`) e o FECHO do
      módulo-raiz (nenhum `.psc` lá dentro). O contrário não é simétrico e não
      devia ser: um pacote pscript PODE depender de um P. Um pacote P com TESTES
      em pscript também está certo (o `sha2` tem um, de propósito) — e é por
      isso que a pergunta é sobre o fecho e não sobre o diretório.
      No `verify`.
- [x] **lock `pack.lock`** (JSON, decidido "dois arquivos, um armazém"): por
      pacote — nome, versão, SHA-256 do tarball, repositório de origem (URL ou
      `path`), `unsafe: true` quando 2.12, faixa de toolchain do manifesto +
      a versão/hash do plangc que resolveu
  - [x] dessincronizado do manifesto → o `install` IMPRIME o diff, e `--frozen`
    (o CI) recusa em vez de avisar (2026-08-23)
- [x] **workspace**: membros por `path`; o hash de um pacote local é o hash do
      DIRETÓRIO (lista ordenada de arquivos + hash de cada — `os.listdir` já
      ordena de propósito); mudou → o lock anota, o build o vê como entrada
- [x] resolução (fase 1 do ciclo): ler manifesto+lock → verificar hashes do
      que já está em `build/pkg/` → baixar o que falta → verificar → extrair em
      `build/pkg/<nome>-<versão>-<hash>/` → montar `--pkg-path` → conferir
      toolchain ANTES de compilar (mensagem: "o pacote foo exige plangc >= X,
      o seu é Y") → **daqui em diante zero rede**

### Parte B — os dois primeiros pacotes (o ciclo de seed)

- [x] **`packages/stl`**: mover os 10 `.ph`; os imports do selfhost viram
      `import <stl/vec.ph>`; as 41 referências externas (Makefile → build.psc,
      harnesses, corpora) atualizadas; **regenerar o seed** — commit isolado,
      repo verde antes e depois (risco nº 4)
- [x] **`packages/pui`**: extrair `lib_pui.psc` (zero import — medido) +
      `pack.json` + `packages/pui/test/` (o `pui_test.psc` e o `.expected`
      saem de `tests/pstudio/` para dentro do pacote; `ppack test` roda testes
      de pacotes do workspace); o `app.psc` do editor importa `<pui/pui.psc>`
      via workspace — hmm: import de `.psc` por pacote é o caso 1.5(c)-lite;
      enquanto módulo pscript não é TU, o import de pacote pscript é textual
      como o import local já é (mesmo mecanismo de hoje, raiz diferente)
- [x] `core`/`hl`/`cv`/`complete` FICAM no pstudio (decidido — intrínsecos)

### Parte C — repositório, comandos, confiança

- [x] **SHA-256**: módulo da stdlib implementado em P (o padrão 108.4, como
      random/time — `psrt_*` novo ou módulo `hash`), ~200 linhas, vetores de
      teste do NIST no harness
- [x] **tarball**: subset ustar (escrever + ler) em pscript — nomes, tamanho,
      conteúdo; sem dono/permissão além do básico; determinístico (ordem
      ordenada, mtime zerado) para o hash ser estável — decisão fina f4.2
- [x] **`index.json`**: por pacote/versão — metadado do manifesto + SHA-256 do
      tarball + **a lista canónica da API** (da resposta 2/5); gerado por
      `ppack index <dir>` (o comando que mantém um repositório-diretório)
- [x] **transportes**: `file://` e `http://` (o cliente HTTP conformante já
      existe); `ppack update` baixa o índice do(s) repos configurados e guarda
      em `build/pkg/index/` (offline depois)
- [x] **`ppack search <termo>`**: por nome, descrição E SÍMBOLO (a lista de API
      no índice — o diferencial decidido)
- [x] **`ppack add nome@versão`** (mexe manifesto+lock, baixa p/ hash, NÃO
      constrói), **`ppack up [nome]`** (versão exata nova, mostra diff de API
      entre as duas versões — as listas estão no índice), **`ppack why`**
- [x] **`ppack publish`**: monta o tarball (com `test/`, sem `build/`),
      SHA-256, assinatura do autor, entrada de índice — e RECUSA: dep por
      `path`, `.psc` em pacote P, versão minor/patch cujo hash de API mudou
      (comparado com a versão anterior no índice)
- [x] **Ed25519 em P** (~500 linhas, aritmética pura; vetores RFC 8032 no
      harness) + **índice assinado** (`index.json.sig` do repo) + assinatura
      por versão (do autor, no índice); chave do repo padrão embutida no
      binário; `ppack key` gera/instala chaves de terceiros
  - **modo `--unsafe`** (2.12): dispensa assinaturas, NUNCA o hash; marcado no
    lock; aviso nomeando o pacote em todo build
- [x] nome global = repo padrão; `fulano/nome` = secundários; o lock fixa a
      origem (o problema dos nomes curtos do podman, registrado)

### Decisões finas a confirmar

| # | pergunta | proposta |
|---|---|---|
| f4.1 | nome do lock | `pack.lock` ao lado do `pack.json` |
| f4.2 | formato do tarball | ustar subset determinístico, `.tar` sem compressão na v1 |
| f4.3 | config de repositórios (lista+padrão) mora onde | no `pack.json` do workspace, seção `repos` |
| f4.4 | `ppack index` assina como | flag `--sign <chave>` |

**Pronto quando**: um projeto FORA deste repo faz `ppack add pui@0.1.0` de um
repo `file://`, compila, roda o teste do pacote; o próprio repo constrói com
`stl` como pacote; publish recusa os três casos com teste; verify 8/8 + seed
do ciclo nº 2.

---

# F5 — reflexão, `--json`, doctest (baterias de linguagem)

**Objetivo.** A tabela de campos no descritor de tipo, e tudo que cai dela:
repr como dado, json genérico, diagnóstico estruturado, `--json` na CLI,
doctest.

### Entregas

- [x] **tabela de campos no `PsDesc`** (FEITA, 2026-08-23):
      `fields: {nome, offset, kind, desc*}` — SÓ campos públicos (não-`private`;
      a mesma noção da lista canónica da API — UMA noção de público para tudo,
      decidido); o `trace` do coletor continua cobrindo TODAS as referências,
      inclusive privadas (mecanismos separados)
  - `struct`/coletados: o descritor já está no objeto (`PsUser.desc`) — só
    cresce; `record` (valor, sem cabeçalho): descritor ESTÁTICO injetado no
    sítio da chamada (o compilador sabe o tipo ali — "um record é grátis")
  - kinds: os primitivos, str, list/dict/set (com desc do elemento), record
    aninhado, struct-ref, enum (com nomes das variantes — o repr precisa),
    def/any (opacos na tabela)
  - custo MEDIDO: +1,4 % no `ppack.c` e +2,6 % no `app.c` do editor — dentro do
    alvo de 5 %. O endereço de um campo vem de uma FUNÇÃO gerada e não de um
    `offsetof` na tabela: `offsetof` num inicializador estático é das poucas
    coisas que o QBE não dobra, e uma função é expressável nos dois back ends
    sem primitiva nova (é também o que faz um `record`, que não tem cabeçalho,
    andar pelo mesmo caminho).
  - o par PsTy/PsDesc é um CICLO, desfeito com uma atribuição no arranque — a
    mesma técnica que o `size` do `PsShape` já usava
- [x] **`repr` vira dado** (FEITO): `ps_repr_ty`/`ps_repr_val`/`ps_repr_desc`
      percorrem a tabela, e a saída é IDÊNTICA AO BYTE à que a forma gerada dava
      — que é a prova de que a troca não mudou a linguagem, só de onde vem o
      código. O `to_str` do tipo continua a ganhar, e agora ganha a QUALQUER
      profundidade (a forma gerada só sabia disso no topo). Uma tupla dentro de
      um contentor ainda usa o adaptador gerado, porque ela vira um `record` e
      imprime-se `(a, b)` e não `Nome(_0=...)` — é a única coisa que ainda o usa,
      e está dito no código.
- [x] **`json.stringify` genérico** (FEITO), pela MESMA tabela: apareceu sem um
      gerador atrás, que é o ponto inteiro da F5. Byte a byte igual ao
      `json.dumps(separators=(',',':'))` do python nos casos do teste, e o que
      sai volta pelo nosso próprio `parse`. As diferenças em relação ao `repr`
      são decisões: um `to_str` do tipo NÃO manda aqui (JSON é dado, e quem o lê
      espera os campos), um enum viaja pelo NOME (f5.2), um conjunto vira ARRAY,
      e o que não atravessa LEVANTA com o CAMINHO onde parou (`[0]`, `.p.x`) —
      64 níveis separam "aninhado" de "ciclo".
- [x] **resposta 6 — diagnóstico estruturado** (FEITA): `--diag-json <arquivo>`
      liga um segundo destino no funil (`fatal_at`/`warn_at`/`cdiag_at`), com
      {arquivo, linha, coluna, gravidade, grupo -W, mensagem}. O TEXTO continua
      intocado — clang-parity 155/155 e os 692 casos medem o texto.
      Três detalhes que fazem a diferença entre servir e não servir:
      o arquivo é escrito TAMBÉM antes de um `exit` por erro (um diagnóstico que
      mata a compilação é justamente o que a IDE mais quer, e perdê-lo por o
      processo ter saído seria o único caso que não pode falhar); sem
      diagnóstico nenhum sai uma lista VAZIA e não a ausência de arquivo ("não
      houve aviso" é uma resposta, e quem consome tem de a distinguir de "o
      compilador nem correu"); e a mensagem é escapada de verdade, então uma
      aspa dentro dela não quebra o JSON.
      Portão: 7 checagens novas em `tests/protocol.sh` (31 agora).
- [~] **`--json` na CLI** (build/test/verify/explain/doc — `why`/`tree`/`search`
      vêm com F4): os MESMOS dados dos eventos e das consultas. Um objeto por
      LINHA no fluxo de eventos, porque quem lê quer reagir enquanto o build
      corre e um documento único só se pode ler no fim; um documento só nas
      consultas, que são resposta e não fluxo. O escapador é o do grafo
      (`G.jstr`) — um segundo seria um segundo lugar para errar. Ainda é
      serialização à mão; quando a reflexão da F5 existir, sai de graça.
- [x] **doctest** (FEITO, 2026-08-23): `>>> expr` numa docstring vira uma aresta
      da suíte. O programa de cada módulo é GERADO no plano a partir da RESPOSTA
      5 (`--api`) — não de um segundo leitor de fontes —, o que quer dizer que o
      doctest de um pacote publicado se pode correr sem ter o fonte à mão. Um
      `.psc` traz os nomes por `from <pkg/mod.psc> import ...` (grafia que
      passou a existir agora: faltava, e era assimetria com `import <>`); um
      `.ph` entra inteiro, porque o que dele atravessa é decidido pela 45.5 e
      não por uma lista de nomes. Uma saída errada põe o build vermelho, com o
      nome do módulo. `publish` continua a NÃO rodar testes.
- [~] baterias em `pbuild/BATERIAS.md` (o `pscript/DESIGN.md` carrega trabalho
      não comitado de outra sessão); gc-stress obrigatório: **128 ok**, e a
      tabela é dado estático e não raiz nova, como se esperava.

### Decisões finas a confirmar

| # | pergunta | proposta |
|---|---|---|
| f5.1 | sintaxe do doctest na docstring | linhas `>>> expr` + linha seguinte = saída esperada |
| f5.2 | `json.stringify` de enum | o NOME da variante (string), não o valor |
| f5.3 | flag do diagnóstico JSON | `--diag-json` (para não colidir com `--json` da CLI ppack) |

**Pronto quando**: baterias verdes, repr/json genéricos com oráculo python3
onde couber, C gerado menor (medido), verify 8/8 + gc-stress limpo.

---

# F6 — o pstudio como IDE (por cima de tudo)

**Objetivo.** O editor orquestra: play, vassoura, painel de build, dev-loop,
erros sublinhados, post-mortem. Nada passa a depender do pstudio.

### Entregas

- [x] **pbuild em processo** (FEITO, 2026-08-23): `packages/pbuild` é uma
      biblioteca, o editor importa-a, e o build corre como tarefa no mesmo
      escalonador que trata o teclado. `pstudio --build [alvo]` prova-o sem
      tela, e `tests/pstudio-build.sh` mede-o no `verify`.
      **Uma coisa saiu diferente do plano, e a favor**: o grafo vem
      SERIALIZADO (`ppack graph`), e não montado no editor. A razão é que o
      descritor é do PROJETO e o editor não o conhece — ele abre qualquer
      árvore. Montá-lo no editor obrigaria a embutir o descritor de cada
      projeto que se abre, o que só funciona para UM projeto, que seria este.
      O custo é um JSON lido uma vez por build.
- [ ] **painel de build**: lê e ESCREVE `pack.json` (o manifesto é do painel;
      `build.psc` é do programador e o painel NÃO o edita — decidido); alvo
      padrão, `-j`, alvo nomeado (linux-amd64 etc.)
      **É o que sobra da F6**, e é um FORMULÁRIO: onde ficam os campos, o que é
      caixa de texto e o que é lista, o que acontece ao gravar. Isso são
      escolhas de quem vai olhar para elas todos os dias — a escolha do alvo já
      existe sem formulário nenhum, na paleta (`!`).
- [x] **play/vassoura** (FEITO, 2026-08-23): na PALETA que o editor já tinha,
      sem inventar atalhos — `Build`, `Build Target…`, `Run`, `Clean`, `Stop
      Build` e `Go To Build Error`. A vassoura mantém `build/pkg`, como a do
      `ppack`. O `Run` constrói e LANÇA (`os.spawn`), mata o anterior por
      SIGTERM antes de relançar (ele está a usar o binário que a construção vai
      reescrever), e o `Stop Build` mata o programa já — ele é do utilizador e
      não do build. `pstudio --run <alvo>` prova-o sem tela, e o
      `tests/pstudio-build.sh` mede-o.
- [~] **`ppack dev`** (2026-08-23): constrói, espera que alguma coisa mude, e
      constrói outra vez. A lista do que se vigia é o GRAFO — os arquivos que o
      compilador disse que lê —, não um diretório: um `dev` que vigiasse a
      árvore veria salvar de editor, temporários e o próprio `build/`. E o que a
      construção PRODUZ fica de fora, senão ela dispara-se a si mesma para
      sempre (o que ela fez na primeira vez que correu).
      **Sem inotify e sem kqueue, e é decisão**: os dois existem, são diferentes
      um do outro, e obrigariam a uma primitiva nova no runtime — para vigiar
      398 arquivos cujas datas se leem em menos de um milissegundo. O laço
      pergunta a cada 200 ms com um debounce de 150. No dia em que a árvore doer,
      a primitiva entra por baixo e o comando não muda.
      **E ele REINICIA o programa** (2026-08-23): mata o filho, espera que ele
      saia, constrói, relança. O `SIGTERM` é um pedido e não uma execução — um
      `SIGKILL` não deixa o programa fechar o que tinha aberto, e um laço que
      corrompe um arquivo a cada salvar é pior do que um que espera meio
      segundo. E o filho sai ANTES de a construção começar, porque ele está a
      usar o binário que ela vai reescrever.
      Para isso entrou na linguagem o terceiro caso de correr um programa:
      `os.spawn` (lança e segue), `os.kill` e `os.alive` — que também COLHE o
      zumbi, senão um laço que relança de dez em dez segundos enche a tabela de
      processos numa tarde. O que volta é o PID e não um objeto: um objeto vivo
      num runtime com coletor levanta a pergunta do que acontece quando ele é
      recolhido com o filho a correr, e três funções sobre um número não têm
      essa pergunta.
- [x] **erros como POSIÇÃO E MARCA** (2026-08-23): o editor lê
      `arquivo:linha:coluna: error:` da saída da aresta — o formato que o
      compilador já usa e que o `ppack` copiou de propósito —, abre o arquivo e
      põe o cursor lá (`Go To Build Error`). É o que "clicar no erro" faz, sem
      precisar do clique. E a linha fica MARCADA na sarjeta (`✗`), que é onde a
      informação continua a ver-se depois de o cursor sair dali.
      Marca e não sublinhado, por uma razão prática: a sarjeta já é desenhada e
      já tem duas marcas (ponto de parada, marcador), então a terceira custa uma
      linha — enquanto um sublinhado ondulado custa um caminho de desenho novo
      por baixo do texto, e a informação que interessa (QUAL linha) é a mesma.
      A marca do build anterior sai quando o seguinte começa: uma marca velha é
      pior do que nenhuma.
- [x] **post-mortem** (FEITO, 2026-08-23): com `-g`, cada moldura imprime o que
      estava em CADA variável, com o `repr` genérico da F5 — que era a
      dependência real, e por isso a ordem. Uma pilha diz ONDE; a pergunta a
      seguir é PORQUÊ, e é ela que faz alguém abrir um depurador.
      Três decisões:
        * os valores são copiados no RAISE e não no relatório — quando o
          relatório acontece a pilha já desenrolou e não há lá nada para ler;
        * são copiados como REFERÊNCIAS (o erro mantém-nas vivas e o coletor
          percorre-as): renderizar no raise seria formatar um grafo inteiro a
          cada erro, incluindo os que alguém usa como fluxo de controlo;
        * o NOME e o TIPO de cada variável são estáticos por moldura, emitidos
          só com `-g` — a moldura recebe-os por uma função à parte
          (`ps_push_fn_dbg`), então um build sem `-g` não paga nem os dois
          stores nem os arrays. A correspondência nome→tipo faz-se do lado da
          árvore PSCRIPT (na de P `list<int>` já é `*PsList` e mais nada), e um
          nome declarado duas vezes com tipos diferentes fica de fora: imprimir
          um valor com o tipo errado é pior do que não o imprimir.
      No terminal sempre; o painel do editor é o que falta.
- [x] barra de status do build (2026-08-23): a barra mostra `[feitas/total]` com
      o que está a correr, e no fim `build ok (N arestas)` ou a PRIMEIRA falha —
      as seguintes são quase sempre consequência dela, e a barra tem uma linha.
      Em texto e não em gráfico, que num editor de texto é o que combina.

**Pronto quando**: o play constrói e roda o próprio pstudio a partir do
pstudio; salvar um arquivo no dev-loop reconstrói só o alcançado e reinicia;
um erro de compilação aparece sublinhado no arquivo certo.

**Estado em 2026-08-23**: o motor corre dentro do editor, os comandos estão na
paleta, o play constrói e lança, o erro do build leva o cursor ao sítio, e o
`ppack dev` reconstrói e relança ao salvar. O que falta é **o que precisa de olhos** — o painel que edita o
`pack.json`, o sublinhado desenhado, a barra com a lista de arestas — O `Run` já lança e mata. A informação para os três painéis já está
toda no `App`: `build_msg`, `build_total`, `build_feitas`, `build_erro`,
`build_pos_*` e `build_targets`.

---

# F7 — o `run` sai do compilador (passo TARDIO)

**Objetivo.** O `plangc` deixa de tomar a ÚNICA decisão que ainda toma. Só
depois de `ppack run` maduro.

- [x] `tests/run-cmd-ppack.sh` mede `ppack run` (9 checagens, os MESMOS
      comportamentos: 2ª vez não constrói nada; editar o fonte, um módulo
      importado ou o COMPILADOR invalida; o status é o do programa; um `.p`
      corre igual; o binário vive em `build/run/`; um arquivo que não existe é
      mensagem). `tests/run-cmd.sh` foi apagado.
- [x] paridade MEDIDA, e melhor dos dois lados: **2,5 s frio / 6 ms quente**,
      contra 3,3 s / ~10 ms do `plangc run`. O que faz o quente ser quente é o
      MANIFESTO — a lista dos arquivos que a construção leu (que o compilador
      disse, não que se adivinhou) com a data de cada um. Sem ele, cada corrida
      pagava meio segundo em duas perguntas ao compilador para descobrir que não
      havia nada a fazer; e montar o descritor inteiro custava DOZE segundos, o
      que o caminho do arquivo solto agora evita construindo um grafo mínimo.
- [x] removidos de `main.p`: o subcomando `run`, `run_cache_dir`,
      `run_manifest_ok/write`, `run_exec`, `run_program`, o `RT_SRCS` (já tinha
      morrido na 1.5a) e o alias `pscript` por `argv[0]`. `--ps-runtime` FICA:
      um projeto fora desta árvore precisa de dizer onde o runtime está, e a
      1.5(a) sozinha não responde isso. `plangc run` agora é um erro que diz
      para onde a coisa se mudou e porquê.
- [x] `~/.cache/pscript` deixa de ser escrito: o binário vai para `build/run/`,
      dentro do projeto, que `make clean` alcança. README atualizado.
- [x] `os.exec` na linguagem (era o que faltava): o programa PASSA A SER o
      processo. Antes ele corria como filho com a saída capturada, o que serve
      para um programa que imprime e para mais nada — sem teclado, sem tela, sem
      tamanho de terminal, sem Ctrl-C.
- [x] seed regenerado; `verify` verde; docs atualizados

**PRONTO** (2026-08-23): o compilador não tem mais política nenhuma, e a
promessa "um binário roda scripts" passou oficialmente ao `ppack`.

---

# F9 — a releitura das especificações, e os buracos que ela achou

Feita a 2026-08-23, com os documentos abertos ao lado do código: `DESIGN.md`,
`ARQUITETURA.md`, `DECISOES.md`, `ppack/DESIGN.md` e `ppack/REPOSITORIO.md`,
decisão por decisão, contra o que existe. **Seis decisões estavam escritas e não
estavam feitas** — nenhuma delas aparecia como pendente em lugar nenhum, que é o
que torna esta varredura o passo que faltava.

- [x] **`pool = console` no EXECUTOR.** O campo existia no grafo e a exportação
      para ninja escrevia-o; o executor ignorava-o. Faltava a metade de baixo:
      `os.run(..., console=True)` é a AUSÊNCIA de captura — sem cano, o filho
      herda os descritores deste processo — e a sema recusa `console=` junto com
      `stdout=`, que seriam duas ordens contrárias sobre o mesmo descritor. Quem
      serializa é o executor (três linhas no `take_ready`), e a suíte do motor
      prova as duas metades de fora.
- [x] **`ppack build --repro`.** Constrói duas vezes, do zero, e compara byte a
      byte. As saídas da primeira são MOVIDAS para `build/repro/` — mover
      preserva o arquivo como ele é (a permissão de execução inclusive) e
      permite pô-lo de volta quando a segunda falha. O grafo da segunda monta-se
      ANTES de mover fosse o que fosse: montá-lo é perguntar ao compilador, e o
      compilador é uma das saídas.
- [x] **`ppack doc --html <pasta>`.** O mesmo conteúdo do terminal como site
      estático, da mesma resposta 5. A caminho apareceu um defeito com dono: o
      `--api` do `ppack doc` nunca passava `--pkg-path`, então todo módulo que
      importa `<pkg/mod.ph>` respondia "não achei".
- [x] **os PISOS dos placares no descritor.** `c-suite >= 220` e
      `wacct >= 741` viviam em duas variáveis de shell no topo do
      `verify-all.sh`. Agora cada placar é duas arestas — uma que roda, outra
      que lê o número e compara (`pbuild/ps/piso.psc`) — e as duas suítes
      entram no `ppack verify`. O arreio LÊ o piso do descritor: um lugar só
      onde se sobe um número.
- [x] **`ppack lock`.** Estava na lista de comandos da v1 e não existia. Refaz o
      lock a partir do manifesto, sem construir; recomeça em vez de remendar, e
      por isso o que já ninguém puxa sai sozinho. A secção dos repositórios
      sobrevive: as chaves aceites por TOFU não são resultado da resolução.
- [x] **as três recusas do `publish`.** Dependência que o destino não resolve,
      `.psc` fora de `test/` num pacote `lang: p`, e subida de versão que não
      bate com a interface (`patch` não muda nada, `minor` só acrescenta). Todas
      de graça: o índice já traz as dependências e a lista canónica da API.

E três achados que não estavam em especificação nenhuma:

- [x] **aspas triplas com aspas dentro.** `"""a "b" c"""` saía como `a  c`: o
      decodificador aplicava a regra do C (literais adjacentes concatenam-se,
      toda aspa é fronteira) ao corpo de uma string tripla. Ciclo de seed.
- [x] **o contador do relatório não recomeçava.** `feitas` e o placar são
      globais, e a segunda construção do mesmo processo dizia `[64/61]` — o
      `ppack dev` fazia isso a cada mudança.
- [x] **a suíte do motor não estava ligada a portão nenhum.** 89 conferências
      que ninguém corria, e uma delas já tinha apodrecido em silêncio (esperava
      dois pacotes no workspace, que hoje tem nove). Entrou no `verify`.

## O que a releitura decidiu NÃO fazer, e por quê

- [ ] **um pacote que traz `.c` PRÓPRIO** (2.13 e "o que cabe dentro de um
      pacote"): a decisão diz que o C de um pacote é compilado pelo `plangc` e
      que as flags dele são declaração no manifesto. O que existe hoje compila o
      C que o COMPILADOR emite, com flags que o descritor passa — nenhum dos
      nove pacotes traz um `.c` escrito à mão. Fazer o manifesto declarar
      `csources`/`cflags` sem um consumidor é escolher a forma no escuro: como
      se nomeiam os arquivos, se o caminho é relativo ao pacote, o que acontece
      com a ordem de link, e se as flags valem para quem consome. Fica anotado
      com o motivo, e não como esquecimento.
- [ ] **o painel de `pack.json` do pstudio** (o que sobra da F6): é um
      FORMULÁRIO, e onde ficam os campos é escolha de quem vai olhar para eles
      todos os dias. A escolha de alvo — a parte útil — já existe na paleta.

---

# F8 — futuro registrado, SEM compromisso de ordem

- [ ] **QBE embutido, forma (2)+(3)**: o C do QBE (18 220 linhas) compilado
      pelo NOSSO front end — é também o teste de fogo do cfront — e o IL indo
      por buffer ao parser dele; `ppack run` frio cai de ~3,3 s para décimos;
      o `as`/`cc` continuam no link
- [ ] **assembler + linker EM P** (decidido: escrever, com minias/neatld como
      referência lida): primeiro alvo amd64/ELF; oráculo `as` byte a byte
      (86 mnemônicos medidos, 10 = 95 %); linker dinâmico é o que substitui o
      cc (glibc, SDL2); o estático + **musl** (`linux-amd64-musl`) dá o
      binário único e a trilha livre; macOS fica no `cc` indefinidamente
- [ ] **MVS** (mínimo do Go) por cima da versão exata — aditivo, o lock não
      muda de formato
- [ ] índice em dois níveis (release assinado + índices grandes) quando a
      lista de API inchar o `index.json`
- [ ] debugger interativo (parar/inspecionar/continuar) por cima do
      post-mortem; pstudio no navegador (registrado como curiosidade)

---

## Mapa de arquivos por fase (para coordenar trabalho paralelo)

| fase | mexe em | NÃO mexe em |
|---|---|---|
| F0 | `selfhost/main.p` (+ funções de saída) | sema/lower/backends |
| F1 | `lexer.p`, `parser.p`, `ps_parser.p`, `ps_sema.p`, `ps_lower.p`, `main.p` + **seed** | runtime, harnesses |
| F2A | `pscript/runtime/psrt_os.p/.ph`, `psrt_rt.p` (laço), `ps_sema/lower` (assinatura os.run) | selfhost front/backends |
| F2B | `pbuild/ps/*` (novo), `tests/pbuild/` (novo) | tudo o mais |
| F3 | `pbuild/ps/*`, `build.psc` (novo), `Makefile`, `tests/*.sh`, `.gitignore` | compilador |
| F4 | `packages/*`, `selfhost` (imports `<stl/...>`) + **seed**, runtime (sha256), `ppack` | — |
| F5 | `psrt_types.ph`, `psrt_val/rt.p`, `ps_lower.p`, `util.p` (diag), `ppack` | — |
| F6 | `pstudio/ps/*`, runtime (`os.watch`), `ppack dev` | compilador |
| F7 | `selfhost/main.p` (remoções) + **seed**, `tests/run-cmd.sh` | — |

## Riscos nomeados (e onde o plano os ataca)

1. **A escada como alvo** (F3-B): a saída de uma etapa é a FERRAMENTA da
   seguinte. É o primeiro alvo a escrever no `build.psc`, não o último — se a
   aresta gorda não a expressar bem, é o desenho que está errado, e melhor
   saber cedo.
2. **`os.run` × workers × coletor** (F2-A): fork com threads vivas é a região
   das armadilhas da 107. Spawn só do laço principal; gc-stress/net-late/
   print-atomic a cada passo; sonda sempre com timeout.
3. **Granularidade de mtime** (F2-B): sem `getmtime_ns` o motor erra em builds
   sub-segundo — por isso ele é entrega da fase, não melhoria.
4. **Mover `stl/`** (F4-B): Makefile+harnesses+seed no mesmo movimento — commit
   isolado, verde antes e depois, e é o ÚNICO conteúdo do ciclo de seed nº 2
   junto com os imports novos.
5. **Dois donos durante F3**: até `ppack verify` 8/8, o Makefile é a verdade;
   nenhum harness passa a chamar ppack antes da Parte D.
6. **A tabela de campos** (F5) muda layout de dado do runtime — o cache
   `PSBUILD_RT` deve ser limpo nos harnesses (lição registrada da 107) e o
   gc-stress é gate, não sugestão.
7. **Contratos que a IDE vai consumir** (eventos, resposta 6, `--json`):
   mudá-los depois de F6 custa caro — por isso são deliberadamente MÍNIMOS
   (quatro eventos, seis campos de diagnóstico).
