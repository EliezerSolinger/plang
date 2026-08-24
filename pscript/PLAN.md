# pscript — plano de execução

**Este arquivo é o ponto de retomada.** Ele existe porque o contexto de uma sessão se
compacta e some; o repositório não. Quem retomar (inclusive eu mesmo depois de uma
compactação) deve ler **este arquivo primeiro**, depois a seção "Estado da
implementação" de `DESIGN.md`.

Atualize o estado das etapas AQUI ao terminar cada uma, no mesmo commit lógico do
trabalho. Uma etapa só está `[x]` quando `make verify` deu 8/8 **e** o seed foi
regenerado.

---

## Estado em 2026-08-20 (a varredura da especificação)

`pscript/AUDIT.md` é o arquivo novo desta rodada: uma linha por decisão numerada
do DESIGN, com veredito conferido por PROVA — um programa que exercita a decisão,
compilado e rodado. As baterias 91 a 96b registram o que ela fechou.

**Fechado nesta rodada** (tudo era decisão antiga sem implementação):

- dict em ordem de inserção (91), o layout compacto do CPython;
- test262 portado como 25 propriedades de ordem contra o node (88.1 revisitada);
- `Task<Task<T>>` não achata, com portão (87.2);
- as três comprehensions — set, dict, e `range`/string como iterável (92);
- nove diagnósticos que explicam a DECISÃO em vez de acusar um token (92.3);
- `items`/`keys`/`values` (61.4) e o walrus (45.2), mais dois defeitos que eles
  desenterraram: `for k in d` dentro de `async def` crashava, e uma condição de
  `if` num `async def` descartava o que ela hoistava;
- `sorted` por `key=len` e por `Comparable`, com o sort dos índices trocado de
  O(n²) para merge sort estável (93.1/93.2);
- o comptime da 65.11, o `-O` da 46.4, `out`/`ref` da 65.12, e quatro defeitos do
  `T[N]` (93.3–93.5, 96b);
- o rastro de pilha (34.2/15.2) e o handler de crash (12.4) — e o defeito que
  isso desenterrou, que era o pior de todos: o ZERO de um tipo coletado era NULL,
  e NULL no meio de uma expressão era segfault em vez de exceção pendente (94.3);
- `plangc run` com cache de conteúdo: 2,9s a frio, 4ms depois (95);
- `const` de módulo que precisa ser construído, e o congelamento fundo (96).

**O que ficou, e por quê** — ver o fim do `AUDIT.md`:

- quatro perguntas que são DECISÃO sua (print de contêiner, tupla terminar ou
  tirar, o `poll()` onde a 18.4 pediu epoll, e o padrão do `--trace`);
- duas coisas de trabalho: `Sequence<T>` como tipo de parâmetro (60.3/62.1) e
  `const def` no pscript (65.10);
- a LINHA por frame no rastro, que custa uma escrita por instrução com chamada.

## Regras que não se negociam

Vieram do usuário ao longo do projeto e valem para tudo abaixo.

1. **~~Nunca commitar. Nunca dar push.~~** — REVOGADA por você em 2026-08-19: o
   commit e o push passaram a ser autorizados, e desde então cada leva entra com
   sua própria mensagem. A regra fica registrada porque explica os primeiros
   meses do histórico (uma árvore limpa e um resumo por etapa).
2. **`make verify` tem de dar 8/8 depois de cada etapa**, e o seed tem de ser
   regenerado (`bootstrap/` em dia com os fontes). A receita está no fim deste
   arquivo.
3. **Nada de atalho.** Solução completa, robusta e definitiva; se algo não couber,
   diga o que ficou de fora e por quê, em vez de entregar meio.
4. **Só o usuário decide design.** Se aparecer uma bifurcação de linguagem, NÃO
   decida: registre como bateria nova em `DESIGN.md` com as opções e a consequência
   de cada uma, escolha a saída **mais conservadora** para não travar, e marque no
   texto que está pendente de decisão.
5. **Todo código e toda mensagem de erro em INGLÊS** (58.1, 51.4), no pscript e no
   selfhost.
6. **libc é o runtime; nunca abstrair.** Exceção única: `--inline-runtime`.
7. **Tuplas foram removidas do P a pedido — não repropor para o P.** No pscript elas
   existem normalmente.
8. Cada etapa entra com **teste que roda**, nos três modos (C, QBE, C89), como a 50.4
   pediu.

## O critério que ordena o trabalho (65)

Duas perguntas, nessa ordem:

1. **Precisa de runtime?** Não → o recurso mora no **P**, e o pscript herda de graça
   porque baixa para P.
2. **É seguro de memória?** Sim → o pscript pode **baixar em cima** disso em vez de
   sintetizar.

Cada travessia converte código do `ps_lower` em código do P que **a sema do P
verifica** (49.1). Por isso levar coisa para o P não é generosidade: é o que faz o
lowering encolher e ficar conferido.

---

## Etapas

### Fase A — em dia

- [x] **A1** `embed`/`embed_bytes` no P (63.5) + `import ... as ns` (42.4)
- [x] **A2** Lexer compartilhado por `LexSpec`; `TokKind` comum
- [x] **A3** Front end do pscript: `ps_lexer`, `ps_ast`, `ps_parser` — os dois
      programas de validação passam inteiros
- [x] **A4** `ps_sema` + `ps_lower` + runtime v0 (`pscript/runtime/psrt.{ph,p}`):
      fatia vertical rodando nos três modos (50.4)
- [x] **A5** Escopo de bloco nas duas linguagens (64.1)
- [x] **A6** `record` no P (65.1): bytes puros checados, `==` por conteúdo campo a
      campo, construtor `Vec(1.0, 2.0)` posicional e nomeado, com lowering C89

### Fase B — tipos de valor no pscript (não precisam do coletor)

> Ordem dentro da fase é livre; o que importa é cada etapa entrar verde nos três modos
> com o seed regenerado. `./reseed.sh` faz a escada e atualiza o `bootstrap/`.

- [x] **B1 `record` no pscript.** Feito. Construtor posicional e nomeado, método com
      `in self`, encadeamento, semântica de valor, `==` por conteúdo — tudo herdado do
      `record` do P, e o lowering ficou um repasse (a promessa da 65 se pagou).
      Descobertas: (a) num MÉTODO o receptor vai no parâmetro 0 e o ctx no 1, porque a
      sugar de método do P lê params[0] — a 49.3 exige que toda função RECEBA o ctx, não
      a posição; (b) o guarda de exceção precisa de um `__zret: T = {0}` declarado
      quando a função devolve record, porque `return {0}` não é C; (c) bug do backend C
      corrigido: `x = (a, b)` perdia os parênteses e virava `(x = a), b`.
- [x] **B2 Tuplas.** Feito para tuplas de BYTES PUROS. É a única construção que o
      lowering SINTETIZA em vez de renomear, porque tuplas foram removidas do P: cada
      SHAPE distinto vira um `record` do P com campos `_0`, `_1`, … — e ser record não é
      coincidência, é o que 58.2 descreve, então `==` por conteúdo e o construtor vêm de
      graça. Tupla com `str` dentro precisa que o COLETOR a rastreie, então ela entra na
      fase C com erro claro até lá.
- [x] **B3 `for`** — feito para `range(a, b, step)`, que o P já tem com o mesmo
      significado (mais um repasse). O protocolo de 40.3 (`has_next()`/`next()`) precisa
      de cursor MUTÁVEL, e o único agregado mutável é `struct`, que é coletado: entra na
      fase C junto com o coletor.
- [x] **B4 `T?`, `??`, `?.`, narrowing por fluxo.** Feito. REPRESENTAÇÃO escolhida por
      espécie, que é o que mantém o caso comum de graça: referência já é ponteiro, então
      `str?` é o ponteiro nulo e custa zero; VALOR não tem padrão de bits sobrando para
      "ausente" (todo int é um int válido), então ganha um record `{has, v}`. Isso é
      implementação, não linguagem — registrado como nota, não como bateria.
      Três bugs achados no caminho, todos consertados e com teste:
      (a) `add_local` não inicializava TODOS os campos e `vec_grow` devolve memória
          suja — um `opt_type` velho fazia o lowering entrar num option que não existia,
          e só aparecia na SEGUNDA compilação do mesmo processo;
      (b) o backend C emitia `??` cru dentro de literal, e trigrafo é substituído na
          fase 1 da tradução: a mensagem `"'??' takes an option"` saía `'^ takes an
          option`. Agora todo `?` sai escapado (`tests/cases/37_trigraph.p`);
      (c) `import` de caminho ABSOLUTO era colado atrás do diretório do incluidor —
          agora usa `path_join`.
- [x] **B5 `match` e `enum`.** Feito. Enum do pscript É enum do P (constantes inteiras
      de C), e o `match` sobre enum/int/bool é o `match` do P — outro repasse. Sobre
      ENUM a exaustividade é exigida sem `case _` (29.2), e o `-Wswitch-enum` do P
      confere de novo no código gerado: a garantia é dita duas vezes e verificada duas
      vezes. Match de STRING não podia ser repasse — o sujeito aqui é um objeto
      coletado, não `const *char` — então vira cadeia if/elif com `ps_str_eq`, que
      compara por CONTEÚDO (22.2), com o sujeito avaliado uma vez só.
- [x] **B6 `try`/`catch`/`finally`/`raise`.** Feito, no modelo de flag da 49.2 e SEM
      `goto` (que o P proíbe em função com `defer` e que a 50.1 já recusara): cada
      statement do corpo do try é guardado por um flag que o raise limpa, e o `finally`
      baixa para o `defer` do P — que é exatamente a semântica dele, inclusive para um
      `return` de dentro do try. `raise error(msg)`/`raise e`, `e.message`/`e.category`.
      Duas coisas que o lowering teve de fazer e valem registro: içar as declarações do
      corpo do try para o bloco do try (cada `if flag:` é um escopo em P), e pular o
      próprio `return` quando o flag caiu — senão a chamada que lançou ainda devolvia
      lixo. Falta: categorias com NOME (hoje `e.category` é int); `with` ainda não.

### Fase C — o coletor e os tipos coletados

> **Ordem escolhida:** o coletor ANTES de list/dict/set. Com só `str` e o erro no heap,
> a máquina de rastreio é pequena e dá para acertá-la; depois cada tipo novo é só mais
> um caso de trace. É o "cresce recurso a recurso" da 50.4.

- [x] **C1 Shadow stack + C2 coletor de Cheney.** Feitos juntos, e funcionando:
      50 mil rodadas alocando ~4,4 milhões de objetos terminam com **7,4 MB de pico**
      de RSS — sem coleta seriam mais de 200 MB — e o valor vivo sai correto, que é o
      que prova que as referências foram reescritas.

      Três decisões de implementação que valem registro:
      - **O frame guarda ENDEREÇOS de slot** (17.1), não valores. É isso que deixa cada
        local coletado continuar sendo uma VARIÁVEL COM NOME no C gerado (`title`, não
        `__slots[2]`) e ainda assim ser encontrada e atualizada. Custa um store por
        local na entrada do bloco.
      - **Um frame por BLOCO que tenha local coletado**, não por função — porque o
        escopo é de bloco (64.1). As declarações do bloco sobem para o topo DELE e
        começam em None: um slot só é registrado quando já contém None ou referência de
        verdade, nunca o que estava na pilha.
      - **Alocar NUNCA coleta.** Quando o bloco enche, encadeia outro; quem coleta é
        `ps_gc_poll`, emitido nos LIMITES DE STATEMENT. É o argumento de segurança
        inteiro: uma expressão em C guarda intermediários em temporários que a shadow
        stack não conhece, então coletar no meio de uma moveria objeto que um
        temporário ainda aponta. O poll só sai depois de statement que pode alocar, e
        isso o lowering sabe porque toda chamada de runtime passa por um lugar só.
- [x] **C3 `str`**: índice por CARACTERE (3.4) com índice negativo, fatia que COPIA
      (17.3) e recorta como a do Python em vez de lançar, `split`, `strip`, `find`,
      `contains`, `startswith`, `endswith`. `len` conta CODEPOINTS e é O(1) — a contagem
      sai na passada que já copia os bytes. Indexar é O(i) hoje porque o armazenamento é
      UTF-8; a largura adaptativa da 7.1 é o que torna O(1), e é mudança de
      REPRESENTAÇÃO, não de assinatura, então entra depois sem mover nada. Falta: 7.1,
      o cache UTF-8 da 51.2 (que hoje É a representação), fatia com passo, e o resto dos
      métodos.
      Decorrência registrada: **`'x'` é STRING no pscript**, igual a `"x"` — não existe
      tipo `char` para um literal de caractere ter (a 3.4 diz que `s[3]` devolve string
      de um caractere), e é a regra do Python. O lexer compartilhado continua
      distinguindo; quem decide que dá no mesmo é o parser do pscript.
- [x] **C4 `list<T>`.** Feita: literal homogêneo com inferência, indexação com índice
      negativo (31.4) e erro de faixa que LANÇA (5.2), atribuição em índice, `append`,
      `len`, `for x in xs`, e o coletor rastreando os elementos quando são referência.
      Dois objetos por baixo — o cabeçalho, que é o que a variável aponta, e o
      armazenamento, que cresce sendo SUBSTITUÍDO: é o que deixa a lista crescer sem
      invalidar nenhuma referência a ela. Elementos ficam INLINE, por valor:
      `list<Vec>` é array plano de records de 24 bytes, sem ponteiro por elemento
      (52.1) — que é a razão de `record` ser tipo de valor. Falta: fatia, `T[N]`
      interoperando por `in` (60.2), e os outros métodos de lista.
- [x] **C5 `dict<K,V>` e `set<T>`.** Feitos: literais, `d[k]` (que LANÇA quando falta,
      5.2) e `get(k, default)` para o outro idioma, atribuição em chave, `in`/`not in`,
      `add`/`remove`, `len`, `for k in d` (dá as CHAVES, como Python), e o coletor
      rastreando chaves e valores quando são referência. Endereçamento aberto com a
      chave guardada POR VALOR — copiada no insert, que é o que faz "chave por conteúdo"
      significar alguma coisa. `set<T>` é isto com valor de tamanho zero: uma
      implementação só, e um lugar só para o coletor aprender. Chave de `record` pede
      hash campo a campo (bytes crus incluem padding) e por ora dá erro claro.

      **Bug de linguagem achado aqui e corrigido:** o C não define a ordem de avaliação
      de argumentos nem dos operandos de `+`, e o pscript promete a do Python — da
      esquerda para a direita. `f"{d.remove('a')} {d.remove('a')}"` dava `True` na
      SEGUNDA chamada porque o C rodou ela primeiro. Agora todo operando não-trivial
      menos o último é ligado a um temporário, em ordem; a vírgula é ponto de sequência,
      e é ela que fixa a ordem. `and`/`or` ficam de fora de propósito: eles curto-circuitam.
- [x] **C6 f-string.** Feita, resolvida INTEIRA em compilação: o parser quebra o
      literal em texto e buracos `{expr:spec}`, parseia cada expressão com o próprio
      parser e devolve uma cadeia de `+`. O runtime vê concatenação e uma chamada de
      formatação por buraco — nunca uma format string para interpretar. Confere com o
      Python de verdade em todos os casos do teste, inclusive `^` (centrar), que só
      pode existir PORQUE não há printf no meio: printf não centra.

- [x] **Comprehensions** (8.1). Uma comprehension é um LAÇO, e laço é statement — então
      ela é içada para antes do statement que a contém e a expressão vira a lista
      pronta. Duas coisas que isso obrigou a acertar: dentro de braço de ternário ou do
      lado direito de `and`/`or` ela é RECUSADA com mensagem clara, porque içar mudaria
      QUANDO ela roda; e uma comprehension aninhada é içada para o corpo do laço de
      fora, não para o statement — senão a lista interna seria construída fora do laço
      que define a variável.

- [x] **Módulos** (41.3). `import geom`, `import geom as g`, `from geom import Vec2
      [as V]`, tipo qualificado (`g.Kind`) e privacidade `private` (44.4/118).
      **Namespace de verdade, resolvido por RENOMEAÇÃO.** A visibilidade é a do
      Python: um nome de outro módulo só existe aqui se o qualificador o nomear ou o
      `from` o trouxer — nunca por simplesmente existir. Como o alvo é uma unidade de
      tradução só, que não tem namespace nenhum, a resolução acontece em compilação:
      cada declaração de um módulo importado recebe um nome global único
      (`geom__area`) e a referência qualificada é reescrita para ele. Dois módulos
      podem declarar `area` cada um; nenhum enxerga o do outro, e o C que sai continua
      legível — `lib_geom__Vec2_add`, não um número.

      **É o único lugar onde o pscript responde diferente do P, de propósito.** A 42.4
      fez do qualificador do P uma GRAFIA CONFERIDA sobre um conjunto plano de nomes,
      porque o P é a linguagem que conversa com o C, onde o nome já É global e
      renomear quebraria justamente o que ela serve. O pscript não tem essa obrigação:
      paga a renomeação e ganha módulos de verdade.

      Detalhes que a implementação obrigou a acertar: o módulo entra no cache ANTES de
      recursar, senão um ciclo `a → b → a` parseia uma segunda cópia e as declarações
      colidem; um módulo importado com STATEMENTS de topo é recusado (importar é pedir
      definições, não rodar um programa); o erro de dentro de um módulo importado passa
      a apontar o ARQUIVO dele, não o do importador; e o furo de f-string passou a
      herdar a posição da f-string — era lexado sozinho e todo erro dentro dele
      apontava para 1:1.
      Gate: `tests/pscript/run/modules.psc` (+2 fixtures) e 9 casos em
      `tests/pscript/bad/ps_import_*`.

