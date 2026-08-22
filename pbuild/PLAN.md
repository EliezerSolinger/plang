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
- [ ] F1 (BLOQUEADA: mexe em lexer/parser/sema, área dele)
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

- [ ] **`--version`**
  - constante `PLANG_VERSION = "0.1.0"` em `selfhost/main.p` (semver da
    LINGUAGEM: menor = recurso novo, maior = quebra — decidido)
  - imprime `plangc 0.1.0 (<hash-dos-bytes>)`; o hash é o mesmo cálculo que o
    `run` já faz (`hash_file(argv[0])`, `main.p:551`) — extraí-lo para função
    reutilizável, porque F7 vai apagar o `run` e a função fica
  - `-h` menciona; sai com status 0
- [ ] **Pergunta 1 — "o que você leu?"** (flag de deps)
  - lista, uma por linha, TODA fonte aberta na compilação: o arquivo pedido,
    imports transitivos (`.ph` e os `.p`/`pmod` que eles puxarem), `embed()`/
    `embed_bytes()`, e os headers de `include <h>` **depois** do preprocessador
    (o `.i` efetivo — o que o manifest do `run` já rastreia hoje; reusar esse
    caminho: a lista existe, falta a saída)
  - caminhos como foram resolvidos (relativos ao cwd), ordem estável
    (a ordem de descoberta é determinística — o laço de inputs de `main.p`)
  - combinável com `--parse-only` para custar só o front end
- [ ] **Pergunta 3 — "o que você VAI emitir?"** (flag de outputs)
  - por entrada: os artefatos que aquela invocação produziria com os mesmos
    argumentos (`x.c`, `x.h` quando `.ph`+backend C, `pmod_*.c` de um `.psc`,
    `.ssa` no backend QBE), SEM rodar sema nem codegen além do necessário
    (front end + resolução de imports — medido: 0,12 s no maior arquivo)
  - o espelhamento do `--out-dir` aplicado aos nomes (o mesmo código de caminho
    que a emissão usa — extrair a função, não duplicar)
- [ ] **Pergunta 2 — a LISTA CANÓNICA DA API + hash (1.5b)**
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
- [ ] **Pergunta 4 — "quem é você?"**: já existe (hash dos bytes); ganha saída
      própria na flag de versão e na resposta 2 (o par versão+hash acompanha a
      lista, para o lock de F4 gravar)
- [ ] formato de saída desta fase: **texto, uma informação por linha** com
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

- [ ] **Docstring `"""..."""` nas duas linguagens**
  - lexer: ligar `triple_str` no `P_LEXSPEC` (`lexer.p:33` — a máquina já
    existe, o pscript já a usa; conferir interação com f-string: em P não há
    prefixo de interpolação, então `"""` é sempre literal cru)
  - gramática: string sozinha como PRIMEIRA instrução de `def`/`struct`/
    `record`/módulo = docstring; em qualquer outro lugar, `"""` é só string
    multilinha (55.1 do pscript, agora também em P)
  - P: a docstring vai para o AST e **não gera código** (dropada no backend —
    zero byte no binário, decidido); pscript: mantém a 46.3 (acessível em
    runtime)
  - precedência: para um módulo P com `.ph` e `.p`, a docstring do **`.ph`
    vence** na API (é a interface); a do `.p` documenta a implementação e não
    sai na resposta 5
  - **resposta 5 do protocolo**: a lista canónica da F0 ganha a docstring de
    cada símbolo (a doc NÃO entra no hash — teste de invariância já preso na F0)
- [ ] **`import <pkg/mod.ph>`**
  - reusar o caminho do `include <...>` (contextual, reconstrução de tokens —
    `parser.p:1284`); vale em P e em pscript
  - resolução: procura em cada raiz de `--pkg-path` (repetível; o ppack passa
    `build/pkg/<nome>-<versão>-<hash>/` por pacote resolvido; para o workspace,
    o diretório do pacote local). SEM fallback para caminho relativo — `<>` e
    `"..."` não se misturam (a ambiguidade silenciosa foi explicitamente
    recusada)
  - erro quando não acha: listar as raízes procuradas (mensagem no padrão da
    casa: explica a decisão, não acusa o token)
  - `--out-dir`: módulo de pacote espelha sob `build/obj/<pacote>/...` — a
    regra de espelhamento ganha uma raiz por origem (decisão fina f1.2)