- [x] **`struct`, o tipo de referência COLETADO (20.1).** Era o buraco que faltava da
      fase C: `record` é valor de bytes puros, `struct` é a referência que o coletor
      possui — campos mutáveis que todo mundo que segura a referência enxerga, campos
      que são eles próprios referências, e uma forma que pode apontar para ELA MESMA
      (lista ligada, árvore). Semântica de referência de verdade: `==` é identidade,
      dois nomes são um objeto só, e `Node?` é o ponteiro nulo (custo zero).

      **Como o coletor aprende um tipo do usuário:** não aprende. Os campos são o que o
      programa disser, então o compilador ESCREVE o rastreio — um `Node__trace` de duas
      linhas que encaminha cada campo de referência — e o descritor do tipo aponta para
      ele. Esse descritor é o typedesc que a 50.2 pediu, chegando onde ele sempre ia
      ser preciso primeiro. Escrito como CÓDIGO e não como tabela de offsets porque
      código é o que o compilador de C confere.

      Detalhe que a bateria QBE cobrou: `sizeof(S)` num inicializador estático é uma das
      coisas que aquele back end não dobra, então o tamanho vai no SÍTIO DA CHAMADA
      (`ps_new(ctx, &S__desc, sizeof(S))`) — em expressão não custa nada.

      Junto vieram: `while x != None:` estreitando dentro do corpo (43.1 — é a forma que
      percorrer uma cadeia pede, e o `if` já tinha a máquina toda); `dyn Trait` sobre
      `struct`, onde a caixa guarda a REFERÊNCIA e precisa dizer isso ao coletor; e a
      regra do receptor: `in self` num record (57.1), `self` num struct (20.1), decidido
      pela ESPÉCIE do tipo e não pela trait.
      Gate: `tests/pscript/run/struct.psc` (com 20 mil alocações e a cadeia viva) e
      3 casos em `tests/pscript/bad/ps_struct_*` / `ps_record_self`.

### Fase D — traits (66/67), decididas e não implementadas

- [x] **D1 Traits no P, forma estática.** Feito: `trait X:` com assinaturas,
      `implement X for T:` (desambiguado do `implement Vec<int>` pelo `for`, 67.2),
      `def f<T: X>` com o limite conferido na INSTANCIAÇÃO, e a regra órfã da 67.3
      (uma implementação por par, e o módulo tem de ser dono da trait ou do tipo).
      O que fez isso caber barato: o bloco `implement` registra os métodos como
      métodos DO TIPO, então uma chamada dentro do genérico monomorfizado resolve
      pela busca de método que o P já tinha — **nenhum despacho novo foi inventado e
      nenhuma vtable é construída**, que é exatamente o que "só a forma estática"
      compra. Depois de registrar, o nó vira a forma que os backends já emitem para
      "struct redeclarada só para carregar corpos de método": nenhum backend aprendeu
      o que é uma trait. Gate: `tests/cases/38_traits.p` e 3 casos em
      `tests/errors/p_trait_*`.
- [x] **D2a Traits no pscript: declaração, conformidade nominal e despacho ESTÁTICO.**
      `trait X:` (contextual, como no P — a 67.2 pediu zero palavra nova e um keyword
      duro tiraria `trait` de quem já usa a palavra como nome), cláusula
      `record R implements X:` e bloco `implement X for T:` (66.1) — inclusive
      ATRAVESSANDO módulos nos dois sentidos: minha trait para o tipo deles, a trait
      deles para o meu tipo. `Self` na assinatura (66.4). Regra órfã e uma
      implementação por par (67.3). Checagem NOMINAL (66.2): ter os métodos não basta.

      **Despacho estático (66.3):** `def f<T: Trait>` monomorfiza. O parâmetro de tipo é
      LIDO dos argumentos (ninguém escreve `f<int>(...)`), o limite é conferido onde o
      tipo concreto existe, e o que a chamada acaba nomeando é uma função comum —
      `largest__Money`, legível no C gerado. Nenhuma vtable é construída e as chamadas
      de dentro do corpo resolvem pela busca de método que já existia. A cópia é feita
      por um walker só, que clona e substitui na MESMA passada: um clone que depois é
      editado precisaria de dois walkers sobre a mesma árvore, e dois walkers divergem
      no dia em que um nó ganha campo (`selfhost/ps_generic.p`).

      Decorrência registrada: com o rename dos módulos, uma mensagem passaria a dizer
      `lib_geom__Vec2`. Agora existe um registro de nome de EXIBIÇÃO — todo diagnóstico
      diz `lib_geom.Vec2`, que é o que a pessoa escreveu.
      Gate: `tests/pscript/run/traits.psc`, `generics.psc` e 13 casos em
      `tests/pscript/bad/ps_trait_*` / `ps_bound_*`.
- [x] **D2b `dyn Trait` e tipo associado.** Feitos.

      **`dyn Trait` (66.3):** o oposto explícito do limite de genérico — para o caso que
      a forma estática não faz, uma lista com valores de tipos DIFERENTES que cumprem o
      mesmo contrato. O valor é encaixotado (`record` é valor e não tem tamanho fixo
      entre os tipos de uma trait) e a caixa carrega a vtable do par. Três coisas saem
      no C, nessa ordem porque o P lê de cima para baixo: um STRUCT por trait usada como
      `dyn` (com receptor `*void`, então um struct serve a todos os tipos), um THUNK por
      (trait, tipo, método) e um VALOR estático de vtable por par. Thunk em vez de
      converter o ponteiro de função: conversão entre tipos de função é a única que o C
      não promete nada sobre — e assim o C gerado continua legível
      (`VT_Shape__Circle__area`). Segurança de objeto: uma trait com `Self` fora do
      receptor, ou com tipo associado, NÃO pode ser `dyn`, e a mensagem diz por quê —
      é onde o Rust traça a mesma linha.

      **Tipo associado (66.4):** `type Item` na trait, `type Item = int` na
      implementação (nas duas formas, cláusula e bloco). Sem ele, `Iterable` obrigaria o
      CHAMADOR a dizer o que a coisa produz. Na comparação de assinaturas o nome é
      substituído por NÓ, igual ao `Self`.

      **Bug de coletor achado aqui, e era grave:** `is_collected` listava só
      `PsStr` e `PsErr`, então um local `list`/`dict`/`set` NÃO entrava na shadow stack.
      O programa segfaultava assim que uma coleta acontecia com uma lista viva —
      `tests/pscript/run/gc_list.psc` é o teste que acusou e que agora prende isso.
      Junto: `opt_is_ref` (que decide representação de `T?`, se a lista rastreia
      elemento e se o dict rastreia chave/valor) também ganhou `dyn`.
      Gate: `tests/pscript/run/dyn.psc`, `assoc.psc`, `gc_list.psc` e 6 casos em
      `tests/pscript/bad/ps_dyn_*` / `ps_assoc_*`.
- [x] **D3 Traits do sistema.** `Comparable` e `Iterable` nas duas linguagens;
      `Printable` só no P, com a assinatura que a 67.4 exigiu.

      **No pscript** elas vêm de um PRELÚDIO: um pedaço de fonte que o compilador
      parseia como qualquer módulo e antepõe às declarações do programa. Escrito como
      fonte de propósito — uma trait montada à mão com nós de AST seria um segundo jeito
      de dizer a mesma coisa, e no dia em que a superfície mudasse um dos dois ficaria
      para trás. Se o programa declarar `Comparable` dele, o dele vale: o prelúdio é um
      PADRÃO, não uma reserva do nome.

      **`for x in obj`** sobre tipo do usuário (40.3): o protocolo escrito por extenso,
      `has_next()` e `next()` — e não o `next() -> Option` do Rust, porque com opção
      iterar uma sequência de opções não distingue o fim de um elemento vazio. O cursor
      precisa AVANÇAR, então o iterador é um `struct`: método de record não muta o
      receptor (20.1/57.1) e o laço nunca terminaria — a mensagem diz isso.

      **No P** as três estão em `stl/traits.ph` e são usadas como o P usa trait: limite
      de genérico, conferido na instanciação, monomorfizado até sumir. `Printable`
      escreve num `Str` do chamador — `ref` e não `out`, porque `out` no P promete que
      o callee atribui a coisa inteira, e o que o método faz é APENDAR.
      Gate: `tests/pscript/run/iterable.psc` + 2 casos em `tests/pscript/bad/ps_iter_*`,
      e a seção de traits em `tests/stl/main.p`.

      **Bug do back end QBE achado aqui:** `(a, b).campo` — vírgula como base de acesso a
      campo — caía em "not a valid lvalue". É a forma que um lowering que liga operandos
      a temporários EM ORDEM produz (o do pscript produz, para manter a avaliação da
      esquerda para a direita). Agora o endereço é o do lado direito, e um rvalue
      agregado ali já É o endereço do objeto, como o caso de campo ao lado já tratava.

### Marco intermediário — o path tracer RODA, e agora em PARALELO

- [x] **`pscript/examples/smallpt_core.psc`**: o smallpt sem a concorrência — uma
      thread, cena montada em código, sem `sys`/`json`/`re` e sem topo assíncrono.
      Tudo o que o smallpt pede da LINGUAGEM, nada do que ele pede do runtime
      concorrente. Ele COMPILA E RENDERIZA: `record` com métodos e `in self`, enum com
      `match` exaustivo, `list<Sphere>`, recursão profunda, `**` em float, `%*`
      modular, variável de módulo com `global`, `include <math.h>`, e o coletor
      atravessando tudo isso. A 96x72 com 40 amostras a caixa de Cornell aparece: a
      faixa de luz no teto, as duas esferas, o chão claro.
      Gate: 32x24 com 1 amostra e checksum, nos três modos.

      **Dois bugs de verdade caíram aqui, os dois de código GERADO:**
      - **Ordem de avaliação em chamada de MÉTODO.** O receptor é um operando e é o
        PRIMEIRO; o pscript promete esquerda para a direita e o C não promete nada.
        `radiance(...).scale(re).add(radiance(...).scale(tr))` — duas chamadas que
        puxam do mesmo fluxo aleatório — dava imagens DIFERENTES no C e no QBE. As
        chamadas comuns já tinham esse tratamento; a forma de método tinha ficado de
        fora. Foi o path tracer que achou, comparando os dois back ends.
      - **`return <literal de lista>` numa função com `defer`.** O back end C monta
        `T tmp = <expr>;` e o literal baixa para uma cadeia de vírgulas — sem
        parênteses aquilo é uma LISTA DE DECLARADORES, e o programa nem compilava.
        Todo outro inicializador já saía em precedência de atribuição; esse não.
        Gate: `tests/pscript/run/return_list.psc`.

      Registrado, não decidido: o RNG precisa de deslocamento LÓGICO, e `int` é i64
      com `>>` aritmético. O `u64` do smallpt original depende da 65.14 (larguras
      exatas) e da 53.1 (estouro de unsigned), que continuam **em aberto** — por ora o
      programa mascara os 53 bits de cima, com o porquê escrito no lugar.

### Fase E — concorrência (a metade mais arriscada do design)

- [x] **E1 `async`/`await`, a máquina de estados (50.1).** Um `async def` vira três
      coisas: um FRAME (struct gerado com os parâmetros, os locais e o resultado), uma
      função STEP cujo corpo é um `match` no estado — um `case` por trecho entre awaits
      — e um INICIADOR que aloca o frame, cria a task e roda o primeiro passo, porque
      chamar um `async def` já COMEÇA (35.3, o future quente do JS: "esqueci de dar
      await e nada rodou" é o bug clássico do modelo frio).

      Por que `match` e não `goto`: o P proíbe `goto` em função com `defer`, e a 50.1
      escolheu a forma do C# por isso. O preço é que controle de fluxo AO REDOR de um
      await tem de ser desmontado em estados — o `if` vira "seta o estado e continue", o
      `while` vira estado de cabeça e estado de corpo — com o step inteiro dentro de um
      `while True:` para que `continue` SEJA o salto. O que sobra é bem legível.

      No frame mora TODO local, não o conjunto mínimo que atravessa um await: o mínimo
      pede análise de vivacidade, e este é o jeito obviamente correto. O custo é um
      objeto por chamada — que é o que uma task é de qualquer forma.

      Erro atravessa await (19.3): a task CAPTURA o erro (limpa a flag, para o resto do
      programa seguir) e ele é relançado onde se dá `await`. `try`/`catch` em volta de
      um `await` no topo funciona.

      **Quatro bugs de verdade caíram aqui:**
      - **`ps_str_concat` nunca preenchia `nchars`** — toda string concatenada dizia ter
        comprimento 0, embora imprimisse certo. Estava lá desde a C3; foi um teste de
        async que passou a construir string em laço que acusou.
      - **Endereço de destino computado ANTES de um valor que aloca.** `F->x = f()`: o C
        não diz qual lado vem primeiro, e um coletor que MOVE objetos transforma isso em
        escrita no endereço velho. Agora, quando o valor pode alocar, ele vira um
        statement próprio antes (`value_first`) — vale para campo de frame, campo de
        `struct`, elemento de lista e chave de dict.
      - **`ctx.ready`/`ready_tail` não eram inicializados** em `ps_ctx_init`: a fila de
        tarefas começava com lixo da pilha e o coletor seguia o lixo.
      - **`await` no meio de uma expressão, no TOPO.** Esperar roda outras tasks, que
        alocam — e no meio de uma expressão há temporários de C segurando referências
        que a shadow stack não conhece. Agora a espera é içada para statements próprios
        antes; e `await` na CONDIÇÃO de um laço de topo é recusado com mensagem, porque
        ali o içamento tiraria a espera de dentro do laço (o topo não é máquina de
        estados; dentro de um `async def` o mesmo caso funciona).

      Junto: nomes que o C já tomou (`double`, `log`, `round`, `time`…) passam a ser
      renomeados com um `_` no fim SÓ quando colidem — o resto do C gerado continua com
      o nome que a pessoa escreveu.
      Gate: `tests/pscript/run/async.psc`, `async_error.psc`, `async_gc.psc` (40 tasks
      com coleta no meio), nos três modos.
- [ ] **E2 Loop de I/O**: epoll no Linux, kqueue no macOS (18.4).
- [x] **E3 Workers** (35.1/36.1), primeira forma. `spawn(f, (a, b))` é UMA thread do
      SO com heap, coletor e contexto próprios (18.1) — nunca um pool, porque um pool
      poria dois trabalhos no mesmo heap e o isolamento é o ponto. A função de entrada
      é NOMEADA e não captura nada: recebe só o que foi mandado, e o que atravessa são
      BYTES (34.3), copiados na saída e na entrada. Nenhuma referência cruza dois heaps,
      então nenhum coletor precisa saber do outro.

      O worker É o canal (36.1): `parent.send(x)` de dentro, `await w.recv()` de fora,
      `w.send(x)` no outro sentido — e `send` para worker que já foi devolve `False`
      (45.3), nem exceção nem silêncio. Erro não capturado vira ESTADO e mensagem para
      o pai (37.4): o programa segue. Nada morre de fora — o programa espera todo mundo
      antes de terminar (36.3).

      O bloco de controle é malloc'ado de propósito: a outra thread segura um ponteiro
      para ele, e um coletor que MOVE não pode mover o que outra thread está lendo.

      Limites desta forma, registrados: mensagem é POD (número, bool, enum, `record`) —
      `str`/`list` pedem a serialização da 34.3, que não existe ainda; `await w.recv()`
      BLOQUEIA (o topo pode, 36.3), e dentro de um `async def` ele ainda não estaciona,
      o que é o que a fase E2 (loop de I/O, 18.4/36.2) resolve.

      **Bug do P achado aqui, e valia por si:** um `typedef` de header C para um ESCALAR
      (`pthread_t` = `unsigned long`) não chegava ao back end QBE, que então lhe dava
      quatro bytes — e todo campo depois dele no struct ficava no offset errado. O C
      nunca viu isso porque imprime o typedef e deixa o header do sistema responder.
      Agora a sema exporta o mapa typedef→escalar e o QBE resolve.
      **Variável de módulo mutável virou WORKER-LOCAL de verdade (42.2).** Ela era um
      `static` de arquivo em C, isto é, COMPARTILHADA entre as threads — dois workers
      chamando `seed()` semeavam o mesmo gerador, e o path tracer paralelo dava um
      número diferente a cada corrida. Agora o conjunto das mutáveis é um struct que o
      CONTEXTO aponta: um por thread, criado no thunk do worker, com as coletadas
      virando raízes daquele contexto. `const` continua estático de arquivo — é
      imutável, e cada worker nasce com ele (52.4).

      Duas correções de escopo vieram junto, as duas de verdade:
      - atribuir dentro de uma FUNÇÃO a um nome que também é variável de módulo criava
        um LOCAL, não escrevia no global — que é a regra do Python e da 55.3 (`global`
        é o opt-in). Estava escrevendo no global.
      - o `pre` (onde o lowering pendura declarações que precisam vir antes do
        statement) era global ao lowering: um temporário pendurado DENTRO de um laço
        saía na frente do LAÇO, referindo a variável do laço de fora dele. Agora cada
        statement guarda e devolve o seu.
      Gate: `tests/pscript/run/workers.psc` (4 threads, cada uma alocando no seu heap),
      `pscript/examples/smallpt_workers.psc` (o path tracer renderizado em paralelo,
      determinístico) e `tests/cases/39_typedef_size.p`.
- [x] **E4 `shared`** (42.1/42.3), variáveis. A terceira camada do modelo: global é do
      WORKER (42.2), mensagem é TRANSFERÊNCIA (34.3), e `shared` é sincronizado POR
      CÓPIA. Cada `shared` tem o seu mutex, e operação composta (`+=`) segura o lock na
      leitura-modificação-escrita inteira — quatro threads incrementando 25 mil vezes
      cada dão exatamente 100 mil.

      Duas regras que a implementação teve de fixar, as duas com mensagem:
      - **valor calculado ANTES do lock**: nenhum código do usuário roda com um lock na
        mão, o que também é o que impede duas leituras da mesma variável de travarem
        uma na outra;
      - **escrever `shared` de dentro de uma função exige `global x`**. É a regra do
        Python (55.3), e aqui obedecê-la em silêncio esconderia o defeito: sem o
        `global`, a linha faria um LOCAL e a variável sincronizada nunca mudaria. Então
        o compilador recusa e diz o que escrever.

      Falta o `dict` compartilhado (a tabela estilo ETS da 42.1), que é estrutura de
      runtime própria; variável escalar e `record` já valem.
      Gate: `tests/pscript/run/shared.psc` e 2 casos em `tests/pscript/bad/ps_shared_*`.

### Fase G — biblioteca e I/O (o que o smallpt ainda espera)

- [x] **Arquivos e `with`** (48.1/19.4). `open(path, mode)` com a forma do Python sobre
      stdio — libc É o runtime, não há por que embrulhar `fopen` — e `read`,
      `readlines`, `write`, `close`. Falha LANÇA com categoria `io` e a mensagem diz
      QUAL arquivo: um programa que para tem de dizer o que estava fazendo.

      `with X as f:` adquire, roda o bloco e libera no fim — inclusive quando um erro sai
      pelo meio, porque a liberação baixa para o `defer` do P, que roda em toda saída de
      bloco. Dentro de um `try` o corpo do `with` é pulado pela mesma flag que o resto
      (senão o bloco rodava depois de o `open` ter falhado). Por ora `with` só aceita
      arquivo: o protocolo geral — o que `with` significa para um tipo seu — não está
      decidido, e inventá-lo seria decidir por você.
      Gate: `tests/pscript/run/files.psc` + `tests/pscript/bad/ps_with_nonfile.psc`.
      Decorrência: o `smallpt_core` agora SALVA a imagem (`smallpt.ppm`) — um path
      tracer que renderiza e não grava é um benchmark, não um programa.
- [x] **`sys`** (48.3): `sys.argv`, `sys.env`, `sys.exit(n)` e `sys.time()`. É o único
      módulo SEM arquivo por trás — o que ele nomeia é o entorno do próprio programa, e
      só o runtime responde. `import sys` cria um namespace embutido cujos membros
      resolvem para nomes que a sema conhece de cor (`__sys_argv` e companhia), o que
      deixa o programa escrever `sys.argv` sem que exista um `sys.psc` para carregar.
      `main` passou a receber `argc`/`argv` e a entregá-los ao runtime na primeira
      linha, porque ninguém mais os enxerga.
      Gate: `tests/pscript/run/sysmod.psc`.
- [x] **`re`** (41.2): ERE do POSIX, direto da libc — dependência zero, "libc é o
      runtime" ao pé da letra. `re.match(padrão, texto)` devolve os GRUPOS ([0] é a
      casada inteira) ou None, que é o que faz `if not m:` ler do jeito certo (40.1);
      padrão inválido LANÇA com a mensagem que a própria libc dá. Sem lookahead e sem
      `\d`, que é o que ERE clássico é.
      Gate: `tests/pscript/run/regex.psc`.
- [x] **`print` com vários valores e `sorted`.** `print(a, b, c)` junta com espaço, como
      no Python (44.2 para o caso que se sentia todo dia; o `*args` geral continua
      adiante). `sorted(xs)` COPIA e ordena números e strings (28.4) — `key=` precisa da
      comparação chamar de volta para o programa e vem com o resto da 28.4.
- [x] **`any` (39.2) e `as` conferido (55.2).** `any` é UM ponteiro para objeto com
      cabeçalho — estreito de propósito, que é o que o deixa do mesmo tamanho de
      qualquer outra referência. `str`, `list` e `dict` já SÃO objetos assim, então
      entram como eles mesmos: nada é embrulhado e nada é copiado; número, bool e None
      ganham a caixa que o cabeçalho paga. Ler de volta é `as`, e `as` CONFERE: a tag
      tem de bater, e a mensagem diz o que o valor realmente era.

      Regra que a implementação obrigou a fixar: uma lista dentro de um `any` tem de ser
      `list<any>` — o que está dentro também precisa carregar o próprio tipo, senão ler
      de volta seria ler bytes que ninguém etiquetou. Um literal em posição de `any`
      já nasce assim.

      Junto: `is` virou o que a 22.2 diz que ele é — IDENTIDADE, o mesmo objeto e não um
      igual — e só referência tem identidade para comparar.
      Falta o TESTE de tipo sobre `any` (o downcast da 50.2): por ora a pergunta se faz
      com `as` dentro de um `try`.
      Gate: `tests/pscript/run/anyval.psc` + 2 casos em `tests/pscript/bad/`.
- [x] **`gather`** (35.3): `await gather(ts)` espera todas e devolve os resultados na
      ordem em que as TAREFAS foram dadas, não na ordem em que terminaram — quem precisa
      saber quem terminou primeiro não devia estar usando `gather`.
      Gate: `tests/pscript/run/gather.psc`.
- [x] **`json`** (41.1): texto entra, `any` sai. Objeto vira `dict<str, any>`, array
      vira `list<any>`, e as folhas são str, float, bool e None. Não há esquema para
      declarar nem tipo para escrever — ler um valor de volta é `as`, que confere
      (55.2), e é esse o contrato inteiro. Número é sempre float, porque JSON tem UM
      tipo numérico e fingir o contrário seria inventar regra que o formato não tem.
      JSON inválido lança dizendo o quê e em que byte.
      Gate: `tests/pscript/run/jsonmod.psc`.
- [x] **`buffer`** (19.4/52.3): a única coisa feita para ser compartilhada. Os bytes são
      malloc'ados e nunca se movem — precisam ser alcançáveis de outra thread, e um
      coletor que MOVE não pode ser dono deles. Então o que atravessa para o worker é o
      HANDLE, e o isolamento da 18.1 continua valendo para tudo que o coletor possui:
      nenhuma referência cruza dois heaps. Fechar é explícito, que é para o que serve o
      `with` (que agora aceita arquivo e buffer).
      `get_f64`/`set_f64`/`size` por ora; a VISTA tipada da 18.3 (`px = fb.view_f64()`
      e depois `px[i] = v`) é o açúcar que falta.
      Gate: `tests/pscript/run/buffers.psc` (quatro threads escrevendo no mesmo bloco).
- [x] **Função é VALOR (28.1) e lambda captura POR VALOR (19.2).** `f: def(int) -> int`
      guarda uma função nomeada ou uma lambda; dá para passar, guardar em `list` e em
      `dict<str, def(...)>`, e chamar de qualquer um desses lugares.

      A captura é por valor: a lambda copia o que lê no momento em que é criada, e é
      isso que faz três closures feitas no mesmo laço guardarem três números diferentes
      — sem célula e sem passada de promoção. O ambiente é um struct gerado, coletado
      como qualquer outro, com a função de rastreio que o compilador escreve (a mesma
      máquina do frame de `async`, reaproveitada).

      Lambda não tem anotação (a forma do Python), então os tipos dos parâmetros vêm do
      CONTEXTO — a anotação de quem recebe. Para isso o tipo esperado passou a ser
      propagado para dentro de argumento de chamada, `append`/`insert` e literal de
      dict; sem contexto, a mensagem diz o que escrever. Uma função NOMEADA usada como
      valor ganha um adaptador de uma linha, porque a ABI de closure recebe o ambiente
      primeiro e a de uma função comum não.

      Ainda fora: `def` LARGO sem assinatura (29.3) e `sorted` com `key` (28.4).
      Gate: `tests/pscript/run/lambdas.psc` + `tests/pscript/bad/ps_lambda_noctx.psc`.
- [x] **Fatia de lista e o resto da lista** (17.3/27.3): `xs[a:b]` COPIA e CLAMPA como
      no Python (passar do fim apara em vez de lançar — é o único lugar em que fatiar e
      indexar discordam de propósito), mais `insert`, `remove_at` e `reverse`.
      Gate: `tests/pscript/run/list_ops.psc`.
- [x] **`T[N]`, `assert` e `defer`** (33.4/46.4/43.4). O array fixo é o OPT-IN: `list` é
      o padrão, e `T[N]` é a saída para quando o tamanho é conhecido e a alocação
      incomoda. É o array do P, que é o do C — sem cabeçalho, sem coletor, os elementos
      moram onde a variável mora. Indexar continua LANÇANDO fora de faixa (5.2): o
      tamanho é conhecido, então o teste é uma comparação com uma constante. Funciona
      como local, parâmetro e variável de módulo (essa é escrita elemento a elemento,
      porque C não ATRIBUI array), e `for x in xs` sobre ele é um laço contado.
      `assert` existe e é strippable; `defer` na superfície é o do P.
      Decorrência: `print` passou a ser no-op enquanto há exceção pendente (49.2) — sem
      isso ele imprimia o valor que o índice inválido não chegou a produzir.
      Gate: `tests/pscript/run/arrays.psc`.
- [ ] **`*args`** (44.2) e `T[N]` interoperando com `list` por `in` (60.2).

### Fase F — o marco

- [x] **F1 `vec3.psc` compila, linka e roda** — o primeiro dos dois programas de
      validação, nos três modos, e já está na suíte. O que ele obrigou a fazer:
      `include <math.h>` com a REGRA DE FRONTEIRA da 45.5 (só assinatura sem ponteiro
      atravessa; `sqrt` entra, `fopen` não, e o que não cabe é PULADO e não recusado —
      um header tem centenas de declarações); chamada a função de C sem ctx; `in` escrito
      no sítio da chamada, com materialização quando o argumento não tem endereço
      (`a.add(b).scale(2.0)` encadeia sobre o RESULTADO de uma chamada); e const de
      módulo construído de constantes.
- [x] **F2 — o smallpt COMPLETO roda e produz a imagem.**
      `pscript/examples/smallpt_full.psc`: o programa de validação da 52, na forma que a
      linguagem tem hoje. Ele lê as opções da linha de comando, renderiza em PARALELO
      com uma thread por worker escrevendo no mesmo buffer, grava o PPM e conta o que
      cada worker fez. Numa passada ele usa: `record` com método e `in self` (52.1/57.1),
      `enum` com `match` exaustivo (29.2), workers (35.1/18.1/36.1/36.3), `buffer`
      compartilhado (19.4/52.3), `shared` com lock por variável (42.1/42.3), `sys.argv`
      e `re.match` (48.3/41.2), `json.parse` lido de volta com `as` conferido
      (41.1/55.2), arquivo com `with` (48.1), lambda capturando por valor (28.1/19.2),
      `assert` (46.4), `defer` (43.4), opção com narrowing (43.1) e `%*` modular (54.1).
      A 96x72 com 64 amostras a caixa de Cornell aparece inteira.

      Diferenças em relação ao `smallpt.psc` original, que continua sendo o alvo: não há
      `async for`/`interval` (o loop de I/O é a fase E2), `sorted` com `key` nem `*args`
      — o progresso é impresso no fim em vez de a cada meio segundo.

      **Dois bugs achados por ele, os dois de coletor:** um `str` como argumento de
      worker não atravessava (agora atravessa como BYTES e é reconstruído do outro lado,
      que é a escada de cópia da 34.3); e o valor que o `with` liga não entrava na
      shadow stack — o bloco do `with` era montado à mão sem o wrap de Henderson, então
      o buffer se movia debaixo do programa assim que uma coleta acontecia.
      Gate: `tests/pscript/run/smallpt_full.expected`, nos três modos.
- [x] **`*args` (44.2) e `sorted(key=)` (28.4).**
      `*xs` é açúcar sobre `list<T>` e nada mais: dentro da função o parâmetro É uma
      lista — a mesma que o resto da linguagem já conhece — e o que o sítio da chamada
      faz é construir uma. Nenhum tipo novo, nenhuma segunda convenção de chamada.

      `sorted(xs, key=f)` calcula a chave de cada elemento UMA vez (n chamadas, não
      n log n) e ordena o pareamento. O adaptador que deixa o runtime chamar de volta
      para o programa é escrito pelo compilador: o sítio da chamada é o único lugar que
      sabe o que são os elementos, e o runtime só move bytes. `key=` é o primeiro
      argumento NOMEADO que existe — o geral (44.1) continua adiante.
      Gate: `tests/pscript/run/varargs.psc` e `sortkey.psc`.
- [x] **`sleep`, `status` e `list` de POD atravessando para o worker.**
      `await sleep(s)` é uma task como qualquer outra, o que mantém UM mecanismo de
      espera na linguagem (36.2); até o loop de I/O existir (18.4) ela realmente dorme a
      thread — no topo é exatamente o certo, e dentro de um `async def` é a limitação
      dita em voz alta. `status(w)` responde running/done/error/gone (37.3), que é o
      mínimo que torna supervisão possível — o `status(id)` com id solto continua em
      aberto. E uma `list` de bytes puros atravessa inteira (34.3): copiada aqui,
      reconstruída lá, dois objetos em dois heaps.

      **Bug de portabilidade achado aqui:** `strdup` é POSIX, não C — sob `-std=c11` o
      glibc o esconde, e uma chamada sem protótipo volta como `int`, isto é, um ponteiro
      com a metade de cima perdida. Duas linhas próprias no lugar. É exatamente a classe
      de problema que o compilar-no-macOS costuma achar.
      Gate: `tests/pscript/run/timers.psc` e a segunda metade de `workers.psc`.
- [x] **Categoria de erro com NOME (15.2).** `e.category == IO` passa a ler como o que
      significa: o enum `Category` (NONE/INDEX/KEY/TYPE/VALUE/ZERO/OVERFLOW/IO, na ordem
      que o runtime já usava) vem do prelúdio, e `raise error(msg, IO)` recebe um também.
      Regra que isso obrigou a fixar: o nome do PROGRAMA ganha do prelúdio — de uma
      declaração e também dos ITENS que um enum do prelúdio introduz. `TYPE`, `VALUE` e
      `KEY` são palavras que um programa tem direito de usar, então o padrão sai de
      cena em vez de colidir.
      **Bug achado junto:** indexar uma lista VAZIA derrubava o programa antes do check
      de exceção rodar — o código gerado ainda faz a leitura cujo valor o check vai
      jogar fora, e ler de lugar nenhum matava o processo. A lista sem armazenamento
      responde um slot de rascunho.

- [ ] **F2b `smallpt.psc` (o arquivo original, sem adaptação).** Falta a vista tipada do
      buffer (18.3), `w.id` + `status(id)`, `interval` de verdade (E2) e o `def` LARGO
      da 29.3.
- [x] **F3 `FEATURES.md` atualizado.** Cada recurso ganhou uma coluna de ESTADO —
      implementado com teste que prende (✅), implementado em parte com o que falta dito
      (◐), ou decidido e ainda não feito (⏳) — e a tabela do topo diz quais são os três
      smallpts que existem hoje e o que cada um cobre.

---

## Se aparecer uma decisão de design

Não decida. Faça isto:

1. Acrescente uma bateria nova em `DESIGN.md` (formato: pergunta → opções, cada uma
   com a consequência nomeada → sem veredito).
2. Escolha a opção **mais conservadora** para não travar, e escreva no texto
   `> PENDENTE DE DECISÃO — segui com (x) para não travar`.
3. Liste a pendência no fim deste arquivo.

## Receita da verificação e do seed

```sh
# bateria completa (~10 min)
bash tests/verify-all.sh          # tem de terminar com 8/8

# regenerar o seed quando a etapa 8/8 acusar DRIFT
V=.verify; CC=cc; CFLAGS="-O2 -std=c11 -w"
rm -rf $V; mkdir -p $V/{out1,out2,out3,stl}
gen() { local bin=$1 out=$2 f b
  for f in stl/*.ph;      do $bin "$f" -o $V/stl/$(basename "${f%.ph}").h || return 1; done
  for f in selfhost/*.ph; do b=$(basename "${f%.ph}"); $bin "$f" -o $out/$b.h || return 1; done
  for f in selfhost/*.p;  do b=$(basename "${f%.p}");  $bin "$f" -o $out/$b.c || return 1; done; }
$CC $CFLAGS -o $V/seed bootstrap/selfhost/*.c
gen $V/seed $V/out1 && $CC $CFLAGS -o $V/s1 $V/out1/*.c
gen $V/s1   $V/out2 && $CC $CFLAGS -o $V/s2 $V/out2/*.c
gen $V/s2   $V/out3 && diff -rq $V/out2 $V/out3     # ponto fixo: tem de bater
cp $V/out2/*.c $V/out2/*.h bootstrap/selfhost/ && cp $V/stl/*.h bootstrap/stl/
rm -rf $V && make plangc
bash tests/verify-all.sh          # 8/8 e "bootstrap em dia"
```

Ciclo rápido durante o desenvolvimento (sem a escada inteira):

```sh
./plangc --out-dir out stl/*.ph selfhost/*.ph selfhost/*.p && \
  cc -O2 -std=c11 -w -o plangc2 out/selfhost/*.c
for m in "" "BACKEND=qbe" "STD=c89"; do
  env PLANGC=./plangc2 $m bash tests/run.sh cases errors modules stl p-suite roundtrip pscript
done
```

## Buracos conhecidos, achados no caminho

- [x] **Variável de módulo MUTÁVEL.** Era um buraco: `x = 1` no topo virava local do
  `main`, e `global x` numa função dava "'x' is not a module variable". Agora uma
  declaração de topo É variável de módulo, a regra do Python — e os statements de topo
  passaram a ser checados ANTES dos corpos das funções, que é o que faz toda função
  enxergar todas elas, inclusive as escritas mais abaixo. O nome continua sendo também
  um LOCAL do topo, de propósito: é o mesmo armazenamento nos dois casos, e é o que
  mantém a análise de fluxo — o narrowing da 43.1 acima de tudo — funcionando para o
  código que vem depois. Uma variável de módulo COLETADA entra como raiz do coletor
  (`gc_list.psc` prende isso).