- [ ] **1.5(a) — `import` implica o módulo (a regra do `.p` irmão)**
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
- [ ] **1.5(d) — `import "x.ph"` dentro de módulo pscript importado**
  - hoje: o import de `.ph` só é honrado quando está no arquivo NOMEADO;
    num módulo importado, silêncio + `#include` órfão (medido). Corrigir em
    `ps_sema`/`ps_lower`: o `.ph` importado por QUALQUER módulo do fechamento
    entra na compilação e nas respostas 1/3
  - o contorno do `hl` em `tests/run.sh` (compilar `hl.p`+lexer+util+utf8 à
    mão) vira o teste de regressão: apagar o contorno, o build do editor tem
    de continuar passando
- [ ] **regenerar o seed** (reseed.sh) uma vez, com os quatro itens dentro
- [ ] baterias registradas no `pscript/DESIGN.md` (número novo, uma por item)

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

- [ ] **API**: `await os.run(argv: list<str>, env: dict<str,str>? = None,
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
- [ ] **`path.getmtime_ns`**: o timespec já é lido (`psrt_os.p:326`); devolver
      `sec*1e9+nsec` numa função nova (não mudar a existente — oráculo python3
      confere `getmtime` em segundos)
- [ ] armadilhas conhecidas (memória da 107): sondar SEMPRE com timeout;
      rodar `gc-stress`, `net-late`, `print-atomic` a cada passo; fork numa
      máquina com workers = threads → spawn só do laço principal, documentado
- [ ] oráculo: casos comparados com `subprocess.run` do python3
      (`tests/oracle/py/`) — status, captura, env, cwd

### Parte B — a biblioteca do motor (pscript puro; **não imprime — relata**)

Módulos propostos (espelham o samurai lido): `lib_graph.psc` (nós/arestas),
`lib_dirty.psc` (sujeira+log), `lib_sched.psc` (fila+executor),
`lib_events.psc` (o contrato com as frentes). Moram em `pbuild/ps/` até
virarem pacote.

- [ ] **grafo**: nó = arquivo (path canónico, mtime_ns com MISSING/UNKNOWN,
      hash do log, gerador, usos); aresta gorda = `argv`, entradas em TRÊS
      faixas (normais | implícitas | order-only), saídas (+ implícitas),
      `env`, `cwd`, `stdout`, `restat`, `generator`, `pool`, `console`;
      contadores `nblock`/`nprune`
  - construtores: de `dict` (a via em memória, 1.8) e de JSON (mesmo shape)
- [ ] **sujeira**: os SEIS testes do ninja NA ORDEM (`graph.cc:222`, lidos):
      falta → restat-log → mais velha que entrada → hash do comando →
      mtime gravado < entrada → sem registro; o hash do comando cobre
      **argv + env efetivo + cwd + stdout + alvo** (as extensões decididas)
- [ ] **restat e poda**: `shouldprune`/`nodedone(prune)` do samurai (~40
      linhas em cima dos contadores) — é o que transforma "regenerei C
      idêntico" em "não recompilo os 18 s"
- [ ] **depfile do `cc -MD`** (o lado C continua estranho, decidido): parser do
      subset Makefile (alvo: os `.d` que gcc/clang emitem; ler o `depsparse`
      do samurai como referência), entradas viram implícitas + gravadas no log
      para a corrida seguinte
- [ ] **log** em `build/log/build.log`, texto com versão no cabeçalho, uma
      linha por saída: `mtime_ns  duração_ms  hash_cmd  hash_env  caminho`
      (o samurai grava `0\t0` na duração; nós usamos — 1.7); releitura na
      carga, rewrite quando inchar (o mecanismo do `loginit` lido)
- [ ] **fila**: caminho crítico com peso = **duração da última vez** (do log;
      1 s de chute na primeira vez), topo-sort + propagação reversa (o
      `ComputeCriticalPath` lido, trocando o peso-1); desempate por id
- [ ] **executor**: N=`os.nproc` (precisa expor no `os` — item novo pequeno),
      `-k N` (padrão 1: para na primeira), pool `console` (sem captura,
      sozinho na vez), sinais (matar filhos e sair com 128+sig), saída de cada
      aresta despejada INTEIRA no evento
- [ ] **higiene**: ERROS — saída declarada e não produzida (stat pós-aresta),
      ciclo (o marcador FLAG_CYCLE lido), entrada que não existe e ninguém
      produz; AVISOS — entrada declarada nunca lida (via resposta 1 quando a
      ferramenta é o plangc), aresta inalcançável, saída sem consumidor
- [ ] **eventos**: `plano_pronto(total)`, `aresta_iniciou(id)`,
      `aresta_terminou(id, status, saída, duração)`, `fim(ok, falhas)` — e
      NADA mais (decidido); `--explain` é consulta sobre o plano, não evento
- [ ] **suíte do motor** (`tests/pbuild/`, harness próprio no padrão da casa):
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
  - [ ] o gate de tag de libc (o grep do verify-all vira veredicto)
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
- [ ] as demais suítes com pisos; QBE fixed point; oráculos/conformance/
      gc-stress como arestas `command()` sobre os harnesses existentes
- [ ] `pack.json` de WORKSPACE na raiz (membros: `packages/*` quando existirem;
      alvo padrão; é DADO — o painel da IDE o edita em F6)

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
- [ ] `ppack verify` — o alvo do verify-all inteiro
- [x] `ppack clean` — apaga o que o build produziu, MANTÉM `build/pkg`
- [x] `ppack explain <saída>` e `ppack graph` (JSON); `why`/`tree`/`lock` são
      de F4 e ficam com ela
- [x] **`ppack ninja`**: desce a aresta gorda para texto ninja — aspeamento
      GERADO (nós sabemos onde cada argumento começa); `restat`/`generator`/
      `pool console` mapeiam 1:1; `env`/`cwd` viram wrapper explícito no
      comando (documentado no cabeçalho de `lib_ninja.psc`, com os quatro
      pontos em que a exportação é conservadora). O aspeamento é GERADO e tem
      caso próprio na suíte: caminho com espaço, argumento com `$`, aspa simples
      — e o comando exportado é RODADO por um shell para conferir que escreve o
      que a aresta prometia. Determinista, conferido duas vezes.
- [ ] `build.ninja` COMITADO na raiz + bootstrap no README (fica com a TROCA:
      um `build.ninja` comitado que descreve um `build/` que o Makefile ainda
      não usa seria um arquivo que mente)

### Parte D — a TROCA (um commit, repo verde antes e depois)

- [ ] `tests/psbuild.sh` reimplementado como chamada de `ppack` (ou os
      harnesses que o usam passam a chamar `ppack` direto)
- [ ] `Makefile` vira casca: `make` → build do seed + `ppack build`;
      `make verify` → `ppack verify`; alvos antigos apontam e avisam
- [ ] `out/` → `build/{obj,bin,log,pkg}`; `.gitignore`; docs atualizados
- [ ] as CINCO listas de módulos somem dos harnesses (a sexta, `RT_SRCS` no
      compilador, morre em F7)

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

- [ ] **`pack.json` de pacote**: `name` (minúsculas, [a-z0-9_-]), `version`
      (semver estrito), `lang` (`p`|`pscript`), `root` (o módulo-interface),
      `deps` (nome → versão EXATA, ou `{path}` para workspace), `system`
      (nome → `{pkg-config}` ou flags literais por alvo), `toolchain`
      (faixa mínima), `description`
  - validação com erros posicionais (linha/coluna no JSON — o parser de json
    do pscript precisa expor posição de erro; item pequeno, conferir)
- [ ] **tipos verificáveis**: pacote `lang: p` com `.psc` no fechamento = erro
      na resolução; pacote P só depende de pacote P (o subgrafo P é livre de
      runtime — invariante conferido no resolve, não no build)
- [ ] **lock `pack.lock`** (JSON, decidido "dois arquivos, um armazém"): por
      pacote — nome, versão, SHA-256 do tarball, repositório de origem (URL ou
      `path`), `unsafe: true` quando 2.12, faixa de toolchain do manifesto +
      a versão/hash do plangc que resolveu
  - dessincronizado do manifesto → atualiza sozinho e IMPRIME o diff
    (entrou/saiu/mudou de hash); `--frozen` para CI recusa
- [ ] **workspace**: membros por `path`; o hash de um pacote local é o hash do
      DIRETÓRIO (lista ordenada de arquivos + hash de cada — `os.listdir` já
      ordena de propósito); mudou → o lock anota, o build o vê como entrada
- [ ] resolução (fase 1 do ciclo): ler manifesto+lock → verificar hashes do
      que já está em `build/pkg/` → baixar o que falta → verificar → extrair em
      `build/pkg/<nome>-<versão>-<hash>/` → montar `--pkg-path` → conferir
      toolchain ANTES de compilar (mensagem: "o pacote foo exige plangc >= X,
      o seu é Y") → **daqui em diante zero rede**

### Parte B — os dois primeiros pacotes (o ciclo de seed)

- [ ] **`packages/stl`**: mover os 10 `.ph`; os imports do selfhost viram
      `import <stl/vec.ph>`; as 41 referências externas (Makefile → build.psc,
      harnesses, corpora) atualizadas; **regenerar o seed** — commit isolado,
      repo verde antes e depois (risco nº 4)
- [ ] **`packages/pui`**: extrair `lib_pui.psc` (zero import — medido) +
      `pack.json` + `packages/pui/test/` (o `pui_test.psc` e o `.expected`
      saem de `tests/pstudio/` para dentro do pacote; `ppack test` roda testes
      de pacotes do workspace); o `app.psc` do editor importa `<pui/pui.psc>`
      via workspace — hmm: import de `.psc` por pacote é o caso 1.5(c)-lite;
      enquanto módulo pscript não é TU, o import de pacote pscript é textual
      como o import local já é (mesmo mecanismo de hoje, raiz diferente)
- [ ] `core`/`hl`/`cv`/`complete` FICAM no pstudio (decidido — intrínsecos)

### Parte C — repositório, comandos, confiança

- [ ] **SHA-256**: módulo da stdlib implementado em P (o padrão 108.4, como
      random/time — `psrt_*` novo ou módulo `hash`), ~200 linhas, vetores de
      teste do NIST no harness
- [ ] **tarball**: subset ustar (escrever + ler) em pscript — nomes, tamanho,
      conteúdo; sem dono/permissão além do básico; determinístico (ordem
      ordenada, mtime zerado) para o hash ser estável — decisão fina f4.2
- [ ] **`index.json`**: por pacote/versão — metadado do manifesto + SHA-256 do
      tarball + **a lista canónica da API** (da resposta 2/5); gerado por
      `ppack index <dir>` (o comando que mantém um repositório-diretório)
- [ ] **transportes**: `file://` e `http://` (o cliente HTTP conformante já
      existe); `ppack update` baixa o índice do(s) repos configurados e guarda
      em `build/pkg/index/` (offline depois)
- [ ] **`ppack search <termo>`**: por nome, descrição E SÍMBOLO (a lista de API
      no índice — o diferencial decidido)
- [ ] **`ppack add nome@versão`** (mexe manifesto+lock, baixa p/ hash, NÃO
      constrói), **`ppack up [nome]`** (versão exata nova, mostra diff de API
      entre as duas versões — as listas estão no índice), **`ppack why`**
- [ ] **`ppack publish`**: monta o tarball (com `test/`, sem `build/`),
      SHA-256, assinatura do autor, entrada de índice — e RECUSA: dep por
      `path`, `.psc` em pacote P, versão minor/patch cujo hash de API mudou
      (comparado com a versão anterior no índice)
- [ ] **Ed25519 em P** (~500 linhas, aritmética pura; vetores RFC 8032 no
      harness) + **índice assinado** (`index.json.sig` do repo) + assinatura
      por versão (do autor, no índice); chave do repo padrão embutida no
      binário; `ppack key` gera/instala chaves de terceiros
  - **modo `--unsafe`** (2.12): dispensa assinaturas, NUNCA o hash; marcado no
    lock; aviso nomeando o pacote em todo build
- [ ] nome global = repo padrão; `fulano/nome` = secundários; o lock fixa a
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

- [ ] **tabela de campos no `PsDesc`** (bateria própria):
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
  - custo medido a validar: ~38 descritores no editor, alvo < 5 % do C gerado
- [ ] **`repr` vira dado**: `ps_repr` genérico no runtime percorre a tabela;
      `to_str` definido VENCE (o teste `repr.psc`/`Money`/`$2` prende); o
      gerado por tipo some do `ps_lower` (menos C emitido — medir antes/depois)
- [ ] **`json.stringify` genérico** pela tabela (record/struct/list/dict/
      primitivos); ciclo → erro com caminho (`a.b[2].c`); `any` → pelo tipo
      dinâmico; `def` → erro
- [ ] **resposta 6 — diagnóstico estruturado**: o funil `fatal_at`/`warn_at`
      (`util.p:150`) ganha um sink que acumula {arquivo, linha, coluna,
      gravidade, grupo -W, mensagem}; uma flag despeja em JSON no fim; **o
      TEXTO continua a referência** (clang-parity e os 692 casos medem o texto
      — gate intocado)
- [ ] **`--json` em toda a CLI** que produz informação (build/test/verify/
      explain/why/tree/search/doc): serialização dos MESMOS dados dos eventos
      e consultas — agora de graça pela reflexão
- [ ] **doctest**: exemplos na docstring viram arestas de teste na suíte do
      pacote/projeto (compila + roda + compara saída); sintaxe na decisão fina
      f5.1; entra no `ppack test` e no `publish` (que já roda? NÃO — publish
      não roda testes, decidido; o doctest é suíte normal)
- [ ] baterias numeradas no `pscript/DESIGN.md`; gc-stress obrigatório (a
      tabela é dado estático, não raiz nova — conferir com o stress)

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

- [ ] **pbuild em processo**: o editor (pscript) importa a biblioteca do motor
      e roda o build como TASK no MESMO laço de eventos da UI (o laço já
      existe — teclado/render; os eventos de aresta chegam como mensagens);
      o grafo como `dict`, sem serializar (1.8)
- [ ] **painel de build**: lê e ESCREVE `pack.json` (o manifesto é do painel;
      `build.psc` é do programador e o painel NÃO o edita — decidido); alvo
      padrão, `-j`, alvo nomeado (linux-amd64 etc.)
- [ ] **play** = `run` do alvo padrão (constrói; o programa abre; parar/re-play
      mata o filho); **vassoura** = clean (mantém `build/pkg`)
- [ ] **`ppack dev`** (e o mesmo motor no editor): inotify no Linux /
      `EVFILT_VNODE` no kqueue do macOS como fonte de fd no multiplexador
      EXISTENTE (item de runtime: `os.watch(paths) -> canal de eventos`;
      bateria própria); debounce curto; reconstrói o alcançado; reinicia o
      programa (mata, espera, relança)
- [ ] **erros sublinhados**: a resposta 6 consumida pelo editor — clique leva
      a arquivo:linha:coluna; o formato de erro do próprio ppack (posicional)
      entra pelo MESMO caminho
- [ ] **post-mortem**: em `raise` não capturado (e nos traps que o runtime já
      pega) com `-g`: despejar a pilha COM VALORES — a shadow stack já carrega
      os frames e o coletor já sabe o que é referência; os valores imprimem
      com o `ps_repr` genérico da F5 (dependência real: F5 antes); no
      terminal sempre, e num painel quando dentro do editor
- [ ] barra de status do build (a lista de arestas + tempo — os eventos bastam)

**Pronto quando**: o play constrói e roda o próprio pstudio a partir do
pstudio; salvar um arquivo no dev-loop reconstrói só o alcançado e reinicia;
um erro de compilação aparece sublinhado no arquivo certo.

---

# F7 — o `run` sai do compilador (passo TARDIO)

**Objetivo.** O `plangc` deixa de tomar a ÚNICA decisão que ainda toma. Só
depois de `ppack run` maduro.

- [ ] `tests/run-cmd.sh` reescrito para medir `ppack run` (os MESMOS
      comportamentos: 2ª vez não chama cc; editar módulo importado invalida;
      editar o compilador invalida; status de saída é o do programa)
- [ ] paridade de experiência conferida: `ppack run x.psc` frio/quente nos
      tempos do `plangc run` de hoje (3,3 s / ~10 ms) — sem regressão
- [ ] remover de `main.p`: o subcomando `run`, `run_cache_dir`,
      `run_manifest_ok/write`, `run_exec`, `run_program`, o bloco `RT_SRCS`
      (a SEXTA lista morre), o alias `pscript` por `argv[0]` (`main.p:410`),
      `--ps-runtime`, `--no-assert`/`-O` se só serviam ao run (conferir: são
      do build de .psc em geral — ficam)
- [ ] `~/.cache/pscript` deixa de ser escrito; nota de migração no README
- [ ] regenerar seed; `verify` 8/8; docs atualizados

**Pronto quando**: run-cmd verde via ppack, o compilador não tem mais política
nenhuma, e a promessa "um binário roda scripts" passa oficialmente ao ppack.

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