### Bateria 68 — as decisões da prática (respondidas por você, 2026-08-14)

- [x] **68.1** limite de genérico NOMINAL no P também (gate: `tests/errors/p_bound_nominal.p`)
- [x] **68.2** larguras exatas COMPLETAS — fecha 65.14 e 53.1 de uma vez.
      `i8`…`u64` e `f32` são tipos de verdade: variável, parâmetro, campo, elemento de
      lista, retorno. As regras, cada uma com o porquê:
      * **literal ADAPTA** à largura do contexto, com a faixa conferida em COMPILAÇÃO
        (`x: u8 = 300` nem compila);
      * **alargamento sem perda é implícito** (i8→int, u8→u32, u32→int; f32→float);
        estreitar tem NOME (`i8(x)`, `u64(x)`…) e a conversão CONFERE — fora da faixa
        lança, na mesma voz de todo estouro (53.1);
      * **aritmética exige tipo comum sem perda**; sinais misturados da mesma largura
        não têm chão comum e convertem por nome (é o que impede `u32 + i32` de
        significar alguma coisa em silêncio); estouro de largura LANÇA;
      * **`%+ %- %*` são a volta intencional**, mascarada à largura (127 %+ 1 em i8 dá
        -128) — a 54.1, agora por largura;
      * **u64 é o inteiro que o i64 não carrega**: ops checadas próprias, formatador
        próprio, `>>` LÓGICO por construção, e as travessias i64↔u64↔float têm nome e
        conferem;
      * unário `-` em unsigned é recusado com a mensagem dizendo as duas saídas.
      **Decorrência no smallpt:** o RNG virou u64 de verdade — a máscara de 53 bits e o
      comentário pedindo desculpas sumiram, e o xorshift64* bate BIT A BIT com o Python
      (verificado: 16620430977058721579).
      Gate: `tests/pscript/run/widths.psc` + 5 casos em `tests/pscript/bad/ps_width_*`,
      nos três modos.
- [x] **68.3** sombra do prelúdio: programa ganha COM aviso; só o item colidido cai
      (gate: `tests/pscript/run/shadow.psc`)
- [x] **68.4** `with` = trait `Closeable`; cleanup roda com exceção pendente
      (gate: `tests/pscript/run/closeable.psc`)
- [x] **68.5** teste de tipo = `match type(x):` com narrowing por case
      (gate: `tests/pscript/run/typematch.psc`)
- [x] **68.6** número JSON pela regra do Python (gate: `jsonmod.psc` atualizado)
- [x] **68.7** lambda só com contexto (nada a fazer)
- [x] **68.8** `w.error()` devolve o Error completo; colher silencia o stderr do join
      (gate: `timers.psc` atualizado)
- [x] **68.9** `for v in x` no P sobre Iterable, zero runtime
      (gates: `tests/cases/40_for_iterable.p`, `tests/errors/p_for_notiter.p`, stl)

**Incidente de ferramenta, registrado porque custou tempo:** os scripts de patch
desta sessão viviam em um tmp/ e um deles se chamava `re.py`; qualquer outro script
dali que fizesse `import re` executava ESSE arquivo (o diretório do script entra no
sys.path do Python) e re-aplicava o patch do regex — daí seções duplicadas no runtime
e ramos duplicados na sema/lowering. Tudo deduplicado e conferido com uma varredura de
definições repetidas; os scripts aplicados foram movidos para fora do alcance do
import. Moral: script de patch nunca leva nome de módulo da stdlib.

Consertos que as 68 puxaram: `Error` reconhecido como referência embutida
(`Error?` é ponteiro nulo, sem record `{has,v}`); seção `re` DUPLICADA no runtime
removida (só o `.p` acusava — protótipo duplicado é legal, corpo não); checagem
de aridade duplicada na chamada de `async def` removida.

### Bateria 69 — nulabilidade no P virou `ref T` (respondida por você, 2026-08-14)

A pergunta original ("cast de ponteiro para tipo nulável?") passou por três
formas até assentar: estrito com migração → anotação clang-style → **inversão
de polaridade**: `*T` fica nulável como C manda, e o polo verificado é um TIPO
novo, generalizando o `ref` que os parâmetros já tinham. O registro completo
do vai-e-vem está na Bateria 69 do DESIGN.md; a especificação em SPECS.MD.

- [x] **69.1** `ref T` tipo de primeira classe: não-nulável, liga-uma-vez,
      auto-deref; LOCAL e RETORNO (campo = bateria futura, exige prova de
      inicialização). Zero migração, zero runtime, `T*` no C emitido.
- [x] **69.2** entrada de `*T` só por narrowing (`if p != None:` / early-return);
      sem cast de volta. Prova por função, conservadora (laço mata fato de quem
      o corpo escreve; label/case mata tudo; `&x` desliga a variável).
      Violação: `-Wnullability`, erro demovível.
- [x] **69.3** açúcar só `??` (avaliação única, C89 via temp içado + `?:`).
- [x] **69.6** parâmetro segue só com o trio `ref v: T` (sem grafia sinônima).
- [x] **69.7** `-Wnull-dereference` de fluxo: só fato PROVADO dispara.
- [ ] **69.x futura** campo `ref` em struct (prova de init em toda construção).
- [ ] **69.8 futura** alias de valor no pscript (ref a campo/elemento),
      condicionado a derived pointers no Cheney.

Gates: `tests/cases/41_ref.p` nos três modos (inclusive roundtrip do printer,
que aprendeu `ref T` e `??`) + `tests/errors/p_ref_param|field|uninit|none|
unproved|nested|rvalue`, `p_coalesce_nonptr`, `p_null_deref` (com `-Werror`).

### Bateria 70 — a varredura das pendências decididas (2026-08-15)

Não é uma bateria de PERGUNTAS: é a leva de coisas que já estavam decididas no
DESIGN e não existiam no compilador. Cada uma entrou com teste que prende, nos
três modos, e o seed foi refeito ao fim de cada ciclo.

**Consertos que a varredura achou (defeitos de verdade, não pendências):**

- **`d[k] += v` e `xs[i] += v` DESCARTAVAM a operação.** O lowering escrevia só
  o operando direito: `d["a"] += 5` deixava 5 onde devia ficar 6. Agora o
  elemento é lido, o operador é aplicado e o resultado volta — com o contêiner e
  o índice ligados a temporários, de modo que cada um é avaliado UMA vez (a
  regra do Python, e a única forma de um efeito colateral no índice se comportar).
  Gate: `tests/pscript/run/compound_index.psc`.
- **`print(f(), x)` lia `x` ANTES de `f()`.** C não define a ordem dos argumentos;
  Python define. Agora os argumentos do `print` passam pelo mesmo ordenador que
  as chamadas usam, e ler uma variável de MÓDULO conta como efeito — porque uma
  chamada ao lado pode ser exatamente quem a escreve.
  Gate: `tests/pscript/run/eval_order.psc`.
- **O tipo esperado vazava para dentro de um operador.** `float(x %* K)` adaptava
  `K` a float; agora o contexto para no operador, que só precisa que seus dois
  lados concordem ENTRE SI (68.2).
- **Três campos novos do contexto não eram inicializados** (`nogc`) — o mesmo
  defeito que a fase E1 já tinha registrado com `ready/ready_tail`, e que faz o
  programa inteiro falhar de um jeito que não parece ter relação. Achado pela
  suíte, no mesmo dia em que nasceu.

**O que passou a existir:**

- [x] **26 `nogc:`** — com orçamento opcional (`nogc(64k):`), que pré-reserva e
      LANÇA ao estourar; aninha por contador; `await` dentro é erro de compilação
      (26.5.1). Gate: `nogc.psc` + 2 casos ruins.
- [x] **28.3 decorador** — `@deco` e `@deco(args)`. `@twice def inc` É
      `inc = twice(inc)`: a função guarda o corpo sob um nome privado e o NOME do
      programa vira variável de módulo com o valor devolvido. Puxou duas coisas
      que faltavam: o tipo de RETORNO como contexto de lambda, e captura
      TRANSITIVA (lambda dentro de lambda). Gate: `decorators.psc`.
- [x] **29.3/29.4 `def` largo** — um `def` sem assinatura guarda qualquer função,
      e chamar exige estreitar (`f as def(str) -> bool`), o que é uma comparação
      do descritor que o valor carrega. Gate: `wide_def.psc` + 2 casos ruins.
- [x] **42.1 `shared dict`** — a tabela ETS: fora dos heaps, lock próprio, chave e
      valor na escada de cópia (com `str`, porque a tabela guarda bytes seus e
      devolve uma string nova no heap de QUEM LÊ). Gate: `shared_dict.psc`.
- [x] **43.2 `??=`** — inclusive sobre elemento, com o índice avaliado uma vez.
- [x] **44.1 default por chamada** — `def f(xs=[])` dá lista nova a cada chamada,
      que é o conserto da armadilha mais famosa do Python. O default é checado no
      escopo que o ESCREVEU e substituído no sítio da chamada. Nomeados entraram
      junto, em função e em método. Gate: `defaults.psc` + 2 casos ruins.
- [x] **44.2 `*args`** — faltava só o splat: `f(a, *xs)` entrega a lista inteira,
      sem construir outra. Gate: `varargs.psc`.
- [x] **44.3 repr derivado** — `Rect(x=1, y=2)` para record, struct e enum,
      aninhado, em `print`, `str()` e f-string; um `to_str()` do tipo sobrepõe.
      Construído como UMA expressão, o que é seguro porque o coletor só roda em
      fronteira de statement. Gate: `repr.psc`.
- [x] **18.3 vista tipada do buffer** — `view_f64/f32/i64/i32/u8`: a mesma
      memória vista como elementos, sem cópia. É uma lista que EMPRESTA: lê,
      escreve, itera e fatia como qualquer outra, e recusa crescer, porque
      crescer seria possuir. Gate: `views.psc`.
- [x] **48.2/51.1 `interval`** — `await t.tick()` em laço comum, com tick que
      COALESCE (quem se atrasou recebe UM tick, não a fila dos que perdeu).
      Gate: `interval.psc`.
- [x] **59/62.4 `pack`/`unpack<T>`** — formato denso, campos na ordem da
      declaração, tamanho como contrato. **Extensão decidida por você hoje: a
      ordem de bytes é PARÂMETRO** (`pack(r, BE)`, `unpack<T>(b, BE)`), com LE
      por padrão — bytes que saem do processo encontram as regras dos outros.
      Entrou um `enum Endian` no prelúdio. Gate: `packing.psc` + 1 caso ruim.
- [x] **63.1/63.5 `embed`/`embed_bytes` no pscript** — o texto vira `str`; o
      binário vira `static` + memcpy, então um megabyte de fonte custa um
      megabyte de DADO e não um megabyte de AST. Gate: `embed.psc`.
- [x] **63.2 template, modo sem header** — `render("email.tpl")` é uma f-string
      que mora num arquivo: mesmas chaves, mesmos escapes, mesma mini-linguagem
      de formato, resolvida em COMPILAÇÃO contra o escopo de quem chamou.
      Gate: `template.psc`.
- [x] **Corrigido no inventário** — `status()` (37.3) e `sorted(key=)` (28.4) já
      existiam e estavam marcados como pendentes.

**O que continua pendente, e por quê (não é esquecimento):**

- [ ] **11-12 `unsafe`** — o que ele destrava (deref de ponteiro cru, aritmética
      de ponteiro, cast entre ponteiros, chamada variádica) pressupõe um tipo
      PONTEIRO no pscript, que não existe. É uma adição de linguagem, não um
      recurso solto — e a medalha da 12.1 continua valendo: o raytracer não
      precisa.
- [ ] **18.4 loop de I/O (epoll/kqueue)** — hoje `sleep` e `tick` realmente
      dormem a thread, que é o certo no topo (não há mais nada para rodar) e a
      limitação honesta dentro de um `async def`. O loop só ganha o que promete
      quando houver DESCRITOR para esperar; enquanto a linguagem não tem socket
      nem arquivo assíncrono, ele seria um `nanosleep` com epoll em volta.
- [ ] **37.2/36.4/18.2 cancelamento, `race`, `transfer`** — um bloco só, e é ele
      que destrava `timeout` (que É race + cancel do perdedor). Mexe no
      escalonador: `t.cancel()` faz o próximo `await` DA TASK lançar lá dentro.
- [ ] **63.2 template, modo COM header** — gerar `render_email(nome: str, ...)`
      a partir da primeira linha do arquivo exige decidir a superfície (como o
      programa NOMEIA a função gerada), e isso é decisão sua.
- [ ] **2.4 `import` de `.ph` de P** — a parte de tipos é clara (a fronteira da
      45.5 já diz o que atravessa); o que falta decidir é como o módulo P entra
      no BUILD do programa pscript.

### Bateria 71 — a prova de fogo: pstudio em pscript (2026-08-15)

O editor foi portado para pscript, com a mão que toca o SDL2 ainda em P
(`pstudio/`, com um README próprio). Roda: abre janela, carrega arquivo,
edita com múltiplos cursores, desfaz, busca, dobra, desenha pelo atlas de fonte
e salva. Dois testes entram no gate — o núcleo headless e o autoteste do
editor inteiro com SDL em driver dummy.

**A divisão que a fronteira impôs** (45.5: só assinatura sem ponteiro
atravessa): `shim.p` expõe janela, eventos e pixels em ESCALARES — handles,
códigos de tecla, cores, um codepoint por vez — e `app.psc`/`lib_core.psc`
carregam o editor inteiro. O pscript chama o P por `include "shim.h"`, o header
que o próprio compilador emite: sem FFI, sem binding.

**O tamanho:** `core.p` (1505 linhas) virou `lib_core.psc` (933) fazendo o
mesmo. Não é estilo: uma linha é `str` e `len(s)` são codepoints, então somem o
cache `ncp` e as três funções de conversão byte↔codepoint; fatiar copia, então
some o `range_text` com malloc/memcpy; o coletor é dono do grafo, então somem
`own`, `own_n`, `group_drop` e os `deinit`.

**Seis defeitos que só um programa de verdade acha**, todos corrigidos com
teste:

- [x] **um método não enxergava variável de módulo** — uma função livre ao lado
      enxergava. As passagens da sema estavam fora de ordem: o corpo do método
      era checado ANTES de os statements de topo declararem as variáveis.
      Gate: `tests/pscript/run/method_globals.psc`.
- [x] **assinaturas resolviam tarde demais** — o efeito colateral vinha de
      checar o corpo, e o topo roda primeiro (39.4). Uma chamada comparava
      `Vec2` com `lib_geom.Vec2` e recusava o valor do tipo que pediu. Agora há
      uma passagem que resolve toda assinatura antes de qualquer chamada.
- [x] **o tipo do CAMPO não era contexto** — `self.lines = []` não compilava,
      nem `UndoGroup([], ...)`. O mesmo já valia para declaração e retorno.
- [x] **`<` `>` `<=` `>=` entre strings comparavam PONTEIROS** — resultado
      silenciosamente errado, ordenado por onde o coletor pôs cada uma. Agora
      comparam conteúdo (`ps_str_lt`), a mesma ordem que `sorted` usa.
- [x] **um local de módulo importado não podia repetir um nome do programa** —
      o guard que protege contra usar um nome não importado disparava também
      sobre um nome que estava sendo LIGADO.
- [x] **`ord`/`chr` não existiam** — e sem eles nenhum texto alcança uma
      interface que fala número (a fronteira inteira, e o desenho de qualquer
      glifo). São o par do Python e a única porta entre caractere e codepoint.
      **Decisão sua a confirmar:** implementei porque o porte parava sem eles.

**Lacunas registradas, sem inventar decisão** (o porte contornou e anotou):

- [ ] `"x" in s` — substring. O `in` do pscript é pertinência em dict/set (8.1)
      e o Python usa a mesma palavra para substring.
- [ ] `for ch in s` — iterar os caracteres de uma string. Hoje o `for` toma
      range, list, dict, set ou um `Iterable` (40.3).
- [ ] **constantes de header C são invisíveis** na fronteira: ela ingere
      FUNÇÕES (45.5), então todo `#define`/enum de um header — os keycodes do
      SDL inteiros — precisa ser redigitado do lado pscript.
- [ ] o que falta do editor: realce de sintaxe (o `codeview.p` usa o lexer do
      compilador, que é P — atravessaria pelo mesmo shim), árvore de arquivos,
      abas, paleta de comandos e minimapa.

### Bateria 73 — o tripé async/worker/shared, fechado (2026-08-15)

Pedido seu: a especificação da linguagem completa, com o sistema de
`async`/`await` + worker + `shared` inteiro. O que entrou, e o que cada peça
conserta:

- [x] **O `await sleep()` ESTACIONA (48.2/18.4).** Era o buraco que fazia o
      resto não significar nada: o timer parava a THREAD, então um `async def`
      rodava do começo ao fim no momento em que era chamado e duas tasks nunca
      se sobrepunham. Agora um sleep é uma task no RELÓGIO — quem espera fica
      estacionado, o resto roda, e só quando nada está pronto a thread dorme,
      exatamente até o próximo prazo. É a metade do loop da 18.4 que faz
      sentido enquanto não houver descritor para esperar.
      Gate: `cancel_race.psc` mede que duas tasks de 4×10ms terminam juntas em
      menos de 75ms — bloqueando levaria o dobro.
- [x] **`t.cancel()` (37.2/36.4).** Não é kill: a task LANÇA no próximo passo
      dela, então `defer` e `with` desenrolam como em qualquer outro erro. Uma
      task 100% CPU sem `await` não cancela — para isso existe worker (36.4).
- [x] **`race(ts)`** devolve o ÍNDICE do primeiro a terminar e cancela os
      outros — é o cancelamento que impede a corrida de deixar órfã.
- [x] **`timeout(t, s)`** é a mesma corrida com o relógio do outro lado: True
      se a task terminou a tempo, False se o relógio venceu, e o perdedor é
      cancelado nos dois casos.
- [x] **`await` dentro de `for` (50.1).** A máquina de estados desmontava `if` e
      `while`; o `for` sobre `range(...)` e sobre lista agora também. Ele ganha
      QUATRO estados, não três: o incremento é um estado próprio porque
      `continue` precisa alcançá-lo — desaçucarar para `while` mandaria o
      `continue` para a cabeça e o laço nunca andaria.
- [x] **Mensagem serializada (34.3).** Bytes continuam por memcpy; `str` e
      `list` de bytes (números, bools, `record`) são serializados e
      RECONSTRUÍDOS no heap de quem recebe — copiar o grafo direto alocaria no
      heap de outra thread e acordaria o coletor dela, que é o que a 18.1
      proíbe.
- [x] **`shared` com a escada de cópia inteira (42.1):** número, `record` e
      agora `str` — os bytes vivem fora de todo heap e a leitura devolve uma
      string nova no heap de quem lê.
- [x] **`w.detach()` (36.3):** o programa deixa de esperar por aquele worker no
      fim. Nada é morto no meio; a thread vai embora com o processo.
- [x] **`transfer(b)` (18.2):** entrega os bytes do buffer e INVALIDA a
      referência de quem enviou — zero cópia, e o erro clássico (dois donos
      escrevendo o mesmo bloco) vira exceção em vez de corrida.
- [x] **Correção que a leitura do runtime achou:** o CABEÇALHO do buffer vivia
      no heap coletado enquanto outra thread segurava o ponteiro. Um coletor que
      MOVE não pode ser dono do que outra thread está lendo — é a mesma razão
      pela qual o bloco de controle do worker é malloc'ado. Agora o cabeçalho
      também é.

**O que continua fora, e por quê:** o `epoll`/`kqueue` da 18.4 (só ganha o que
promete quando houver DESCRITOR para esperar — socket, arquivo assíncrono; a
metade dos prazos está feita), a cópia PROFUNDA de grafo em mensagem (34.3 diz
que o caso geral serializa; hoje serializa `str` e `list` de bytes, e um grafo
com ciclo pede a guarda que a 18.2 menciona), e `unsafe` (11-12), que pressupõe
um tipo ponteiro no pscript.

As baterias 74 e 75, logo abaixo, mexem em dois desses: a fila do worker ganha
descritor (que é meio caminho do `epoll`) e a cópia profunda passa a ser
trabalho a fazer. `unsafe` fica fora por decisão.

## Baterias 74 e 75 — decididas pelo usuário, AINDA NÃO implementadas

Tudo abaixo já é decisão fechada. Falta escrever.

### 74.1 — `await w.recv()` ESTACIONA — FEITO

`w.recv()` bloqueava a thread na condvar do worker: uma task esperando mensagem
congelava todas as outras, e `async` + worker eram duas coisas que não se
usavam juntas. Agora receber é uma TASK SEM PASSO, exatamente como o timer da
48.2: ela estaciona, o escalonador a completa quando a mensagem chega, e o
resto continua rodando.

**Como ficou.** Cada fila ganhou um descritor por direção — um `pipe` POSIX, e
não o eventfd do Linux, porque este runtime compila nos dois lados e o pipe é o
que existe em ambos. Um byte entra quando uma mensagem é empurrada (e quando o
worker termina, que também é notícia); quem lê drena e olha a fila de verdade,
então acordar à toa não custa nada. O escalonador espera num `poll` sobre os
descritores das recepções estacionadas COM o prazo mais próximo como timeout —
que é a forma que a 18.4 pede: um socket entraria na mesma lista sem mudar o
desenho. Uma condvar não serviria: ela pertence a uma fila, e o escalonador
espera por várias ao mesmo tempo.

Detalhes que a implementação obrigou a decidir:

  * mensagem já na fila termina a recepção na hora, sem estacionar e sem tocar
    o escalonador — o caminho comum não paga nada;
  * uma recepção CANCELADA (37.2) não tira nada da fila: engolir uma mensagem
    que ninguém vai ler é justamente o que `timeout(w.recv(), ms)` não pode
    fazer;
  * `PS_POLL_MAX` (64) filas por espera; acima disso o laço olha as primeiras e
    revisita o resto em 2ms, o que limita a latência sem alocar no caminho que
    devia ser o barato.

**Dois bugs que apareceram no caminho**, os dois de coletor: `ctx->timers`
nunca era encaminhado na coleta (a lista dos timers é raiz tanto quanto a fila
de prontos), e o frame de uma mensagem que É referência usava o descritor POD,
deixando o coletor com um ponteiro velho. Os dois consertados; o segundo passou
a importar de verdade porque uma recepção estacionada vive muitas coletas.

Teste: `tests/pscript/run/recv_parks.psc` — um worker que responde em 60ms e uma
task local que dorme 6x10ms terminam JUNTAS, e duas tasks esperam em dois
workers diferentes ao mesmo tempo.

### 74.2 — cópia PROFUNDA de grafo em mensagem — FEITO

O caso geral: `list<str>`, `list<list<T>>`, `dict<K,V>`, `set<T>`, `struct` com
referências, e ciclo. (Um `record` não entra na lista porque a 58.2 já o
mantém puro — ele continua atravessando por memcpy, que é o caminho rápido.)

**Como ficou.** A divisão é a mesma das funções de rastreio: o compilador sabe
os TIPOS, o runtime sabe o FORMATO. O compilador deixa um `PsShape` estático
por tipo que viaja — e, para um `struct`, um par de funções geradas que andam
pelos campos (`S__ser`/`S__des`, uma chamada por campo). O runtime tem o
formato e a guarda de ciclo, e não precisa aprender nada sobre tipos.

O formato de um valor: POD são os bytes; toda referência leva um TAG — ausente,
nova, ou uma já escrita. A nova vem seguida do corpo; a já escrita, do número
que recebeu. Quem lê registra cada objeto ANTES de ler o corpo dele, na mesma
ordem em que quem escreve registrou. Essa é a guarda de ciclo inteira: uma
lista que contém a si mesma escreve o próprio número na segunda vez, e quem lê
já tem a lista (ainda vazia) para apontar. O efeito colateral que se ganha de
graça é o certo: um objeto que aparece duas vezes chega como UM objeto.

Três coisas que a implementação obrigou:

  * a tabela de "já escritos" é endereçamento aberto sobre o ENDEREÇO do
    objeto — uma varredura linear faria um grafo de dez mil nós custar cem
    milhões de comparações;
  * chave e valor de um `dict` são montados FORA da tabela e só então
    inseridos: inserir pode reorganizá-la, e um valor que se insere no mesmo
    dict escreveria num slot que já mudou de lugar;
  * o `size` de um shape não cabe no inicializador estático (`sizeof` é uma das
    poucas coisas que o QBE não dobra — a mesma razão pela qual `PsDesc` não
    tem tamanho), então ele começa em zero e o `main` preenche todos antes da
    primeira mensagem.

O caminho especial de `str` e `list` de bytes FOI REMOVIDO: o geral cobre os
dois, e duas máquinas para o mesmo trabalho é o que apodrece. A regra do
`sendable` deixou de perguntar "isto é plano?" e passou a andar no tipo campo a
campo, dizendo qual parte não atravessa (`field 'log' of Job is file, ...`).

Testes: `tests/pscript/run/deep_messages.psc` (grafo com ciclo, string repetida
que chega como um objeto só, os cinco formatos) e
`tests/pscript/bad/send_unsendable.psc`.

### 74.3 — esperar por task cancelada LANÇA (confirmado)

Fica como está: cancelamento é um erro com categoria própria e viaja como
qualquer outro (19.3). Quem quiser ignorar filtra por categoria no `catch`.

### 75.1 — `unsafe` (11-12) fica FORA do v0.1

Registrado com o motivo, não descartado: nem o raytracer nem o editor
precisaram, e o shim em P já cobre o caso real (SDL2 inteiro) sem furar a
sandbox. Volta quando aparecer algo que a fronteira 45.5 não dê conta. Enquanto
não voltar, o pscript NÃO tem tipo ponteiro — e é isso que mantém o `--safe` da
12.3 desnecessário.

**Por que ele perdeu o sentido** (palavras do usuário: a linguagem evoluiu para
outro lado). Três decisões posteriores comeram o `unsafe` por baixo, uma por
vez:

  * o coletor virou um Cheney de dois espaços (15.1), e **objeto do pscript
    anda**. Ponteiro cru para dentro do heap não é uma opção perigosa que o
    programa assume — é uma opção que não funciona, a menos que o coletor ganhe
    objeto fixado, espaço não-móvel e a fragmentação que vem junto;
  * o `buffer` saiu do heap coletado (bytes malloc'ados, endereço estável) e
    ganhou `view_*`, `pack`/`unpack` com endianness. O caso "mexer em memória
    crua" passou a ter resposta SEGURA melhor do que a insegura seria;
  * a fronteira 45.5 se firmou como o jeito de falar com C, e o shim do pstudio
    provou: SDL2 inteiro atravessou sem uma linha de `unsafe`, com o compilador
    conferindo os dois lados.

Dito de outro jeito: o `unsafe` do pscript já existe e chama-se **P** — o
`psrt.p` e os shims são exatamente a parte insegura, escrita numa linguagem com
ponteiro de verdade e conferida pelo mesmo compilador. Do pedido original sobrou
só a chamada variádica, que não pede tipo ponteiro nenhum e ainda não tem um
caso real. Se voltar, volta por aí — e depois, no máximo, por um ponteiro
restrito a memória DE FORA do heap coletado. Deref de objeto coletado pede outro
coletor, e essa é a conta que nunca fechou.

### 75.2 — template SEM header: passa um dict e renderiza — FEITO

O usuário fechou a 63.2 pelo outro lado: não existe linha de cabeçalho nem
função tipada gerada. O template recebe um DICT com os valores e renderiza:

    render("email.tpl", {"nome": "Ana", "valor": 12.5})

A forma de uma chave só, sem dict, continua sendo o `render(path)` que já
funciona. O que fica de fora, por decisão: declarar tipos no arquivo e gerar
`render_email(nome: str, valor: float)`.

**Como ficou.** O dict é um LITERAL escrito na chamada, e é isso que mantém a
promessa da 63.2 de não haver motor de template em tempo de execução: o
conjunto de chaves fica conhecido no instante em que o arquivo é emendado, os
buracos são resolvidos, tipados e formatados na compilação, e os valores podem
ser de tipos DIFERENTES — coisa que um `dict` de verdade, homogêneo, não
poderia carregar. Um buraco sem valor e um valor sem buraco são erros, os dois
com a posição certa. Uma chave que dois buracos pedem é clonada
(`ps_clone_expr`), porque o mesmo nó emendado duas vezes seria conferido e
baixado duas vezes. Um dict VARIÁVEL é recusado com mensagem própria: ele
exigiria busca em tempo de execução, e com ela a chance de faltar chave — que
é exatamente o motor que a 63.2 não quis.

Testes: `tests/pscript/run/template_dict.psc` (+ `twice.tpl`) e os três de
recusa em `tests/pscript/bad/render_{missing_key,unused_key,dict_var}.psc`.

### 75.3 — `import "shim.ph"`: o compilador PUXA o módulo P para o build — FEITO

`import "shim.ph"` num programa pscript faz o plangc compilar o `.p`
correspondente e emitir o `.c` ao lado do seu, num comando só. Os tipos que
atravessam continuam sendo os da fronteira 45.5 — o import não afrouxa nada,
só tira do usuário o trabalho manual que o porte do pstudio fez à mão
(compilar o P, incluir o header gerado).

**Como ficou.** O `.ph` é lido com o PRÓPRIO front-end do P — mesmo lexer,
mesmo parser —, e as declarações passam pela mesmíssima peneira que um header
C atravessa (`ingest_cdecls`): assinatura sem ponteiro, membro de enum,
constante escalar. O driver, ao parsear o `.psc`, vê o import e acrescenta o
`.ph` e o `.p` irmão à lista de entradas, então um comando emite os dois lados
na mesma árvore espelhada. Do lado da baixada o import vira um import de P
(não um `include` de C): assim a sema do P confere cada chamada que a baixada
gerou contra as declarações de verdade — a 49.1 fazendo o trabalho dela — e
cada back end faz o que já fazia com um módulo P (o C inclui o header gerado,
o QBE funde os layouts).

Dois detalhes que a implementação obrigou: o laço de entradas do driver virou
um `while` (um `for` não veria o que foi acrescentado no meio) com o
incremento no TOPO, porque o corpo tem `continue`s; e um módulo puxado, quando
existe `-o`, escreve ao LADO do arquivo nomeado, com o nome que o fonte dele
dá — `-o` nomeia um arquivo, e o módulo puxado não foi nomeado por ninguém.

Testes: `tests/pscript/run/pmodule.psc` + `pmod_mathx.ph`/`.p`, e a suíte passa
a linkar os `pmod_*.c` que o compilador emitir.

### 75.4 — escolhas de implementação, CONFIRMADAS

Quatro coisas que eu decidi implementando e o usuário ratificou:

  * `await race(ts)` devolve o ÍNDICE do vencedor (o valor se lê da task);
  * `await timeout(t, ms)` devolve `bool` — True se terminou a tempo — e
    cancela o perdedor nos dois casos;
  * o CABEÇALHO de um `buffer` nunca é liberado (os bytes são, no `close`):
    outra thread pode estar segurando o ponteiro, e liberar seria
    use-after-free entre contextos;
  * o valor inicial de um `shared str` é um LITERAL, porque é escrito antes de
    existir qualquer contexto.

## Baterias 76 a 80 — I/O de verdade: pool, socket e o que o JS faz

Decisões do usuário, todas fechadas, nenhuma implementada ainda. É o programa
de trabalho da próxima fase: `async` deixa de ser sobre relógio e passa a ser
sobre I/O, que é a razão pela qual `async` existe.

**O desenho em uma frase:** `async/await` para I/O, `spawn`/worker para CPU, e
cada worker com escalonador próprio (então um worker também usa `await`).

### 76.1 — o que o runtime atende: arquivo, socket e DNS, tudo agora

A separação é a da libuv, e não é gosto: **socket tem modo não-bloqueante de
verdade** e entra no `poll` que a 74.1 já construiu; **arquivo não tem** —
`read(2)` bloqueia sempre — e por isso precisa de thread; **DNS** (`getaddrinfo`)
também bloqueia e vai ao pool.

### 76.2 — TODO I/O vira aguardável

`f.read()` passa a devolver uma task: `texto = await f.read()`. O código
existente ganha um `await` na frente, e como o topo também espera, nada fica
impossível de escrever. Um nome por operação, e o que é lento PARECE lento —
que é a lição do async colorido.

### 76.3 — um pool por processo, preguiçoso

UM pool para o processo inteiro, criado na primeira operação assíncrona, com N
threads (padrão = núcleos, teto 8) e `PSCRIPT_POOL` para mandar diferente. A
thread do pool **nunca toca o heap de ninguém**: ela trabalha em bytes
malloc'ados e devolve bytes malloc'ados; quem constrói o valor no heap é o
escalonador do contexto que pediu, exatamente como a recepção de mensagem da
74.1 faz. Cada contexto tem sua fila de conclusão e seu descritor de acordar.

### 76.4 — cancelar I/O solta quem espera

Uma operação já em voo não se interrompe: `read(2)` não volta até voltar.
Então `cancel`/`timeout` **liberam quem esperava na hora** (com o erro de
cancelamento), a operação termina em paz na thread do pool e o resultado é
descartado. Nada vaza e nada é cortado no meio.

### 77.1 — o módulo `net`, orientado a conexão

    import net

    srv = net.listen(8080)
    c = await srv.accept()
    dados = await c.read(4096)
    await c.write("pong")
    c.close()

    ip = await net.lookup("exemplo.com")

Esconde socket/bind/listen/setsockopt atrás do que o programa quer. A conexão
é `Closeable`, então entra no `with`.

### 77.2 / 78.1 — HTTP é NOSSO, escrito em pscript, depois do socket

Nada de terceiro dentro do runtime. O teste do que entra no `psrt` é: **precisa
de acesso privilegiado ao heap, ao coletor ou ao escalonador?** Coletor,
escalonador, pool, `poll`, socket e DNS precisam; parser de HTTP, JSON e URL
não — são máquinas de estado sobre bytes, e ficam melhor escritas em pscript,
onde o usuário lê e depura na própria linguagem.

O llhttp é ele mesmo uma máquina de estados descrita num DSL em TypeScript que
cospe C; reimplementá-la a partir da especificação nos dá o mesmo parser sem um
`.c` de terceiro. Entra DEPOIS que socket e pool estiverem verdes.

Quem quiser **TLS** ou a libcurl usa `import "tls.ph"` / `import "curl.ph"` — a
fronteira da 75.3 existe justamente para isso, e a libcurl ainda por cima tem o
laço dela, que teria de ser dirigido pelo nosso `poll`: integração, não
linkagem, e integração desse tamanho não mora debaixo da abstração.

### 77.3 — o laço DRENA no fim do programa

Como o JS: ao chegar ao fim, o escalonador roda até não haver mais nada pronto,
nem prazo, nem I/O em voo. Hoje uma task órfã morre pela metade (medido:
`orphan:start` sai, `orphan:end` nunca). Com isso, uma task solta passa a
funcionar como todo mundo espera e um servidor no topo deixa de precisar de
`while True` artificial.

### 77.4 / 78.2 — console: `print` síncrono, e os dois irmãos assíncronos

`print` continua como é — escrita em buffer, barata, canal de diagnóstico da
linguagem; um `await` em cada print envenenaria todo programa. Entram TAMBÉM
`await aprint(...)` (mesmos argumentos, mesma junção por espaço) e
`sys.out`/`sys.err` como objetos de arquivo, para quem quer escrever bytes,
redirecionar ou usar `with`. E `await input()` estaciona, porque stdin espera
por gente.

**O porquê, que vale escrever:** embrulhar um `print` bloqueante num `async def`
NÃO o torna assíncrono. Um `async def` é uma máquina de estados que só cede
onde há `await`; se o corpo chama `write(2)` e ele bloqueia, a thread inteira
para com todas as tasks daquele contexto. O que torna algo não-bloqueante é a
OPERAÇÃO ser uma task — no pool ou no `poll`.

### 78.3 — `async:` e `async lambda`, os dois

    t = async:
        await sleep(1)
        print("pronto")

    g = async lambda x: await busca(x)

O bloco `async:` vira uma Task ali mesmo, capturando por valor como o lambda faz
(19.2) — é o que serve disparar trabalho de fundo sem declarar função, e casa
com a drenagem: `async:` sozinho é fire-and-forget que agora termina.

### 78.4 — `await` CEDE SEMPRE, como o JS

Mesmo com o valor pronto, o `await` passa pelo escalonador. Ordem previsível e
justiça entre tasks — sem isso, um laço de `await`s que sempre acha resposta
pronta (um cliente rápido, num servidor) nunca deixa outra task rodar.

### 79.1 — `read` devolve `list<u8>`

Bytes são bytes: um socket traz metade de um caractere UTF-8, um JPEG, um frame
binário. `read` dá `list<u8>` e quem sabe que aquilo é texto chama `str(b)`, que
LANÇA se não for UTF-8 válido. `write` aceita os dois. Usa um tipo que a
linguagem já tem, que já atravessa em mensagem, e deixa o parser de HTTP
natural.

### 79.2 — até n bytes, vazio é fim

`read(n)` devolve o que chegou (1..n); o vazio significa que o outro lado
fechou — a semântica do `recv(2)`, que é o que todo parser incremental espera.
Quem quiser exatamente n chama `read_exact(n)`, que insiste e LANÇA se o fim
vier antes.

### 79.3 / 80.2 — `open` e `close` aguardáveis, mas a limpeza fecha síncrono

`f = await open("x")` vai ao pool. `await f.close()` existe. MAS `with` e
`defer` chamam o fechamento BLOQUEANTE — porque `with`/`defer` também rodam
durante o DESENROLAR de uma exceção, e esperar no meio do desenrolar obrigaria a
limpeza a virar estado da máquina (um `with` podendo estacionar na saída por
erro). `close(2)` só demora em caso patológico, então o custo é ~zero e a
delicadeza toda é evitada.

### 79.4 — combinadores

Já existem `gather` (= `Promise.all`, resultados na ordem DADA, não na de
chegada), `race` (índice do vencedor, cancela o resto) e `timeout`. Entram:

  * `gather_settled` (= `allSettled`): espera todas e devolve o estado de cada
    uma, valor ou erro, sem que a primeira falha derrube o conjunto;
  * `first_ok` (= `any`): a primeira que der certo vence; se todas falharem,
    lança com o conjunto de erros;
  * `gather(ts, at_most=8)`: teto de concorrência, para que mil arquivos não
    virem mil tasks afogando o pool.

### 80.1a — strings ATRAVESSAM a fronteira P↔pscript

Hoje não atravessam, e por isso não existe aqui a dança de `c_str()` do C++.
Com socket e HTTP chegando, um shim em P vai querer receber e devolver texto.
Decidido: definir como uma string cruza — provavelmente `const *char` mais
tamanho, COPIADO dos dois lados, para que nenhum ponteiro de heap coletado
escape e nenhum `malloc` do P entre no coletor. A conversão passa a existir,
explícita e num lugar só.

### 80.1b — largura adaptativa da `str` (a 7.1, inteira)

`s[i]` hoje varre (O(n)); `len(s)` já é O(1) pelo `nchars` no cabeçalho.
Decidido fazer o PEP 393: latin-1 / UCS-2 / UCS-4 escolhidos por string
conforme o maior codepoint, com índice e fatia O(1) SEMPRE. Mexe em
representação, coletor, concatenação (converter larguras), `pack`, mensagem
entre heaps e fronteira com o P — é uma leva inteira sozinha, e vem depois do
I/O.

## O que já está FEITO desta fase

### 78.4 / 77.3 — o escalonador: cede sempre, e drena no fim — FEITO

`await` de um valor já pronto agora passa pelo escalonador antes de continuar
(a task vai para o fim da fila), e ao chegar ao fim do programa o laço roda até
não haver mais nada pronto, nem prazo, nem I/O em voo. Medido antes: uma task
órfã imprimia `orphan:start` e nunca `orphan:end`; agora termina. Teste:
`tests/pscript/run/loop_drain.psc`, onde duas tasks cujos awaits SEMPRE acham
resposta pronta intercalam em vez de uma monopolizar.

O worker também drena o laço dele antes de terminar a thread.

### 76.1/76.2/76.3/76.4 + 79.1/79.2 — arquivo pelo POOL — FEITO

Um pool por processo, preguiçoso, N = núcleos (teto 8, `PSCRIPT_POOL` manda
diferente), threads destacadas. Uma thread do pool só toca o item de trabalho
(malloc'ado) e a libc — esse é o contrato inteiro, e é o que deixa o coletor
sem saber que o pool existe. A conclusão acorda o contexto por um PIPE por
contexto, e o `poll` do escalonador já esperava em descritores desde a 74.1.

A superfície ficou:

    f = await open(caminho, "r")     # abrir também vai ao pool
    b = await f.read(4096)           # list<u8>, até n, vazio = fim
    t = await f.text()               # tudo, decodificado e VALIDADO
    r = await f.read_all()           # tudo, cru
    ls = await f.readlines()
    n = await f.write(x)             # str ou list<u8>
    await f.close()                  # e `with`/`defer` fecham SÍNCRONO (80.2)

`read()` sem argumento deixou de existir: o nome diz o que volta, e não o
número de argumentos. Cancelar solta quem espera na hora e deixa a chamada
terminar sozinha (76.4) — `read(2)` não para no meio.

Três coisas que a implementação obrigou, e que valem registro:

  * **`errno` não atravessa**: é macro (o P não a enxerga) e é POR THREAD — a
    thread que leria não é a que falhou. A mensagem vem da OPERAÇÃO;
  * **método `async def`** passou a existir (não existia: o parser aceitava e a
    sema ignorava). Sem ele, um método que lê arquivo é impossível de escrever;
  * **entrada de worker pode ser `async def`**: a thread tem escalonador
    próprio e dirige a própria entrada como o topo faz. É o que torna "todo
    worker usa async/await" verdade e não slogan.

### `try`/`catch` DENTRO de `async def` — FEITO

Era recusado ("o partidor só sabe if, while e for"), e sem ele nada que faça
I/O consegue tratar erro. Agora o corpo do `try` roda em estados próprios com o
guarda de exceção apontando para o estado do CATCH — então um erro que nasce
DEPOIS de uma suspensão ainda cai no handler, em vez de encerrar a task.

**O que continua faltando, e é o próximo:** `with`, `defer` e `finally` em volta
de um `await`. E há um BUG anterior a esta fase: hoje o corpo de um `defer`
dentro de um `async def` é emitido antes do `return` do ESTACIONAMENTO — ou
seja, a limpeza roda quando a task apenas suspende. O conserto certo é a seção
de limpeza: cada `defer` arma um bit no frame, e toda saída de verdade (return,
falha, fim) roda os armados em ordem inversa; o estacionamento não roda nada.

### Um bug de nome achado no caminho

`main` está na lista de nomes que o C já tem, então `ps_cname("main")` é
`main_` — e a busca do frame do `async def main` procurava `main__frame`
enquanto o frame se chamava `main___frame`. Não achava e usava silenciosamente
o PRIMEIRO frame da lista, gerando código que referencia locais que não existem
ali. Agora a busca usa o mesmo nome que a criação, e não achar é erro interno
em vez de palpite.

### 50.1 — limpeza dentro de `async def`: `defer`, `with`, `finally` — FEITO

Uma função `async` vira máquina de estados, e o passo dela RETORNA toda vez que
a task suspende. Por isso ela não pode usar o `defer` do P: o P roda o corpo do
defer em cada `return`, e a limpeza disparava numa SUSPENSÃO — medido, o corpo
do defer aparecia antes do `return` do estacionamento. Era um bug anterior a
esta fase, e é por causa dele que `with` era recusado dentro de `async def`.

A saída: cada limpeza arma um BIT no frame, e toda saída DE VERDADE — `return`,
falha, o fim do corpo — roda as armadas em ordem inversa. Uma suspensão não
roda nada. O `with` fecha ao sair do bloco e desarma o bit, então uma saída
posterior não fecha de novo; se a saída for por erro ou por `return` de dentro
do bloco, quem fecha é o caminho da saída. O `finally` é a mesma máquina.

E o fechamento continua sendo o BLOQUEANTE mesmo com `await f.close()`
existindo (80.2), porque a limpeza também roda com exceção pendente.

Teste: `tests/pscript/run/async_cleanup.psc`.

### 77.1 — o módulo `net`: socket e DNS — FEITO

    import net

    srv = net.listen(0)          # 0 = o sistema escolhe; `srv.port()` diz qual
    c = await srv.accept()
    dados = await c.read(4096)   # list<u8>, até n, vazio = o outro lado fechou
    await c.write("pong")
    c.close()                    # e `with` fecha sozinho

    c2 = await net.connect("exemplo.com", 80)
    ip = await net.lookup("exemplo.com")

`accept`, `read` e `write` são POLLED: o descritor entra no mesmo `poll` que o
escalonador já roda desde a 74.1, e a chamada de sistema acontece quando ela
não pode mais bloquear. `connect` e `lookup` vão ao POOL, porque
`getaddrinfo` bloqueia e não há como convencê-lo. O teste é um servidor e dois
clientes no MESMO processo e na mesma thread — o que só funciona porque cada
espera estaciona.

Coisas que a implementação obrigou:

  * **prontidão vem do `poll`, não do `errno`**: errno é macro (o P não a
    enxerga) e é por thread. Perguntar ao `poll` custa uma chamada e responde a
    única pergunta que importa;
  * **SIGPIPE** é desarmado com um handler VAZIO, porque `SIG_IGN` é macro de
    cast e `MSG_NOSIGNAL` é só do Linux;
  * **`INADDR_ANY` também é macro de cast** — e vale zero, que é o que se
    escreve;
  * **o `fd` de um trabalho começa em -1 e não em zero**: zero é um descritor
    perfeitamente válido (stdin), e é exatamente por esse campo que o
    escalonador distingue socket de trabalho de pool. (Custou uma suíte
    inteira travada para descobrir.)

### 79.4 — `gather_settled` e `first_ok` — FEITOS

`gather_settled(ts)` espera todas e devolve `list<Error?>`: o erro de cada uma,
None onde deu certo. Os valores se leem das próprias tasks, que já terminaram.
`first_ok(ts)` devolve o índice da primeira que deu certo e cancela o resto;
se todas falharem, lança.

**O `at_most` entrou com OUTRA FORMA, e o motivo é de desenho:** com o começo
QUENTE da 35.1, a task já está rodando no instante em que é criada — um limite
no `gather` chegaria depois de todas terem começado, e não haveria o que
estrangular. O lugar de limitar é onde as tasks são CRIADAS:

    quadrados = await gather_map(peça, itens, at_most=3)

Ele anda pelos ITENS e nunca tem mais que `at_most` tasks vivas ao mesmo tempo
(o teste mede o pico e prende em 3). Os resultados voltam na ordem DADA, que é
a promessa que o `gather` já fazia. O adaptador é emitido por sítio de chamada,
como o do `sorted(key=)`, porque só ali se conhece o tipo do elemento — e é
coletado ANTES da baixada, junto com os lambdas, senão o protótipo não existe
quando o corpo que o chama é escrito.

Isso destravou duas coisas menores no caminho: um `async def` agora pode ser
usado como VALOR (o símbolo por trás dele é a função de partida, que já tem a
forma certa: devolve uma task), e o adaptador de função-valor passou a saber
disso.

### 78.2 — `aprint`, `sys.out` e `sys.err` — FEITOS

`print` continua síncrono. `await aprint(...)` tem os mesmos argumentos e a
mesma junção por espaço, e vai ao pool. `sys.out`/`sys.err` são arquivos
comuns, então `await sys.out.write(b)` é a mesma operação de escrever em
qualquer arquivo — e `close()` neles não faz nada, porque pertencem ao
processo e não ao programa.

### 78.3 — o bloco `async:` — FEITO

    t = async:
        await busca()
        registra()

Vira um `async def` cujos PARÂMETROS são o que o bloco capturou, e a análise de
captura é a mesma do lambda (19.2): um nome de fora, lido dentro, viaja por
valor. Sozinho no topo é fire-and-forget que a drenagem da 77.3 termina.

**`async lambda` — FEITO**, e sem compor nada: ele vira DUAS coisas que já
funcionavam, uma em cima da outra. `async lambda x: e` gera um `async def
__alam<N>(<capturas>, x)` com o corpo, e o próprio nó vira um lambda COMUM cujo
corpo é a chamada `__alam<N>(capturas..., x)`. A máquina de estados cuida do
corpo, o ambiente de captura cuida do valor, e nenhuma das duas precisou
aprender sobre a outra. O tipo que recebe diz que volta uma task:

    f: def(int) -> Task<int> = async lambda x: await busca(x)

### 81/83/84/85/86 — texto atravessando a fronteira: `CStr` e `CBytes` — FEITOS

Dois tipos de VALOR no P, `{ponteiro, tamanho}`, que **não alocam nada**:
`CStr` para texto e `CBytes` para bytes. Eles moram em `stl/cstr.ph` — e aqui
vale registrar um desvio da 83.3, que dizia "núcleo da linguagem": o
compilador os RECONHECE por nome (é ele que monta o par no sítio da chamada e
que copia na volta), mas a DECLARAÇÃO precisa morar num arquivo, porque um
tipo que o compilador injetasse em cada módulo daria definição duplicada em C
quando dois headers se encontrassem no mesmo `.c`. Um `import` resolve, e o
75.3 puxa o header transitivamente, então na prática o programa não escreve
nada a mais.

Como ficou, medido no teste `text_boundary`:

  * **ida sem cópia**: o compilador monta o par apontando para os próprios
    bytes do `str`, e isso é seguro porque uma chamada C não coleta;
  * **volta com cópia e conferência**: o P nunca dá posse (devolve estático ou
    um buffer seu, a convenção do `strerror`), o pscript copia na chegada, e
    para texto VALIDA UTF-8 — bytes inválidos lançam;
  * `in s: CStr` no P é ponteiro const, então o que atravessa é o endereço do
    par; sem `in`, o par vai por valor. Os dois funcionam;
  * o teste mostra a diferença que justifica tudo: `texto_tamanho("olá mundo")`
    dá **10** do lado P (bytes) e `len()` dá **9** aqui (codepoints).

### 77.2 / 78.1 — HTTP/1.1 em pscript — FEITO

`tests/pscript/run/lib_http.psc`: a máquina de estados do llhttp reescrita a
partir da especificação, em pscript, sem um `.c` de terceiro no runtime. Ela é
INCREMENTAL (`feed(bytes)` diz se o pedido acabou), entende corpo por
`content-length` e por PEDAÇOS, e recusa o que o llhttp recusa — espaço antes
dos dois-pontos e `content-length` junto com `chunked`, que são as duas formas
clássicas de contrabando de pedido.

`http_server.psc` põe um servidor e três clientes no MESMO processo e na mesma
thread, conversando por socket de verdade. Isso só funciona porque toda espera
estaciona.

**Dois bugs de compilador que só apareceram aqui**, ambos no partidor de
estados e ambos anteriores a esta fase:

  * `break`/`continue` dentro de um laço que virou ESTADOS eram emitidos como
    `break` do C — que sai do `switch` e volta ao mesmo estado na volta do
    `while (1)`: laço infinito. Nunca apareceu porque nenhum teste tinha um
    `break` dentro de um laço async;
  * sair de um `with` por `break`/`continue` pulava o fechamento. Agora o salto
    roda as limpezas armadas desde o início do laço.

E `str` ganhou `lower()`/`upper()` (ASCII, e dito em voz alta: caixa em Unicode
depende de língua, e um `lower()` que fingisse saber disso mentiria).

### 80.1b — indexar em O(1) — FEITO, mas NÃO como PEP 393

A decisão pedia a largura adaptativa do PEP 393 (latin-1/UCS-2/UCS-4 por
string). Não foi isso que entrou, e o motivo só ficou visível depois de o resto
desta fase existir — vale registrar por inteiro, porque é uma decisão que eu
tomei sozinho:

**TUDO neste sistema quer os bytes UTF-8.** O socket manda bytes, o arquivo
grava bytes, a mensagem entre heaps serializa bytes, a fronteira com o P (84.1)
empresta um ponteiro para bytes, o `print` escreve bytes. Com o texto guardado
em UCS-4, cada uma dessas travessias teria de MATERIALIZAR o UTF-8 — e é
exatamente por isso que o próprio PEP 393 guarda as DUAS formas, com um cache
UTF-8 preguiçoso ao lado. O preço real da adaptativa aqui seria duas cópias de
toda string que atravessa qualquer coisa.

O que entrou alcança a mesma propriedade observável — `s[i]` e fatia em O(1) —
com uma cópia só:

  * **ASCII não precisa de nada**: `nchars == len` já É a prova de que cada
    byte é um caractere, então o índice é acesso direto. Essa prova estava no
    cabeçalho desde a 51.2 — só ninguém tinha reparado nela. Cobre a
    esmagadora maioria das strings e TODO texto de protocolo;
  * **o resto ganha um índice de deslocamentos**, construído na primeira vez
    que alguém indexa AQUELA string, guardado nela e coletado com ela. O(n) uma
    vez, O(1) daí em diante, e nada para quem nunca indexa. Como uma `str` é
    imutável (31.3), ele nunca se invalida.

Se um dia aparecer um programa que sofra com isso — muito texto não-ASCII,
indexado o tempo todo, sem atravessar nada —, a adaptativa continua registrada
e o caminho está livre. Teste: `tests/pscript/run/str_index.psc`.

## Onde a fase parou

Tudo o que as baterias 76 a 86 decidiram está implementado. Duas coisas saíram
diferentes do texto da decisão, as duas explicadas acima: a largura adaptativa
do PEP 393 virou um índice que dá a mesma propriedade sem duplicar toda string
que atravessa alguma coisa, e o `at_most` mudou de lugar — de `gather` para
`gather_map` —, porque com começo quente um limite no `gather` chega tarde
demais para estrangular qualquer coisa.

### A ordem de implementação

  1. escalonador: `await` cede sempre (78.4) e o laço drena no fim (77.3);
  2. pool de threads (76.3) com fila de conclusão por contexto;
  3. arquivo aguardável (76.2, 79.1/79.2/79.3/80.2) — quebra os testes que usam
     `f.read()`, e eles são atualizados junto;
  4. `sys.out`/`sys.err` e `aprint` (78.2);
  5. `net`: socket no `poll`, DNS no pool (77.1);
  6. combinadores (79.4);
  7. `async:` e `async lambda` (78.3) — FEITOS;
  8. strings atravessando a fronteira (80.1a);
  9. largura adaptativa (80.1b);
 10. HTTP em pscript (77.2/78.1).

## Baterias 81 a 86 — texto atravessando a fronteira

O `str` do pscript e o `const *char` do P nunca se encontraram: a 45.5 só deixa
escalar passar. Com socket e HTTP chegando, um shim em P vai querer receber e
devolver texto. Decidido, e ainda não implementado.

### 84.1 / 85.2 — `CStr` e `CBytes`: um par {ponteiro, tamanho}

Dois tipos de VALOR, do tamanho de dois registradores, que **não alocam nada**:

    CStr    = { ptr: const *char, len: usize }   # texto
    CBytes  = { ptr: const *u8,   len: usize }   # bytes quaisquer

Eles existem para **carregar o tamanho junto com o ponteiro** e para o
compilador poder dizer até onde aquele ponteiro é seguro. Não são construtores:
o `Str` da STL (`init`/`append`/`deinit`, com `realloc`) fica onde está,
intocado, e continua sendo quem FABRICA texto.

**Por que isso não traz alocação escondida para o P:** o P não tem alocação
escondida hoje porque não tem operação de string que possa alocar — `a + b`
entre strings é erro ("cannot add two pointers"), `==` e `in` comparam por
`strcmp`, e fabricar texto é `snprintf` no seu buffer ou o `Str` da STL, cujo
`realloc` está dentro de uma função que você chamou. Um tipo valor
{ponteiro, tamanho} nunca aloca, então a propriedade fica intacta.

### 84.2 — a regra que dá a segurança

Como o `ref T` da 69: `CStr`/`CBytes` podem ser **parâmetro, variável local e
tipo de retorno**, e NÃO podem ser campo de struct, elemento de array nem
variável global. Assim nenhum deles sobrevive por acidente ao escopo que o
criou, e a fronteira fica provada: o pscript copia antes de a chamada voltar.
Nunca são None.

### 83.1 — posse: o P nunca dá posse

O `CStr` devolvido por uma função P aponta para memória que o P mantém —
estática, literal, ou um buffer dele válido até a próxima chamada (a convenção
do `strerror`). O pscript **copia na chegada** e, a partir daí, aquilo é do
coletor dele. Se o P fez `malloc`, a responsabilidade de liberar continua sendo
do P; o pscript nunca libera memória do outro lado, e nenhum ponteiro do heap
coletado escapa.

### 83.2 — bytes que chegam são VALIDADOS

Virando `str`, o pscript confere UTF-8 e **lança** com categoria e posição se os
bytes não forem válidos — em vez de deixar entrar um `str` que mente sobre o
próprio `len()`. Virando `list<u8>`, copia como está. A validação fica onde a
promessa é feita.

### 83.3 — os dois tipos moram no NÚCLEO do P

Não na STL: é o compilador que precisa reconhecê-los nas duas pontas da
fronteira e na conversão de literal.

### 81.2 — o literal continua `const *char`

`printf("%s", "x")` segue igual. Onde se espera um `CStr`, o literal vira um na
hora, e o TAMANHO é dobrado em tempo de compilação — a conversão custa zero.
Uma direção só, nunca o contrário.

### 81.3 — sem garantia de NUL; imprime-se com `%.*s`

O tipo promete TAMANHO, não terminador (uma fatia não termina em NUL). Para a
libc, o idioma do P passa a ser `printf("%.*s", i32(s.len), s.ptr)`, que já é o
jeito certo em C. Quem precisar mesmo de um `const char*` copia para um buffer
seu.

### 81.4 — empresta na ida, copia na volta

pscript→P: o `str` vira `{p, n}` apontando para os próprios bytes — **zero
cópia**, seguro porque uma chamada C não coleta (só `ps_gc_poll` coleta, e C não
o chama), então nada se move debaixo dela. P→pscript: cópia na chegada. E,
quando a largura adaptável da 80.1b existir, o objeto guarda a forma UTF-8 na
primeira vez que alguém a pede, para que a ida continue sem cópia.

### 86.1 — parâmetro de array NU vira ERRO no P

Medido: `def f(b: u8[8])` emite `uint8_t b[8]`, que **decai**; dentro da função
`sizeof(b)` dá 8 (o ponteiro) enquanto fora dá 4 para um `u8[4]`; e passar um
`u8[4]` onde se declarou `u8[8]` compila calado.

Já `def f(in b: u8[8])` emite `uint8_t (*b)[8]` — ponteiro para array, que **não
decai** (`sizeof(*b)` é o tamanho real), cujo descasamento o compilador acusa, e
cuja leitura o P já protege (`b[0] = 1` num `in` é erro).

Decidido: em fonte P, a forma nua vira ERRO apontando a saída — `in b: u8[8]`
(referência conferida) ou `b: *u8, n: usize`. O front-end C continua aceitando,
porque lá é C de verdade.

**E um achado que salvou um "conserto" errado:** `in b: u8[N]` NÃO deve emitir
`const uint8_t (*b)[8]`. Passar `&a` (array não-const) para um ponteiro-para-
array const é **erro em ISO C antes do C2X** — falha em c89, c99 e c11 sob
`-pedantic-errors`. Sem o `const` funciona nos três. A forma que o P emite hoje
é a única portável, e a garantia de somente-leitura vem do P, em tempo de
compilação, e não do tipo em C. Também medido: `CStr` como struct passada e
devolvida por valor compila limpo em c89.

### 86.2 — na fronteira, texto e bytes são SEMPRE `CStr`/`CBytes`

Inclusive quando o tamanho é fixo. Uma regra só para lembrar. O `in b: u8[N]`
continua existindo para código P↔P, onde a checagem de tamanho é de graça.

## Pendências de decisão acumuladas

Nenhuma no momento. (Acrescente aqui conforme aparecerem, com o número da
bateria.)

## As duas que vinham da bateria 72

### 72.5 — assinatura inteira e tipo associado, no P — FEITO

O lado pscript já conferia tudo (66.4): parâmetros, `in`, retorno e o tipo
associado. O lado P conferia só o NOME do método e a CONTAGEM de parâmetros —
uma implementação podia devolver outra coisa e só ser descoberta muito depois,
dentro de um corpo monomorfizado, com o erro apontando para a linha errada.
Agora `implement Trait for T:` confere a assinatura inteira: o tipo de cada
parâmetro, o modo (`in`/`out`/`ref` faz parte do contrato) e o tipo de retorno.

A comparação é por SUBSTITUIÇÃO: o nome do próprio trait vale pelo tipo que
implementa (é assim que `self: *Comparable` vira `self: *Point`) e o tipo
associado vale pelo que a implementação escolheu. Substituir e depois comparar
ganha de uma comparação que saiba de traits — o que sai é um tipo comum, e a
igualdade comum responde por ele.

E o P ganhou **tipo associado**: `type Item` no trait, `type Item = f64` na
implementação. Sem ele o `Iterable` da stl era um contrato de `i64` com nome
geral; com ele o mesmo contrato serve um contador de inteiros e uma série de
temperaturas, e o genérico que percorre qualquer um dos dois nunca escreve o
tipo do elemento. Não custa nada em execução: o P monomorfiza, então quando
existe código o tipo associado já é o concreto e o trait sumiu (67.1).

Testes: `tests/cases/43_assoc_type.p` (dois tipos, dois `Item`, um genérico só
e o `for v in x` da 68.9 lendo `f64`), `tests/errors/p_trait_sig.p` e
`tests/errors/p_trait_assoc.p`.

### 72.6 — um `const` record atravessa por referência — FEITO

A 45.5 deixa escalares passarem porque um escalar é uma cópia e uma cópia não
aliasa nada. Um `record` também é bytes, mas copiá-lo para dentro de uma
chamada significaria a ABI de struct do C — então o que atravessa é o
ENDEREÇO, e o endereço só é seguro sob duas condições que o compilador
confere: o lado P recebe `in` (ponteiro const: lê e não escreve) e o argumento
é um `const` de módulo, que vive no escopo de arquivo do C e por isso tem
endereço estável e bytes que nada muda.

O TIPO vem do header (75.3): um `record` do P de números vira um `record` do
pscript, com o `from_hdr` que impede a baixada de emitir uma segunda
definição. Uma declaração só — que é o único arranjo em que as duas linguagens
não podem discordar do layout de algo que as duas nomeiam. Só `record` do P (e
não qualquer struct): `record` é a palavra para um valor que o compilador
CONFERE ser bytes puros, e é a que tem construtor nos dois lados, então
`Rect(3, 4)` quer dizer a mesma coisa em quem escreve e em quem declarou.

A checagem é no PONTO DA CHAMADA porque só ele sabe o que está entregando.
Alargar depois (aceitar um local, por exemplo) é aditivo; começar largo não
teria volta.

Testes: `tests/pscript/run/const_record.psc` + `pmod_geom.ph`/`.p` e
`tests/pscript/bad/const_record_mut.psc`.

## Bateria 88 — os corpora de fora (2026-08-17)

Decidida na 88 do DESIGN. Aqui é onde a implementação chegou.

### 88.a Infraestrutura — FEITA

- `tests/psbuild.sh` — um `.psc` vira binário, do jeito que o `tests/run.sh` faz.
  Existe porque três arreios passaram a precisar exatamente disso e nenhum deles
  deve reinventar a receita: os corpora, os oráculos e o placar de desempenho.
- `tests/fetch-external.sh` — ganhou os quatro corpora novos (JSONTestSuite,
  llhttp, WPT url, test262 Promise). Nada disso é distribuído com o repositório.
- `tests/conformance/run.sh` — o arreio, com portão TOTAL.
- `tests/conformance/compare.py` — compara WANT×GOT por caso, com `<corpus>.skips`
  contado e impresso à parte. Um skip cujo caso volta a concordar é reportado
  como STALE, para a nota morrer junto com o problema.

### 88.b JSON — FEITO, 318/318

`bash tests/conformance/run.sh json`. 95 documentos que têm de ser aceitos, 188
recusados, 35 que a RFC deixa em aberto e ficam PREGADOS em
`tests/conformance/json.expected` — assim uma mudança de ideia aparece como
diff em vez de passar despercebida.

Nos 35 em aberto concordamos com o Python em 32; os três são inteiro grande
demais, que aqui é RECUSA (não há bignum e estouro lança em todo lugar, 7.2) e
lá é bignum. Divergimos do node em dez, e não é sobre JSON: o
`readFileSync(f,"utf8")` do node troca byte inválido por U+FFFD antes de o
parser ver.

O parser ganhou, além dos consertos da 88.4: **limite de profundidade de 1000**
(`PS_JSON_MAX_DEPTH`), que é fronteira de segurança e não preferência — descida
recursiva sobre texto de terceiro sem limite é um estouro de pilha esperando ser
pedido, e o corpus pede.

Regressão travada em `tests/pscript/run/jsonstrict.psc`.

### 88.c URL — FEITO, 890/891

`pscript/lib/url.psc` — porte do `whatwg-url`, estado por estado. Inclui IPv4
(com octal e hexadecimal, que é por que `http://0x7f.1` é um jeito válido de
escrever `127.0.0.1`), IPv6 com compressão e cauda IPv4, os conjuntos de
percent-encoding aninhados, Punycode (RFC 3492) e a parte FORMULÁVEL do UTS-46:
o bloco ASCII de largura plena, os três pontos finais, o conjunto ignorado de
largura zero, e os espaços e não-caracteres proibidos.

O que fica de fora está escrito no `url.skips`: a metade do UTS-46 que é TABELA
(dobra de caixa fora do ASCII, blocos de compatibilidade, NFC). O único caso que
falha precisa do bloco de símbolos matemáticos.

### 88.d HTTP — FECHADO, 202/202 (10 pulados com motivo)

`tests/conformance/llhttp_digest.py` lê as fixtures `.md` do llhttp (entrada
```http`, log de eventos ```log`) e REDUZ o log ao que os dois lados sabem
dizer: método, alvo, protocolo, versão, cabeçalhos, corpo, completo, erro. Nada
na redução é generoso conosco — o que ela descarta é o que o llhttp confere e
nós não modelamos (deslocamento em bytes, fronteira de span, a API de pausa, o
campo `flags`); o que ela guarda é tudo o que nós modelamos.

212 fixtures aproveitadas, 41 puladas: as `-lenient-*` medem a máquina RELAXADA
do llhttp (cada uma dessas bandeiras existe para aceitar algo que a RFC recusa,
por compatibilidade com clientes já implantados — dívida que não carregamos), e
`-finish`/`pausing` dirigem uma API que não expomos.

`pscript/lib/http.psc` (era `tests/pscript/run/lib_http.psc`) ganhou: parser de
RESPOSTA, lista `raw` de cabeçalhos na ordem de chegada, junção de repetidos com
`, ` (RFC 9110 §5.3, e `raw` é o que preserva `set-cookie`), recusa de
`content-length` duplicado ou não-numérico, separação protocolo/versão, corpo
que termina com a conexão (`finish()`), e trailers depois do último chunk.

**O que o corpus arrancou do parser.** Cada linha é uma porta de request
smuggling que estava aberta, e a maioria não é sutil:

  * **CR solto aceito como fim de linha.** `x:<CR>Transfer-Encoding: chunked` era
    UM cabeçalho para nós e DOIS para quem não para no CR — o payload clássico.
  * **LF solto aceito**, pela mesma razão exata. Isso REVERTE o que o arquivo
    dizia ("todo servidor aceita"): era verdade e irrelevante, e o llhttp em modo
    estrito recusa por este motivo, oferecendo leniência como opt-in.
  * **`obs-fold` aceito** — `Foo: bar<CRLF><SP>Content-Length: 38` continuava o
    cabeçalho anterior para nós. RFC 9112 §5.2 mandou parar em 2022.
  * **nome de cabeçalho não era conferido como token** (`Fo@:`, `en-US
    Content-Type:`, nome com byte de controle) e **valor aceitava controle**.
  * **`Content-Length` sem limite** (`1000000000000000000000` passava) e
    **recusado DEPOIS de registrado**, o que lê como "aceitou e então falhou".
  * **Transfer-Encoding sem as regras da 6.1**: `chunked` fora do último lugar,
    TE junto com CL, TE vazio, TE duplicado — cada um é um comprimento que dois
    hops leem diferente.
  * **linha de status frouxa**: `HTTP/1.1  200 OK` passava, `HTTP/01.1` passava,
    tab no lugar do espaço passava.
  * **1xx/204/304 decidiam DEPOIS do Transfer-Encoding**, então um `101
    Switching Protocols` com TE ganhava um corpo — o primeiro pacote do
    protocolo seguinte entregue como corpo da resposta.
  * **`CONNECT` ganhava corpo** — o primeiro pacote do túnel.
  * **alvo do pedido sem conjunto de caracteres** (byte cru acima de 0x7E).
  * **extensão de chunk sem gramática** (`;` sem nada, aspas sem fechar, espaço
    depois do tamanho).
  * **preâmbulo do HTTP/2** (`PRI * HTTP/1.1`) era lido como pedido comum, e o
    que vem depois são frames binários: rebaixamento de protocolo com o parser
    do lado errado.

E **três erros de modelagem MEUS no arreio**, que é o outro lado do exercício:
o log do llhttp não escapa aspas (eu apagava barras invertidas reais); ele imprime
span de espaço em branco por NOME e sem aspas (`span[body]=lf`, e eu perdia o
byte); e `code=22/23` é `HPE_PAUSED_UPGRADE` — **pausa não é recusa**, é o parser
dizendo "pare, pegue o socket", e lê-la como erro transformava quinze parses bem
sucedidos em falhas.

**A regra de comparação, dita explicitamente.** Mensagem que TERMINOU é comparada
exatamente — campo, valor e ordem. Para a que não terminou quando os bytes
acabaram, a regra é "nenhuma contradição": o llhttp fecha cada span no byte em que
o lê, e um parser que lê a linha inteira antes de decidir naturalmente relatou
menos. Um valor em que um dos lados parou no meio (`protocol=HT` contra
`protocol=HTP`) conta como concordar, porque prefixo é o que parar no meio parece.
É a mesma redução que o digest já faz ao jogar fora offsets e fronteiras de span.

### 88.e O modo de estresse do coletor — FEITO

`tests/gc-stress.sh` + `PSCRIPT_GC_STRESS=N` no runtime. Ver 88.5 do DESIGN para
a família inteira de defeitos que ele revelou e por que ela era invisível.

## Bateria 89 — `upper`/`lower` completos (2026-08-19) — FEITO

Ver a 89 do DESIGN para as decisões. Aqui está o que ficou:

- `tools/gen_unicode_case.py` → `pscript/runtime/unicase.bin` (22 KB), embutido
  com `embed_bytes` (63.1). 678 faixas de maiúscula, 102 mapeamentos 1→N, 667
  faixas de minúscula, 1 mapeamento 1→N, e os conjuntos `Cased` (150 faixas) e
  `Case_Ignorable` (437) que o sigma final precisa.
- Busca binária direto no blob: sem inicialização, sem alocação.
- Sigma final implementado — a única regra condicional que não é de locale.
- **Conferido contra o Python nos 1.114.112 pontos de código**
  (`tests/oracle/py/unicase.psc`): 1525 mapeamentos de maiúscula, 1433 de
  minúscula, mesmo hash dos dois lados.
- Gate próprio: `tests/pscript/run/unicase.psc`.

## Oráculos e placar — FEITOS

- `tests/oracle/run.sh` — os intérpretes de referência como ORÁCULOS, no molde do
  `clang-compare.sh`. `py/` compara a semântica da linguagem com o `python3`,
  `js/` compara o modelo de runtime com o `node`. Um par é `<nome>.psc` ao lado de
  `<nome>.py`/`.mjs`, escritos para imprimir as mesmas linhas.
- O que eles acharam de primeira: faltavam `abs`, `min`, `max`, `str.replace`,
  `str.join` e `"ab" * 3` — implementados; `upper` só fazia ASCII — virou a
  bateria 89; e **os prazos iguais acordavam em LIFO** porque o timer era
  empilhado na cabeça da lista, enquanto o JS acorda na ordem de registro. Duas
  tasks em `await sleep(0)` alternavam de trás para frente.
- Divergência que fica registrada em vez de escondida: `str()` de uma lista
  ainda não existe, e o que o Python imprime para uma é um repr com aspas — uma
  decisão de formatação, não de semântica.
- `tests/bench.sh` — o mesmo programa aqui, no `python3` e no `node`, com tempo
  de COMPILAÇÃO à parte. A coluna de compilação é longa de propósito: somos AOT
  através de C com o compilador do sistema no `-O2`, e node e python não compilam
  — a coluna é deles por não ter. Não é uma corrida em que estamos.

## O placar de desempenho, como ele saiu

`bash tests/bench.sh`, um núcleo, respostas conferidas entre os três, com
`-O3 -flto` (ver a bateria 90 para por que essas flags e não outras):

| programa | compilar | nosso | python3 | node |
|---|---|---|---|---|
| partida (programa vazio) | 2,3 s | **0,003 s** | 0,028 s | 0,037 s |
| fib(30) recursivo | 1,5 s | **0,007 s** | 0,124 s | 0,057 s |
| crivo até 2 milhões | 1,4 s | **0,065 s** | 0,233 s | 0,078 s |
| 200 mil concatenações + join | 1,5 s | 0,095 s | **0,067 s** | 0,096 s |

A coluna de compilar é longa de propósito e é só nossa: somos AOT através de C
com o compilador do sistema. Não é uma corrida em que estamos.

**Nada disso vem do nosso gerador de código, que não otimiza nada** — ele emite
chamadas de runtime e deixa o resto para o `cc`. Os ganhos acima são do GCC mais
duas correções de política nossas (a bateria 90): o `-flto`, porque programa e
runtime são duas unidades de tradução e toda operação é uma chamada atravessando
essa fronteira; e o orçamento do coletor proporcional ao conjunto vivo, que
tirou a quadrática de qualquer programa que acumula.

**Onde ainda perdemos, medido:** construir texto. Era 4× mais lento que o Python
E DIVERGINDO (0,49 → 1,27 us por item de 50 mil para 400 mil); agora é 1,4× e
plano. O que sobra é o custo próprio de um coletor que copia contra a contagem de
referências do CPython nesse padrão exato — não é mais um defeito, é a troca.

**Dois achados de desempenho que o placar destapou**, os dois consertados:

  1. **`f() + g()` avaliava a esquerda DUAS VEZES.** Os slots de substituição que
     fazem o operador ler os temporários são um par único, e uma baixada aninhada
     os salva e limpa — então instalar o da esquerda e depois baixar a direita
     através dele perdia o da esquerda, e a esquerda era baixada de novo dentro do
     `binary_raw`. `fib(n-1) + fib(n-2)` passou de 2ⁿ para 3ⁿ chamadas: `fib(25)`
     levava **17,45 s** onde agora leva 0,00. Nenhum teste pegou, porque com
     operandos puros a resposta é idêntica — só o relógio acusa. Gate novo em
     `eval_order.psc`, com um contador, que é o que torna isso visível.
  2. **O `for` e o verificador discordam sobre o escopo.** A 64.1 diz que um nome
     nascido num bloco morre com ele e que o `for` não vaza a variável — mas a
     sema ainda conta a variável do laço como da FUNÇÃO, então `for i in ...`
     seguido de `i = 2` é recusado como redefinição. A regra e a checagem não
     concordam; registrado aqui em vez de contornado em silêncio.

## O que a bateria 88 deixou EM ABERTO

- [x] **test262**: FEITO em 2026-08-20, como três pares de oráculo em
      `tests/oracle/js/` (`promise`, `turns`, `settle`) ao lado do `ordering`
      que já existia — 25 propriedades de ORDEM de resolução de
      `all`/`allSettled`/`any`/`race`, reescritas em `await` e conferidas
      contra o node a cada `verify-all`. O que o test262 mede em cima do modelo
      de objetos do JS (thenable, `Symbol.species`, `.call` com outro `this`)
      continua fora, e continua sendo o motivo pelo qual isto foi PORTADO em
      vez de copiado — ver a 88.1.

      As quatro perguntas que valia fazer e as respostas que o node deu:
      um `raise` ANTES do primeiro `await` sai no await e não na chamada,
      mesmo com o início quente da 35.1; a mesma task duas vezes numa lista dá
      dois lugares e uma execução só; um erro dentro de um `gather` aninhado
      chega ao await de fora inteiro, sem embrulho; e o `first_ok` sem nada
      para escolher recusa, como o `Promise.any`. As duas divergências reais
      estão impressas de propósito e não puladas: o nosso `race` CANCELA os
      perdedores e o do JS não, e a ordem de erro entre DUAS falhas simultâneas
      é desempate que ninguém decidiu aqui — então nenhuma linha pergunta por
      ela.
- [ ] **Oráculos** (decisão sua): `node` para o modelo de runtime (ordem de
      microtask, `await` que cede sempre, EOF de socket, ordem de timer) e
      `python3` para a semântica da linguagem (`-7//2`, `-7%3`, repr de float,
      fatia, ordem de dict, sort estável, métodos de str) — hoje conferidos À
      MÃO, caso a caso, no molde do `clang-compare.sh`.
- [ ] **Placar de desempenho lado a lado** (decisão sua): tempo de execução e
      tempo de compilação/partida contra node e python. O nosso demora a
      compilar porque é AOT com otimização máxima, e isso faz parte — não
      estamos competindo em velocidade de compilação.
- [ ] **`Awaitable`** (87.1) e a não-achatação (87.2).
- [ ] **Auditoria da especificação inteira**: varrer as 88 baterias contra a
      implementação, empiricamente e não pelo `[x]`.

## 4.4 RESPONDIDA e implementada — o dict itera em ordem de inserção (2026-08-20)

Ver a bateria 91 do DESIGN para a decisão. O que ficou:

- `PsDict` virou o dict COMPACTO: `index` (cap × i64, número da entrada ou
  EMPTY/DEAD), `keys`/`vals`/`state` DENSOS em ordem de inserção, `nent` como
  marca d'água. A iteração anda pelas entradas, então a ordem é a ordem.
- `ps_dict_cap` virou `ps_dict_nent` — o nome importava, porque o espaço de
  índices deixou de ser slot de hash e passou a ser entrada.
- Reconstrução COMPACTA em ordem, e só cresce quando foi o conjunto VIVO que
  encheu a tabela: uma tabela cheia de mortos é compactada no lugar.
- O coletor encaminha `index` também, e percorre `nent` entradas em vez de `cap`
  slots.
- Bate com o Python nos três casos difíceis: reatribuir mantém a posição,
  remover-e-reinserir vai para o fim, crescer não reordena.

Gates: `tests/pscript/run/dictorder.psc` e o par do oráculo, que voltou a
comparar a ordem.

## (histórico) A pendência, como ela foi achada

**A pergunta 4.4 do DESIGN nunca foi respondida, e a implementação respondeu por
omissão.** "Iteração de dicionário preserva ordem de inserção?" — as opções eram
(a) sim, e é garantia da linguagem, (b) sim, mas detalhe de implementação, (c)
não. A tabela hash respondeu (c) por não ter sido perguntada.

Isso importa porque o Python **garante** ordem de inserção desde a 3.7 e há dez
anos de código que depende disso: JSON que precisa voltar na mesma ordem,
configuração, saída de teste. O `Map` do JS garante o mesmo. Uma linguagem que
diz "ergonomia de Python" e itera em ordem de hash surpreende exatamente onde
menos deveria.

O que custaria, medido pela forma e não por chute: a tabela ganha uma lista
append-only de slots em ordem de inserção mais um índice inverso por slot (para
o `del` invalidar a entrada), a iteração passa a andar por essa lista, e o
`rehash` a reconstrói compactando. É o desenho do dict compacto do CPython, e lá
ele deixou o dict MENOR, não maior.

**Respondida em 2026-08-20 e implementada** — ver acima. Fica registrado como o
achado apareceu: não foi alguém relendo o documento, foi um par de oráculo que
divergiu, e a divergência não era bug nem escolha.

## Lacunas que o oráculo cobrou e foram implementadas (2026-08-20)

Escrever o par de coleções achou três coisas que faltavam, todas do núcleo do
Python:

- **fatia com passo** — `xs[::2]`, `xs[::-1]`, `xs[1:7:3]`, para lista E string.
  A de string copia por CARACTERE e não por byte, que é o que faz `s[::-1]` de
  texto com acento voltar como texto em vez de UTF-8 quebrado. As regras de
  fronteira (negativo conta do fim, clampa, passo negativo inverte os padrões,
  passo zero lança) ficaram numa função só, `ps_slice_bounds`, porque lista e
  string têm de responder idêntico.
- **`x in xs` sobre lista** — varredura linear por VALOR, com a mesma noção de
  igualdade que a chave de dict usa (conteúdo para `str`, nunca ponteiro). O
  `set` continua sendo a razão de o `set` existir (8.1) e isto é O(n) e diz
  isso — mas recusar faria da grafia óbvia um erro numa linguagem cujo norte a
  escreve exatamente assim.
- **`str.lstrip`/`rstrip`**.

E uma que fica registrada e não implementada: **um builtin como VALOR de função**
(`sorted(xs, key=len)`) não existe; escreve-se `key=lambda w: len(w)`.

---

# O NIO, à nossa maneira — o plano (baterias 135-140, 2026-08-24)

As decisões estão em `pscript/DESIGN.md`, baterias 135-140. **Só o utilizador
decide**; o que está lá está fechado e não se repropõe.

Sete fases. A **N** vem primeiro e não é sobre bytes — é a renomeação dos tipos,
feita antes para que nada novo nasça com o nome errado.

---

## FN — a regra dos nomes (139)

`list`→`List`, `dict`→`Dict`, `set`→`Set`, `socket`→`Socket`, `buffer`→`Buffer`.
Ficam minúsculos os VALORES: `int`, `float`, `bool`, `str`, `bytes` e os
numéricos com tamanho.

~1 150 sítios. É código e não prosa, portanto `sed` sobre os `.psc` e sobre as
mensagens do compilador; **à mão** os `.md`, que é a lição que a tradução para
inglês custou dois erros a aprender.

Ordem dentro da fase: primeiro o compilador aceita os dois nomes (o velho com um
aviso), depois a árvore migra, depois o velho sai. Sem isso, o commit do meio não
compila.

**Fica de pé:** a linguagem com uma regra em vez de um hábito, e o `verify` verde.

---

## F0 — `bytes`, `Buffer`, e as fatias (135.1, 135.3, 135.5, 136)

O tipo `bytes`: imutável, coletado, fatiável sem copiar, e apoiado num bloco que
não se move. O `Buffer` que já existe ganha fatias mutáveis com dono
(`PsBufView.owner` já está lá, documentado exactamente para isto).

E o coletor ganha **finalizadores**, que é a maquinaria nova desta fase e a
condição para que um `bytes` não precise de ser fechado.

`len`, indexar, iterar, comparar e `str()` passam a valer nos dois.

**Fica de pé:** `b = bytes_of("olá"); h = b[0:2]` sem uma cópia, e o `gc-stress`
com um caso que abre e larga dez mil blocos.

---

## F1 — a I/O passa a falar bytes (135.2, 135.4)

`c.read_into(buf, off, n)`, `c.write_from(buf, off, n)`, e `readv`/`writev` para
quem tem várias fatias. `f.read_all()` e `R.fetch()` devolvem `bytes`.
`b.freeze()` entrega o bloco com zero cópia e invalida o buffer (18.2).

**O `c.read(n)` deixa de existir.** A travessia é pacote a pacote, cada um com o
seu commit e o `verify` verde, e os publicados sobem de versão — que o `0.x` da
F10 do pstudio destrancou:

| | quem migra |
|---|---|
| F1a | `tar` (16 sítios) |
| F1b | `sha2`, `ed25519` |
| F1c | `http`, `url` |
| F1d | `repo`, `pforge`, `pstudio`, e os testes de conformidade |

**Fica de pé:** um proxy que move um megabyte deixa de o copiar quatro vezes.

---

## F2 — o `Mapping` (137)

`os.mmap(path, mode)` devolve um `Mapping`: fecha com `with`, fatia-se em `bytes`
sem copiar, e tem as opções que o sistema dá — `advise`, `sync`, `lock`,
`populate`.

E o **guarda do SIGBUS**, que é a parte delicada: entrar no `with` grava um ponto
de retorno e a **profundidade da pilha-sombra**; o manipulador confirma que o
endereço é de um mapa nosso, desenrola até àquela profundidade e levanta — e
re-levanta o sinal se não for, para que um defeito a sério continue a matar.

Primeiro consumidor real: o `pforge` a hashear um tarball sem o trazer para a
memória.

**Fica de pé:** `with os.mmap(tar, "r") as m: sha256(m[:])`, e um teste que
**trunca o ficheiro debaixo do mapa** e exige a excepção em vez do cadáver.

---

## F3 — o `Mapping` em P, e a ponte (138)

`declare Mapping` / `implement Mapping`: o compilador materializa a struct onde
for pedido, com o mecanismo dos genéricos e não com um header que possa derivar.
O guarda não atravessa — em P vale a regra do C, e isso fica escrito.

A ponte é o `CBytes` que já existe: um `Mapping` e um `Buffer` atravessam para P
**sem cópia e sem fixação**, porque nenhum dos dois se move.

**Fica de pé:** uma função em P a ler um tarball mapeado pelo pscript, e o mesmo
`mmap` a servir os dois lados.

---

## F4 — o ficheiro que o `java.nio.file` tem e nós não (140)

`os.pread`/`os.pwrite` (posicional, sem `seek` — é o que torna o acesso
concorrente a partir de workers seguro), `os.stat` de uma vez em vez de seis
chamadas, e `os.listdir` a PERCORRER em vez de devolver a lista toda.

**Fica de pé:** um `pforge` que anda numa árvore grande sem construir a lista
inteira primeiro.

---

## F5 — `os.watch` (140)

Uma tarefa aguárdavel, como um socket: o descritor do inotify/kqueue entra no
mesmo `poll` do escalonador. Sem thread e sem sondagem.

Dois consumidores no dia seguinte: o `check_external` do editor deixa de sondar,
e o `pforge dev` — que o plano do PTY usou como justificação e que não existe —
passa a ser possível.

**Quatro coisas por decidir ANTES de escrever uma linha** (140.1): a recursão é
trabalho nosso e não do núcleo; o macOS não tem `inotify` e o `kqueue` não serve
(a resposta lá é o **FSEvents**, uma API diferente — é a maior distância entre
plataformas de todo o plano); coalescer ou entregar cru; e um evento de cada vez
ou um lote. O que já está decidido: o transbordo é um `OVERFLOW` explícito e
nunca um silêncio.

**Fica de pé:** o editor sabe que um ficheiro mudou sem perguntar.

---

## F6 — o descodificador incremental (140)

O que o `CharsetDecoder` do NIO é: alimentar bytes e receber o texto que já dá
para dizer, guardando o que ficou a meio de um codepoint.

Foi a peça que faltou de verdade: o widget de terminal da F8 do pstudio teve de
escrever a máquina de estados de UTF-8 à mão porque `str(b)` descodifica tudo e
levanta.

**Fica de pé:** o terminal deixa de ter o seu próprio descodificador, e o teste
dele que parte um codepoint em dois pedaços passa a medir o do runtime.

---

## O que NÃO está no plano

| não entra | porquê |
|---|---|
| o `Selector` | o escalonador já é isso, e melhor |
| `position`/`limit`/`flip` | o erro que o próprio Java foi corrigir |
| `mmap` de escrita | uma segunda história de durabilidade, e nada precisa dela ainda |
| `FileLock` | não há dois processos a disputar um ficheiro neste ecossistema |
| `sendfile` | vem de graça depois do `Mapping` + `writev` |
| UDP, sockets Unix | são sockets, não são NIO; fase própria quando alguém os pedir |
