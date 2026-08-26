# pscript — documento de decisões

Linguagem de script sobre o plang. **Nada aqui está decidido** até você decidir.

Como funciona: cada bateria tem perguntas numeradas. Cada pergunta traz as opções
com a **consequência** de cada uma — o que ela obriga, o que ela impede, o que
custa. Você responde por número (`1.1 b`). A resposta vira decisão registrada
neste arquivo, com data e motivo.

Ordem: as baterias vão do mais a montante para o mais a jusante. Responder a 1
muda quais opções da 5 ainda fazem sentido. Se uma pergunta estiver mal formulada
ou faltar opção, diga — a lista não é fechada.

---

## O que você já disse

Isto não são decisões minhas, são coisas que você afirmou. Ficam aqui para eu não
esquecer nem contrariar:

- **Você odeia `union`.** Nada de valor universal em união etiquetada.
- **Tipos primitivos podem continuar primitivos.**
- **PHP como exemplo** de referência: só um `array` e ainda tem escalares de
  verdade — reconhecendo que "não é uma implementação ideal", mas é um exemplo.
- **Gosta da ideia de um god object**, um container universal.
- **Levantou** que uma função dentro de um objeto poderia compilar só para um
  ponteiro de função boxeado.
- **libc é o runtime**: nunca abstrair. Exceção única, já existente, é
  `--inline-runtime` para chamadas que o compilador injeta.
- **Tuplas foram removidas do P a seu pedido** e não devem ser repropostas sem
  decisão explícita sua.

---

## DECISÕES FECHADAS

### Bateria 1 — Identidade (2026-07-29)

**1.1 Propósito.** Linguagem própria de **uso geral**, no espírito de Go, JS e
Python — mas **compilada**. Secundariamente serve para prototipar código que
depois vira P, e para scriptar o pstudio. **Não** é embutível num programa P
hospedeiro (isso foi descartado, e com ele o contrato de embutir).

**1.2 Público.** Só você. Quebrar a linguagem é permitido, sem migração nem
aviso.

**1.3 Relação com o P.** **Linguagem separada**: gramática e arquivos próprios,
compartilhando o compilador e os backends. O P não é alterado para acomodar o
pscript.

**1.4 A razão de existir.** Textualmente: *"vai ser uma cópia do Python
compilada e com tipos estáticos"*. E as quatro coisas que o P não tem:

1. Coleta de lixo
2. Fechamento com captura
3. `try`/`catch`
4. Lambda

**O que NÃO foi marcado como razão de existir**, e isso reorienta o projeto:
- **Não declarar tipo** não é o ponto — pscript tem **tipos estáticos**.
- **Objeto universal** não é o ponto. Continua interessando como recurso, mas
  não é o que justifica a linguagem, então não dita a arquitetura.

Consequência direta: pscript não é uma linguagem dinâmica. É uma linguagem
estática com superfície de Python e um runtime — e o runtime existe pelas quatro
coisas acima, não por dinamismo. Isso torna o projeto muito menor do que seria
uma reimplementação de Python.

### Bateria 2 — Tipagem (2026-07-29)

**2.1 Como o tipo aparece.** **Inferido, sem anotar.** `x = 1` deduz o tipo.
Anotar é opcional — para forçar largura ou documentar.

**2.2 Nomes dos primitivos.** **Os dois.** `int` é apelido de `i64`, `float` de
`f64`. Escreve-se Python no dia a dia; as larguras exatas (`i8`…`u64`, `f32`)
continuam disponíveis quando importam.

**2.3 Reatribuir com outro tipo.** **Erro, salvo quando anotado como universal.**
O primeiro valor fixa o tipo da variável. Existe um tipo que aceita qualquer
coisa, e uma variável declarada assim aceita os dois.

> É aqui que o objeto universal reentra: **não como base da linguagem, mas como
> opt-in explícito.** Entrar nele é implícito (qualquer valor cabe), sair exige
> dizer o que se espera. Sem isso o dinamismo vazaria para todo lado e o
> desempenho seria de Python em código que devia ser estático.

**2.4 Interop.** **`import` de `.ph` direto**: o pscript enxerga tipos e funções
de P como se fossem dele. Consequência assumida: o sistema de tipos do P é
visível dentro do pscript — não há tradução de fronteira.

### Bateria 3 — Dados (2026-07-29)

**3.1 Contêineres genéricos.** `list` escrito sem parâmetro **é** `List<any>`.
Para elemento desboxeado, anota-se: `List<int>`.
*(Esclarecido na 4.1: `x = [1, 2, 3]` sem anotação recebe `List<any>`.)*

**3.2 Tuplas.** **Existem, como tipo de primeira classe**: `a, b = f()`, retorno
múltiplo, desempacotamento, tupla guardada em variável.
Decisão vale **só para o pscript** — o P continua sem tuplas.

**3.3 Contêineres são tipos novos**, escritos para o pscript, já com cabeçalho de
GC e percurso de filhos. Não são o `Vec`/`Dict` da STL com GC por cima.
Consequência assumida: duas famílias de contêiner no repo — a manual (STL, para
P) e a coletada (pscript).

**3.4 String.** `s[3]` devolve o **quarto caractere**, como Python. Consequência:
indexar codepoint em UTF-8 é O(n), então a representação precisa resolver isso —
cache de posição ou largura fixa. Fica para a bateria de representação.

### Bateria 4 — Memória (2026-07-29)

**4.1 Inferência de contêiner (esclarece 3.1).** `x = [1, 2, 3]` sem anotação
recebe **`List<any>`** — encaixota por padrão. `List<int>` é o opt-in de
desempenho, escrito à mão.

> Divisão que fica: **escalar é estático e desboxeado; contêiner é universal por
> padrão.** Escreve-se Python e funciona; quando a memória importa, anota-se.

**4.2 Modelo de coleta.** **Rastreamento (mark-sweep).** Coleta ciclo sem esforço
extra, que é o caso normal num objeto com referência ao pai. Assume-se que a
liberação não acontece no ponto onde o objeto morreu.

**4.3 Descoberta de raízes.** **Shadow stack explícita**: o compilador emite, por
função, o registro dos valores coletados que ela segura. Portátil e igual nos dois
backends. Descartados: varredura conservadora (precisa de limites de pilha por
plataforma, e briga com "libc é o runtime") e mapa preciso (teria que ser feito
duas vezes, uma por backend).

**4.4 Liberação determinística de recurso.** **`with`, baixando para o `defer`
que o P já tem.** Fecha na saída do bloco, independente do coletor.
**Sem `__del__`** — nem como rede de segurança. Recurso fora de um `with` não tem
garantia de fechamento, e isso é aceito.

### Bateria 5 — Erros, classes, fechamento (2026-07-29)

**5.1 Modelo de erro.** **Um tipo de erro só.** `try` / `catch e:` pega tudo; `e`
carrega mensagem e possivelmente um código. Sem hierarquia, sem herança, sem
identidade de tipo em runtime. Filtrar por categoria fica com o usuário.

**5.2 Chave ausente / índice fora.** **Lança erro.** `d.get(k, default)` é o
caminho que não lança.

**5.3 `class` não existe.** Só função e agregado. Comportamento é função que
recebe o objeto. Os `struct` com método que o P já tem cobrem o caso comum, e o
pscript os enxerga via `import` de `.ph` (2.4).

> Consequências: não há método definido pelo usuário sobre `any`, não há
> `__getattr__`, não há tabela de chaves compartilhada por classe — e portanto o
> saco não tem como virar registro barato por essa via. Registro com campos
> nomeados vem de `struct` de P.

**5.4 Fechamento com captura: DESCARTADO.** Textualmente: *"desisti, não preciso
desse recurso"*. Uma função aninhada não enxerga variável local da função de
fora.

> Isso remove um dos quatro itens da 1.4, e é a maior simplificação até agora:
> sem captura não há célula, não há objeto de ambiente, não há passada de
> promoção de local capturado (a `analyze_cells` do CPython), e desaparece a
> segunda maior fonte de ciclo para o coletor.
>
> **Mas muda o que "lambda" quer dizer.** Uma lambda que não captura é uma função
> anônima que vê só os próprios parâmetros e os globais — ou seja, um ponteiro de
> função, sem ambiente. Continua útil para callback; deixa de ser o recurso que
> normalmente se entende por lambda. Ver bateria seguinte.

### Bateria 6 — Lambda e forma do programa (2026-07-29)

**6.1 Lambda continua, sem ambiente.** Vê os próprios parâmetros e os globais, e
nada mais. É um ponteiro de função anônimo — serve para callback
(`sort(xs, lambda a, b: a < b)`), custa zero de runtime, não precisa de objeto de
ambiente nem de passada de promoção.

**6.2 Hello world é código solto no arquivo.** `print("oi")` no topo executa de
cima para baixo; o compilador embrulha num `main` implícito.

**6.3 Execução: compilado, mais um comando que roda.** `pscript x.ps -o bin` e
também `pscript run x.ps`, que compila num temporário e executa — conveniência de
script, ainda AOT. Implica **cache de compilação**, senão `run` fica lento.
Interpretador e REPL ficam de fora (e `eval` contradiria os tipos estáticos).

**6.4 Sintaxe por indentação, reusando o lexer do P.** Mesmo INDENT/DEDENT.

### Bateria 7 — Representação e semântica (2026-07-29)

**7.1 String: largura adaptativa**, como o CPython (PEP 393): 1 byte se todo
caractere couber em latin-1, 2 se couber em 16 bits, senão 4. `s[i]` é O(1) e
texto ASCII não desperdiça. Custo assumido: todo código de string tem três
caminhos.

**7.2 Estouro de inteiro lança erro.** Não dá a volta. Implementável sobre os
builtins de overflow do compilador C, que são baratos. Bignum descartado — desfaria
escalar desboxeado (4.1) e o apelido `int` = `i64`.

**7.3 `1 + "2"` é erro.** Sem coerção implícita entre número e string.

**7.4 Módulos: reusa o do P.** `import` e `include <h>` com a mesma semântica. O
interop com P (2.4) sai de graça.

### Bateria 8 — Escopo e implementação (2026-07-29)

**8.1 Açúcar no v0.1:** f-strings, comprehensions, decoradores e `set` — todos os
quatro entram.

> Observação sobre decorador: sem captura (5.4), um decorador não pode embrulhar a
> função num fechamento. Então `@memo` não consegue guardar cache por função a não
> ser via global. Vale rever o que decorador significa aqui.

**8.2 Onde vive:** `pscript/` no mesmo repo, ao lado de `selfhost/`, `stl/` e
`pstudio/`. Compartilha a bateria de verificação e o seed.

**8.3 Marco do v0.1:** **o pstudio reescrito em pscript.**

> Isso é muito maior que as opções que eu havia oferecido, e tem uma consequência
> que reorganiza tudo: **pstudio é interop com SDL2 do começo ao fim.** O v0.1
> passa a exigir interop pesado com C desde o primeiro dia — e é por isso que a
> discussão de segurança abaixo deixa de ser teórica.
> Também exige revisitar 5.3 (sem `class`): o pstudio de hoje é `struct` com
> método por toda parte. Via `import` de `.ph` isso continua disponível, mas então
> boa parte do pstudio em pscript seria escrita em tipos de P.

**8.4 Verificação:** suíte de programas `.ps` com saída esperada (como
`tests/cases/`) **mais** testes específicos de coletor: ciclo que precisa liberar,
laço com teto de memória, contagem de objetos vivos.

---

### Bateria 9 — Segurança: eixos e fronteira (2026-07-29)

**9.1 Os quatro eixos são para garantir**, todos:
- deref de nulo impossível
- uso após liberação
- cast não reinterpreta bits
- nada não-inicializado

Somados aos dois já decididos antes sem a palavra "segurança" aparecer (índice
fora e chave ausente lançam — 5.2; estouro de inteiro lança — 7.2), isso é um
compromisso de **segurança de memória de verdade**, não "mais seguro que C".

**9.2 Onde a insegurança mora: em P.** Sem construir uma segunda linguagem
insegura dentro do pscript. Bindings, envelopes e o que abre ponteiro vivem em
`.p`/`.ph`.

**9.3 Emenda à 2.4 — opção (i).** pscript importa qualquer `.ph` livremente, e
**ponteiro cru é tipo restrito**: circula, guarda-se, passa-se adiante como handle
opaco. A parede fica no *uso*, não na importação.

**9.4 Anulável `T?`, com não-nulo por padrão**, e **toda travessia de C devolve
`T?`**. `fopen` dá `*FILE?` e não se toca antes de testar. Mata a classe de deref
de nulo na fronteira exata onde ela nasce, com custo de runtime zero.

### Bateria 10 — Segurança: GC × C (2026-07-29)

**10.1 Deref de `*T` em pscript é possível, com uma palavra que marca.**

> Revisa parcialmente a 9.2: P continua sendo a camada insegura (é onde vivem
> bindings e envelopes), **e** o pscript tem um marcador para os casos em que se
> abre o ponteiro direto, sem escrever envelope. O nome é `unsafe` (11.1), ele
> libera quatro coisas (12.1) e aparece como bloco ou na assinatura (12.2).

**10.2 Objeto coletado NÃO atravessa para C.** Só tipo de C atravessa. Elimina de
vez a classe de bug mais difícil de achar (C guardando a única referência a um
objeto que o coletor então libera).

**10.3 Callback de C só pode ser função de P.** A fronteira de entrada fica em
código escrito à mão, não num trampolim gerado, e a shadow stack não precisa de
disciplina de reentrada.

**10.4 O coletor fica livre para virar movedor/compactador depois.** Não há
contrato de não-mover.

> **As três últimas se sustentam mutuamente, e é por isso que o desenho fecha:**
> se o coletor pode mover, nenhum ponteiro de objeto coletado pode atravessar
> (10.2 segue de 10.4); e se nada coletado atravessa, o callback — que precisa de
> `userdata` — tem que morar em P (10.3 segue de 10.2). O mundo do pscript é
> fechado; a ponte é o P.
>
> **Consequência para o marco do v0.1 (8.3).** "pstudio reescrito em pscript"
> passa a significar: **a lógica do editor em pscript, a camada SDL em P.** O loop
> de evento, os callbacks e o `userdata` ficam em P; buffer de texto, undo,
> command palette, autocomplete vão para pscript. Isso é uma divisão sã — e é bom
> que tenha aparecido antes de escrever a primeira linha.

### Bateria 11 — Segurança: a palavra e as checagens (2026-07-29)

**11.1 A palavra é `unsafe`.** O nome que se reconhece sem explicação.

**11.2 `unsafe` libera** deref de ponteiro cru (`*p`, `p->campo`) e aritmética de
ponteiro (`p + 1`, `p[i]` sem limite conhecido).

> **Corrigido pela 12.1:** cast entre tipos de ponteiro e chamada variádica também
> ficam dentro de `unsafe` — eu havia lido a resposta original como "proibidos
> sempre", e não era isso. Então `printf` É escrevível em pscript, dentro de
> `unsafe`; f-string (8.1) continua sendo o caminho normal, porque é açúcar de
> compilação e não precisa de argumento variável nenhum.

**11.3 Sair de `any` é checado em tempo de execução, e falhar lança erro.**
`int(x)` sobre um `any` que guarda string lança. Custa um compare de etiqueta.
Sem isso `any` seria furo de segurança de tipo sem ponteiro nenhum envolvido.

**11.4 Não-inicializado: reusa o `out` do P.** O trio `out`/`ref`/`in` já existe
e a sema **já rastreia** inicialização por ele. Um binding declara `out sb` e o
compilador aceita `stat(path, out sb)` sem exigir zeragem. Zero mecanismo novo.

### Bateria 12 — Granularidade e política de falha (2026-07-29)

**12.1 `unsafe` gateia as quatro coisas** — deref, aritmética de ponteiro, cast
entre tipos de ponteiro, e chamada variádica. (Corrige a leitura de 11.2: não são
proibidos sempre, são gateados.) Então `printf` é escrevível em pscript, dentro de
`unsafe`; f-string continua sendo o caminho normal.

**12.2 `unsafe` aparece nos dois lugares:** como bloco (`unsafe:` indentado, para
região mínima) e na assinatura (`unsafe def f()`, quando a função inteira é ponte,
com propagação automática — chamar de função segura é erro).

**12.3 Modo `--safe`: sim, mas depois do v0.1.** Barato como flag; o custo real é
a stdlib curada que um plugin precisa para conseguir fazer algo.

**12.4 Política de falha — a fronteira C/pscript é a fronteira crash/exceção.**
Ideia sua, textualmente: *"tudo o que é em C geraria um erro e um crash, em pscript
geraria uma exceção tratável e debugável"*.

- Falha em código pscript → **exceção capturável** (`try`/`catch`), com posição e
  pilha.
- Falha em C / dentro de `unsafe` → **crash**, sem pretensão de recuperar.

> Isso é consequência dos quatro eixos (9.1), não um mecanismo novo: se pscript
> não pode corromper memória, toda falha dele é *definida* e portanto lançável; e
> falha em C é *indefinida* e portanto não recuperável. Capturar `SIGSEGV` e
> continuar significaria seguir com estado corrompido — Java e C# só conseguem
> fingir que dá porque não têm C na jogada.
>
> **Crash e debugável não são opostos.** Um handler de `SIGSEGV`/`SIGBUS`/`SIGFPE`
> lê a **shadow stack** e imprime a pilha de pscript antes de morrer. Não captura,
> mas diz onde.
>
> **E essa é a terceira conta que a shadow stack paga:** raízes do coletor,
> desenrolamento de erro (`try`/`catch` percorre os frames executando `defer`), e
> pilha post-mortem no crash. Um mecanismo, três problemas — vale registrar porque
> justifica sozinho o custo de push/pop por função.

### Bateria 13 — Classificação de ponteiro e travessia de string (2026-07-29)

**13.1 Quem classifica: o envelope em P, à mão.** Você escreve
`def criar_janela(...) -> Janela` em P e decide ali o que devolver. Sem
mini-sistema de anotação no binding, sem regra automática por forma do tipo.
Custo assumido: uma linha sua por API de C — no caso do pstudio, ~40 funções do
SDL2.

**13.2 Caixa opaca é comparável por identidade.** `a == b` compara o ponteiro por
baixo, e serve como chave de dict pelo endereço — então `dict[janela] = estado`
funciona, que é idioma comum. Não imprime endereço.

**13.3 `char *` de C para `str` de pscript: copia sempre.** A `str` é dona dos
bytes e o coletor manda nela. Sem vista sem cópia, nem para literal imortal.

**13.4 `str` guarda tamanho E termina em NUL de cortesia.** String inteira
atravessa para C de graça; fatia (`s[2:5]`) continua precisando de cópia na
travessia, porque o NUL do fim não é o fim da fatia.

> **Colisão a resolver, entre 7.1 e 13.4.** A representação é de largura
> adaptativa (1 byte se latin-1 couber, 2 se UCS-2, senão 4). Só que:
>
> - Numa string de 1 byte, os bytes são **latin-1, não UTF-8**. Entregar isso a C
>   como `char *` está certo só para ASCII puro; `"café"` sairia errado.
> - Numa string de 2 ou 4 bytes, não existe `char *` nenhum para entregar.
>
> Ou seja, "NUL de cortesia" só compra travessia grátis para ASCII. O CPython tem
> exatamente esse problema e resolve guardando **uma representação UTF-8 em cache
> no próprio objeto**, preenchida na primeira travessia. Precisa de decisão — está
> na bateria seguinte.

### Bateria 14 — Runtime: string, coletor, alocador (2026-07-29)

**14.1 Travessia de string: cache de UTF-8 no objeto.** Além da forma nativa
(largura adaptativa, 7.1), o objeto guarda uma representação UTF-8 preenchida na
primeira travessia e reaproveitada depois — como o CPython. Custa um ponteiro por
string e memória dobrada nas que atravessam; travessia em laço deixa de ser caro.

**14.2 Gatilho do coletor: os dois limites, e nenhum pode exceder.** Analisa
**bytes alocados** *e* **número de objetos** desde a última coleta; qualquer um dos
dois passando do limite configurado dispara. Cobre tanto o programa que aloca uma
lista gigante quanto o que aloca um milhão de caixinhas.

**14.3 Alocador: arena com bump allocator.** Alocar é incrementar um ponteiro.

> **Tensão a resolver.** Bump allocation e mark-sweep não compõem bem: o ganho do
> bump é justamente nunca liberar individualmente, e o sweep produz buracos que
> precisam ser reusados. Os pares naturais são *bump + coletor que copia/compacta*
> ou *malloc/freelist + mark-sweep*.
> Como você deixou o coletor livre para virar movedor (10.4), bump + cópia é
> coerente como destino — mas falta dizer o que o v0.1 faz com os buracos do sweep.
> Está na bateria seguinte.

**14.4 Não existe objeto imortal, porque não existem esses objetos.** Correção sua,
e ela desfaz uma suposição que eu tinha importado do Python:

- **`bool` é primitivo.** `True`/`False` são valores, não objetos no heap. Não há
  singleton a imortalizar.
- **`None` não é um valor universal.** Só faz sentido como o caso vazio de um tipo
  opcional/anulável — que é exatamente o `T?` da 9.4.
- **Escalar não precisa de GC**, período. Isso já estava na 4.1 (escalar estático e
  desboxeado) e eu não tinha levado às últimas consequências.

> Consequência que segue: `None` em pscript é o estado vazio de `T?`, no modelo de
> Kotlin/Swift, **não** um objeto singleton no modelo de Python. E aí a
> nulabilidade **compõe** com o universal (`any?`) em vez de o universal conter um
> objeto None. Mais limpo, e cai fora do coletor inteiramente.

### Bateria 15 — Coletor copiador, exceção, cache (2026-07-29)

**15.1 Coletor copiador desde o v0.1.** Marca os vivos e **copia** para arena nova;
a antiga volta livre inteira. Resolve a tensão da 14.3: o bump allocator funciona
perfeito e não existe buraco para reusar. Permitido porque a 10.2 já proíbe objeto
coletado de atravessar para C, e a 10.4 deixou o coletor livre para mover.

> **O que "copiador" cobra, e precisa de resposta (bateria seguinte):**
>
> 1. **A shadow stack passa a guardar ENDEREÇO DE SLOT, não valor.** O coletor
>    reescreve os ponteiros, então precisa de `**Val` (onde a variável está) e não
>    de `*Val` (o que ela vale). Muda o desenho da shadow stack — e é melhor
>    descobrir agora que depois de emiti-la.
> 2. **`unsafe` × mover.** Dentro de `unsafe`, código pscript pode pegar ponteiro
>    para dentro de um objeto coletado (o array de trás de uma `list`). Uma coleta
>    naquele intervalo invalida o ponteiro. A 10.2 protege a fronteira com C, não
>    esse caso interno.
> 3. **Ponteiro interior em geral.** `xs[2:5]` sobre uma `list` de pscript: cópia,
>    ou vista? Vista com ponteiro cru é ponteiro interior num objeto que se move.
> 4. O cache de UTF-8 (14.1) é uma segunda alocação pendurada na string — o
>    copiador tem que mover as duas e manter o vínculo.

**15.2 A exceção tem um tipo só, com metadados de tudo:**
- mensagem
- **código de categoria** (inteiro/enum: índice, chave, tipo, io…) — nas suas
  palavras, *"ela só tem 1 tipo, mas tem metadados pra tudo, por isso o
  inteiro/enum é importante"*. É o que permite filtrar sem comparar texto.
- posição no fonte (arquivo, linha, coluna)
- pilha de pscript, lida da shadow stack

**15.3 `pscript run`: cache por arquivo, em disco.** Guarda o C/objeto por hash do
fonte; recompila só o que mudou. Assume-se o custo de manter um mini sistema de
build.

**15.4 Respondida na 17.4** (`async` entra; gerador, sobrecarga de operador e
pattern matching ficam fora). Pergunta original: geradores (`yield`), `async`/`await`, sobrecarga de
operador e pattern matching estrutural entram ou ficam fora do v0.1.

### Bateria 16 — Toolchain e distribuição (2026-07-29)

**16.1 Linker próprio: NÃO no v0.1.** Suas palavras: *"era integrar a stack própria
aqui, porém deixamos para o futuro"*. Fica registrado como **objetivo futuro
declarado** — "não depender de `cc` instalado" — e não como consequência acidental
do cache. O caminho para lá existe: backend QBE já emite assembly, faltariam
assembler e linker.

> Por que não agora: o custo do `run` não é linkar (`ld` com uma dúzia de objetos é
> ~10ms), é **invocar `cc` por arquivo** (50–200ms cada). Linker próprio otimizaria
> a parte que já é rápida. E linkar contra `.so`/`.dylib` — resolver símbolo,
> `rpath`, ordem de biblioteca — é justamente o que faz `lld` e `mold` serem
> projetos grandes.

**16.2 Velocidade do `run`: cache de `.o` por arquivo.** `cc -c` no que mudou,
relinka o resto.

**16.3 Biblioteca do sistema: `cc` resolve, como hoje.** `pkg-config --libs` e o
`cc` cuida do resto, incluindo `rpath` no macOS.

**16.4 O runtime do pscript é fonte P compilado junto.** Coletor, tipos, string:
tudo `.p`/`.ph` entrando na compilação como qualquer módulo. Sem `libpscript.a`,
sem `.so`, nada a instalar ou versionar em separado — coerente com o princípio do
plang de que o programa é o C que ele vira.

### Bateria 17 — Consequências do coletor copiador, e escopo (2026-07-29)

**17.1 A shadow stack guarda endereço de slot (`**Val`).** Registra *onde* a
variável está, para o coletor reescrever o ponteiro depois de copiar.

> Consequência para a geração de código: **variável coletada precisa de endereço
> estável** — não pode viver só em registrador. Na prática, tomar o endereço dela
> já força o compilador C a colocá-la na pilha. Vale saber antes de emitir.

**17.2 Dentro de `unsafe`, é proibido apontar para dentro de objeto coletado.**
`unsafe` só abre ponteiro que veio de C; pegar o endereço do interior de uma `list`
é erro de compilação.

> Mantém a regra pura e fecha, de tabela, a porta de passar buffer de pscript para
> C — reforçando a 10.2 em vez de abrir exceção. E dispensa mecanismo de pin.

**17.3 `xs[2:5]` é cópia.** Nenhum ponteiro interior existe no sistema, o que
elimina a parte mais difícil de um coletor copiador. Fatiar em laço aloca — é o que
Python faz.

**17.4 Escopo do v0.1 — `async`/`await` ENTRA.** Ficam de fora: geradores
(`yield`), sobrecarga de operador, pattern matching estrutural.

> **Isto é o item mais caro já selecionado, e vale dizer o porquê antes de
> começar.** Normalmente `async` se constrói *sobre* gerador/corrotina; sem
> gerador, ele precisa de transformação própria para máquina de estados. Três
> consequências:
>
> 1. **Transformação de máquina de estados própria**: os locais da função async
>    viram campos de um frame, e cada `await` é um ponto de retomada.
> 2. **Esse frame vive no heap e o coletor tem que percorrê-lo** — ele segura
>    referências coletadas e não está na pilha, então a shadow stack não o cobre.
>    Precisa ser objeto rastreado como qualquer outro.
> 3. **Precisa de escalonador**, e para o pstudio ele tem que cooperar com o loop
>    do SDL (`SDL_WaitEvent`), não competir com ele.
>
> Curiosidade: erguer locais para um frame no heap é quase exatamente a passada que
> fechamento por célula exigiria — e essa foi descartada na 5.4 como "não preciso
> desse recurso". Vale checar se, tendo a máquina de `async`, o fechamento sai
> quase de graça.

### Bateria 18 — Concorrência e event loop (2026-07-29)

**Ponto de partida seu:** pscript é de uso geral e autônoma, então **não pode
depender do SDL** nem ser modelada em torno dele. E libuv foi considerada e
descartada — *"depois descobri que ela mais vai complicar do que ajudar"*.

> Consistente com uma decisão que você já havia tomado: `pstudio/DESIGN.md:20` —
> *"Sem libuv: o loop do SDL é o único loop. Operações lentas vão a um mini
> work-queue em P (~300 linhas, pthreads) e voltam via SDL_PushEvent (semântica de
> completions)."* Aquele work-queue **é** o event loop; falta generalizar.
>
> E libuv briga com três coisas já decididas: traz loop próprio que quer ser dono
> da thread; todo callback dela seria entrada C→pscript, que a 10.3 restringe a
> função de P; e é dependência grande fora da libc, contra o princípio de que
> **libc é o runtime**.

**18.1 Modelo de concorrência: single-thread com workers isolados, estilo Web
Worker.** Cada worker tem **heap e coletor próprios**. Nada de memória
compartilhada, exceto uma estrutura desenhada para isso (18.3).

> É o encaixe ideal para o coletor copiador (15.1): cada heap coleta sozinho, sem
> coordenação entre threads, sem barreira de escrita, sem parada global. É a mesma
> razão pela qual funciona em JS e em Erlang.

**18.2 Mensagem: cópia profunda + transferência.** O padrão copia o grafo (com
guarda de ciclo); para buffer grande, `transfer` move a posse e invalida a
referência de quem enviou — zero cópia.

> A cópia profunda é a **quarta conta** que o percurso de filhos paga: o coletor já
> sabe andar no grafo de um objeto, e clonar entre heaps é o mesmo caminho.

**18.3 Buffer compartilhado: bytes + vistas tipadas.** Alocado **fora** dos heaps
coletados; o mesmo buffer é visto como `List<i32>` ou `List<f64>` sem cópia, com
operações atômicas para coordenar. Nunca contém referência a objeto.

> Correção de uma objeção que eu havia levantado: isso **não** contradiz a 17.3
> ("fatia é cópia"). A 17.3 trata de fatia de contêiner *coletado*, que se move; o
> buffer compartilhado é memória que nunca se move, então uma vista sobre ele não é
> ponteiro interior em objeto móvel. Sem conflito.
>
> O que sustenta o isolamento é ele conter **bytes, não referências**: se pudesse
> guardar objeto, haveria ponteiro cruzando heaps e o modelo cairia.

**18.4 Multiplexação de I/O: `epoll` no Linux e `kqueue` no macOS, desde o v0.1.**
Não `poll()` como paliativo.

> Consequência assumida: dois back-ends de I/O a escrever antes do hello world. Em
> troca, o loop é I/O-first de verdade e escala para milhares de descritores — o que
> é coerente com "linguagem autônoma de uso geral" e não com "loop de programa
> gráfico".

**18.5 O loop do pscript é a base; SDL entra como fonte.** Correção sua, contra o
enquadramento que eu havia feito: modelar a integração como "SDL é dono e bombeia o
pscript" seria fazer a linguagem no formato do SDL. Inverte-se — o loop do pscript
é dono, e SDL é mais uma fonte de evento dentro dele.

> **A restrição real dessa inversão.** No macOS, evento de Cocoa tem que ser
> bombeado na **thread principal**, e o SDL não expõe descritor que se possa
> esperar em `epoll`/`kqueue`. Então a forma que funciona: o loop do pscript é dono
> e roda na thread principal, e quando existe janela o timeout da espera fica
> limitado ao intervalo de quadro, com `SDL_PollEvent` a cada volta — o que um
> programa gráfico faz de qualquer jeito. Sem janela, o loop bloqueia normalmente.
>
> Isso inverte `pstudio/DESIGN.md:20`, e a inversão precisa ser registrada lá
> quando o pstudio migrar para pscript.

### Bateria 19 — Contradições encontradas ao imaginar o conjunto (2026-07-29)

Método, nas suas palavras: *"vamos decidindo e resolvendo as contradições; só
descobrimos elas ao imaginar como um todo"*. Varredura sobre as ~120 decisões.

**19.0 Duas resolvidas sem precisar de decisão:**

- **NUL de cortesia (13.4) pertence ao cache de UTF-8 (14.1)**, não à forma nativa.
  É o cache que C recebe, então a largura adaptativa (latin-1/UCS-2/UCS-4) deixa de
  ser problema na travessia.
- **`epoll`/`kqueue` (18.4) não briga com "libc é o runtime"** — são APIs de sistema
  operacional, não biblioteca de terceiro. Mas fixam pscript em **Linux + macOS**
  até alguém escrever o caminho de IOCP para Windows.

**19.1 A maior colisão, e a saída.** O marco do v0.1 é o pstudio (8.3); o pstudio é
`struct` com campo nomeado por toda parte; e pscript aparentemente não tinha como
declarar isso (5.3 tirou `class`, `struct` de P é memória manual, `dict` não tem
tipo nos campos).

**Resposta sua: a `struct` do pscript é um SUPERSET da `struct` do P.** Mesma
sintaxe, mesmos campos, mesmos métodos — mais:
- ciclo de vida gerenciado pelo coletor (sem `init`/`deinit`)
- campos podem guardar referência coletada, e o compilador **gera a função de
  percurso** a partir dos tipos dos campos, sem anotação nenhuma

> E isso esclarece retroativamente a 5.3: **`struct` de P já tem método** (`StrMap`
> tem `put`, `get`, `rehash`). Então "sem `class`" nunca quis dizer "sem tipo de
> campos nomeados" — quis dizer sem sistema de classe com herança, MRO e metaclasse.
> O modelo de dados do pstudio transfere quase literalmente.

**19.2 Fechamento volta, por valor.** Revisa a 5.4 (que o havia descartado) e a 6.1
(que dizia lambda sem ambiente). A lambda copia o valor do local no momento em que é
criada.

> Motivo pelo qual mudou: `async` (17.4) já obriga a erguer locais para um frame no
> heap, e captura por valor é uma fração dessa máquina. Sem ela,
> `xs.map(lambda a: a * fator)` não funciona — idioma que apareceria no primeiro dia.
> Por valor e não por referência: não dá contador compartilhado, mas dispensa célula
> e dispensa a passada de promoção.

**19.3 Exceção atravessando `await`: guardada na task, relançada no `await`.** A task
carrega o erro (com mensagem, categoria, posição e pilha da 15.2) e o `await` o
relança no chamador como se tivesse acontecido ali. Mantém `try`/`catch` em volta de
`await` funcionando como se fosse síncrono, que é o que Python e JS fazem.

**19.4 Buffer compartilhado: fechamento explícito.** `with buffer(n) as b:` ou
`b.close()`, coerente com a 4.4 (recurso determinístico via `with`). Sem refcount
entre heaps. Assume-se: buffer fora de um `with` vaza, e fechar enquanto outro worker
usa é erro de execução.

### Bateria 20 — Struct, record e travessia (2026-07-29)

**20.1 A distinção é pela ORIGEM, sem palavra nova.**
- `struct` declarada num fonte pscript → **coletada**, campos podem guardar
  referência, o compilador gera a função de percurso a partir dos tipos.
- `struct` importada de um `.ph` de P → **manual**, layout de C, não guarda
  referência coletada.

A mesma construção significa duas coisas conforme onde está declarada.

**20.2 Struct coletada não atravessa para P/C. `record` atravessa.**

Terceiro tipo, introduzido por você aqui. Leitura (pendente de confirmação na
bateria seguinte, porque a frase original era ambígua): **um `record` só tem campos
de tipo primitivo/básico — e é exatamente isso que o torna legível e COPIÁVEL para
P/C.**

| Construção | Coletada? | Guarda referência? | Atravessa para P/C? |
|---|---|---|---|
| `struct` de pscript | sim | sim | **não** (10.2) |
| `record` de pscript | sim (21.2) | não (só primitivos, 21.1) | **sim, por cópia** |
| `struct` importada de P | não | não | sim |

> Por que isso fecha: o que impedia a travessia era o coletor mover o objeto e
> haver referência dentro dele. Um agregado de puros primitivos não tem referência a
> rastrear e é copiado na travessia em vez de emprestado — então nada se move
> debaixo de ninguém, e a 10.2 continua intacta.

**20.3 Lambda: duas formas, o compilador escolhe.** Sem captura, ponteiro puro e
zero alocação (o que a 6.1 prometia); com captura por valor (19.2), ponteiro +
ambiente coletado. O usuário não vê diferença.

**20.4 Genéricos em struct coletada: sim, como no P.** Reusa a monomorfização por
instanciação que o P já tem. Encaixa bem com o coletor: a função de percurso é
gerada **por instância**, com os tipos concretos já resolvidos — que é exatamente o
que o coletor precisa. E o mecanismo vai existir de qualquer forma, porque
`List<int>` (4.1) já é genérico.

### Bateria 21 — `record` fechado (2026-07-29)

**21.1 `record` contém só primitivos e outros records.** `int`, `float`, `bool`,
larguras fixas, e records aninhados. Nada de `str`, `list`, `dict` ou `struct`
coletada.

**21.2 `record` é objeto coletado, copiado na travessia.** Vive no heap com
cabeçalho; atribuição compartilha a referência (semântica de referência, uniforme
com o resto do pscript); só a passagem para P/C faz cópia.

> Consequência de implementação: como ele tem cabeçalho, o **layout não é
> compatível com C**. Então "copiado para P/C" é *marshalling campo a campo*
> gerado pelo compilador, não um `memcpy`. É código gerado real, e é barato porque
> 21.1 garante que só há escalares.

**21.3 `record` não tem método**, só campos. Comportamento é função que recebe —
mantém a distinção com `struct` (que tem método, 20.1) nítida.

**21.4 Aninhamento numa direção só:** `struct` coletada pode ter campo de `record`;
`record` nunca contém `struct`. É essa assimetria que preserva a travessia — um
record jamais aponta para coletado, então nunca há referência a rastrear dentro dele.

### Bateria 22 — segunda varredura de contradições (2026-07-29)

**22.1 Travessia de `record`: ida-e-volta quando marcado `out`/`ref`.** O trio do P
decide — `in` só copia para dentro, `out`/`ref` copiam de volta ao retornar. Faz
`stat(path, out sb)` funcionar, e reusa mecanismo que já existe (11.4). O compilador
gera as duas cópias.

**22.2 `==` compara conteúdo; `is` compara identidade.** Vale para `list`, `dict`,
`struct` e `record`. Coerente com o `==` de conteúdo que o P já tem para string.
Exige comparação recursiva **com guarda de ciclo** — e ciclo é caso normal aqui
(`o.pai`).

**22.3 Um event loop por worker.** Cada worker tem heap, coletor **e** loop próprios,
com seu próprio `epoll`/`kqueue`. Isolamento completo. Consequência: um descritor de
arquivo pertence ao loop que o abriu, e um worker consegue fazer `await` de I/O.

**22.4 Erro não capturado numa task mata só a task.** Ela guarda o erro (19.3) e
morre; quem der `await` o recebe. Se ninguém der `await`, o runtime reporta na saída
("unhandled rejection"), como JS e Python.

### Bateria 23 — Coletor, sintaxe de `any`, e reabertura da 4.3 (2026-07-29)

**23.1 Coletor copiador: semiespaço (Cheney).** Duas metades; copia os vivos de uma
para a outra e troca. ~50 linhas, o algoritmo mais simples que existe. Custo
assumido: reserva 2x o endereçamento do heap vivo. Geracional fica para quando
medir — e a barreira de escrita entra só se pagar por si.

**23.2 Sair de `any` se escreve `int(x)`**, na forma de cast do Python. Assumido: o
mesmo texto significa "converta" (de `str` para `int`) e "desencaixote checando", que
são operações diferentes com a mesma cara.

**23.3 Este documento vive em `pscript/DESIGN.md`**, ao lado do de pstudio.

**23.4 A 4.3 (chave só int/str) está REABERTA.** Suas palavras: *"devemos ter nosso
próprio dict… se for um tipo `any`? qualquer coisa hasheável serviria"*.

O que muda: o dict é tipado, então a chave tem tipo estático — `Dict<int, V>`,
`Dict<str, V>`, `Dict<Ponto, V>`. A pergunta deixa de ser "quais tipos a linguagem
permite" e passa a ser **"o que torna um tipo hasheável"**, e no caso de
`Dict<any, V>` o despacho é pela etiqueta em runtime.

Candidatos, e o que cada um custa:

| Tipo | Hash derivável sem protocolo? | Problema |
|---|---|---|
| primitivo | sim, pelos bits | nenhum |
| `str` | sim, por conteúdo | nenhum |
| `record` | **sim** — 21.1 garante só escalares dentro | nenhum |
| `tuple` de hasheáveis | sim, recursivo | nenhum |
| `struct` coletada | por conteúdo, recursivo | **é mutável**: o hash muda depois de inserida |
| `list`/`dict`/`set` | idem | idem |

> **E uma colisão técnica de verdade: coletor copiador × hash por identidade.**
> Hash por endereço é o que Python usa para objeto mutável — e funciona lá porque o
> CPython **nunca move**. Com semiespaço (23.1) o endereço muda em cada coleta, então
> hash por endereço quebra a tabela.
>
> Se `struct` como chave for desejado, o cabeçalho precisa de **id estável** —
> uma palavra por objeto, ou atribuída de forma preguiçosa na primeira vez que se
> pede o hash. É custo real e é a decisão que a bateria seguinte precisa fechar.
>
> (A caixa opaca de C, 13.2, não tem esse problema: ponteiro de C não se move.)

### Bateria 24 — Chave de dict, e a contradição hash × igualdade (2026-07-29)

**24.1 Não existe tipo não-hasseável.** Sua formulação: *"todo tipo ou tem uma
identidade por instância, ou pode ser copiado e hasheado, no caso de primitivos e
pequenos"*. Então:
- primitivo, `str`, `record`, `tuple` de hasseáveis → hash por **conteúdo**, derivado
  pelo compilador a partir dos campos, sem protocolo
- `struct`, `list`, `dict`, `set` → hash pela **identidade** da instância

E `Dict<any, V>` nunca falha na inserção, porque não há chave inválida.

**24.2 Id estável: campo no cabeçalho, sempre.** Todo objeto nasce com id. Necessário
porque o semiespaço (23.1) muda o endereço em cada coleta, então identidade não pode
ser o endereço.

> Cabeçalho vira `{ty, gc, id}` — três palavras. E o Cheney precisa de um slot para o
> *forwarding pointer* durante a coleta; o truque clássico é sobrescrever um campo
> existente (o `ty`) enquanto a cópia acontece, então não custa uma quarta palavra.

**24.3 `tuple` é chave** quando seus elementos são hasseáveis. Cobre
`d[(linha, coluna)]`, que é idioma comum.

### Bateria 25 — Contradição resolvida, e o que ela reorganizou (2026-07-29)

**25.1 Agregado mutável NÃO é chave.** Resolve a 24.4 pelo caminho do Python, e pelo
motivo exato pelo qual o Python o faz. Revisa a 24.1.

Chave é: primitivo, `str`, `record`, `tuple` de hasseáveis — **todos hasheados por
conteúdo**. `struct`, `list`, `dict` e `set` ficam fora. O `==` da 22.2 permanece
conteúdo para tudo, e o contrato "iguais têm o mesmo hash" está restaurado.

**25.2 Duas coisas que isso reorganizou de graça:**

- **Hash por identidade sai do caminho quente do dict.** A única coisa que continua
  sendo chave por identidade é a **caixa opaca de C** (13.2) — e a identidade dela é
  um ponteiro de C, que não se move. Então `dict[janela] = estado` continua
  funcionando para handle do SDL, que era o caso de uso real. Mutar não afeta nada,
  porque a chave é a identidade.
- **A justificativa do `id` no cabeçalho MUDOU.** Ele não é mais necessário para
  hashear. E `is` também não precisa dele: comparar dois endereços num instante é
  válido mesmo com coletor que move, porque nenhuma coleta acontece no meio da
  comparação.
  O que exige o campo é a decisão 25.3 abaixo: um id **visível ao programa** tem de
  ser estável entre coletas.

**25.3 `id(x)` é visível no programa**, como no Python. É isso — e só isso — que
obriga o campo de id estável no cabeçalho (24.2). Assumido: o valor aparece em log e
em teste, e alguém vai depender dele sem querer.

**25.4 Checagem de format string: só no pscript.** Lá variádica exige `unsafe` (12.1),
então é caso raro e vale ser rígido. O P fica como está, para não mexer nos placares
de conformidade (c-suite 220, wacct 741, clang-compare 155).

### Bateria 26 — `nogc:`, bloco sem coleta (2026-07-29)

Ideia sua: um bloco onde o coletor não roda, como seção crítica. **Existe em outras
linguagens, mas é raro** — vale registrar o precedente porque ele traz o detalhe que
decide se a ideia funciona:

- **.NET**: `GC.TryStartNoGCRegion(bytes)` / `EndNoGCRegion()`, público desde 2015,
  usado em jogo para seção crítica de quadro. **Exige orçamento declarado**, porque o
  runtime pré-reserva; sem isso a promessa não se sustenta.
- **JNI**: `GetPrimitiveArrayCritical` desliga o coletor para você segurar ponteiro
  cru para dentro de um array — a versão de FFI da mesma ideia.
- **Go**: só desligamento global (`debug.SetGCPercent(-1)`), não bloco.
- **Python**: `gc.disable()` desliga apenas o coletor de ciclos; refcount continua.

**26.1 Nome: `nogc:`.** Diz o mecanismo, não a metáfora. Descartado `critical:`
(carrega bagagem de seção crítica de thread), `pinned:` (impreciso dado 26.3) e
`atomic:` (colide com os atomics do buffer compartilhado, 18.3).

**26.2 Orçamento opcional.** `nogc(64k):` pré-reserva e checa; `nogc:` sem orçamento
apenas suspende a coleta.

**26.3 Estourar o orçamento lança erro.** Coerente com o resto da linguagem — índice
fora, chave ausente e estouro de int todos lançam.

> Leitura que decorre de 26.2 + 26.3: **o erro só existe quando há orçamento
> declarado.** Um `nogc:` sem orçamento não tem o que exceder, então o heap cresce
> enquanto o bloco durar. É o preço de o orçamento ser opcional, e a saída é usar a
> forma com orçamento onde o trecho aloca de verdade.

**26.4 NÃO destrava ponteiro interior — o bloco é só latência.** A 17.2 continua
valendo integralmente: nem dentro de `nogc:` se aponta para dentro de objeto
coletado.

> Isso recusa deliberadamente o uso que eu havia sugerido (o bloco como `pin` de
> escopo léxico), e mantém a regra em uma peça só: **objeto coletado nunca é
> apontado de fora, ponto.** Travessia para C continua sendo cópia (20.2 para
> `record`, 13.3 para `str`). Uma garantia a menos para verificar, e nenhuma
> exceção à 10.2.

### 26.5 Consequências que seguem, e precisam de confirmação

1. **`await` dentro de `nogc:` tem de ser erro de compilação.** Senão a task suspende,
   o loop roda outra task no mesmo heap, e ela aloca com o coletor desligado. É
   checável estaticamente.
2. **Desenrolamento sai de graça:** o bloco baixa para o `defer` que o P já tem
   (`defer gc_resume()`), exatamente como o `with` da 4.4. Exceção saindo do bloco
   reativa o coletor sem código novo.
3. **Aninhamento é contador, não booleano** — uma função com `nogc:` pode ser chamada
   de dentro de outro `nogc:`.
4. **É local ao worker.** Como cada worker tem heap e coletor próprios (18.1), o bloco
   não coordena nada entre threads.

## Bateria 27 — A razão de existir, reescrita (2026-07-30)

Esta bateria nasceu de uma rodada de provocações minhas contra o desenho. Quatro
delas foram respondidas, e a primeira **substitui a 1.4**.

### 27.1 O critério de divisão entre P e pscript

Minha provocação era: as razões da 1.4 (GC, fechamento, try/catch, lambda) não
justificam linguagem separada — justificam `plangc --gc`. A resposta reformula o
problema inteiro:

> *"O problema que eu tenho com o P é que ele é uma linguagem de SISTEMAS, e é
> instável. Eu queria uma garantia de segurança de memória. Você questiona se o
> compilador do P pode ser o mesmo do pscript: é verdade, pode SER. A diferença é que
> uma é ZERO RUNTIME — sem nada compilado e linkado ao executável, sem GC rodando em
> segundo plano, usa a ABI do C. A outra é livre, não polui a ABI do C, tem herança de
> memória, posso trabalhar com múltiplas threads com segurança, com workers isolados
> sem que nada quebre, posso ter erros claros, posso ter stack trace e infinitamente
> mais — porque uma se preocupa com a ABI do C e a outra é livre dentro do seu próprio
> sandbox."*

**Então a divisão não é uma lista de recursos, é um CONTRATO DE RESTRIÇÃO:**

| | P | pscript |
|---|---|---|
| Runtime | **zero** — nada linkado, nada em segundo plano | tem runtime, e por isso é livre |
| ABI | é a ABI do C, e não pode poluí-la | não fala com a ABI do C |
| Memória | manual, do programador | do runtime |
| Fronteira | o sistema | o próprio sandbox |
| Critério de admissão de recurso | *dá para fazer isso sem runtime?* | *isso melhora a linguagem?* |

E o critério de admissão é o que resolve toda discussão futura sobre onde um recurso
mora: **"isso precisa de runtime?"** Se precisa, é pscript. Se não, pode ser P.

Isso também explica retroativamente decisões que pareciam gosto e eram consequência:
"libc é o runtime" é o contrato de zero-runtime do P dito de outra forma; e o GC, as
threads, a exceção e o rastro de pilha só podem existir onde há runtime.

**Consequência formal:** a 1.3 fica **emendada**. pscript é linguagem separada — com
gramática, sema e stdlib próprias — mas **pode compartilhar o compilador**. O que não
se compartilha é o contrato.

### 27.2 Uso geral que compete vence "só eu escrevo"

Minha provocação: a 1.1 ("compete com Go, JS, Python") e a 1.2 ("só você escreve") se
puxam em direções opostas em toda decisão.

**Resolvido em favor da 1.1.** pscript é de uso geral e para competir. Consequência
assumida: obriga stdlib de verdade, documentação, estabilidade e mensagem de erro
pensada para quem não conhece o interior. A 1.2 deixa de ser licença para pular isso.

### 27.3 Inferência de contêiner homogêneo — REVISA a 4.1

Minha provocação: `List<any>` por padrão faz o laço mais comum da linguagem
(`for x in [1,2,3]: soma += x`) pagar caixa no heap por elemento **mais** checagem de
etiqueta por acesso (11.3) — velocidade de Python com passos extras, apagando a
vantagem que os tipos estáticos compraram.

**Aceita.** Se todos os itens do literal forem do mesmo tipo — **primitivo ou
`record`** — o array infere o tipo do elemento corretamente. Só heterogêneo vira
`List<any>`.

> Revisa a 4.1, que dizia `List<any>` sempre. Pequeno ponto a esclarecer: e literal de
> `struct` homogêneo (`[ed1, ed2]`)? Ali não há caixa a economizar, porque `struct` já
> é referência — mas há tipo a checar, então inferir `List<Editor>` ainda paga.

### 27.4 O problema não é fechamento — é FUNÇÃO COMO VALOR

Aqui minha provocação estava errada, e a correção muda bastante coisa:

> *"O meu problema não é bem com a closure, é com funções como tipos de primeira
> classe — funções como valores, callbacks. Isso é a razão de tanto código ruim e
> tanto bug. Não quero várias callbacks no meu código, muito menos passar funções com
> corpo como parâmetro para outras funções, mas sim valores ou objetos."*

E a defesa da concorrência, que responde diretamente à minha provocação de que
`async` era desproporcional:

> *"`async`/`await` é essencial para concorrência e lidar com IO, e worker é o que
> falta para completar tarefas de CPU intensive que o modelo async não resolve. E o
> shared memory resolve o problema de race condition, por isso é definição da
> linguagem."*

**A coerência disso é forte, e vale dizer em voz alta:** `async`/`await` foi inventado
exatamente para matar callback hell, e passagem de mensagem foi inventada exatamente
para matar estado compartilhado. Você não está escolhendo três recursos — está
escolhendo **o modelo de concorrência que dispensa callback**, com os três papéis
separados:

| Papel | Mecanismo |
|---|---|
| Concorrência de I/O | `async`/`await` |
| Paralelismo de CPU | worker isolado |
| Compartilhar estado com segurança | só o buffer desenhado (18.3) |

**Decisões que isto REVISA, e que ficam pendentes de fechamento:**

- **6.1 / 19.2 / 20.3 (lambda e captura por valor)** entram em contradição direta com
  "não quero passar função como parâmetro". Se função não é valor, **lambda não existe**
  — e cai com ela toda a máquina de ambiente, de captura e de ponteiro de função
  encaixotado.
- **8.1 (decorador)** depende de receber e devolver função. Sem função como valor,
  decorador não tem como funcionar.
- **A questão do "god object guardar função"**, que ocupou uma conversa inteira sobre
  ABI uniforme e `vectorcall`, fica **vazia**. Não há função para guardar.

**E fica uma pergunta prática que precisa de resposta:** como se escreve uma tabela de
despacho sem função como valor? A command palette do pstudio é literalmente
nome → ação, e o `Vfs` dele é um struct de ponteiros de função.
> Palpite de onde a resposta está: o próprio `pstudio/DESIGN.md` já resolveu a
> heterogeneidade uma vez sem interface — *"a heterogeneidade se resolve com enum +
> box e `match type`"*. Uma palette seria `enum Comando` mais um `match`, e o
> despacho fica sendo dado, não função.

## Bateria 28 — Função como valor: REVERTIDA de volta (2026-08-12)

Depois de semanas de intervalo e com a cabeça fresca, a 27.4 foi **parcialmente
revertida**:

> *"Eu pensei muito nisso por semanas e decidi que vou manter função como valor de
> primeira classe. Isso vai manter mais parecido com Python, no final é o melhor que
> posso fazer, e é uma linguagem de script. E substitui coisas como strategy pattern."*

**28.1 Função É valor de primeira classe.** Guarda-se em variável, passa-se como
argumento, devolve-se, põe-se em contêiner.

**28.2 `lambda` existe normalmente.** Restaura a 6.1, a 19.2 (captura por valor) e a
20.3 (duas formas, o compilador escolhe: sem captura é ponteiro puro, com captura é
ponteiro + ambiente coletado).

**28.3 Decorador fica completo.** Pode embrulhar de verdade. Restaura a 8.1, e funciona
por causa da 22.5 — copiar por valor uma referência ainda aponta para o mesmo objeto,
então o `cache` de um `@memo` é compartilhado entre chamadas.

**28.4 `sorted(xs, key=...)` igual ao Python.** Recebe função.

**28.5 Tabela de despacho: `enum` + `match`, mesmo assim.** Apesar de função ser valor,
a command palette e o `Vfs` do pstudio ficam como `enum Comando` + `match` central — o
que o `pstudio/DESIGN.md` já havia escolhido para heterogeneidade. Despacho é **dado**,
não função, por preferência de estilo e não por limitação da linguagem.

> **Consequência: `enum` existe em pscript.** Estava na minha lista de buracos nunca
> discutidos e a resposta da 28.5 o pressupõe.

### 28.6 O que sobra da 27.4, e o que ela devolve à vida

**Sobra**, e continua sendo a justificativa da concorrência: `async`/`await` para I/O,
worker isolado para CPU, buffer compartilhado desenhado para estado comum. Isso não foi
revertido.

**Cai**: "função como valor é a raiz de código ruim" deixa de ser regra da linguagem e
passa a ser conselho de estilo — visível na 28.5, onde o estilo escolhido é `enum` mesmo
tendo a opção.

**Volta à vida uma pergunta que eu havia declarado vazia:** função dentro de `any`.
Enquanto o tipo é estático (`f: def(int) -> int`) o **call site conhece a assinatura**, e
não é preciso ABI uniforme nenhuma — é só um ponteiro indireto. Mas um `any` que guarda
função perde a assinatura, e aí volta toda a discussão de adaptador gerado e convenção
uniforme (a do `vectorcall` do CPython).

**Perguntas novas que a reversão cria:**
1. Qual a sintaxe do tipo de função? (`def(int, int) -> int`, como o P já usa?)
2. Função pode entrar em `any`? Se sim, precisa da ABI uniforme e do adaptador gerado.
3. `List<def(int) -> int>` é escrevível?

## Bateria 29 — Função como valor: representação e tipos (2026-08-12)

Nota sobre a reversão da 28: *"eu sei que eu me contradiz, mas foi uma decisão muito
difícil mesmo. O ideal era melhor não ter, mas no mundo real temos que ter."* Fica
registrado que a mudança de posição foi deliberada e custou semanas — não é
inconsistência, é a decisão amadurecendo. É a mesma conclusão a que Python, JS, Go e
C# chegaram.

**29.1 Tipo de função: `def(int, int) -> int`**, exatamente como o P já escreve
ponteiro de função. Zero sintaxe nova, coerente com "a struct do pscript é superset da
do P" (20.1).

**29.2 `enum` igual ao P.** Constantes nomeadas com valor inteiro, e `match` sobre elas
com exaustividade checada — o `-Wswitch` que o plangc já tem. Variante com dado
(*tagged union*) fica de fora; entra se a command palette pedir.

**29.3 `any` e `def` são universais SEPARADOS.**
- `any` = valor/dado. Estreito: um ponteiro para objeto com cabeçalho.
- `def` sem assinatura = função de assinatura desconhecida. Gordo: `{fp, env, sig}`.

> **O argumento que decidiu, e não é "força a especificar":** os dois têm tamanhos
> naturais diferentes. Se função morasse dentro de `any`, ou `any` ficaria largo o
> bastante para o pior caso — e **todo** `any` do programa pagaria, inclusive
> `List<any>`, que é o contêiner padrão (4.1) — ou encaixotar função custaria uma
> **alocação a mais**, um objeto no heap só para guardar `{fp, env}` que já eram valor.
> Separados, cada um fica no seu tamanho e nenhum compromete o outro.
>
> **Dois efeitos colaterais bons:** a tabela de despacho passa a ser visível no tipo
> (`Dict<str, any>` é dado por chave; `Dict<str, def>` é callback por nome), o que dá
> algo *grepável* a quem se preocupa com sopa de callback — a preocupação da 27.4. E os
> casos genuinamente "qualquer coisa" (serializar, mandar para worker, imprimir)
> naturalmente **excluem** função, então o `any` estreito não perde caso de uso real.
>
> **Custo assumido:** duas perguntas que todo mundo vai fazer — "por que não posso pôr
> função no `any`?" e "qual dos dois eu uso?".

**29.4 `def` sem assinatura exige estreitar antes de chamar:**

```python
f = tabela["salvar"] as def(str) -> bool
f(caminho)
```

Um compare do descritor de assinatura (internado em comptime, então compare de
ponteiro) e depois chamada indireta normal. **Zero argumento encaixotado, zero
adaptador gerado.** Mesmo contrato da saída checada de `any` (11.3).

> Deliberadamente NÃO se pode chamar `def` sem dizer a assinatura esperada. Poder
> chamar direto exigiria ABI uniforme estilo `vectorcall`, e com ela o encaixotamento
> de todo argumento que atravessa — o custo do Python, evitado aqui porque a checagem
> de saída já existe na linguagem.

**29.5 Valor de função é sempre `{fp, env}`** — ponteiro gordo, como o `funcval` do Go.
16 bytes, e a chamada passa o `env` como argumento oculto (em registrador em x86-64 e
ARM64, então praticamente grátis em tempo). Atribuição uniforme: função sem captura
recebe `env = NULL` e ignora o parâmetro.

> Descartado: ponteiro nu quando não captura. Seria 8 bytes e chamada idêntica a C no
> caso comum, mas o mesmo *tipo* passaria a ter duas representações, com conversão em
> toda atribuição.
>
> **Consequência concreta:** uma função de P importada tem ABI de C (`int(int)`), então
> atribuí-la a um valor de função de pscript exige um **adaptador gerado de uma linha**
> que descarta o `env`. Só para funções de fato usadas como valor.
>
> **E o que importa da 27.1: nada disso toca a ABI do C.** É convenção interna do
> sandbox; o P continua zero-runtime com ABI intacta.

## Bateria 30 — Interfaces (2026-08-12)

**30.1 Interfaces entram em pscript, com conformidade ESTRUTURAL** — **REVISADA nas
66.2 (checagem passa a ser NOMINAL) e 67.1 (o P ganha trait na forma estática). O texto
abaixo fica pelo registro do caminho, e a nota sobre vtable ser DADO continua valendo —
foi ela que fundamentou a 67.1.**
 — como em Go: se o
`struct` tem os métodos, ele satisfaz a interface, sem declarar nada. **O P fica como
está**, com "enum + box e `match type`" como o `pstudio/DESIGN.md` decidiu.

> Isso fecha o primeiro dos dois buracos que eu havia levantado: **o protocolo de
> iteração é uma interface.** `for linha in buffer` funciona se `Buffer` tiver os
> métodos de iteração — sem `__iter__`, sem gerador (excluído na 17.4), sem convenção
> de nome mágico.
>
> Nota para o futuro, se algum dia se cogitar levar interface ao P: **vtable é DADO, não
> runtime.** Uma interface compilada é um struct de ponteiros de função — exatamente o
> que o `Vfs` do pstudio é hoje, escrito à mão. Então a rejeição registrada no
> `pstudio/DESIGN.md` foi sobre complexidade, não sobre o contrato de zero-runtime.
> Estrutural agora, no lado que tem liberdade; o P só se pagar.

**Pendências que a 30.1 cria:** conformidade estrutural exige que a sema compare
conjuntos de métodos, e uma vtable é gerada por par (tipo, interface). E satisfazer por
acidente passa a ser possível — que é o custo conhecido do modelo do Go.

## Bateria 31 — A regra de fronteira, e semântica pendente (2026-08-12)

**31.1 Uma função de P é segura em pscript se e somente se a assinatura dela não
trafica ponteiro cru.** Fecha o furo que a 9.2, a 9.3 e a 12.2 deixavam entre si.

```
def abrir(caminho: str) -> Arquivo            # segura
def fopen(p: *char, m: *char) -> *FILE?       # não é
```

> Por que essa regra é boa: é **mecânica e verificável, sem anotação nenhuma** — nada
> de `safe def` (que exigiria palavra nova no P, justamente a linguagem que se quer
> manter estável), e nada de "toda função de P exige `unsafe`" (que tornaria `print`,
> `abrir` e toda a stdlib marcados, esvaziando a fronteira).
>
> E o melhor: **faz o envelope da 13.1 se auto-declarar.** Escrever envelope *é* trocar
> ponteiro por tipo seguro — então a regra não é um decreto sobre envelopes, é a
> descrição do que envelope faz. O `unsafe def` da 12.2 fica reservado para função **de
> pscript** que contém bloco `unsafe` e quer propagar.

**31.2 `await` dentro de `nogc:` é erro de compilação.** Confirma a consequência que a
26.5 havia levantado: senão a task suspende, o loop roda outra task no mesmo heap, e ela
aloca com o coletor desligado. Checável estaticamente.

**31.3 `str` é imutável.** Permite internar, compartilhar sem cópia, e cachear com
segurança o hash e a representação UTF-8 (14.1). Consequência assumida: concatenar em
laço aloca a cada volta, então a stdlib precisa de um construtor de string à parte
(equivalente ao `StrBuf` que o P já tem).

**31.4 Índice negativo conta do fim**, como Python: `xs[-1]`, `xs[2:-1]`. Custa um teste
de sinal por indexação — e como o índice é `int` estático, o compilador elimina o teste
quando o valor é constante, que é o caso comum.

## Bateria 32 — Números, erros e custos aceitos (2026-08-12)

**32.1 `int + float` promove para float, com aviso quando perde precisão.** Promove por
padrão (como Python e C); se o `int` não couber exatamente em `f64` — acima de 2^53 — o
compilador avisa nos casos em que dá para saber estaticamente.

> Não contradiz a 7.3 (que proibiu `1 + "2"`): coerção entre numéricos é conversão de
> largura, não reinterpretação de categoria.

**32.2 Divisão por zero lança, capturável como qualquer erro.** Mesma categoria dos
outros, com mensagem, código, posição e pilha (15.2). Assumido: um `catch` genérico
engole defeito de programação junto com falha de I/O — a disciplina de filtrar pela
categoria fica com quem escreve o `catch`.

**32.3 `id(x)` fica, e a palavra no cabeçalho com ele.** Cabeçalho é `{ty, gc, id}`.

> E o custo que eu havia levantado **encolheu muito** depois da 27.3: com literal
> homogêneo inferindo `List<int>`, uma lista de mil inteiros não tem objeto nenhum —
> são mil `int64_t` num array. A conta de "mil caixas × 24 bytes" só valia quando o
> padrão era `List<any>`.

**32.4 `set` de `struct` é impossível, e isso é aceito.** Quem quer conjunto de objetos
usa `Dict<int, Struct>` indexado por um id próprio. Mantém o contrato hash/igualdade
limpo (25.1) e evita `set` e `dict` terem regras de chave diferentes.

## Bateria 33 — A STL do pscript, e arrays (2026-08-12)

**33.1 Os contêineres são biblioteca de runtime privilegiada — nem embutidos no
compilador, nem biblioteca comum.** Suas palavras:

> *"O compilador pscript vai ter sua própria biblioteca com sintaxe dentro dele para os
> próprios tipos, e o código gerado vai usar essa biblioteca P. Mas não vai ser
> exatamente a mesma do P. Podemos copiar a STL do P para usar como base, mas vai ser
> adaptada para o código específico de tipos dinâmicos de pscript."*

Ou seja:
- **O compilador conhece os tipos**: `list`, `dict`, `set`, `str`, `tuple` têm sintaxe
  literal, nome reservado e checagem de tipo própria.
- **Uma biblioteca em P os implementa**, e ela **acompanha o compilador**.
- **A biblioteca é um FORK da STL do P**, não um reuso: mesma base, adaptada para
  cabeçalho de GC, função de percurso e suporte a `any`.
- O P gerado pelo ps-lower chama essa biblioteca.

É o modelo do pacote `runtime` do Go e do `core`/`alloc` do Rust. **Refina a 3.3**, que
dizia "tipos novos": não são escritos do zero, são forkados e adaptados.

> **Bom:** como a STL do P é header-only com métodos `inline`, os métodos do contêiner
> **inlinam no C gerado** — `xs[i]` não paga chamada de função. Arquitetura de biblioteca
> com desempenho de embutido, o que raramente dá para ter junto.
>
> **Dívida assumida:** fork significa divergência. Bug corrigido numa família não
> propaga para a outra, e a `map.ph`/`dict.ph` de hoje passa a ter uma prima. É o preço
> de o coletor existir num lado e não no outro.

**33.2 A função de percurso é escrita à mão no runtime.** Resolve a contradição entre
16.4 (runtime é P), 3.3 (contêineres próprios) e 20.1 (struct de P não é rastreada): o
runtime é **código P privilegiado**, e cada contêiner traz sua própria função de percurso
escrita à mão, como o `tp_traverse` do CPython. Não mexe no contrato do P (27.1) e não
tem problema de bootstrap.

**33.3 `record` pode ter campo de array de tamanho fixo.** `Cor` com `u8[4]`, `Rect` com
`f32[4]`. É POD, tem layout de C, atravessa por cópia (20.2). Estende a 21.1, que falava
só de escalares e records aninhados.

**33.4 `List<T>` é o padrão; `T[N]` é opt-in.** Suas palavras: *"em pscript por padrão
vai vir um `list`, mas poder especificar um tipo de array P fixo seria útil"*.

`T[N]` é tipo completo — local, parâmetro, campo — como no P. Sem alocação e sem coletor
para buffer de tamanho conhecido. Não é o caminho normal: é a saída para quando o tamanho
é fixo e a alocação incomoda.

> **Consequência que precisa de resposta, e é sobre a shadow stack.** A 17.1 diz que a
> shadow stack guarda **endereço de slot** (`**Val`), um por variável coletada. Mas um
> local `Editor[4]` são **quatro** referências coletadas contíguas. Registrar quatro
> entradas separadas funciona e é desperdício; o natural é a shadow stack aceitar
> **faixa** (endereço + contagem) além de slot único. Pequena extensão, mas muda a
> estrutura, e é melhor decidir antes de emiti-la.
>
> E a orientação de uso que decorre de ter dois tipos de sequência: `T[N]` quando o
> tamanho é conhecido e não cresce (zero alocação, fora do coletor), `List<T>` quando
> cresce.

## Bateria 34 — Últimas pendências de runtime (2026-08-12)

**34.1 A shadow stack aceita FAIXA: endereço + contagem.** Uma entrada cobre um
`Editor[4]` inteiro (e é a mesma forma que cobre os locais de um frame de `async`).
Decidido antes de emitir a estrutura, que era o ponto.

**34.2 Rastro de pilha: função + arquivo:linha por frame.**
`em editar (codeview.psc:142)`. Cada frame da shadow stack carrega um ponteiro para
nome/posição estáticos — dado imortal, fora do coletor. Sem valores de argumentos.

**34.3 Mensagem entre workers: serializa para bytes, com fast path para POD.** O caso
geral serializa (quem envia escreve num buffer, quem recebe desserializa no próprio
heap — necessário porque copiar grafo direto alocaria no heap de outra thread e
dispararia coleta cruzada, o que a 18.1 proíbe). **Mas `record` e primitivos atravessam
direto via `memcpy`**: a 21.1 garante que são dado puro, então o fast path é seguro por
construção.

> Refina a 18.2: "cópia profunda" era subespecificado. E note a escada que se formou —
> `record` é o tipo que atravessa barato para **C** (20.2), para **worker** (aqui) e
> para **disco** (serialização trivial). Ele virou a moeda de troca de todas as
> fronteiras, sem ter sido desenhado para isso.

**34.4 `struct` por origem FICA, com aviso ao mover.** Sem palavra nova: declarada em
pscript é coletada, importada de P é manual (20.1). O compilador avisa quando uma struct
declarada em pscript colide em nome com uma importada de P — o caso perigoso do fluxo de
prototipagem (mover código de um lado para o outro), pego sem custo de vocabulário.

## Bateria 35 — Threading e workers: a superfície (2026-08-12)

**35.1 Worker é criado com função nomeada do mesmo programa.**
`w = spawn(processar, args)` — o binário é um só, o worker começa naquela função, numa
thread do SO com heap/coletor/loop próprios (18.1, 22.3). Os `args` atravessam por
mensagem (34.3: serialização, com `memcpy` para POD). **A função de entrada não captura
nada** — recebe só o que foi mandado, o que preserva o isolamento por construção.

> Descartado o modelo JS de `Worker("arquivo.psc")`: em linguagem compilada num binário
> só, apontar para arquivo obrigaria compilação dinâmica ou binários múltiplos.
> `spawn(fn)` é o que Go e Rust fazem.

**35.2 Mensagem chega por canal esperado com `await`** — `msg = await canal.recv()`.
Nada de handler `on_message`: um modelo só (tudo é `await`), sem reintroduzir callback
como estrutura central (27.4). Backpressure natural: quem não lê, acumula na fila.

**35.3 Task é future explícito e quente.** Chamar `async def` **já inicia** a task e
devolve `Task<T>`; `await t` colhe o resultado (ou relança o erro, 19.3). Composição por
`gather`/`race` sobre listas. Modelo de JS/promise — descartada a corrotina fria do
asyncio, que é a fonte clássica de "esqueci de dar await e nada rodou".

**35.4 Workers são explícitos: um `spawn` = uma thread do SO.** Sem pool implícito no
runtime — pool implícito quebraria o isolamento da 18.1 (dois trabalhos na mesma thread
compartilhariam heap). `WorkerPool` pode existir na stdlib, por cima, depois.

## Bateria 36 — Threading e workers: canal, shutdown, cancelamento (2026-08-12)

**36.1 O worker É o canal.** `spawn` devolve o worker, e ele já é o duto nos dois
sentidos: `w.send(x)` de fora, `await w.recv()` de fora; do lado de dentro, o worker fala
com o pai por um par simétrico (`parent.send/recv` ou equivalente). Um duto por worker.

**36.2 O canal é acordado pelo próprio `epoll`.** A fila de mensagens tem um
eventfd/self-pipe registrado no loop do worker — canal **é** uma fonte de I/O como
qualquer outra. Um mecanismo de espera só; esperar canal e socket ao mesmo tempo não é
caso especial. (É como libuv e tokio fazem por baixo.)

**36.3 Shutdown: main espera todos; `w.detach()` marca os descartáveis.** Join implícito
por padrão — nunca mata trabalho no meio. Worker em laço infinito trava a saída, e a
resposta para isso é o modelo da 36.4.

**36.4 Cancelamento: NÃO existe kill externo. O worker se finaliza.** Sua formulação,
que é um modelo completo:

> *"Fornecemos meios para a pessoa finalizar o próprio worker de forma segura, já que
> isso envolve limpeza no runtime. Vale para o worker e para o processo principal. E
> fornecemos meios para receber a mensagem do pai — já que o próprio processo é o canal,
> isso simplifica e resolve muita coisa. Cada processo pode ter seu próprio id, e passar
> essa informação permite comunicação entre processos de forma segura. Com o id dá até
> para verificar o estado do processo."*

Desmontando nas partes:

- **Terminação é sempre voluntária**: existe um `exit()` seguro (roda `defer`s, fecha o
  heap, avisa o pai), e não existe `w.kill()`. Quem quer parar um worker **manda
  mensagem pedindo**; o worker coopera lendo o canal. Cancelamento é protocolo, não
  mecanismo — coerente com terminação limpa envolver o runtime local, que só o próprio
  worker pode executar.
- **Todo worker (e o main) tem um id.** O id é **valor** — serializável, passa por
  mensagem (34.3).
- **Passar o id habilita topologia**: dois irmãos conversam se alguém lhes apresentou os
  ids. Resolve o que o "par implícito" (36.1) sozinho não cobria, sem introduzir
  `Channel<T>` como tipo: **o id é o canal endereçável**.
- **O id permite inspecionar estado** — vivo, terminado, com erro.

> É o modelo do Erlang (pid + mensagem + inspeção), na versão mínima. E note a
> consistência com a 12.4: assim como não se captura falha de C, não se mata worker de
> fora — nos dois casos, a metade que não coopera não tem como estar num estado seguro.

## Bateria 38 — Releitura adversária: contradições e custos (2026-08-13)

Rodada de provocações sobre a espec completa (as duas linguagens + o pipeline).

**38.1 O bug da 24.4 tinha voltado por outra porta, e fechou: o dict COPIA a chave
`record` ao inserir.** A combinação que quebrava: `record` hasheia por conteúdo e é
chave (25.1) + tem semântica de referência (21.2) + nada o tornava imutável — então
`d[rec] = 1; rec.x = 2; d[rec]` não achava. Agora a chave guardada é um **snapshot**:
mutar o record depois não corrompe nada, porque o dict é dono da cópia.

> Precedente no próprio repo: o `StrMap` da STL já copia a chave string ao inserir
> ("the map makes its own copies of keys"). Mesma jogada, e `record` é POD pequeno —
> cópia barata. Nota de implementação: a cópia no insert também **congela o hash** no
> momento certo, então lookup posterior com o record mutado simplesmente não acha (como
> se fosse outro valor), em vez de corromper a tabela.

**38.2 `tuple` é IMUTÁVEL, como Python.** `t[0] = x` é erro. É o que torna tupla-chave
(24.3) são, o hash cacheável, e o que o desempacotamento espera de qualquer forma.

**38.3 O custo de codegen do coletor movedor está ACEITO como preço do desenho.**
Explicitado: como a shadow stack guarda endereço de slot (17.1), o endereço de todo
local coletado **escapa** — o compilador C é obrigado a mantê-lo residente em memória e
recarregá-lo após cada chamada. Local coletado nunca vive em registrador através de uma
chamada.

> A contrapartida que faz valer: o ps-lower emite a shadow stack como **código P
> comum**, então os dois backends herdam de graça e a corretude é automática (o
> otimizador de C não pode cachear o que escapou). Zero trabalho por backend.
> E ficou anotada a válvula futura sem decisão: dentro de `nogc:` nada move, então um
> otimizador PODERIA cachear — segundo papel para o bloco da 26, se um dia medir.

**38.4 I/O de arquivo: pool interno do runtime, como Node/libuv.** `epoll` não
multiplexa arquivo regular (diz "pronto" e o `read()` bloqueia no disco do mesmo
jeito), então `await ler_arquivo()` despacha a syscall para um pool de threads
**interno, invisível ao usuário, que só toca dado de C** — nunca objeto coletado.

> Não contradiz a 35.4 (sem pool de *workers* implícito): aquilo era sobre onde roda
> código pscript; isto é sobre onde roda uma syscall. As threads do pool não têm heap,
> não têm coletor, não executam pscript — recebem (fd, buffer C, tamanho) e devolvem
> (código de retorno). A fronteira é a mesma da 10.2.
> Consequência assumida: o runtime tem threads mesmo num programa sem nenhum `spawn`.

## Bateria 39 — Semântica nunca decidida (2026-08-13)

**39.1 Divisão: Python completo.** `7/2 == 3.5` (`/` entre ints dá float), `7//2 == 3`
(piso), `-7 % 3 == 2` (sinal do divisor), preservando a identidade
`a == (a//b)*b + a%b`. Custo assumido: o tipo do resultado de `/` nunca é `int`, mesmo
entre ints — quem quer aritmética inteira escreve `//`. E `%` de sinal do divisor custa
um ajuste sobre o que a CPU dá (um teste + soma condicional), eliminável quando os
sinais são conhecidos estaticamente.

**39.2 `any` é TAGGEADO: int pequeno embutido no ponteiro.** Bit baixo distingue
"ponteiro para objeto" de "int de 63 bits inline" (o esquema de OCaml/V8/LuaJIT). Um
`any` que guarda int não aloca **nada** — mata a pressão de GC de `Dict<str, any>` com
números, que era o custo remanescente de ter recusado objetos imortais (14.4).

> Não é union no fonte — é representação interna do runtime, invisível na linguagem.
> Custa um mask por acesso a `any` (que já é checado, 11.3) e o coletor testa a tag
> antes de seguir ponteiro. Ints acima de 63 bits significativos boxam normalmente.
> Decidido AGORA e não "medindo depois" porque a tag muda todo acesso a `any` — o
> retrofit seria caro.

**39.3 Rastro através de `await`: cadeia lógica, costurando os awaits.** Cada task
guarda a referência de onde foi criada/aguardada, e o rastro atravessa `await` como se
fosse chamada síncrona. É o que faz o "try/catch em volta de await parece síncrono"
(19.3) valer também para depuração. Custo: capturar um frame-ref por task no spawn.

**39.4 Top-level await: SIM — o main implícito é async.** `dados = await baixar(url)`
funciona solto no arquivo; o main é uma task como qualquer outra, rodando no loop.
Coerente com "tudo é `await`" (37) e zero regra especial.

## Bateria 40 — Semântica do dia a dia (2026-08-13)

**40.1 Truthiness: só `bool` e `T?`.** Condição exige bool, com uma exceção: `if maybe:`
testa não-nulo de um `T?` (modelo Kotlin/Swift). Coleção vazia se escreve
`if len(xs) > 0:`. Diverge do Python de forma visível e aceita — some a ambiguidade
"zero ou ausente?" de `if x:` sobre int.

**40.2 Escopo de variável: de FUNÇÃO, como Python.** — **REVISADA na 64.1: escopo de
BLOCO, igual ao do P.** O texto abaixo fica pelo registro do caminho.
 `for x in xs:` deixa `x` vivo
depois do laço; variável nascida num ramo de `if` é visível depois dele.

> **Correção de fato registrada** (a justificativa original citava C e P como
> precedente): **C é escopo de bloco**, não de função; e **P também é** — a sema recusa
> redeclaração no mesmo escopo mas permite sombra em bloco novo, e o modelo de variáveis
> do QBE foi justamente consertado nesta base ("homônimos em blocos irmãos/aninhados são
> variáveis DISTINTAS"). O que o P tem de parecido é pontual: a variável do `for` vive no
> escopo de fora e é reaproveitada se redeclarada com o mesmo tipo.
> A decisão fica de pé pelo mérito próprio — fidelidade ao Python, que é o norte do
> projeto — e **não** muda o P.
>
> Custo real que ela compra: o compilador precisa de **análise de atribuição definida**
> ("possivelmente não atribuído": usar `x` quando só um ramo o criou é erro de
> compilação — a versão estática do `UnboundLocalError`).

**40.3 Protocolo de iteração: `has_next()` + `next()`.** Interface estrutural (30.1) com
dois métodos; `for x in xs:` baixa para `while it.has_next(): x = it.next()`.

> Bônus que essa escolha compra de graça: **dissolve a pergunta do aninhamento de
> `T??`** — com `next() -> T?`, iterar `List<int?>` não distinguia fim de elemento-None
> e exigia decidir se `T?` aninha. Com dois métodos, o problema não existe.

**40.4 Global mutável pertence ao worker principal.** Suas palavras: *"o global já é um
worker, e os outros são filhos dele. Um worker só se comunica com outro por mensagem e
transferência — em outras palavras, só o worker principal pode acessar variáveis
globais."*

Filho não vê global: estado entra por mensagem no `spawn` e volta por mensagem.

> **Pendência imediata (bateria seguinte): como isso se IMPÕE.** Uma função que toca
> global mutável não pode rodar num worker filho — e com função-como-valor (28.1) a
> checagem transitiva no grafo de chamadas não é trivial. As saídas candidatas estão na
> próxima rodada.

## Bateria 41 — Stdlib e módulos (2026-08-13)

**41.1 JSON no v0.1: `json.parse(s) -> any` e `json.dump(x) -> str`.** O caminho
dinâmico — é o caso de uso natural do `any`, e navegar exige os casts checados da 11.3.
Versão tipada por struct (`parse<Config>`, estilo serde) fica para depois.

**41.2 Regex: POSIX da libc (`regcomp`/`regexec`).** Zero dependência — "libc é o
runtime" ao pé da letra. ERE clássico: grupos e alternação sim; sem lookahead, sem `\d`.
Envelope em P trivial (o compilador já ingeriu `regex_t` em teste). Se um dia apertar,
a discussão PCRE2/motor próprio reabre com uso real na mão.

**41.3 Módulos com NAMESPACE completo:** `import util` → `util.f()`, e
`from util import f`. A 7.4 fica valendo só para **resolução de arquivo**; a
visibilidade é Python. Custo: sema de módulos própria, diferente da do P.

> Você levantou: *"talvez poderíamos até implementar o namespace completo no P
> também"*. Vai para a bateria seguinte como pergunta própria — mexe na linguagem que
> sustenta selfhost e pstudio, onde todo import hoje é plano.

**41.4 Estado compartilhado entre workers — ideia sua, em desenho.** Textualmente:
*"tem como fazer todo estado global ser sincronizado por padrão? ou talvez criar um
tipo de variável ou record mutado compartilhado entre os workers… toda vez que alguém
evita o estado compartilhado acaba inventando isso, então podemos criar uma estrutura
global, uma memória que vive em todas as threads porém sincronizada e segura… uma
keyword `global`/`shared` que já sincronizava aquilo."*

> Precedente exato: **ETS do Erlang** — processos isolados por mensagem + tabela
> compartilhada com **cópia na entrada e na saída**, sincronizada pelo runtime. A cópia
> é o que preserva o isolamento (18.1): nenhuma referência cruza heaps, nenhum coletor
> coordena. E a moeda de cópia já existe no design: a escada do `record` (34.3).
> O que não fecha: compartilhar objeto coletado direto (ponteiro cruzando heaps).
> Formato, restrições de tipo e atomicidade: bateria 42.

## Bateria 42 — `shared`: estado sincronizado entre workers (2026-08-13)

**42.1 Formato: variável `shared` + dict compartilhado.**
- `shared contador = 0`, `shared config: Config` (record) — variável sincronizada de
  tipo **copiável** (primitivo, `str`, `record`, `tuple`): ler copia para fora,
  escrever copia para dentro.
- `shared d: Dict<str, Config>` — a tabela ETS de verdade, para estado nomeado
  dinâmico entre workers. Vive fora dos heaps coletados, com locks próprios; chave e
  valor restritos à escada de cópia.

> Tipo coletado (`struct`, `list` comum) não pode ser `shared` — ponteiro cruzando
> heaps derrubaria a 18.1. É a cópia que preserva o isolamento, como no ETS do Erlang.

**42.2 Global comum é WORKER-LOCAL: cada worker tem o seu.** Todo worker nasce com sua
própria cópia dos globais (inicializador constante). Função que toca global toca **a
sua** — nenhuma raça possível, nenhuma análise de coloração, `spawn` aceita qualquer
função.

> **Revisa a 40.4** ("só o main acessa"): o filho VÊ globais, só que os dele. O
> espírito da 40.4 — nenhum estado compartilhado por acidente — fica intacto, e a
> imposição que parecia exigir coloração transitiva no grafo de chamadas **desaparece
> por construção**. O modelo final tem três camadas nítidas:
> global = privado do worker; `shared` = sincronizado por cópia; mensagem = transferência.

**42.3 Atomicidade: tudo atômico, lock por variável.** Cada `shared` tem seu mutex;
operação composta (`+=`, ler-modificar-escrever de record) segura o lock inteiro.
Nunca há raça em operação única. Custo assumido: ler `shared` em laço quente paga lock
a cada volta — a saída é copiar para local antes do laço, que é o idioma certo de
qualquer forma.

**42.4 Namespace no P: SIM, opcional e compatível.** O P ganha `import ... as ns`
(forma qualificada) **sem quebrar nada** — o import plano continua valendo, selfhost e
pstudio não mudam uma linha. Primeira mudança no P motivada pelo pscript, e entra no
regime normal do repo: bateria de verificação completa, seed regenerado.

> **IMPLEMENTADO (2026-08-14).** `import "x.ph" as ns` dá `ns.func`, `ns.CONST`,
> `ns.EnumItem` e o tipo `ns.Tipo`. O alias é uma GRAFIA, não um escopo: o P linka
> plano, então `ns.f` e `f` são o mesmo símbolo — o que o alias acrescenta é a
> checagem (o membro tem de ser declarado por aquele módulo, e os imports DELE não
> reexportam, regra do Python) e a legibilidade. Qualquer coisa realmente declarada
> como `ns` ganha do alias. `as` continua identificador comum (reconhecido por texto,
> não virou palavra-chave), e `include ... as` é erro com mensagem própria. Gates:
> `tests/modules` exercita as duas grafias no mesmo arquivo, mais 5 casos em
> `tests/errors/p_ns_*`.

## Bateria 43 — Ergonomia do `T?` e limpeza (2026-08-13)

A 9.4 pôs `T?` em toda travessia de C e a 40.1 exigiu bool em condição — mas nunca se
decidiu como se SAI de um `T?`, e o `s = s or "padrão"` tinha morrido sem reposição.

**43.1 Narrowing por fluxo.** `if x != None:` prova não-nulo e, dentro do ramo, `x` É
`T` — o smart cast de Kotlin/TypeScript. Só para locais; reatribuição dentro do ramo
invalida a prova.

> Compõe com a análise de atribuição definida que a 40.2 já exigiu — é a mesma
> infraestrutura de fluxo, pagando duas contas.

**43.2 Coalescing: operador `??` (e `??=`).** `nome = entrada ?? "anônimo"`. Só para
`T?`, impossível confundir com lógica booleana. Sintaxe que Python não tem, assumido —
a alternativa (`or` com duas semânticas conforme o tipo) era a sutileza que morde.

**43.3 Navegação segura `?.` e `?[i]`.** `cfg?.tema ?? "claro"` — o par clássico.
Custo assumido: cadeia longa esconde qual elo era None.

**43.4 Superfície de limpeza: `finally` + `with` + `defer`, os três.** try/catch/finally
e with como Python; defer também na superfície (limpeza perto da aquisição, herdado do
P). Sobreposição assumida — três formas, o usuário escolhe o idioma.

## Bateria 44 — Funções e módulos no miúdo (2026-08-13)

**44.1 Default mutável: avaliado POR CHAMADA.** `def f(xs=[])` dá lista nova a cada
chamada sem o argumento — conserta a armadilha mais famosa do Python, divergindo dele
exatamente onde ele é defeituoso.

**44.2 `*args` existe, como açúcar sobre `List<T>`.** O call site constrói a lista; a
função recebe `list` comum. `f(*xs)` (splat) espalha na chamada. Tipado e sem ABI
variádica — não toca a 12.1, que era sobre variádica **de C**. (`print(a, b, c)`
precisa disso no primeiro dia.)

**44.3 `print(rect)` mostra repr derivado pelo compilador:** `Rect(x=1, y=2)` para
struct/record/tuple/enum, o mesmo em f-string. Um `to_str()` definido pelo tipo
sobrepõe. É o modelo do dataclass — depuração boa de graça.

**44.4 Privacidade: a regra do P, replicada.** `static` no topo = privado do módulo
(alinhado com o que o P já faz: `static` vira linkage interna); sem `static` =
exportado, visível via `util.nome` (41.3). Zero conceito novo, uma regra nas duas
línguas.

> **A grafia mudou na 118:** a palavra é **`private`**, nas duas linguagens. O
> `static` continua existindo e significa uma coisa só — **método estático**
> dentro de um `struct`, em pscript. A regra desta decisão não mudou, só o nome.

## Bateria 45 — Fidelidade de detalhe e restos (2026-08-13)

**45.1 f-string: subconjunto útil da spec.** `{expr}`, precisão (`.2f`),
largura/alinhamento (`>8`, `<8`, `^8`), zeros (`08d`), hex (`x`) — resolvido inteiro em
compilação. Fora: braces aninhados (`{x:{w}}`), `!r`/`!s`, formato dinâmico.

**45.2 Extras Python no v0.1: walrus e slice com passo.**
- **Walrus `(x := expr)`** — o P já tem, a sema de hoisting existe; herdar é quase grátis.
- **Slice com passo** — `xs[::2]`, `[::-1]`; fatia já é cópia (17.3), o passo só muda o
  laço.
- **Ficam fora**: comparação encadeada `a < b < c` e `for`/`while` com `else`.

**45.3 `send` para worker morto devolve `bool`.** Nem exceção (criaria try/catch em
todo envio para uma raça que não é defeito), nem silêncio (esconderia o fato). O bool
diz "entregou na fila" — e fica documentado que isso não significa "será processado".

**45.4 Interface estrutural cobre struct de P também.** A vtable de cada par
(tipo, interface) carrega a flag "coletado?"; o rastreio do GC consulta antes de seguir
o ponteiro de dados. Interop máximo: um `Vec` de P pode entrar num `for` de pscript.

> Custo assumido e registrado: o valor de interface tem **dois regimes de vida** — se o
> dado é coletado, o valor é raiz rastreada; se é de P, o usuário responde pela vida do
> objeto (como em qualquer uso de tipo de P). A flag na vtable é o que impede o coletor
> de seguir ponteiro manual.

**45.5 Interop com C é DIRETO, não só via P.** Observação sua: *"se é interopável com
P, também é interopável com C"* — e é mais forte que transitividade. A 7.4 reusa o
sistema de módulos do P **incluindo `include <stdio.h>`**: o pscript enxerga declaração
de C pelo mesmo ingest do cfront, sem `.ph` intermediário. E a régua da 31.1 classifica
cada função de C mecanicamente, sem regra nova:

- `int abs(int)`, `double sin(double)` — assinatura sem ponteiro → **chamável direto e
  seguro**. A libm inteira entra de graça.
- `char *getenv(const char *)` — trafica ponteiro → exige `unsafe` ou envelope em P.
- variádica (`printf`) → `unsafe` (12.1); callback de C → função de P (10.3); macro
  `#define` de objeto → alias já resolvido pelo compilador.

> A fronteira real nunca foi "P vs C" — é **"assinatura sem ponteiro vs com ponteiro"**
> (31.1), e ela corta as duas do mesmo jeito. P é onde se ESCREVEM os envelopes, não um
> pedágio obrigatório.

## Bateria 46 — Identidade e convenções (2026-08-13)

Fecha a 1.5, a pergunta mais antiga em aberto do documento.

**46.1 O nome fica: pscript.** Coerente com plang/plangc/pstudio.

**46.2 Extensão: `.psc`.** (Corrigir os exemplos anteriores do documento que diziam
`.pss` — eram informais.) Header não existe: módulo é namespace (41.3).

**46.3 Docstring Python de verdade.** String como 1ª instrução de def/struct/módulo,
acessível em runtime. Custo assumido: cada docstring é uma `str` viva no binário.

**46.4 `assert` existe e é strippable com flag de build**, como o `-O` do Python.
Footgun herdado e assumido: assert com efeito colateral some no build otimizado — a
regra de estilo é "assert nunca tem efeito", e vale um aviso do compilador quando a
condição chama função (detectável no caso comum).

## Bateria 47 — Números finos (2026-08-13)

**47.1 Float como chave: permitido, comparando por BITS.** Para fins de chave (dict e
hash de record/tuple), float compara bit a bit — NaN acha NaN, `+0.0` e `-0.0` são
chaves distintas. Sem entrada órfã, e resolve float **dentro** de record-chave junto.
O `==` normal continua IEEE (`nan != nan`, `+0.0 == -0.0`).

**47.2 `1.0 / 0.0` lança**, como Python — consistente com int÷0 (32.2). Check por
divisão float, eliminável quando o divisor é constante não-zero. `inf`/`nan` continuam
existindo como resultado de outras operações (overflow de float não lança — só divisão
por zero, como Python).

**47.3 `**` à Python, com a emenda que a tipagem estática obriga.** `2**10` é int
(overflow lança, 7.2); expoente **constante** negativo dá float em comptime
(`2**-1 == 0.5`). A emenda: expoente **variável** não pode mudar o tipo do resultado
em runtime — então `int ** int` variável tem tipo estático `int`, e expoente negativo
em runtime **lança**. Quem quer o comportamento float escreve a base float
(`2.0 ** n`).

**47.4 Case Unicode com tabelas completas embutidas.** upper/lower/casefold corretos
(é→É, ß→SS), tabela gerada offline e embutida — o mesmo padrão do atlas de fonte do
pstudio. Dezenas de KB no binário, assumido. (O marco é um editor: busca
case-insensitive usa casefold no primeiro dia.)

## Bateria 48 — Stdlib e implementação (2026-08-13)

**48.1 Arquivo: Python-like.** `with open(path, "r") as f:` + read/readlines/write;
falha lança com categoria io. Por baixo, o pool de I/O da 38.4.

**48.2 Kit async do v0.1: `sleep`, `timeout` e `interval` — os três.**
- `await sleep(segundos)` — timer sobre o próprio loop (timeout do epoll).
- `timeout(task, segundos)` — race contra o relógio que **cancela** o perdedor (37.2);
  o idioma que evita task órfã.
- `interval`/timer repetido — tick periódico (cursor piscando no editor).
Fica fora: `select` dedicado entre canais (`race` sobre `recv()` cobre).

**48.3 `sys`, como Python.** `sys.argv`, `sys.env`, `sys.exit(n)`.

**48.4 Instâncias genéricas: static inline por TU, como o P já faz.** Cada módulo que
usa `List<X>` recebe sua cópia estática — o mecanismo `inline Vec<int>` que o P já tem
("TU-local, link-safe in many TUs"). O cache de .o (16.2) fica intacto, zero
coordenação entre módulos. Custo assumido: código duplicado entre .o, bloat moderado.

## Bateria 49 — Implementação: pipeline, exceção, contexto, frame (2026-08-13)

Perguntas de engenharia — onde o design encontra limitações concretas do plangc e dos
backends.

**49.1 Pipeline: AST próprio → ps-lower → AST do P.** O pscript tem AST e sema
próprios (inferência, `T?`, narrowing, interfaces, `any`); o ps-lower traduz para o AST
do P existente, e daí segue o pipeline normal. **A sema do P roda como verificador do
lowering**: erro dela em código gerado = bug do ps-lower pego cedo — o mesmo papel que
o `backend_verify` já faz para os backends. O AST do P não ganha nó novo (1.3 intacta).

**49.2 Exceção por FLAG + checagem por chamada** — o modelo do CPython (`return NULL` +
`PyErr`). Função que pode lançar seta a flag no ctx e retorna; o chamador checa
`if exc: goto unwind` após cada chamada; o rótulo de unwind executa os `defer`s do
frame e propaga.

> Por que não setjmp/longjmp: **o QBE não implementa a semântica de `returns_twice`** —
> local em registrador através de um setjmp não tem garantia. Flag é C puro, idêntico
> nos dois backends, e o custo é um branch previsível por chamada que pode lançar.

**49.3 Contexto explícito: todo função de pscript recebe `ctx` como 1º parâmetro
oculto.** Heap atual, topo da shadow stack, flag de exceção, globais do worker — tudo
pendurado no ctx. Portátil a qualquer C (até c89), zero TLS, QBE indiferente, e worker
é só "outro ctx" — o modelo do BEAM.

> Função de P chamada de pscript **não** recebe ctx (a assinatura limpa da 31.1 fica
> limpa). Função de pscript exportada como valor `{fp, env}` (29.5) carrega o ctx no
> caminho da chamada normalmente, porque quem chama é código pscript que o tem.

**49.4 Shadow stack: frame struct por função (Henderson).** Os locais coletados SÃO
campos de um struct-frame local; entrada = 1 push (ligar o frame na lista do ctx),
saída = 1 pop (via `defer`, que também cobre o unwind da 49.2). Faixa (34.1) sai de
graça — array de referências é campo do frame. Otimização de folha ("função que não
aloca pula o frame") fica anotada para depois, sem compromisso.

## Bateria 50 — Implementação: async, identidade, binário, ordem (2026-08-13)

**50.1 Async retoma por `match(state)` no topo do step function.** Cada `await` grava
`frame.state = N` e retorna; retomar é chamar o step de novo e o `match` despachar. Sem
goto — compatível com a regra do P (goto proibido em função com defer), e o `match`
vira jump table no C. Modelo do C#. Bônus de sinergia: `await` em posição de expressão
usa o hoisting de statement-expression que a sema do P **já tem**.

**50.2 Identidade de tipo: typedesc único, emitido no módulo que DECLARA o tipo.**
Vtables de interface podem duplicar por TU (48.4) — todas apontam para o typedesc
único; `is`/downcast compara typedesc. Objeto coletado já aponta para o seu via o `ty`
do cabeçalho — a MESMA identidade nos dois caminhos (header e vtable), sem símbolo
fraco, sem strcmp.

**50.3 Um binário: o plangc ganha o terceiro front end, selecionado por extensão**
(`.c` via cfront, `.p`, `.psc`), e `pscript` é alias/symlink com a CLI própria
(`run`, cache). Um build, uma bateria de verificação, um seed.

**50.4 Ordem de construção: fatia vertical mínima.** Hello world `.psc` de ponta a
ponta o quanto antes — parser mínimo → ps-lower → P → roda — com GC ingênuo (bump sem
coleta) no primeiro momento. Daí cresce feature a feature com teste junto. O risco de
pipeline aparece na primeira semana; o runtime evolui protegido por suíte.

## Bateria 51 — Implementação: restos que a releitura achou (2026-08-13)

**51.1 `interval` consome-se com `await t.tick()` em laço comum.** Zero gramática nova
— resolve o conflito que a 48.2 criou (interval aprovado sem `async for` existir).
Tick coalesce (não acumula fila). `async for` fica para quando/se async iterators
vierem.

**51.2 `str` é INLINE: uma alocação.** Cabeçalho + len + hash + bytes no fim
(flexible array member). Uma cópia no Cheney, localidade perfeita. **E o cache UTF-8
(14.1) fica FORA do heap coletado** — malloc sob demanda, liberado quando o dono morre.
Isso resolve o item 4 da 15.1 (o vínculo entre dois objetos móveis que o copiador teria
que manter): o cache não se move, só o dono.

**51.3 Float em `any` boxa; a tag da 39.2 é só para int.** Esquema de 1 bit, simples.
NaN-boxing descartado — limita ponteiro, amarra plataforma, retrofit impossível.
Float-em-any pesado só aparece em JSON numérico, e se doer um dia, mede-se.

**51.4 Mensagens de erro em INGLÊS**, como o P e toda a infraestrutura de paridade
clang. Coerente com "uso geral que compete" (27.2).

## Bateria 52 — smallpt, e a revisão que ele forçou: record é VALOR (2026-08-13)

**O programa de validação do runtime é o smallpt** (raytracer de 99 linhas do Kevin
Beason), reescrito idiomático com workers — escolha sua. Ele exercita exatamente a
metade mais arriscada do design: paralelismo por tiles, `f64` desboxeado em laço
quente, libm direto (45.5), buffer compartilhado (18.3), PPM via `open()` + f-string.
O marco do v0.1 (pstudio, 8.3) continua; o smallpt vem antes, como prova do runtime.

**52.1 REVISÃO DA 21.2: `record` é tipo de VALOR.** Vive na pilha ou inline no
contêiner, copiado na atribuição, **sem cabeçalho**, layout compatível com C — como
struct de Go/C++. Motivado pelo caso concreto: o laço de radiância cria milhões de
`Vec` por segundo, e objeto coletado com 24 bytes de cabeçalho para 24 bytes de dado
era 100% de overhead no tipo mais quente do programa.

**A cascata de simplificações que isso dispara (por isso a revisão é coerente, não
remendo):**
- **Travessia para C vira `memcpy`/passagem direta** — o marshalling campo a campo da
  21.2 morre; o layout já é o de C. A 20.2 fica mais simples do que era.
- **`List<Vec>` é array plano contíguo** de valores de 24 bytes — sem ponteiro por
  elemento, cache perfeito para o raytracer.
- **Campo record em struct coletada é inline**, e o percurso do coletor **pula** — a
  21.1 garante que não há referência lá dentro. Menos trabalho de trace.
- **Shadow stack não registra records** — valor na pilha de C, invisível ao coletor.
- **Chave de dict (38.1) fica natural**: valor já entra por cópia; o snapshot não é
  mais um mecanismo, é a semântica.
- **Mensagem entre workers (34.3)**: o fast path de `memcpy` vira literal.
- **Entrar em `any` boxa** (como int fora da faixa da tag): o box ganha cabeçalho na
  hora. `id(record)` deixa de existir — valor não tem identidade, como int.

> Pendência aberta pela revisão: **`tuple` provavelmente segue o mesmo caminho**
> (imutável + mesma escada de cópia → valor). Confirmar antes de implementar.

**52.2 Sobrecarga de operador CONTINUA FORA — decidido com o caso concreto na mesa.**
O smallpt idiomático usa `add/sub/mul/dot/cross` nomeados. Registro forte: não foi
omissão — o raytracer inteiro de vetores foi olhado e a resposta foi funções nomeadas
mesmo assim. Reabertura futura exige caso mais forte que este.

**52.3 Framebuffer: `shared buffer` com vista `List<f64>`.** Cada worker escreve seu
tile direto — tiles disjuntos, zero contenda, zero mensagem por pixel. É o caso de uso
que a 18.3 foi desenhada para atender.

**52.4 Cena é global const; RNG é estado local do worker.** `const CENA: Esfera[9]`
— todo worker nasce com ela (42.2, init constante), zero envio. RNG semeado por
(seed_base, id do worker): determinístico e sem contenda.

## Bateria 53 — O que ESCREVER o smallpt descobriu (2026-08-13)

O rascunho existe: `examples/vetor.psc` + `examples/smallpt.psc` (~370 linhas), com a
matriz de cobertura em `FEATURES.md`. Escrever forçou o seguinte:

**53.1 ⚠ PENDENTE — estouro de `u64`.** A 7.2 ("estouro de inteiro lança") não
distinguiu signed de unsigned, e o RNG xorshift64* **exige** multiplicação que dá a
volta. Proposta em aberto para sua decisão: **`iN` lança (7.2 fica), `uN` dá a volta**
— a semântica do C, onde unsigned wrap é definido e é o que todo hash/RNG/checksum
assume.

**53.2 Sintaxe usada no rascunho SEM decisão formal — precisa de bênção:**
- Construtor tipo-chamada: `Vec(1.0, 2.0, 3.0)`, `Esfera(raio=..., pos=...)` com args
  nomeados (o modelo dataclass; args nomeados herdados do P).
- Tipo de tupla escrito `(float, int)` — e `(float, int)?` anulável.
- Docstring com aspas triplas `"""…"""` (string multilinha nunca foi decidida).
- Literal `[...]` para `T[N]` em contexto const.
- `raise error("msg")` para lançar, `raise e` para relançar.
- Casts genéricos na saída de `any`: `List<any>(x)`, `Dict<str, any>(x)`, `str(x)`, e
  record-de-any `Estat(m)` — generalização do `int(x)` da 23.2.
- `global` para atribuir global de dentro de função (inclusive `shared`) — o
  `ST_GLOBAL` do P/Python.
- `match` exaustivo sobre enum conta como "todos os caminhos retornam" na análise de
  retorno (a `radiancia` termina em match sem `case _`).
- Narrowing de `T?` também em condição de ternário (`f(x) if x else y`).

**53.3 Nomes de API inventados no rascunho — stdlib naming a fixar:** `Buffer`,
`buffer(n)`, `.vista_f64()`; `pai.send(...)` (o canal do worker para o pai);
`sys.tempo()`; `status(id)` e o enum de estados (`RODANDO`…); categorias de erro
(`ERRO_IO`…); `re.match -> Match?`.

**53.4 Os dois achados bons:**
- **A `radiancia` inteira não aloca.** Depois da 52.1 (record = valor), o laço quente
  roda 100% na pilha — o coletor não é acionado no caminho crítico. `nogc:` ali seria
  cargo cult, e o rascunho não o usa.
- **`unsafe` não aparece no programa.** Um raytracer paralelo completo, com interop de
  libm, JSON, regex e framebuffer compartilhado — sem uma linha insegura. É o resultado
  que a arquitetura de segurança prometia.

**53.5 O que o smallpt NÃO exercita** (lista em FEATURES.md): import de `.ph`, `?.`,
`finally`, `transfer`, `timeout`/`race`/cancel, slice com passo, `is`/`id()`, splat,
decorador, float-chave, StrBuf, `nogc`, `unsafe`, `--safe`. O segundo exemplo (pstudio)
cobre a maioria; os de concorrência avançada pedem um exemplo de rede.

## Bateria 54 — Bênçãos do rascunho, parte 1 (2026-08-13)

**54.1 Resolve a 53.1: TUDO lança; wrap tem operadores dedicados.** Estilo Zig:
`%+`, `%-`, `%*` fazem aritmética modular (dá a volta) em qualquer largura; os
operadores normais lançam no estouro para **signed e unsigned** igualmente. Shift
continua shift (descartar bits altos é a definição, não estouro). O RNG do smallpt
vira `x %* 2685821657736338717` — o wrap fica **visível** no ponto exato onde é
intencional.

> Mais seguro que a proposta que eu tinha posto na mesa (uN dá volta como C): aqui
> estouro acidental de unsigned também é pego, e o modular explícito documenta a
> intenção. Custo: três operadores novos na gramática.

**54.2 Construtor tipo-chamada ABENÇOADO.** `Vec(1.0, 2.0, 3.0)` posicional (ordem da
declaração) e `Esfera(raio=..., pos=...)` nomeado, para record e struct. Uma forma só
de construir qualquer coisa — o modelo dataclass.

**54.3 `raise` fechado:** `raise error(msg, categoria?)` — construtor do tipo único
(5.1), categoria opcional com default USER; `raise e` relança preservando a pilha
original; `raise` nu dentro de `catch` relança o erro corrente.

**54.4 Tipo de tupla com parênteses:** `def f() -> (float, int)?`. A vírgula
desambigua de parênteses de agrupamento; o parser paga um lookahead.

## Bateria 55 — Bênçãos do rascunho, parte 2 (2026-08-13)

**55.1 `"""` é string multilinha GERAL**, como Python — em qualquer lugar; docstring
(46.3) é só o caso dela em 1ª instrução.

**55.2 `as` para desencaixotar; `T(x)` só converte.** REVISA a 23.2. Duas operações,
duas grafias:
- `x as List<any>`, `m as Estat`, `v as int` — **desencaixota checando** (lança
  categoria TYPE se a etiqueta não bate). Mesma forma do `as def(...)` da 29.4 —
  agora uniforme.
- `int("42")`, `float(n)` — **converte valor** (parse, alargamento). `T(campos...)`
  continua sendo o construtor (54.2).

O rascunho precisa de ajuste: `List<any>(bruto)` → `bruto as List<any>`, etc.

**55.3 As duas regras de sema abençoadas:** `global` para atribuir global/`shared` de
dentro de função (o ST_GLOBAL do P), e match exaustivo sobre enum conta como "todos os
caminhos retornam".

**55.4 Trio `in`/`ref`/`out`: só `in` no v0.1** — o ganho quente (ler sem copiar) sem
os riscos de escrita; `ref`/`out` nativos ficam para depois (o `out` da 11.4/22.1
continua valendo na fronteira com P/C).

> **CONTINGENTE à bateria 56**: a motivação do `in` é evitar cópia de record grande —
> o que só existe se record continuar sendo VALOR (52.1). Ver a seguir.

## Bateria 56 — Reconfirmação: record é VALOR (2026-08-13)

Você levantou *"acho que tudo é referência, porque são objetos"* e pediu para conferir
o que tinha decidido. Conferido: era verdade **até a 52.1**, que você mesmo revisou com
o smallpt na mesa. Posto lado a lado (21.2 × 52.1), a decisão foi **RECONFIRMADA:
record é valor.**

A divisão oficial da linguagem, agora com reconfirmação explícita:

| Família | Semântica de `a = b` |
|---|---|
| primitivo, `record`, `tuple` | **valor** — copia; mutar `a` não afeta `b` |
| `struct`, `list`, `dict`, `set`, `str` | **referência** — compartilha (str é imutável) |

É a divisão de Go e C# (struct vs class). Custo aceito e nomeado: **duas semânticas de
atribuição para ensinar** — `r2 = r1; r2.x = 5` não muda `r1` num record, mas muda num
struct. A regra de bolso: *record é dado, struct é entidade.*

Com isso a 55.4 (trio, só `in` no v0.1) fica confirmada: `in` liga a slot de pilha e
evita a cópia dos records grandes no laço quente.

## Bateria 57 — Record ganha método: REVISA a 21.3 (2026-08-13)

Você perguntou *"fui eu que decidi que record não tem função?"* — sim, na 21.3
(29/jul), escolhendo "não, só campos" contra "sim, como struct de P". Mas a decisão
foi tomada sob premissas que mudaram: record ainda era objeto coletado por referência
(a distinção com struct era estilística), interfaces não existiam, e o smallpt não
estava na mesa. Re-olhada com o contexto de hoje:

**57.1 Record TEM método.** Como Go faz com tipo-valor: açúcar sobre função com
`in self` — lê sem copiar (55.4), não muta o receptor por padrão. Consequências:

- **Encadeamento**: `x.sub(obj.pos).norma()` em vez de `norma(sub(x, obj.pos))` — o
  único encadeamento possível, já que sobrecarga de operador está fora (52.2, firme).
- **Record pode satisfazer interface** (30.1) — a exclusão de interfaces era
  consequência não escolhida da 21.3, e cai junto.
- A distinção record/struct não precisa mais do "sem método": ela é estrutural —
  **valor vs entidade** (56).

> Nota de semântica que decorre de record ser valor: método de record recebe `in self`
> (leitura). Um método que quisesse mutar teria que devolver um record novo — o estilo
> funcional que o próprio smallpt já usa. Se um dia `ref self` em record for desejado,
> é bateria nova (mutação em valor tem as sutilezas de "muta a cópia de quem?").

O smallpt pode migrar para o estilo encadeado ou manter funções livres — os dois são
válidos agora; `vetor.psc` ganha as duas formas quando a implementação começar.

## Bateria 58 — Código em inglês, e a definição de record por bytes (2026-08-13)

**58.1 Todo código pscript oficial é em INGLÊS** — identificadores e comentários, como
o selfhost e o pstudio. O rascunho foi traduzido (`vetor.psc` → `vec3.psc`; `Esfera` →
`Sphere`, `radiancia` → `radiance`, etc.), e isso **resolve a 53.3 por convenção**: a
stdlib inventada no rascunho fica `sys.time()`, `parent.send`, `fb.view_f64()`,
`status(id) == RUNNING`, `e.category == IO`. (Coerente com a 51.4: mensagens de erro
em inglês; e com a 27.2: uso geral que compete.)

**58.2 A definição essencial de record é "BYTES PUROS", não "tamanho fixo".** Sua
lembrança era "record só precisa ter tamanho estático de bytes" — conferido: o tamanho
estático é consequência; a propriedade que sustenta tudo é **nenhuma referência
coletada dentro** (21.1 + 33.3: primitivos, enums, records aninhados, `T[N]` desses).
Uma referência a struct também tem 8 bytes fixos — e se pudesse entrar num record, caía
em cascata: o memcpy entre workers (34.3) copiaria ponteiro para heap alheio, a
travessia para C (20.2) entregaria ponteiro que o coletor move, o GC não poderia mais
pular records no trace (52.1), e o hash por conteúdo (25.1) hashearia endereço.

**58.3 RESOLVIDA na 59** — serialização binária direta de record.

## Bateria 59 — `pack`/`unpack`: serialização binária de record (2026-08-13)

Decidida por você em prosa: *"ter um tamanho fixo de bytes permite a serialização;
memcpy apenas internamente, se for preciso copiar. Essa serialização vai fazer parte
de uma rotina do runtime e da linguagem. Endianness faz parte das funções pack e
unpack (por padrão little-endian) — essas funções são internas da linguagem, já
definidas."*

**59.1 `pack(r)` / `unpack<T>(b)` são funções INTERNAS da linguagem**, geradas pelo
compilador por tipo de record (ele conhece os offsets), parte do runtime — não código
de usuário, não protocolo.

**59.2 O formato é DEFINIDO: campos na ordem da declaração, little-endian, DENSO
(sem bytes de padding no formato).**

> **Extensão decidida por você em 2026-08-15:** a ordem de bytes é PARÂMETRO —
> `pack(r, BE)` e `unpack<T>(b, BE)` — e little-endian continua o padrão. A razão
> é a fronteira: bytes que ficam no processo podem seguir a regra da casa, mas
> bytes que SAEM encontram as regras dos outros (protocolo de rede, formato de
> arquivo de terceiro), e ter de virar cada campo à mão desfaria o ganho de o
> formato ser gerado pelo compilador. Entrou um `enum Endian: LE / BE` no
> prelúdio; o resto do contrato (denso, ordem de declaração, tamanho como
> validação) não muda.

> Isso resolve o problema do lixo de pilha **sem custo na construção**: o padding do
> layout em memória simplesmente não entra no formato — o `pack` copia campo a campo
> pelos offsets que o compilador conhece. Nada de memset em todo construtor.
> E o "memcpy interno quando for preciso" fica exato: **quando o record não tem
> padding e a máquina é little-endian** (todos os alvos atuais — x86-64 e ARM64 —
> são), `pack` É um memcpy. É otimização de implementação, não semântica.

**59.3 O tamanho fixo é o contrato do `unpack`:** `unpack<Sphere>(b)` conhece o
tamanho exato do formato e **lança** (categoria VALUE) se `len(b)` não bater. É o que
a observação original ("tamanho fixo permite a serialização") compra: validação por
comprimento, sem header no formato.

**59.4 A mesma máquina serve as outras fronteiras.** O fast path de mensagem entre
workers (34.3) e o `pack` compartilham o gerador — mensagem de record É um pack para a
fila. E é a resposta concreta ao seu ponto: *"várias coisas que objetos dinâmicos
limitam"* — record dá isso porque é bytes puros (58.2); struct/list nunca darão, e não
devem.

> Suposição registrada à espera de bênção (não decidida): `pack` devolve `List<u8>` e
> `unpack<T>` a recebe — usa tipo que já existe, sem introduzir um tipo `bytes` novo.
> Se um dia houver tipo `bytes` dedicado, o par migra junto.

## Bateria 60 — T[N] × list, e interfaces do sistema (2026-08-14)

Origem: sua pergunta *"nós não temos array de tamanho fixo? e forma nativa de converter
para list sem cópia? imagino que sim porque é interop com P"*. Metade confirmada,
metade decidida agora.

**60.1 O backing da `list` fica no heap MÓVEL, como está.** A 17.3 reconfirmada:
conversão `T[N]` ↔ `list` é **cópia**, sempre. Descartado o backing estável (malloc),
que habilitaria vistas sem cópia ao custo de alocação não-bump e rastreio de backings.
Cheney puro, coletor simples.

**60.2 `T[N]` atravessa para P por `in` — o borrow de chamada.** `def blur(in px:
f64[N])` em P lê os bytes do pscript direto, sem cópia, válido **só durante a
chamada**. É a exceção SEGURA à regra de cópia — segura porque `T[N]` vive fora do
coletor e não se move (33.4); a 10.2 (objeto coletado não atravessa) fica intacta,
porque `T[N]` não é coletado. Interop numérico pesado sem custo.

**60.3 Interfaces DEFINIDAS PELO SISTEMA.** Ideia sua: *"interfaces definidas pelo
sistema (Iterável, Sequência etc.) — tipos nativos já as implementariam quase sem
custo, e também poderíamos implementá-las explicitamente."*

- A linguagem/stdlib define o conjunto padrão (`Iterable`, `Sequence`, …; o conjunto
  inicial exato fica para fixar com a stdlib).
- **Tipos nativos satisfazem nativamente, quase sem custo**: quando o tipo concreto é
  conhecido no call site, o compilador monomorfiza/inlina direto (zero vtable); o
  despacho por vtable só existe quando o valor circula COMO interface.
- **Tipos de usuário satisfazem das duas formas** — estrutural (30.1) ou por
  declaração explícita. Isso REFINA a 30.1: estrutural por padrão, com afirmação
  opcional para intenção visível e erro mais cedo.

> Consequência prática: `def total(xs: Sequence<float>)` aceita `List<float>` e
> `f64[N]` sem duplicar código nem copiar — resolve a pergunta original pela via da
> interface, não pela via do aliasing de memória (que a 60.1 recusou).
>
> Pendência técnica anotada: o protocolo de iteração (40.3) põe `has_next`/`next` no
> próprio objeto — para contêiner nativo o compilador baixa o `for` para laço de
> índice (custo zero, sem cursor), mas contêiner de USUÁRIO iterado aninhado precisa
> de cursor separado. Uma convenção `iter()` pode ser necessária; decidir com o
> primeiro caso real.

## Bateria 61 — Semântica fina que a stdlib cobra (2026-08-14)

**61.1 Continuação de linha: SÓ parênteses, como o P.** Sem `\` do Python, sem regra
de ponto inicial. Encadeamento longo se embrulha em `(...)`. O rascunho usava `\` sem
decisão — corrigido.

**61.2 Comparável: números, `str` (codepoint) e `tuple` (lexicográfica) — o conjunto
do Python.** Record/struct ordenam com `key=` ou método próprio; sem derive de `<` por
campo (a ordem de declaração viraria contrato semântico invisível).

**61.3 `const` em referência CONGELA FUNDO.** `const xs = [1, 2]` proíbe rebinding E
mutação do conteúdo, transitivo, checado em compilação.

> Custo aceito e nomeado: imutabilidade vira uma **dimensão do sistema de tipos**
> (o readonly do TypeScript). Pendência que isso cria: uma const-ref passada a função
> exige noção de "parâmetro que não muta" para o checador propagar — a candidata
> natural é estender o `in` (55.4) para referências, fechando o trio com a mesma
> palavra. Decidir quando a stdlib for tipada.

**61.4 Iteração e pertinência: pacote Python completo.** `for k in d` dá chaves;
`d.items()`/`keys()`/`values()`; `x in list` (busca linear); `"ab" in s` (substring);
`for c in s` dá caracteres.

## Bateria 62 — Interfaces do sistema fechadas, e bytes (2026-08-14)

**62.1 Conjunto inicial: `Iterable`, `Sequence`, `Comparable`, `Printable`.**
- `Iterable` — percorrível no `for`;
- `Sequence` — Iterable + `len()` + `get(i)` (é o tipo do parâmetro que aceita
  `List<T>` e `T[N]` sem cópia, 60.3);
- `Comparable` — ordenação custom no `sorted` (nativos: números/str/tuple, 61.2);
- `Printable` — `to_str()`, sobrepõe o repr derivado (44.3).

**62.2 Conformidade explícita: `implements` no cabeçalho, antes dos dois pontos.** —
**a última frase (conformidade estrutural implícita continua valendo) foi REVOGADA pela
66.2: agora é nominal.**

Sintaxe sua: `struct Rows implements Iterable:` (lista com vírgula:
`implements Iterable, Printable`). Não é herança (5.3 intacta) — é afirmação que o
compilador confere na hora, com erro cedo. A conformidade estrutural implícita (30.1)
continua valendo sem a cláusula.

**62.3 `iter()` opcional: o `for` chama se existir.** Se o tipo tem
`iter() -> (algo com has_next/next)`, o `for` o usa — cursor fresco, aninhamento
funciona. Senão, usa `has_next`/`next` direto no objeto (padrão `Rows`, single-pass).
Contêineres nativos continuam baixados para laço de índice, custo zero. Fecha a
pendência da 60.3.

**62.4 `pack` devolve `List<u8>`, abençoado.** Sem tipo `bytes` novo.

**62.5 Afirmação sua, registrada como princípio:** *"eu sei que é estranho que parte
da linguagem seja programada um nível abaixo (no caso, P), mas vai ser bom ter partes
hardcodadas e funções embutidas no runtime, porque são coisas que usamos sempre."*

> Não é estranho — é a norma: os builtins do CPython são C; o runtime do Go é Go
> privilegiado com assembly; o núcleo do Java é C++ com intrínsecos. A 33.1 já tinha
> essa forma ("biblioteca de runtime privilegiada"); isto a confirma como princípio:
> **o que se usa sempre mora embutido, escrito no nível de baixo, com a interface do
> nível de cima** — e o contrato da 27.1 (P = zero runtime) não se fere, porque o
> runtime do pscript é cliente do P, não parte dele.

## Bateria 63 — embed e template em arquivo (2026-08-14)

Ideia sua: *"um formato de template padrão para strings, porém em arquivo, que a
linguagem compila como strings dinâmicas num binário interno — ou a possibilidade de
empacotar o arquivo em uma string em tempo de compilação."* E a motivação, textual:
*"é um terror fazer isso em C, uma gambiarra enorme"* — `xxd -i`, `objcopy -b binary`
com símbolos por plataforma, limite de 65k em literal de MSVC. O C23 só padronizou
`#embed` agora. Precedentes do recurso: `//go:embed`, `include_str!`/`include_bytes!`
(Rust), `@embedFile` (Zig).

**63.1 Dois primitivos comptime:**
- `embed("help.txt") -> str` — valida UTF-8 em compilação; vira dado estático.
- `embed_bytes("font.bin") -> u8[N]` — dado estático fora do coletor (N inferido do
  arquivo). O atlas de fonte do pstudio embutido: binário único.

**63.2 Template em arquivo: OS DOIS MODOS.** A unificação: como a f-string é açúcar
100% de compilação (45.1), template é **f-string que mora num arquivo**.
- **Sem header** — `render("email.tpl")`: os `{nome}`/`{valor:.2f}` resolvem contra o
  escopo do ponto de uso, em comptime. Uma f-string externa, literal.
- **Com header** — primeira linha declara `{param: tipo}`: o compilador gera uma
  função tipada (`render_email(nome: str, valor: float) -> str`), reutilizável de
  qualquer módulo, com assinatura visível.

**63.3 Regras idênticas à f-string:** `{{ }}` escapa, mesma mini-linguagem de formato,
comptime puro — sem reavaliação em runtime, sem diretivas de bloco (`{for}`/`{if}`
ficaram fora: seria uma segunda linguagem para especificar e depurar).

**63.4 O conteúdo embutido entra no HASH do módulo.** Mudou o template ou o binário,
recompila quem embute — o cache (15.3/16.2) registra as dependências de embed. Correto
por construção.

> Notas de implementação: no C gerado, embed vira array estático de bytes (não literal
> de string — evita os limites de literal e é portátil). E fica anotado o detalhe que
> este recurso expõe: **literais de `str` (e embeds) são objetos estáticos que o Cheney
> não deve copiar** — o coletor precisa reconhecer dado estático (bit no cabeçalho ou
> teste de faixa de endereço). Isso já era verdade para todo literal de string da
> linguagem; o embed só torna o caso grande demais para ignorar.

**63.5 `embed`/`embed_bytes` entram TAMBÉM no P.** Decisão sua. Passa no critério de
admissão do P com folga (27.1: "dá para fazer sem runtime?" — é puro comptime): no C
gerado vira `static const` array, zero runtime, zero ABI. Em P:
`ATLAS: const u8[] = embed_bytes("font.bin")`.

- **Benefício imediato, antes de o pscript existir**: o atlas de fonte do pstudio
  embutido — o editor vira binário único hoje.
- O `render`/template fica **só no pscript** — depende da máquina de f-string, que o P
  não tem e não deve ganhar por tabela.
- É a **segunda mudança no P** motivada pelo pscript (a primeira: `import ... as ns`,
  42.4). Mesmo regime: bateria de verificação completa, seed regenerado.

> **IMPLEMENTADO (2026-08-14).** Expandido em `selfhost/embed.p`, logo depois do
> parse (`cc_load_module`) e antes da sema — porque a sema infere tipo e comprimento
> de array a partir do inicializador ANTES de checar a expressão, então uma chamada
> ainda seria chamada na hora em que `u8[]` precisa do tamanho. O nó vira um literal
> de string comum: os dois backends, o folding e o teste de inicializador estático
> não souberam de nada. Caminho relativo ao arquivo que escreve o embed (regra do
> `include_str!`/`//go:embed`). `embed` recusa nul (truncaria a string C);
> `embed_bytes` dimensiona o array EXATAMENTE no tamanho do arquivo, então
> `len(ATLAS)` é o tamanho. Achado de brinde: o backend QBE emitia um byte a mais em
> `char x[3] = "abc"` (o C descarta o nul quando o array enche exatamente) — corrigido
> junto. Gates: `tests/cases/34_embed` (texto, binário com nul, tamanho exato e com
> padding) e 3 casos em `tests/errors/p_embed_*`.

**Miúdas registradas sem bateria:**
- ~~`send(id)` para worker `gone`~~ — resolvida na 45.3 (devolve bool).
- ~~Interface sobre struct de P~~ — resolvida na 45.4 (satisfaz, com flag na vtable).
- P é instável e é a fundação do pscript (runtime em P, lowering para P): o contrato de
  estabilidade entre os dois é a bateria de verificação (`make verify`) — o pscript
  entra nela como consumidor, igual ao pstudio hoje.

**Pendências que a 36.4 cria (bateria seguinte):**
1. `send(id, msg)` para id de irmão: o runtime roteia como? (registro global de workers
   protegido por trava? o pai encaminha?)
2. Task dentro de um worker: cancela-se (`t.cancel()` cooperativo no `await`), ou tasks
   também só terminam sozinhas? Timeout de I/O precisa de resposta aqui.
3. O que `status(id)` reporta exatamente, e o id de um worker morto é reusável?

## Bateria 37 — Threading e workers: roteamento, cancelamento, supervisão (2026-08-12)

**37.1 Roteamento por registro global.** Uma tabela id→fila, protegida por trava, fora
dos heaps coletados. `send(id, msg)` é direto de qualquer worker para qualquer outro.

> É o **único estado global do runtime**, e vale registrar como tal. A trava só protege
> a tabela (inserir/remover/olhar), nunca as filas em si — cada fila tem sua própria
> sincronização de produtor/consumidor.

**37.2 Task cancela; worker não.** A assimetria é deliberada e tem um porquê:

- **Task**: `t.cancel()` faz o próximo `await` da task lançar erro de cancelamento lá
  dentro; `defer`/`with` rodam no desenrolar normal (12.4). Timeout vira trivial:
  `race` + cancel do perdedor. Uma task 100% CPU sem `await` não cancela — para isso
  existe worker.
- **Worker**: só termina sozinho (36.4).

> Por que a assimetria é correta: cancelar task é **seguro por construção** — só age em
> ponto de `await`, onde o estado é consistente por definição (a task está suspensa em
> fronteira conhecida). Matar worker de fora agiria em ponto arbitrário, inclusive no
> meio de uma coleta. O critério é o mesmo da 12.4: só se interrompe onde há estado
> consistente.

**37.3 `status(id)` reporta `running / done / error / gone`**, e em `error` o objeto de
erro completo (mensagem, categoria, posição, pilha — 15.2) fica disponível para o pai
colher. O mínimo que torna supervisão possível.

**37.4 Worker que morre com erro não capturado vira estado + mensagem para o pai.** O
programa segue; quem criou decide — relançar, recriar, ignorar. Supervisão estilo
Erlang, versão mínima. Estende a 22.4 (que cobria task) para o worker inteiro.

> Somando 36 + 37, o modelo fechou com três regras que cabem num parágrafo:
> **tudo é `await`** (resultado, mensagem, I/O — um mecanismo de espera só, 36.2);
> **nada morre de fora** (task cancela em ponto seguro, worker se finaliza, falha vira
> dado para o pai); **id é valor** (passa por mensagem, habilita topologia e inspeção
> sem tipo novo).

### 24.4 CONTRADIÇÃO (RESOLVIDA na 25.1): hash por identidade × `==` por conteúdo

A 22.2 decidiu que **`==` compara conteúdo** para todos os agregados. A 24.1 decidiu
que **`list`/`dict`/`struct` hasheiam por identidade**. As duas juntas quebram o
contrato que faz tabela hash funcionar — *objetos iguais têm de ter o mesmo hash*:

```python
d = {}
d[[1, 2]] = "a"
d[[1, 2]]          # não acha: as duas listas são ==, mas têm id diferente
```

Três saídas coerentes, e é preciso escolher uma:

1. **O dict tem a sua própria relação de chave**: conteúdo para tipo de valor
   (primitivo, `str`, `record`, `tuple`), identidade para tipo de referência
   (`struct`, `list`, `dict`). O `==` geral continua sendo conteúdo. Coerente, e
   exige explicar que "achar no dict" e "ser `==`" não são a mesma pergunta.
2. **Agregado mutável não é chave** (volta atrás na 24.1 para eles). É o que o Python
   faz, e por este motivo exato. Perde `dict[janela] = estado` para `struct`.
3. **`==` passa a ser identidade para agregado mutável** (volta atrás na 22.2 em
   parte): conteúdo para `record`/`str`/`tuple`, identidade para `struct`/`list`/`dict`.
   É o modelo do JavaScript. Contrato restaurado, e `[1,2] == [1,2]` passa a ser falso
   — que é o que mais surpreende quem vem de Python.

### 22.5 Uma boa notícia que caiu da 19.2

Captura **por valor** parecia fraca, mas não é, porque **copiar por valor uma
referência ainda aponta para o mesmo objeto**. Então:

```python
def memo(f):
    cache = {}                       # dict: referência
    return lambda x: cache_ou_chama(cache, f, x)   # copia a REFERÊNCIA
```

O `cache` é copiado por valor, mas o valor é a referência — logo a lambda muta o
mesmo dicionário em toda chamada. **`@memo` funciona.** Captura por valor só falha
para *reatribuir* um escalar capturado (um contador `n += 1` de fora).

Isso desfaz a ressalva que a 8.1 tinha levantado sobre decorador não poder embrulhar.

Levantado por você: *"depende do tipo de ponteiro… alguns ponteiros devem ser
boxeados por tipo"*. Em vez de um único `*T` opaco, cada **espécie** de ponteiro de
C chega em pscript com uma representação própria:

| O que é em C | Como chega em pscript | Precisa de `unsafe`? |
|---|---|---|
| `SDL_Window *` (handle opaco) | caixa opaca com etiqueta de tipo — só se passa adiante | não |
| `T *` + tamanho (buffer) | `slice<T>`, indexado com checagem de limite | não |
| `char *` (string NUL-terminada) | convertido para `str` na fronteira | não |
| `void *` / ponteiro cru de verdade | `*T` cru | sim |

Se essa classificação valer, **`unsafe` deixa de ser rotina e vira exceção**: quase
todo interop cai numa das três primeiras linhas. Perguntas: quem classifica — o
envelope em P à mão, ou uma anotação no binding? A caixa opaca é comparável e
hasheável? Converter `char *` para `str` copia ou compartilha?

### Ainda em aberto sobre segurança

1. ~~Classificação de ponteiro~~ — resolvida na 13.1 (envelope em P, à mão).
2. ~~Checagem de format string~~ — resolvida na 25.4 (só no pscript).
3. **Formato do rastro de pilha.** A exceção carrega a pilha (15.2), lida da shadow
   stack (12.4) — mas o formato do rastro não foi decidido.

## Bateria 64 — Escopo: as duas linguagens iguais (2026-08-14)

Levantada por você ao ver o lowering: *"temos que deixar as duas linguagens com o
mesmo escopo"*. O descasamento apareceu sozinho na primeira fatia vertical — a sema
do pscript aceitou um nome nascido dentro de um `if` e a sema do P recusou o mesmo
nome, e a saída provisória tinha sido içar as declarações no lowering.

**64.1 Escopo de BLOCO nas duas. REVISA a 40.2.** No pscript, um nome declarado
dentro de um bloco morre com ele, como no P e no C. O idioma if/else do Python
continua disponível, escrito com o opt-in que o P já tinha: `nonlocal x` diz que a
PRÓXIMA atribuição de `x` mora no escopo da função.

```python
nonlocal label
if counter < LIMIT:
    label = "small"
else:
    label = "big"
print(label)
```

> **Por que essa direção e não a outra.** A 40.2 já carregava uma correção anotada: a
> justificativa original dizia que C e P eram escopo de função, e **os dois são de
> bloco** — a decisão tinha ficado de pé só por fidelidade ao Python. Do outro lado, o
> P não podia mudar: a sema dele é COMPARTILHADA com o frontend de C, e C é escopo de
> bloco por definição; o backend QBE tinha acabado de ser consertado justamente para
> que homônimos em blocos aninhados fossem variáveis distintas; e o contrato do P é
> "semântica de execução 100% C". Mudar o P custaria separar as duas semas e desfazer
> aquele conserto.

**O que essa decisão comprou, além da coerência:**

- O lowering deixou de içar declarações: uma declaração do pscript vira uma
  declaração do P, e ponto. Menos código e menos superfície para errar.
- A análise de atribuição definida encolheu — ela ainda existe (declarar sem valor e
  ler antes de atribuir continua erro), mas não precisa mais casar nomes que nascem
  dentro de ramos diferentes.
- `nonlocal` do pscript baixa para o `nonlocal` do P sem tradução nenhuma.

**O que ela custou, nomeado:** diverge do Python, que é o norte declarado (1.4). Um
nome de laço não sobrevive ao laço, e `for` não vaza a variável de iteração.

> **Bug do P que ela desenterrou.** Com `nonlocal x` seguido de `x: T = e` (a primeira
> atribuição TIPADA), o P içava uma declaração inferida e **ainda** emitia a declarada
> dentro do bloco — uma sombra. O trecho depois do bloco lia um slot que ninguém
> escreveu. Só a forma inferida (`x = e`) consultava `fn_nonlocals`. Corrigido: a forma
> tipada iça com o tipo declarado e o sítio original vira atribuição. Gate:
> `tests/cases/35_nonlocal_typed.p`.

## Bateria 65 — O que atravessa, nos dois sentidos (2026-08-14)

Levantada por você: *"muitas coisas do P poderiam ir para o pscript e vice versa"*,
*"não vejo nenhum motivo do record não estar no P também"*, e o alvo:
*"uma virar uma espécie de superset da outra, porém sem perder o objetivo de cada uma
(uma sem runtime e sem GC, de sistema, outra com GC)"*.

**O princípio que isso propõe.** O critério de admissão da 27.1 ("precisa de
runtime?") deixa de ser só um filtro e vira o **critério de ordenação**: um recurso
mora no P se não precisa de runtime — e o pscript o herda de graça, porque baixa para
P. Precisa de runtime, é exclusivo do pscript. O superset é
**pscript ⊇ P na superfície**, com o P sendo o subconjunto que roda sem runtime.

Consequência imediata, e é o que você achou: **nada zero-runtime deveria ser exclusivo
do pscript.** Se é, o recurso está sendo negado ao P sem razão.

**O segundo eixo, que o `record` não expôs.** Alguns recursos são zero-runtime e ainda
assim contrariam o OUTRO contrato do P — *"semântica de execução 100% C"* (spec §1).
`//` e `**` custam duas instruções e nenhuma biblioteca, mas dão resposta que o C não
dá. Esses não caem pelo teste automático: precisam de decisão explícita sobre qual dos
dois contratos do P ganha.

---

**O que o P é — com a correção de enquadramento.** Eu tinha dito que *"o P acabou
virando uma linguagem de comunicação com o nativo e o pscript"*, e você corrigiu:
*"na verdade o P não é apenas uma linguagem de lowering e especificação, ela é uma
linguagem de sistema — cumpre o papel dela em ambientes que não podem ter o GC. Mas
também pode ser vista como o outro lado do pscript, ou o pscript o outro lado do P. É
como C e C++, porém um C++ com GC."*

**Registrado como correção:** ser camada de comunicação é CONSEQUÊNCIA de o P ser
completo e sem runtime, não o propósito dele. O P existe por si, para embarcado,
kernel, laço quente e binário pequeno. Que ele acabe sendo o alvo do lowering (49.1) e
a linguagem do runtime do pscript (16.4) decorre disso.

Isso ainda explica a regra de zero-runtime retroativamente — uma linguagem que vai ser
ao mesmo tempo o ALVO de um lowering e a IMPLEMENTAÇÃO de um runtime não pode ter
runtime próprio, seria um runtime debaixo de outro — mas a explicação é um bônus, não
a razão.

**A analogia C/C++, onde ela é melhor e onde engana.**

- *Melhor*: o superset do C++ é um tratado entre duas implementações, e envelheceu mal
  (o C99 tem coisas que o C++ nunca pegou). Aqui ele é forçado por CONSTRUÇÃO: o
  pscript baixa para P, então tudo que o P exprime o pscript exprime, por definição do
  pipeline. Um compilador, uma bateria de verificação, um seed.
- *Engana*: o C++ **herdou** a insegurança do C. O pscript deliberadamente não herda a
  do P — os quatro eixos da 9.1 — e usa `unsafe` como ponte de volta. Não é "P + GC";
  é **P + GC − a insegurança, com `unsafe` devolvendo o que faltar**.

E divide os candidatos abaixo em dois grupos com justificativas diferentes:

- **P como transportador** (`record`, larguras exatas, layout, `embed`): melhoram o que
  a camada faz de melhor, que é carregar dado através de fronteira. A 52.1 já dizia que
  record é *a moeda de todas as fronteiras*; ter a MESMA declaração dos dois lados faz a
  travessia custar zero, nem tradução.
- **P como linguagem de aplicação** (`T?`, f-string, `//`, lambda): não se justificam
  pelo transporte. Se justificam porque selfhost e pstudio SÃO aplicações escritas em P
  — mérito próprio, decisão caso a caso.

**O critério são DUAS perguntas, não uma.** Observação sua: *"também vai facilitar o
lowering, ao passar as coisas que não precisam de runtime para o P e são seguras de
memória"*. Está certo, e o mecanismo é concreto: **cada travessia converte código do
`ps_lower` em código do P que a sema do P VERIFICA.** Com `==` por conteúdo e o
construtor no P, o lowering emite `a == b` e `Vec(1.0, 2.0)`; sem eles, teria de
sintetizar temporário, atribuição campo a campo e cadeia de comparações — e nada disso
passaria pela sema, que só veria o resultado já desmontado. Como a sema do P É o
verificador do lowering (49.1), quanto mais semântica mora no P, mais do pscript é
verificado em vez de confiado.

O segundo teste é o que a sua frase acrescenta:

1. **Precisa de runtime?** Não → mora no P.
2. **É seguro de memória?** Sim → o pscript pode baixar em cima disso em vez de
   sintetizar.

A segunda pergunta importa porque o P é a camada INSEGURA. Se o pscript baixa em cima
de algo do P que abre buraco, a garantia dos quatro eixos (9.1) morre no lowering em
vez de morrer no fonte — e um furo no lowering é muito mais difícil de ver. `record`
passa nos dois testes: bytes puros, sem ponteiro, sem aliasing.

> **Tensão a vigiar.** A sema do P serve TRÊS consumidores: entrada P, entrada C, e a
> verificação do que o pscript gera (49.1). Foi ela que forçou o escopo de bloco na
> 64.1. Todo item do Grupo A a faz crescer, e ela é a peça que menos pode errar.

### Grupo A — zero-runtime, hoje só no pscript (candidatos naturais ao P)

**65.1 `record` — DECIDIDO (2026-08-14).** Convivem: `record` recusa qualquer campo
ponteiro (primitivos, enums, records aninhados, `T[N]` desses); `struct` aceita tudo.
Regra de bolso: *record é dado, struct é entidade* — a mesma 56 do pscript, uma regra
nas duas linguagens. Ganha `==`/`!=` por conteúdo (campo a campo, código gerado — nunca
memcmp, que compararia o padding) e o construtor `Vec(1.0, 2.0)` posicional e nomeado.
Fica de fora do P o `pack`/`unpack` (59), por decisão sua.

**65.2 f-string no P, resolvida inteiramente em compilação — FEITA na 119.1, na
forma (a).** No pscript ela constrói
um `str`; no P ela teria de baixar para o que o C tem — uma string de formato mais os
argumentos. Forma possível: `printf(f"{n} itens")` vira `printf("%d itens", n)`.
- (a) Sim, só em posição de argumento de função variádica (printf/snprintf).
- (b) Sim, e também produzindo `const *char` num buffer que o chamador dá.
- (c) Não: formatação é assunto de runtime, o P usa printf à mão.

> Consequência de (a): resolve o caso que dói (mensagem de erro, log) sem inventar
> alocação nenhuma. Consequência de (b): precisa de um buffer, e aí a assinatura fica
> estranha para uma expressão. Consequência de (c): a divergência de superfície entre
> as duas linguagens fica maior justo no lugar mais visível do dia a dia.

**65.3 `T?` não-nulo por padrão, com `??` e `?.`, no P — FECHADO DE OUTRA FORMA
pela 69 (ver 117.5).** O que entrou não foi nenhuma das três: `ref T` é o tipo
não-nulável (local e retorno), `*T` continua anulável para a fronteira com o C,
`??` é o único açúcar (69.3) e o `-Wnull-dereference` cobra a prova. `T?` no P
**não se repropõe**.
- (a) Sim, igual ao do pscript (9.4, 43.1-43.3), com narrowing por fluxo.
- (b) Só `??` e `?.` como açúcar, sem tipo anulável (sem garantia, só ergonomia).
- (c) Não: o P interopera com C, onde todo ponteiro é anulável, e a garantia seria
      falsa na fronteira.

**65.4 Lambda sem captura no P — FEITA na 119.2, na forma (a).** A 20.3 já diz que o compilador escolhe entre ponteiro
puro e `{fp, env}`; a forma SEM captura é literalmente um ponteiro de função, que o P já
tem. `sorted(xs, key=lambda v: v.x)` sem alocar nada.
- (a) Sim, e capturar vira erro de compilação com mensagem que diz por quê.
- (b) Não: o P tem `def` aninhado nenhum, e uma função nomeada resolve.

**65.5 Interfaces estruturais estáticas no P — FEITO pela (a)**, na 67.1 (`trait`
no P, só na forma estática) mais o limite nominal da 68.1. Ver 117.5.
- (a) Sim, como restrição nomeada de genérico (`def sort<T: Comparable>`).
- (b) Não: `declare`/`implement` já resolve, e a mensagem de erro é boa o bastante.

**65.15 O superset é de FONTE ou de CAPACIDADE?** Levantada pela analogia com C/C++,
que escolheu fonte e paga por isso até hoje.
- (a) **Capacidade** (é o que vale hoje): tudo que o P exprime, o pscript exprime — com
      outra grafia quando for o caso. Um `.p` NÃO compila como `.psc` (o parser do
      pscript nem tem `*T`).
- (b) **Fonte**: um `.p` compila como `.psc`, com a superfície insegura do P disponível
      dentro de `unsafe`.

> Consequência de (b): o pscript teria de aceitar ponteiro, `union`, `goto` e a
> aritmética do C — tudo dentro de `unsafe`, mas tudo dentro do parser. É o caminho que
> deu ao C++ trinta anos de compromissos, e a 9.1 (quatro eixos garantidos) fica muito
> mais difícil de sustentar. Consequência de (a): existe código P que precisa ser
> reescrito para virar pscript, e a fronteira é a interop (2.4/9.3), não a colagem.

### Grupo B — zero-runtime, mas divergem da semântica do C

Aqui o teste automático não vale: os dois contratos do P se chocam.

**65.6 `//` (piso) e `**` no P.** Custam um ajuste de sinal e um laço de quadrados.
Nenhuma biblioteca.
- (a) Sim: o P ganha operadores que o C não tem, e a superfície casa com o pscript.
- (b) Não: `/` e `%` do P são os do C, e um `//` ao lado deles é armadilha de leitura.

**65.7 Estouro de int que lança/checa no P.** No pscript lança (7.2). No P não há para
onde lançar — não há exceção. Formas possíveis: `-ftrap` que aborta, ou builtins
`add_checked(a, b, out ok)`.
- (a) Builtins checados explícitos, opt-in por chamada.
- (b) Um modo de compilação que insere as checagens e aborta.
- (c) Não: o P é o C, e overflow com sinal é responsabilidade de quem escreve.

**65.8 Divisão por zero no P.** Mesma forma da 65.7.

### Grupo C — zero-runtime, hoje só no P (candidatos ao pscript)

**65.9 Genéricos `declare`/`implement` no pscript.** A 48.4 já decidiu "static inline
por TU, como o P já faz" — então é a MESMA máquina. Falta dizer se a sintaxe também é a
mesma, ou se o pscript infere a instanciação sem `declare`.

**65.10 `const def` (função avaliada em compilação) no pscript.** Zero runtime, e o
pscript já vai precisar dela para f-string e para `T[N]`.

**65.11 Comptime do P no pscript:** `is_defined`, `typestr`, `hasfield`, e os
predefinidos (`__FILE__`, `__LINE__`, `__func__`…).

**65.12 `out`/`ref` no pscript.** A 55.4 pegou só o `in`, com a justificativa de que
mutar variável do chamador é para o que serve o valor de retorno. Com `record` sendo
valor, `out`/`ref` voltam a fazer sentido para evitar cópia de record grande.

**65.13 `embed`/`embed_bytes` no pscript.** Já decidido na 63.5 que é das duas;
implementado no P, falta no pscript.

**65.14 Larguras exatas (`i8`…`u64`, `f32`) no pscript.** A 2.2 disse "os dois nomes",
com `int` = `i64` e `float` = `f64` — falta dizer se as larguras exatas aparecem só em
`record` (para layout) ou em qualquer variável.

### Grupo D — precisam de runtime: exclusivos do pscript por construção

`str`, `list`, `dict`, `set`, exceção, `async`/`await`, workers, `shared`,
comprehension, fatia, closure COM captura, repr derivado, `pack`/`unpack`, `any`
taggeado, o coletor inteiro. Nenhuma pergunta aqui: é a definição da divisão.

### Grupo E — fechados, não reabrir sem caso novo

- **Tuplas no P** — removidas a seu pedido; ficam só no pscript.
- **Sobrecarga de operador** — fora nas duas (52.2, decidida com o raytracer na mesa).
- **`goto` no pscript** — fora (50.1 retoma async por `match`, não por goto).
- **Variádica de C no pscript** — fora (12.1), `*args` cobre.
## Bateria 66 — Traits: o modelo (2026-08-14)

Levantada por você: *"sera que traits igual rust nao seria uma solucao melhor? quais as
diferencas entre traits(rust) e interfaces(java) na pratica?"* — e a lembrança de que
interface não podia entrar no P por causa de vtable.

**Correção da lembrança, com o documento na mão.** A 30.1 já registrava: *"vtable é
DADO, não runtime. Uma interface compilada é um struct de ponteiros de função —
exatamente o que o `Vfs` do pstudio é hoje, escrito à mão. A rejeição foi sobre
complexidade, não sobre o contrato de zero-runtime."* Então interface **já era
admissível** no P. O que traits mudam é melhor do que destravar: como RESTRIÇÃO de
genérico, o caso comum não tem vtable nenhuma — monomorfiza e some. A vtable vira o
caso explícito, não o padrão.

**"Trait ou interface" não é a pergunta.** Os dois nomes escondem três eixos
independentes, e é neles que Java e Rust divergem na prática:

| | Java | Rust | Go | pscript antes desta bateria |
|---|---|---|---|---|
| quem declara | o tipo | um `impl` à parte | ninguém | o tipo (`implements`) |
| checagem | nominal | nominal | estrutural | estrutural + intenção |
| tipo alheio | não | **sim** | sim | não |
| despacho | só dinâmico | **escolhido por sítio** | dinâmico | vtable implícita |
| `Self` | F-bounded | **nativo** | não tem | em aberto |

> Registro de contexto: metade do motivo de traits existirem em Rust **não se aplica
> aqui** — em Rust, trait é como se definem operadores (`Add`, `PartialEq`), e a 52.2
> pôs sobrecarga de operador fora, decidida com o raytracer na mesa.

**66.1 A implementação mora nos DOIS lugares.** Cláusula no cabeçalho para o caso comum
(`record Vec implements Printable:`) e bloco separado para tipo que não é seu
(`implement Printable for geo.Point:`).

> É o que destrava satisfazer uma trait do pscript com um `record` que veio de um `.ph`
> do P — impossível antes, porque a declaração teria de estar no arquivo do P, que não
> conhece a trait.

**66.2 Checagem NOMINAL — REVISA a 30.1 e a 62.2.** Ter os métodos não basta: tem de
declarar, na cláusula ou no bloco. Mata o "satisfaz por acidente" que a 30.1 tinha
assumido como custo.

> **Essa decisão só fecha porque a 66.1 existe.** Sozinha, ela mataria a 45.4 (um
> `struct` do P entrando num `for` do pscript sem declarar nada). Com o bloco separado,
> a interop volta por outra porta e fica melhor: `implement Iterable for geo.Rows:`
> escrito DO LADO DO PSCRIPT, explícito e conferido.

**66.3 Despacho: os DOIS, escolhidos por sítio de uso.** `def sort<T: Comparable>`
monomorfiza — zero custo, sem vtable, reusando a monomorfização por TU da 48.4.
`dyn Trait` continua existindo, explícito, para lista heterogênea.

**66.4 `Self` e tipo associado: os dois.** Sem `Self`, `Comparable` cai no F-bounded do
Java (o tipo se repete e vaza na assinatura). Sem tipo associado, `Iterable` obriga o
CHAMADOR a dizer o elemento em vez da implementação.

```
trait Comparable:
    def cmp(in self, other: Self) -> int

trait Iterable:
    type Item
    def has_next(self) -> bool
    def next(self) -> Item
```

> A 40.3 fica intacta: `has_next()`/`next()` e não o `next() -> Option` do Rust — a
> escolha original foi por um motivo que continua valendo (com `Option`, iterar
> `List<int?>` não distingue fim de elemento-None).

## Bateria 67 — Traits no P, e coerência (2026-08-14)

**67.1 O P ganha trait SÓ na forma estática. REVISA o "o P fica como está" da 30.1.**
Trait como restrição de genérico (`def sort<T: Comparable>`), que monomorfiza e some:
zero vtable, zero custo, nada novo no binário. `dyn` fica só no pscript.

> O que isso compra no P: o que hoje é `*void` mais convenção passa a ter contrato
> conferido. O que NÃO muda: lista heterogênea no P continua sendo enum + `match type`,
> como a 30.1 decidiu — a metade da 30.1 que falava do P sobrevive.
>
> Consequência para o lowering: um `dyn Trait` do pscript baixa para um struct de
> ponteiros de função em P. Vtable é dado, então isso cabe sem o P precisar da forma
> dinâmica na superfície.

**67.2 `implement` serve às duas coisas, desambiguado pelo `for`.** `implement Vec<int>`
instancia um genérico (o que o P já faz); `implement Printable for Vec:` satisfaz uma
trait. Zero palavra nova nas duas linguagens.

> Colisão que a 66.1 criou e que só apareceu ao escrever a bateria: o P já usa
> `implement` para instanciação de genérico. Duas palavras parecidas convivendo
> (`impl` e `implement`) seria pior do que uma com duas formas que o parser separa
> sem esforço.

**67.3 Regra órfã do Rust.** Só pode implementar se a TRAIT ou o TIPO for seu, e no
máximo uma implementação por par (trait, tipo) no programa inteiro.

> É o que torna o bloco separado seguro. Sem ela, dois módulos implementam
> `Printable for int` de formas diferentes e o comportamento passa a depender de quem
> linkou — com o erro aparecendo longe da causa e culpando o inocente.

**67.4 No P, só as traits do sistema que vivem sem runtime.** `Comparable` e `Iterable`
são puro contrato de método e entram iguais. `Printable` devolve `str`, que é objeto
coletado — no P ela entra com outra assinatura, escrevendo num buffer:

```
# P
trait Printable:
    def to_str(in self, out b: StrBuf)
```

> A alternativa (mesmo conjunto, mesmas assinaturas) obrigaria o P a ter um `str` — e
> aí ou vira `const *char` e a pergunta "quem libera?" não tem resposta, ou o P ganha
> um tipo com dono, que é runtime disfarçado.

**Pendências que estas duas baterias criam, para uma bateria futura:**

1. A sema precisa comparar conjuntos de métodos com `Self` resolvido para o tipo
   concreto — é a peça nova mais delicada.
2. Tipo associado em monomorfização: `T::Item` tem de resolver na instanciação.
3. Como a regra órfã se verifica com compilação por módulo (o P não tem visão global do
   programa em tempo de compilação de uma TU).
4. `dyn` e o coletor: a 45.4 desenhou a flag "coletado?" na vtable — ela continua
   valendo, agora para `dyn` em vez de para interface estrutural.
---

## Bateria 68 — O que a prática cobrou (2026-08-14)

A implementação inteira rodando expôs oito pontos que tinham ficado "no
conservador para não travar", mais um pedido novo. Todos decididos por você.

**68.1 O limite de genérico vira NOMINAL nas duas línguas. ✅ decidido e feito.**
O pscript já era (66.2); o `check_bound` do P era estrutural. Agora o P também
exige o par declarado com `implement X for T:` — a checagem é uma consulta ao
mapa que a regra órfã já mantinha. A 65 (mesmas perguntas, mesmas respostas)
prevalece sobre a conveniência do "satisfaz por acidente".

**68.2 Larguras exatas COMPLETAS no pscript. ✅ decidido e feito (fecha 65.14 e 53.1).**
`i8`…`u64` e `f32` como tipo de variável, parâmetro e campo, com a aritmética
checada por largura. Estouro LANÇA em signed e unsigned igualmente — a posição
que a 53.1 já defendia — e `%+ %- %*` são a volta intencional, mascarada à
largura. Regras que a implementação fixou: literal ADAPTA com faixa conferida em
compilação; alargamento sem perda é implícito, estreitar tem nome e confere;
sinais misturados da mesma largura convertem por nome; `int`≡`i64` e `float`≡`f64`
são o MESMO tipo, não duas grafias. `>>` em unsigned é lógico por natureza — o
xorshift64* do smallpt roda literal e bate bit a bit com o Python.

**68.3 Sombrear o prelúdio: o programa ganha, COM AVISO. ✅ decidido e feito.**
A regra do Python para builtins, mais um `-Wshadow-prelude` dizendo onde. E a
mecânica foi corrigida: colidir com UM item de enum derruba só aquele item —
declarar `TYPE` não leva `IO` junto. Um `implement X for T:` USA o nome, não o
declara: implementar trait do prelúdio não é sombra.

**68.4 O protocolo do `with` é a trait `Closeable`. ✅ decidido e feito.**
`trait Closeable: def close(self)` no prelúdio; `with` aceita qualquer
implementador — nominal, como todo uso de trait — e chama `close()` em toda
saída do bloco. Arquivo e buffer são as duas implementações que o runtime traz.
Regra que a implementação fixou: o cleanup roda mesmo com exceção PENDENTE (o
erro é retirado, o close roda em contexto limpo, o erro volta), e um close()
que lança PERDE para o erro original — a falha que começou é a que vale.

**68.5 O teste de tipo é `match type(x):`. ✅ decidido e feito.**
O dispositivo do P, trazido: os cases são os tipos que um `any` guarda, e dentro
de cada case o sujeito É aquele tipo — sem `as`, sem segunda checagem escrita à
mão. `is` continua sendo só identidade (22.2).

**68.6 Número de JSON segue a regra do Python. ✅ decidido e feito.**
Literal INTEIRO no texto vira int; ponto ou expoente vira float. Custo honesto,
assumido com os olhos abertos: o tipo passa a depender da GRAFIA no texto.

**68.7 Lambda continua só com o tipo do CONTEXTO. ✅ decidido (nada a fazer).**
A forma do Python; a mensagem de erro já ensina a anotar quem recebe.

**68.8 O pai colhe o erro COMPLETO do worker. ✅ decidido e feito.**
`w.error()` devolve o mesmo `Error` de um catch — mensagem e categoria —
reconstruído no heap do pai (34.3). Colher é o que silencia a linha automática
no stderr do join: quem colheu decide o que aquilo significa (37.4). Falha que
NINGUÉM colheu continua sendo reportada no join, porque silêncio esconderia.

**68.9 O `for` do P deixa de ser só `range`. ✅ pedido seu, feito.**
`for v in x` aceita, além do array dimensionado, qualquer valor cujo tipo
implemente `Iterable` (nominal, 68.1). A sema reescreve para um bloco próprio —
cursor ligado uma vez, `while has_next(): v = next()` — com toda chamada DIRETA
pela busca de método que o bloco `implement` preencheu. Zero vtable, zero
alocação, zero runtime; nenhum backend soube que existiu um `for`.

## Bateria 69 — Nulabilidade no P: a pergunta que mudou de resposta (2026-08-14)

Começou como "dá pra converter ponteiro em tipo nulável com cast?". A primeira
rodada decidiu o modelo estrito (`*T` não-nulo, `*T?` nulável com migração por
warning) — e a segunda rodada o DERRUBOU, quando ficou claro que no P o `T?` só
poderia existir para ponteiros: não seriam optionals, seria o `_Nullable` do
clang com outra roupa, o `?` significaria coisas diferentes nas duas línguas, e
o modo estrito brigaria com a natureza intrusiva do código de sistemas (next/
prev/callback são legitimamente nulos; campo não estreita; sem exceção não há
válvula). A resposta que ficou inverte a polaridade:

**69.1 `ref T` vira tipo de primeira classe no P. ✅ decidido e feito.**
O polo VERIFICADO é um tipo novo — referência não-nulável, liga-uma-vez,
auto-deref — generalizando o `ref` que os parâmetros já tinham. `*T` fica
nulável como C manda: zero migração, zero runtime, ABI intacta (é `T*` no C
emitido). v1 cobre LOCAL e RETORNO; campo de struct exige prova de
inicialização em toda construção e ficou para bateria futura.

**69.2 A entrada de `*T` em ref-land é só por narrowing. ✅ decidido e feito.**
`r: ref T = *p` compila sob `if p != None:` (ou o idioma `if p == None:
return`). Sem cast de volta: o tipo nunca mente. A prova é por função,
sensível a fluxo e conservadora — laço mata fato de quem o corpo escreve,
label/case mata tudo, `&x` desliga o rastreio da variável. Violação é
`-Wnullability`, erro por default e demovível (`-Wno-error=nullability`).

**69.3 Açúcar: só `??`. ✅ decidido e feito.**
`a ?? b` para ponteiros (avaliação única de `a`, `b` só no caminho None),
apertando mais que o ternário e menos que `or`. Rebaixado a temp içado + `?:`
— C89 puro, igual nos dois backends. `?.` ficou fora: `p?.x` com campo de
valor não tem resposta boa sem default.

**69.5 Só o polo `?`… virou só o polo `ref`.** (A pergunta original era
`?`/`!` de anotação; com a inversão, o não-nulo explícito É o `ref T`.)

**69.6 Parâmetro continua com o trio. ✅ decidido.** `ref v: T` é a única
grafia em parâmetro; `v: ref T` seria sinônimo eterno. `ref T` como tipo
aparece em local e retorno.

**69.7 `-Wnull-dereference` de fluxo, junto. ✅ decidido e feito.**
Os mesmos fatos que autorizam o `ref` acusam o contrário: deref de ponteiro
PROVADO None em todo caminho que chega nele. Só fato provado dispara — o
aviso nunca chuta.

**69.8 `ref` no pscript: estudo futuro.** Não-nulo já é o DEFAULT lá (`T?` é o
opt-in de nulo). O que sobraria — alias de valor (referência a campo de record
/ elemento de lista) — colide com o GC copiador: ponteiro para o interior de
objeto que o Cheney move exige derived pointers no coletor e no shadow stack.
Registrado como bateria futura, condicionado a resolver isso.

Gates: `tests/cases/41_ref.p` (bind em variável/campo, escrita através,
forward pro trio, retorno ref, `??` com e sem None) + 9 erros novos
`tests/errors/p_ref_*`, `p_coalesce_nonptr`, `p_null_deref` — nos três modos,
incluindo o roundtrip do printer P (que aprendeu a soletrar `ref T` e `??`).

## Bateria 72 — o que o porte cobrou (2026-08-15)

Perguntas que nasceram de portar o editor e de um teste que sondou o contrato
das traits. Todas respondidas por você.

**72.1 `ord`/`chr` ficam. ✅** São o par do Python e a única porta entre
caractere e codepoint — sem eles nenhum texto alcança uma interface que fala
número, que é toda a fronteira do 45.5. Lançam em entrada inválida (`ord` exige
exatamente um caractere; `chr` exige 0..0x10FFFF) e são UTF-8 dos dois lados.

**72.2 `"ab" in s` é SUBSTRING, como no Python. ✅** Não conflita com a 8.1:
uma string não é contêiner de outra coisa, então não há segunda leitura
possível para `needle in hay`.

**72.3 `for ch in s` itera CARACTERES. ✅** `len(s)` já são codepoints e `s[i]`
já é um caractere (3.4); iterar é o fecho disso. E não é só conforto: o
contorno por índice reconta o offset UTF-8 a cada acesso, então um laço sobre
string era quadrático — o laço anda pelos bytes UMA vez.

**72.4 Constantes de header C atravessam. ✅** Membro de `enum`, `static const`
escalar **e `#define` numérico**. É a mesma segurança do resto da fronteira
(nenhum endereço cruza), e sem isso toda biblioteca C de verdade obriga a
duplicar tabela de constantes — que é exatamente onde o erro por desatualização
mora (os keycodes do SDL, no porte, tiveram de ser redigitados).

**72.5 `implement` confere a ASSINATURA INTEIRA, e o P ganha tipo associado. ✅**
O checador olhava nome e aridade, então uma trait que promete `-> i64` podia
receber um impl que devolve outra coisa — e era esse buraco que fazia
`for v in it` render qualquer tipo. Fechar sem `type Item` (66.4, que o pscript
já tem) tornaria `Iterable` do P inútil para qualquer coisa que não fosse
`i64`; as duas coisas entram juntas.

**72.6 Atravessa a fronteira: `const` de tipo `record`, só LEITURA. ✅** O lado
P recebe `in ref T` (`const T*`). É imutável, vive o processo, não se move, não
morre e não tem lock a respeitar — e o compilador CONFERE no sítio da chamada
que o argumento é um nome que resolve para um `const` de record. Cobre tabela
de lookup e configuração fixa. `shared` fica de fora: entregar o endereço
furaria a promessa da 42.3 (todo acesso sob o mutex), e a forma com lock de
escopo (`with borrow(x) as r:`) fica registrada para se o caso aparecer.

**72.7 O próximo bloco é cancelamento + `race` + `timeout` (37.2/36.4/18.2).**
É o último pedaço da fase E: `t.cancel()` faz o próximo `await` DA TASK lançar
lá dentro, `race` fica com o primeiro e cancela o perdedor, e `timeout` é os
dois juntos.

# Estado da implementação (atualizado 2026-08-14)

O compilador do pscript vive em `selfhost/ps_*.p`, **junto com o frontend de C**
(`cfront.p`) — precedente do próprio repo: o binário `plangc` já hospedava duas
linguagens, agora hospeda três, e a extensão escolhe (50.3). O RUNTIME vive em
`pscript/runtime/` (16.4: fonte P compilado junto com o programa, não com o
compilador). Só o design fica solto em `pscript/`.

## O que é COMPARTILHADO com o P (e por quê)

A divisão não é "o que dá para reaproveitar": é **o que não codifica uma
linguagem**. Tudo abaixo é neutro e por isso é código único, nunca copiado.

| Compartilhado | Onde | O que foi preciso |
|---|---|---|
| Arena, StrBuf, diagnósticos, arquivos, caminhos, literais C | `util.p` | já era neutro |
| UTF-8 | `utf8.p` | já era neutro |
| **Máquina de lexing** — indentação, strings, números, posições, recuperação tolerante | `lexer.p` | ganhou um `LexSpec` (tabela de palavras + quais operadores estendidos existem). `lex()`/`lex_ex()` continuam sendo a porta do P; o pscript passa a SUA tabela |
| Vocabulário de tokens | `ast.ph` (`TokKind`) | é o lexer que emite; os tokens só do pscript estão marcados e o spec do P nunca os produz |
| `spell_tok` | `lexer.p` | `include` é palavra CONTEXTUAL nas duas: as duas remontam `<h>` a partir dos tokens |
| AST do P + backends C/QBE/P + **sema do P** | `ast.ph`, `backend_*.p`, `sema.p` | é o ALVO do lowering (49.1) — e a sema do P é o VERIFICADOR dele |

## O que é FORK (e por quê)

| Fork | Onde | Por quê |
|---|---|---|
| Tabela de palavras + extensões léxicas | `ps_lexer.p` | `record`/`shared`/`pass` são palavra aqui e identificador lá; f-string, aspas triplas, `??`, `?.`, `%*`, `**`, `//`, `@` não existem no P |
| Árvore | `ps_ast.ph` | 1.3: o AST do P não ganha nó por causa do pscript. Um arquivo é um PROGRAMA (`PsModule.main`), os tipos são o reticulado do pscript, `record` e `struct` são coisas diferentes |
| Gramática | `ps_parser.p` | descida recursiva e disciplina de INDENT/DEDENT iguais porque funcionam; a gramática é outra |
| Semântica | `ps_sema.p` | o P deixa a checagem funda para o compilador C; o pscript não pode — tipagem estática com inferência e semântica de execução própria |
| Lowering | `ps_lower.p` | onde o runtime aparece: `ctx`, checagem de exceção, e a escolha entre `ps_add` e um `+` cru |

## Pronto e travado por teste

**Front end.** Lexer compartilhado parametrizado (o P saiu byte-idêntico). Parser
completo o bastante para os DOIS programas de validação: `vec3.psc` e
`smallpt.psc` (29 declarações, 24 statements de topo) passam inteiros. Cobre
record/struct com `implements` e métodos, enum, `def`/`async def`/`static def`,
parâmetros `in`/default/`*args`, `shared`, `const` de módulo, import/from/as,
`include <h>`, if/elif/else, while, `for i, s in`, match com `case _`,
try/catch/finally, with/as, defer, unsafe, nogc, assert, global/nonlocal, raise,
tuplas, fatias `[i:j:k]`, `T?` e `T[N]` compondo nas duas ordens, `??`, `?.`,
`?[`, `**`, `//`, `%*`/`%+`/`%-`, comprehension, dict/set, lambda, walrus, `as`,
f-string, spawn/await, decoradores e `from x import a as b`.

**Fatia vertical de ponta a ponta (50.4), rodando nos TRÊS modos** (C, QBE, C89):
`.psc` → lexer → parser → sema → lowering → AST do P → sema do P → backend →
binário que roda. O que já compila e executa:

- `print`, `str`/`int`/`float`/`bool`, `len` de string;
- aritmética com a semântica do pscript, e ela está certa contra o Python de
  verdade: `7/2 = 3.5` (39.1), `-7//2 = -4` (piso), `-7%3 = 2` (sinal do
  divisor), `2**10 = 1024`, estouro de int LANÇA (7.2), divisão por zero LANÇA
  (32.2/47.2), e `%+`/`%-`/`%*` dão a volta (54.1) — emitidos por unsigned,
  porque estouro com sinal é indefinido em C e o operador cujo propósito é dar a
  volta não pode ser a única operação que o alvo pode assumir que nunca acontece;
- `repr` de float como o do Python: a forma MAIS CURTA que relê igual
  (`0.1 + 0.2` sai `0.30000000000000004`);
- concatenação e comparação de string por conteúdo;
- if/elif/else, while, break/continue, funções com parâmetros e retorno,
  variáveis de módulo, `const`, `global`, `nonlocal`;
- exceção de ponta a ponta: `ps_div` lança, o check do statement vê, toda chamada
  posterior vira no-op, e o ponto de entrada vira mensagem com arquivo:linha e
  status de saída 1.

**Runtime v0** (`pscript/runtime/psrt.{ph,p}`): alocador bump (14.3, já a forma
que o copiador de Cheney quer), `PsCtx` com TODOS os campos que a 49.3 pede
(heap, topo da shadow stack, flag de exceção) mesmo os que ainda ninguém lê,
`str` INLINE de uma alocação só (51.2), tipo único de erro com metadados (15.2),
e a aritmética que checa. Sem coletor ainda: heap cheio é falha barulhenta, de
propósito.

**Suíte `pscript`** em `tests/run.sh`, dentro de `make test` e `make verify`: os
`.psc` válidos têm de passar pelo front end (`--parse-only`), os inválidos têm de
falhar com a mensagem certa, e os programas de `tests/pscript/run/` são
compilados, linkados com o runtime e EXECUTADOS — saída combinada e status de
saída comparados.

**Módulos com namespace de verdade (41.3), implementados por RENOMEAÇÃO.**
`import geom`, `import geom as g`, `from geom import Vec2 [as V]`, tipo
qualificado (`g.Kind`) e `private` privando o nome do módulo (44.4, grafia da 118). A
visibilidade é a decidida na 41.3 — a do Python: um nome de outro módulo só
existe aqui se o qualificador o nomear ou o `from` o trouxer. Como o alvo é uma
unidade de tradução só, que não tem namespace nenhum, a resolução é feita em
compilação: toda declaração de um módulo importado recebe um nome global único
(`geom__area`), e a referência qualificada é reescrita para ele enquanto os
nomes ainda estão sendo resolvidos. Dois módulos podem declarar `area` cada um.

É o único ponto em que o pscript responde diferente do P de propósito: a 42.4
fez do qualificador do P uma GRAFIA CONFERIDA sobre um conjunto plano de nomes,
porque o P é a linguagem que conversa com o C — lá o nome já É global e renomear
quebraria justamente o que ela serve.

**A leva de 2026-08-15 (bateria 70 do PLAN):** `nogc:` com orçamento,
decoradores (inclusive com argumentos), `def` largo com estreitamento checado,
`shared dict` (a tabela ETS), `??=`, defaults por chamada e argumentos
nomeados, splat `f(*xs)`, repr derivado, vistas tipadas do buffer, `interval`
com tick que coalesce, `pack`/`unpack` com a ordem de bytes por parâmetro,
`embed`/`embed_bytes`, e `render("x.tpl")` (template sem header). No caminho
caíram três defeitos de verdade: `d[k] += v` descartava a operação,
`print(f(), x)` lia `x` antes de `f()`, e o tipo esperado vazava para dentro de
um operador.

## O que escrever o compilador descobriu

Três correções vieram de escrever o código, não de reler o documento:

- **`in` é escrito no SÍTIO DA CHAMADA** (`intersect_sphere(in s, in r)`), como
  no P — eu tinha assumido que era só propriedade do parâmetro.
- **`match` é palavra-chave LEVE**: depois de um ponto é nome de membro
  (`re.match(...)`). A suavidade é posicional — nada depois de um `.` começa um
  statement.
- **Escopo**: virou a bateria 64.

E dois bugs do P que só apareceram porque o pscript passou a gerar P:

- o backend C emitia `(a < 0) != (b < 0)` sem parênteses, e gcc/clang avisam sob
  `-Wparentheses` — código gerado que só compila com aviso desligado não serve;
- `nonlocal x` seguido de `x: T = e` (a primeira atribuição TIPADA) içava uma
  declaração inferida e ainda emitia a declarada dentro do bloco, uma sombra.

## Próximo passo, na ordem

O tracker vivo é `pscript/PLAN.md`: fases, o que está `[x]`, o que falta, e a
receita de verificação e do seed. Este documento continua sendo o que DECIDE; o
plano é o que registra até onde a implementação chegou.

## BATERIA 1 — Identidade

O que a linguagem é, antes de como ela funciona. **RESPONDIDA** — ver acima.

**1.1 Para que serve o pscript?** (pode ser mais de um)
- (a) Scriptar o pstudio — plugins, macros, configuração do editor.
- (b) Linguagem de uso geral, autônoma, que compete com Python para tarefas do
  dia a dia.
- (c) Camada de prototipagem: escreve rápido em pscript, reescreve em P o que
  virar quente.
- (d) Linguagem embutível em programas P quaisquer, como Lua é para C.

> Consequência: (a) permite recortar muita coisa (sem sistema de pacotes, sem
> stdlib larga). (b) obriga stdlib, e o custo real está aí, não no compilador.
> (c) exige que os dois lados conversem com facilidade. (d) obriga um contrato de
> embutir — quem inicializa o runtime, quem é dono da memória — que é a decisão
> mais restritiva das quatro.

**1.2 Quem escreve pscript?**
- (a) Você e mais ninguém.
- (b) Quem usa o pstudio, sem necessariamente saber P.
- (c) Público amplo, com expectativa de documentação e estabilidade.

> Consequência: (a) libera quebrar a linguagem quando conveniente. (c) obriga
> versionar e obriga mensagens de erro pensadas para quem não conhece o interior.

**1.3 Qual é a relação com o P?**
- (a) pscript é uma linguagem separada que por acaso compila usando o mesmo
  compilador.
- (b) pscript é o P com açúcar dinâmico — mesmo arquivo, mesmo módulo, mesma
  sintaxe, e você escolhe por declaração se aquilo é dinâmico.
- (c) Duas linguagens, dois arquivos, interop explícito.

> Consequência: (b) é o mais ambicioso e o que menos duplica; também é o que
> arrisca fazer o P ficar mais complicado para quem só quer P. (c) mantém o P
> intacto ao preço de fronteira.

**1.4 O que o pscript tem que o P não tem, e que é a razão dele existir?**
Pergunta aberta, sem opções. Do que já apareceu na conversa, os candidatos são:
não declarar tipo, objeto universal, coleta de lixo, fechamento com captura.
Falta você dizer quais desses são *o ponto* e se tem outro.

**1.5 Nome e extensão.** "pscript" fica? A extensão `.ps` colide com PostScript.

---

## BATERIA 2 — A forma do programa

**2.1 Como é o hello world?**
- (a) `print("oi")` solto no arquivo, executa de cima para baixo.
- (b) Precisa de `def main()`, como P.
- (c) Os dois: código solto no topo é o corpo do `main` implícito.

**2.2 Sintaxe por indentação, como P?**
- (a) Sim, e reusa o INDENT/DEDENT do lexer que já existe.
- (b) Chaves.
- (c) Outra coisa.

**2.3 Módulos.**
- (a) Reusa `import`/`include` do P como está.
- (b) Sistema próprio: pacotes, caminho de busca, `__init__`.
- (c) Sem módulos no começo — um arquivo só.

**2.4 Como se executa?**
- (a) Só compilado: `pscript x -o bin`, roda o binário.
- (b) Compilado + um comando que compila num temporário e executa direto.
- (c) Interpretado de verdade, com REPL e `eval`.

> Consequência de (c): é um segundo motor de execução além do compilador, e
> `eval` obriga a linguagem a permanecer inteiramente dinâmica para sempre. Se
> `eval` não existe, muita coisa pode ser resolvida em tempo de compilação.

**2.5 Interop.** Marque o que precisa existir:
- pscript chama função de P
- pscript chama libc direto (`include <stdio.h>`)
- P chama função de pscript
- pscript e P no mesmo arquivo

---

## BATERIA 3 — Tipagem

**3.1 Modelo.**
- (a) Dinâmica: nenhum tipo se escreve, todo valor carrega o seu.
- (b) Estática com inferência: nenhum tipo se escreve *na maioria dos casos*, mas
  cada variável tem um tipo fixo que o compilador descobriu.
- (c) Gradual: anotar é opcional; o que não está anotado é dinâmico.

> Consequência: em (a) todo inteiro é objeto no heap, e o desempenho é o de
> Python. Em (b) `x = 1` é um `i64` em registrador, mas `x = 1` seguido de
> `x = "a"` é erro. Em (c) você tem os dois desempenhos e duas disciplinas de
> tipo no mesmo compilador, que é o custo de implementação mais alto dos três.

**3.2 Se houver dinamismo, ele é opt-in ou opt-out?**
- (a) Tudo é dinâmico salvo onde você anota.
- (b) Tudo é estático salvo onde você pede um tipo universal.

**3.3 Conversão implícita.** `1 + "2"` é:
- (a) Erro.
- (b) `3` (string vira número, como PHP).
- (c) `"12"` (número vira string, como JavaScript).

**3.4 `None` é um tipo separado?** Uma variável de inteiro pode receber `None`,
ou isso é erro?

---

## BATERIA 4 — Dados

**4.1 Quais agregados a linguagem tem?**
- (a) Um só, universal: chave inteira contígua *é* a lista (PHP).
- (b) Dois: lista e dicionário, distintos.
- (c) Três ou mais: lista, dicionário, e um registro/objeto de campos nomeados.

> Consequência de (a): não existe resposta rápida para "isto é lista ou mapa?", o
> que aparece em serialização e em iteração. Consequência de (b)/(c): mais tipos
> para o usuário conhecer, e a pergunta 4.2 passa a ter peso.

**4.2 `o.campo` e `o["campo"]` são a mesma coisa?**
- (a) Sim: atributo é entrada do agregado (JavaScript, PHP).
- (b) Não: atributo e item vivem em espaços diferentes (Python).

> Consequência de (a): você não pode ter simultaneamente uma chave `"keys"` e um
> método `keys()`. Consequência de (b): dois mecanismos de acesso para explicar.

**4.3 Que tipos podem ser chave de dicionário?**
- (a) Só inteiro e string.
- (b) Qualquer valor imutável.
- (c) Qualquer valor, com igualdade e hash definíveis pelo usuário.

> Consequência de (c): a linguagem passa a ter protocolo (`__hash__`, `__eq__`),
> e todo tipo precisa responder por isso.

**4.4 Iteração de dicionário preserva ordem de inserção?** **RESPONDIDA na
bateria 91: (a), e é GARANTIA da linguagem** — implementada com o dict compacto
do CPython (índices para um vetor denso na ordem de chegada).
- (a) Sim, e é garantia da linguagem.
- (b) Sim, mas é detalhe de implementação — não prometido.
- (c) Não.

**4.5 `==` entre dois agregados compara conteúdo ou identidade?**
E existe um operador separado para o outro (`is`)?

**4.6 Strings são imutáveis?**

**4.7 `s[3]` de uma string devolve o quarto byte ou o quarto caractere?**
> Consequência: caractere em UTF-8 é O(n) para indexar. As saídas conhecidas são:
> indexar byte e ter um iterador de caracteres (Go, Rust); indexar caractere com
> cache de posição; ou guardar tudo em UTF-32 e pagar 4x de memória.

**4.8 Inteiro.**
- (a) 64 bits, e estourar dá a volta.
- (b) 64 bits, e estourar é erro.
- (c) Cresce sem limite (bignum), como Python.

> Consequência de (c): todo inteiro passa a ser objeto no heap, o que interage
> diretamente com a 3.1.

---

## BATERIA 5 — Objetos e comportamento

**5.1 Existe classe?**
- (a) Não: só o agregado e funções. Comportamento é função que recebe o objeto.
- (b) Sim, como forma de declarar um conjunto de campos e métodos, com herança
  simples.
- (c) Sim, com o modelo completo: herança múltipla, ordem de resolução,
  metaclasse, descritor.

**5.2 De onde vem o método?**
- (a) Está no próprio objeto, como qualquer outro campo.
- (b) Está num objeto de tipo compartilhado por todas as instâncias.
- (c) Protótipo: o objeto aponta para outro objeto onde se procura o que falta.

> Consequência: (a) é o mais simples e é a resposta que casa com 4.2(a); também
> é o que gasta memória por instância. (b) é o que permite muitas instâncias
> baratas.

**5.3 Função é valor de primeira classe?** Pode ser guardada em variável, passada,
devolvida, posta dentro de um agregado?

**5.4 Fechamento: uma função aninhada pode ler variável da função de fora?**
- (a) Não.
- (b) Sim, por valor: uma fotografia no momento em que a função é criada.
- (c) Sim, por referência: se a de fora mudar, a de dentro vê a mudança.

> Consequência de (c): variável capturada não pode viver na pilha, precisa ir para
> o heap. Isso exige uma passada no compilador que descobre quais locais são
> capturados e os promove.

**5.5 Uma função aninhada pode *atribuir* a variável da função de fora?**
Se sim, precisa de palavra para isso (o `nonlocal` do Python)?

**5.6 Sobrecarga de operador.** `a + b` para tipo de usuário existe?

---

## BATERIA 6 — Memória

**6.1 Quem libera memória?**
- (a) O usuário, com `init`/`deinit` manuais, como o P e a STL de hoje.
- (b) Contagem de referência: libera na hora que o último dono solta.
- (c) Coletor por rastreamento: periodicamente descobre o que é inalcançável.
- (d) Contagem de referência mais um coletor de ciclos (o que o CPython faz).

> Consequência de (b): objeto que aponta para si mesmo, direta ou
> indiretamente, nunca é liberado — e num god object `o.pai = p; p.filho = o` é
> uso normal, não patológico. Consequência de (c): a liberação não é no ponto
> onde o objeto deixou de ser usado, então recurso que precisa fechar na hora
> (arquivo, socket) precisa de outro mecanismo. Consequência de (d): você paga o
> custo de (b) em toda atribuição *e* escreve o coletor de (c).

**6.2 Se houver coletor, como ele descobre o que está vivo na pilha?**
- (a) O compilador emite, em cada função, um registro explícito dos valores que
  aquela função está segurando.
- (b) O coletor varre a pilha de C inteira e trata qualquer coisa que pareça um
  ponteiro como se fosse (conservador, estilo Boehm).
- (c) O compilador gera um mapa preciso por ponto de chamada.

> Consequência: (a) custa instruções em toda função que aloca, mas é portátil e
> explícito. (b) não custa nada no código gerado, mas precisa saber onde a pilha
> começa e termina em cada plataforma, e pode manter vivo o que já morreu. (c) é o
> mais rápido em execução e o mais caro de implementar — e teria que ser feito
> duas vezes, uma por backend.

**6.3 Liberação determinística de recurso.** Um arquivo aberto precisa fechar num
ponto previsível. Como?
- (a) `with arquivo(...)` que baixa para o `defer` que o P já tem.
- (b) Método `__del__` chamado quando o objeto é coletado.
- (c) Fechar na mão.

> Consequência de (b) junto com 6.1(c): código de usuário roda durante a coleta,
> objeto pode ressuscitar durante a finalização, e a ordem entre finalizadores de
> objetos que se referenciam é indefinida.

**6.4 Vale colecionar programa que vaza?** Se o programa é curto (script), nunca
liberar é uma opção legítima para o v0.1?

---

## BATERIA 7 — Erros

**7.1 Modelo.**
- (a) Erro é valor de retorno, e quem chama verifica.
- (b) Uma função aborta a execução até quem estiver disposto a capturar
  (`error`/`pcall` do Lua): um mecanismo, sem hierarquia de tipos de erro.
- (c) Exceções com classes, hierarquia, `try`/`except`/`finally`.

**7.2 `d["chave_que_nao_existe"]` faz o que?**
- (a) Erro.
- (b) Devolve `None`.
- (c) Aborta o programa.

> Consequência de (b): o defeito aparece longe da causa, quando o `None`
> finalmente é usado.

**7.3 Erro de programação e erro de operação são a mesma coisa?** Divisão por
zero, índice fora, cast inválido — mesma categoria que "arquivo não existe", ou
categoria separada que sempre aborta e não se captura?

---

## BATERIA 8 — Escopo do v0.1 e implementação

**8.1 O que precisa rodar para o v0.1 estar pronto?** Escolha o menor programa
que você consideraria prova de vida.

**8.2 O que fica explicitamente de fora do v0.1?** Candidatos: classe, gerador
(`yield`), `async`, pattern matching, comprehension, decorador, f-string,
desempacotamento, sobrecarga de operador, sistema de pacotes, stdlib.

**8.3 Onde vive o código.** `pscript/` no mesmo repo? Este arquivo vai para lá?

**8.4 Como se prova que funciona.** O oráculo de identidade por byte não serve —
o C gerado é novo, não é refatoração de algo que já existia. O que serve como
prova?

**8.5 Vale reler o runtime C do jaketa?** A lógica dele foi portada para a STL em
P; a pergunta é se ainda tem coisa lá que interessa.

## Bateria 87 — O que pode ser esperado, e o que `await` NÃO faz (2026-08-17)

Levantada por você ao escolher os corpora: *"temos que discutir se vale a pena
ou não tornar as Tasks aqui thenable ou não"*.

**87.1 O aguardável é um TRAIT, no formato do `Future` do Rust — não o thenable
do JS.** `await` aceita `Task<T>` e qualquer tipo que implemente
`Awaitable<T>`:

```python
trait Awaitable<T>:
    def poll(self, w: Waker) -> Poll<T>

struct Pooled implements Awaitable<Conn>:
    def poll(self, w: Waker) -> Poll<Conn>:
        ...

c = await pool.get()
```

> **Por quê essa forma e não a do JS.** O `.then` não é um recurso de design: é
> uma cicatriz de interoperabilidade. Promise nasceu tendo que conviver com
> jQuery Deferred e Q, e a saída foi tipagem por pato — "se tem `.then`, é
> promessa". O preço aparece até hoje: um objeto que por acaso tem um campo
> `then` vira aguardável sem querer; `Promise<Promise<T>>` não existe porque
> tudo achata sozinho; e `Promise.resolve(thenable)` custa ticks a mais que
> ninguém consegue prever. Nada disso tem desculpa histórica aqui. A bateria 66
> já nos deu traits para exatamente esta necessidade — um protocolo NOMEADO,
> monomorfizado, com custo zero — e usá-los é o que mantém a promessa de que
> quem escreve o tipo sabe o que ele faz.

**87.2 `await` sobre `Task<Task<T>>` NÃO achata.** Devolve `Task<T>`; para
chegar ao `T`, dois `await`. Achatar seria o tipo mentindo: a assinatura diz
`Task<Task<T>>` e chega `T`. É também a razão pela qual em JS é IMPOSSÍVEL ter
uma promessa de promessa — uma limitação real que estaríamos importando de
graça.

**Estado (2026-08-20).** A **87.2 está VALENDO e agora tem portão**: conferido
que `await` sobre `Task<Task<int>>` devolve `Task<int>` e que dois níveis a mais
também não achatam — `tests/pscript/run/task_nest.psc`. É teste para uma
propriedade que a implementação cumpre por NÃO fazer nada, que é justamente o
tipo de coisa que começa a falhar em silêncio no dia em que alguém ensina o
`await` a ser prestativo.

A **87.1 continua decidida e não implementada**, e o `await` só aceita `Task<T>`
— o subconjunto correto, porque o trait é aditivo e nada do que existe muda de
significado quando ele chegar. O que falta não é digitar o trait: é decidir a
forma do `Poll<T>` e do `Waker` **neste** escalonador (o `poll` é chamado por
quem, e com que garantia de que o acordar não perde um evento), e isso é
bateria, não tarefa.

## Bateria 88 — Os corpora de fora, e o que eles acharam (2026-08-17)

Pedido seu: *"sera que conseguimos baixar uns programas de testes em javascript
e portar para aqui? eu digo pacote inteiro de testagem de runtime JS pra ca…
alem disso veja se implementamos toda a especificacao"*.

**88.1 O que porta, e o que não porta.** Medido antes de escolher:

| corpus | tamanho | licença | porta? |
|---|---|---|---|
| llhttp `test/**.md` | 212 casos úteis | MIT | **sim, direto** |
| JSONTestSuite | 318 | MIT | **sim, direto** |
| WPT `urltestdata.json` | 891 (267 devem falhar) | BSD-3 | sim, com um parser de URL |
| test262 | 53.892; `Promise/` = 732 | BSD-3 | **quase nada** |
| node `test/parallel` | 4.722 | MIT | **quase nada** |

O que o test262 mede é o **modelo de objetos do JS** (`Promise.allSettled.call(
NotPromise, …)`, atributos de `.name`, `Symbol.species`). Dos 732 do `Promise/`,
só 115 não citam `Symbol`/`prototype`/`species`/thenable — e mesmo esses são
`.then()`, que não existe aqui por decisão (87.1). Os 24 `test-promise-*` do
node são sobre o *warning de unhandled rejection* do node, não sobre semântica.
Registrado para não se reabrir a discussão sem caso novo.

> **Feito em 2026-08-20, e o "quase nada" virou 25 propriedades.** O que não
> porta é o CORPUS; o que ele mede porta. As perguntas que os 732 casos do
> `Promise/` existem para fixar foram reescritas em `await` como três pares de
> oráculo (`tests/oracle/js/promise`, `turns`, `settle`) — a ordem em que o
> `all` responde contra a ordem em que as tasks terminaram, o `allSettled`
> mantendo a ordem da entrada com as falhas no lugar, o `any` ignorando as
> falhas anteriores ao primeiro sucesso, o revezamento de várias tasks prontas,
> a task criada DENTRO de outra, o `await` que cede mesmo no que já acabou. E
> duas divergências impressas de propósito: o nosso `race` cancela os
> perdedores, e o desempate entre duas falhas simultâneas não foi decidido —
> então nenhuma linha pergunta por ele.

**88.2 Os três corpora entram, com portão TOTAL** (decisão sua), no molde do
`tests/clang-compare.sh`: uma divergência sem explicação reprova. O que
sabidamente não fazemos vive em `tests/conformance/<corpus>.skips`, uma linha
por caso com o motivo — contado e impresso, nunca dobrado no placar. Um skip
cujo caso passa a concordar é reportado como STALE.

**88.3 O parser de URL é PORTADO, não escrito do zero** (decisão sua). A fonte é
o `whatwg-url` (MIT, jsdom), que é transcrição direta da especificação WHATWG —
e é a especificação que o corpus mede. O `urllib.parse` do Python foi descartado
como fonte: implementa a RFC 3986, que é OUTRA coisa, e discorda desta sobre
barra invertida, sobre quantas barras `http:/example.com` precisa, sobre letra
de unidade do Windows em `file:` e sobre IDNA.

**88.4 O que os corpora acharam.** Esta é a razão de existirem:

- **JSON**: `\uXXXX` NÃO ERA DECODIFICADO (`"é"` voltava como as quatro
  letras `u00e9`); o conjunto de escapes era aberto (`\x` lia como `x`); byte de
  controle cru dentro de string era aceito; a gramática de número era o
  `strtod`, que fala C e não JSON (`01`, `.5`, `2.`, `0x1F`, `NaN`, `Infinity`
  passavam); documento TRUNCADO virava valor (`[` sozinho devolvia lista vazia);
  e não havia limite de profundidade, então cem mil `[` era um segfault
  alcançável a partir de uma string de terceiro. **318/318 depois.**
- **URL**: dígito do Punycode errado (`xn--n3h` saía `xn--n~h`); `^` no conjunto
  de escape errado; limite do número IPv4 no lugar errado (`0x100000000` lia
  como NOME de domínio em vez de endereço fora de faixa). **890/891 depois**, o
  restante é a tabela NFKC dos símbolos matemáticos.

**88.5 O modo de ESTRESSE do coletor, e a família de bugs que ele revelou.** O
achado maior não veio de um corpus: veio de rodar os corpora. Um coletor que
COPIA tem um jeito só de estar errado — alguém segurou um ponteiro através de um
ponto seguro sem pôr na pilha de sombra. O objeto move, o portador fica com o
endereço velho, e o que ele lê a partir dali é o que o alocador entregou àquela
memória depois.

O perigo não é o conserto (duas linhas cada) — é ser INVISÍVEL: com o limiar de
2 MiB um programa pequeno nunca coleta, então a suíte inteira fica verde com o
bug ali. Ele aparece depois, numa entrada maior, como resposta errada longe da
causa.

`PSCRIPT_GC_STRESS=N` coleta a cada N-ésimo ponto seguro e **envenena a
from-space com 0xDD em vez de liberá-la** (janela de 16 blocos, senão a memória
não tem fim). Assim um ponteiro velho é ou `0xDDDDDDDDDDDDDDDD` — falha imediata
na linha culpada — ou `0xDDDDDDDD`, que não é tag, tamanho nem estado válido. É
o `--stress-gc` do V8 e o `gc.set_threshold(1)` do CPython, pela mesma razão.

Os defeitos que ele achou, todos reais, todos consertados:

  1. **cada ESTADO de uma máquina async é um bloco** e não tinha moldura própria:
     um temporário coletado nascido ali (o iterável de um `for`) nunca era raiz;
  2. **`ps_task_wait` cedia a vez ANTES de registrar `t`** — o escalonador rodava,
     alocava, coletava, e a função lia o endereço que a task tinha antes. Parecia
     deadlock e era ponteiro pendurado;
  3. **a variável de iteração de um `for` não era raiz** — o corpo do laço era
     montado fora da moldura;
  4. **os argumentos de uma chamada não eram raízes**: o ponto seguro pode cair
     DENTRO de um argumento, e os já avaliados vivem em temporários de C. Pior:
     C não especifica a ordem, então qual deles está podre depende do compilador
     e do nível de otimização. A forma normal segura é avaliar todos primeiro,
     em ordem, para variáveis que a pilha de sombra segura;
  5. **o mesmo para o construtor de `struct`** e para os **dois lados de um
     operador binário** (`s + f(x)` carrega `s`, `f` coleta, `s` está podre);
  6. **`nonlocal x` registrava a variável na moldura do BLOCO** onde ela era
     primeiro atribuída, e o P depois iça a declaração para o escopo da FUNÇÃO —
     a moldura era estourada no fim do bloco e o resto do programa lia lixo;
  7. **`ps_forward` copiava DUAS VEZES** um objeto já em to-space, e a to-space é
     dimensionada para uma cópia de tudo — cópias a mais passam do fim;
  8. **um `defer`/`with`/`finally` de TOPO rodava depois da destruição do
     contexto.** `ps_ctx_done` era a expressão de retorno do ponto de entrada, e
     o P avalia a expressão de retorno ANTES dos defers do bloco (SPECS §8, e
     tem de ser assim — o valor precisa existir antes da limpeza que pode
     sobrescrever de onde ele veio). Então a sequência era *libera o mundo* e só
     então `print("bye")`. Agora `ps_ctx_done` só apura o status e a liberação é
     `ps_ctx_free`, registrada como o PRIMEIRO defer do ponto de entrada — e
     defers rodam LIFO, então ela é a última coisa a acontecer no processo;
  9. **os locais de um `try` não eram raízes**: as declarações do corpo são
     içadas para o topo do bloco do try (têm de ser — o catch e o finally as
     leem, e o corpo roda sob guarda), e içar tirou-as da moldura do corpo para
     um bloco que não tinha nenhuma;
 10. **a exceção pendente sumia durante a limpeza de um `with`.** O `defer` tira
     o erro do contexto para fechar num contexto limpo e o põe de volta; entre
     as duas coisas ele vive num temporário de C, o `close()` aloca, o coletor
     não enxerga o erro em lugar nenhum, e o que volta para `ctx->exc` é o
     endereço que ele tinha antes;
 11. **NENHUMA das cinco combinadoras** (`gather`, `gather_settled`, `race`,
     `first_ok`, `gather_map`) registrava moldura. São as funções do runtime
     MAIS expostas ao coletor — elas dirigem o escalonador, o escalonador roda o
     passo de outra task, e esse passo aloca. A lista de tasks recebida e a
     lista sendo construída atravessavam tudo isso em temporários de C. (O
     `base` relido dentro do laço do `gather` mostra que o perigo era meio
     conhecido; a metade que faltava é que a própria lista também anda.)

 12. **a VISTA de um buffer (18.3) mandava o coletor mover o buffer.** Um
     `PsBuffer` é malloc'ado de propósito — cabeçalho e bytes — porque outra
     thread segura o ponteiro e um coletor que MOVE não pode ser dono do que
     outra thread está lendo (19.4/52.3), e o próprio `case PS_TY_BUFFER` do
     coletor diz isso. Mas o caso da lista encaminhava `l->owner` assim mesmo:
     copiava um cabeçalho malloc'ado para dentro do heap coletado e apontava a
     vista para a cópia — uma cópia que a coleta seguinte descartava, porque
     nada no heap a reivindica. A vista sobrevivia ao buffer por uma coleta;
 13. **o próprio modo de estresse tinha um defeito**, e no pior lugar possível:
     o cemitério era estático do MÓDULO, isto é, compartilhado entre threads.
     Cada worker tem heap e coletor próprios (18.1), então dois coletores
     empilhavam e despejavam da mesma lista ligada ao mesmo tempo — que a glibc
     reporta como `double free or corruption`. Agora ele mora no CONTEXTO, como
     os blocos.

 14. **`in` sobre armazenamento COLETADO não pode ser um empréstimo.** Este é o
     mais fundo, e o único que não quebra nada — ele responde ERRADO. `in` é
     açúcar sobre ponteiro (55.4), e um ponteiro para um elemento de `list` ou
     para um campo de um frame `async` é um ponteiro INTERIOR a um objeto que o
     coletor move. O callee tem statements, statements têm pontos seguros, e um
     ponto seguro move o objeto — então o empréstimo lê os bytes onde o valor
     ESTAVA. Nada estoura: os bytes continuam mapeados e continuam parecendo um
     record.

     Como apareceu: `smallpt_full` renderiza a MESMA imagem duas vezes com o
     mesmo coletor e uma imagem DIFERENTE para cada frequência de coleta —
     `acc.add(d)` dentro de um `async def` vira `Vec_add(&__fr->acc, …)`, e o
     frame anda. Cinco pixels de uma linha, em silêncio. O `smallpt_core`, que é
     a mesma matemática numa função comum, é estável — foi essa diferença que
     apontou para o frame.

     A regra agora: empresta-se DIRETO só de onde não anda — um local, um
     caminho de campos ancorado num local, um temporário que a baixada acabou de
     materializar, ou um ponteiro que outro já possui (`*p`, que é o que um
     parâmetro `in` reemprestado é). Todo o resto é COPIADO para um local
     primeiro. O preço é uma cópia onde `in` prometia nenhuma, e é o preço
     honesto: o que `in` prometeu emprestar não fica onde estava.

**Um teste que estava medindo a coisa errada:** `interval.psc` tomava o relógio
DEPOIS de criar o `interval`, o que assume que criar é de graça. Sob estresse não
é — uma coleta cai entre as duas linhas e come parte do primeiro período. O teste
agora mede a partir de antes, que é o que ele sempre quis dizer.

Gate: `bash tests/gc-stress.sh`.

**88.5b O llhttp FECHADO: 202/202, dez pulados com motivo.** O corpus arrancou
doze portas de request smuggling que estavam abertas — CR solto e LF solto aceitos
como fim de linha, `obs-fold`, nome de cabeçalho não conferido como token, valor
com caractere de controle, `Content-Length` sem limite, as três regras de
Transfer-Encoding da 6.1, linha de status frouxa, 1xx/204/304 decidindo depois do
Transfer-Encoding (um `101` ganhava corpo, isto é, o primeiro pacote do protocolo
seguinte), `CONNECT` ganhando o primeiro pacote do túnel, alvo sem conjunto de
caracteres, extensão de chunk sem gramática, e o preâmbulo do HTTP/2 lido como
pedido comum. A lista completa está no PLAN.

Duas reversões de decisão que o corpus forçou, as duas registradas onde estavam
escritas: **o LF solto passa a ser recusado** (o arquivo dizia "todo servidor
aceita", o que era verdade e irrelevante — o argumento contra o CR solto é palavra
por palavra o argumento contra o LF solto), e **`obs-fold` deixa de continuar
cabeçalho** (RFC 9112 §5.2).

E três erros de modelagem MEUS no arreio, que é o outro lado do exercício: o log
do llhttp não escapa aspas; ele imprime span de espaço em branco por NOME
(`span[body]=lf`); e `code=22/23` é `HPE_PAUSED_UPGRADE` — **pausa não é recusa**,
é o parser entregando o socket, e lê-la como erro transformava quinze parses bem
sucedidos em falhas.

Os dez que ficam de fora são de três tipos, nenhum deles defeito: o llhttp lê
TRÊS protocolos (HTTP, RTSP e ICE) e mantém tabela de qual método pertence a qual,
enquanto a RFC 9110 §9 diz que método é token e a lista é extensível; ele expõe uma
API de `reset` que duas fixtures medem; e ele é máquina byte a byte, então numa
entrada TRUNCADA já recusou onde um parser bufferizado por linha ainda está lendo —
ele disse não e nós não dissemos nada, e nenhum dos dois disse sim.

**88.6 Os oráculos, e o que eles cobraram de imediato.** `tests/oracle/run.sh`
roda os nossos programas DUAS VEZES — aqui e no intérprete cujo comportamento
dissemos que íamos copiar — e diffa. `python3` para a semântica da linguagem,
`node` para o modelo de runtime, no molde do `clang-compare.sh`.

Na primeira execução faltavam `abs`, `min`, `max`, `str.replace`, `str.join` e
`"ab" * 3` — todos implementados. E dois achados de ordem:

  * **prazos iguais acordavam em LIFO.** O timer era empilhado na cabeça da lista
    e a lista é percorrida em ordem quando o relógio dispara, então duas tasks em
    `await sleep(0)` alternavam de trás para frente. O JS acorda na ordem de
    registro, e qualquer laço que valha a pena imitar também. Agora é acrescentado
    no fim.
  * **`f() + g()` avaliava a esquerda duas vezes** — ver o PLAN, achado pelo
    placar de desempenho e não pelo oráculo, mas da mesma família: uma coisa que
    nenhum teste de saída pega porque a resposta não muda.

## Bateria 97 — o que um contêiner MOSTRA (2026-08-20)

Pergunta que a varredura achou aberta: `print([1, 2, 3])` era erro, e a 44.3
tinha decidido o repr derivado de `struct`/`record`/`enum` sem falar de
contêiner.

**97.1 Como o Python, com aspas dentro.** `[1, 2, 3]`, `{'a': 1}`, `{1, 2}`, e
uma string DENTRO do contêiner sai com aspas — `['a', 'b']`, não `[a, b]`. O
motivo de escolher a forma que "volta como código" é que ela é a única que não
mente: `['a, b']` e `['a', 'b']` são coisas diferentes, e sem as aspas as duas
imprimem igual.

**97.2 O que isso arrasta, dito antes de doer:**

  * **float dentro segue o repr de float** que a linguagem já tem (`[1.0]`, não
    `[1]`), porque é o mesmo `str()` de sempre;
  * **aninhamento com guarda de CICLO.** `o.pai` é caso normal aqui (22.2 já paga
    essa conta para `==`), então o repr tem um teto de profundidade e imprime
    `...` ao bater nele, como o Python imprime `[...]`;
  * **`str` de contêiner é o MESMO texto que `print`.** Uma forma só: sem par
    `str`/`repr` como o Python tem, porque a diferença entre os dois só se ensina
    depois de doer, e o caso em que ela importa (string dentro) já está resolvido
    pela escolha de 97.1.

## Bateria 98 — a tupla TERMINA (2026-08-20)

Estava a meio caminho: o tipo `(int, int)` e o literal `(1, 2)` parseavam, e
`len`, índice e `a, b = f()` não existiam. Meio caminho é o pior dos dois, e a
varredura mostrou onde dói: `d.items()` teve de ser estreitado para só existir
dentro de um `for`, porque como VALOR ele seria uma lista de PARES.

**98.1 Entra o pacote inteiro** que a 3.2 prometeu, a 38.2 congelou e a 54.4
escreveu: desempacotamento (`a, b = f()`), retorno múltiplo, índice (`t[0]`),
`len`, imutabilidade (`t[0] = x` é erro), e tupla como CHAVE de dict (24.3), com
hash e igualdade por CONTEÚDO derivados dos campos.

**98.2 E o que ela desbloqueia, que é o teste de a decisão ser certa:**
`d.items()` passa a ser um valor de verdade (`List<(K, V)>`), `for k, v in
d.items()` deixa de ser forma especial, `d[(linha, coluna)]` funciona, e uma
função que devolve duas coisas para de precisar de um `record` só para isso.

### 98.5 A pergunta sua que melhorou o desenho: a tupla NUNCA vira objeto

*"Se a tupla é imutável, conseguimos saber em tempo de compilação se vira valor ou
se vira objeto?"* Sim — e a resposta é mais forte que a pergunta: **não vira
objeto nunca.**

O que eu tinha escrito na 98.4 era "tupla pura = valor, tupla com referência =
objeto coletado com percurso gerado". Está errado, e o que mostra isso é a
imutabilidade:

  * o que o coletor precisa não é um CABEÇALHO, é saber **onde, dentro daqueles
    bytes, estão as referências** — e isso é dado de TIPO, conhecido em
    compilação, não informação por valor;
  * imutável + sem identidade (`is` sobre valor já é recusado, 22.2) significa
    que **copiar é indistinguível de compartilhar**: não há mutação para
    propagar nem identidade para preservar;
  * sem mutação não há barreira de escrita, que é o outro motivo pelo qual um
    coletor movedor normalmente quer objetos.

Então a escolha não é "valor ou objeto": é **quantos slots o frame registra**.

  * **local, argumento, retorno:** o frame registra um slot por referência
    DENTRO do valor (`&t._0`) em vez de um slot para o valor. É a mesma faixa que
    a 34.1 abriu para array, e custa zero numa tupla pura;
  * **variável de módulo:** uma RAIZ por referência dentro (`ps_add_root(&__g->t._0)`)
    — mesma ideia, outro lugar;
  * **dentro de contêiner** (`List<(str, int)>`, que é o que `d.items()` como
    valor precisa): o contêiner leva um **ponteiro de percurso** que o compilador
    escreveu (`etrace` na lista, `vtrace` no dict) e o coletor anda DENTRO de
    cada elemento em vez de segui-lo. Feito, com estresse;
  * **chave de dict:** continua pura. Hash e igualdade profundos são o mesmo
    percurso, e vêm com ele.

E o que isso ganha contra a versão com objeto: `d.items()` de mil pares é UMA
lista de 16 KB em vez de mil alocações de 40 bytes mais mil ponteiros; e
`d[(linha, coluna)]` não aloca nada em nenhuma volta do laço.

O `==` de uma tupla com referência também espera esse percurso, e é recusado com
a saída escrita na mensagem (comparar slot por slot).

### 98.6 E `d.items()` como VALOR, que era o pagamento disso

Com a tupla podendo guardar referência, `items()` deixou de ser forma especial:
como valor ele é **a comprehension que alguém escreveria à mão** — `[(k, d[k])
for k in d]` — construída na sema. Tudo o que vem depois (o laço, a tupla, a
lista, o percurso que o coletor precisa) é máquina que já existia.

As duas formas coexistem e cada uma é a melhor no seu caso: com DOIS nomes (`for
k, v in d.items()`) o laço lê o dict direto e **não constrói lista nenhuma**; como
valor, você tem a lista de pares para guardar, ordenar ou devolver.

E a tupla imprime como o Python imprime — `('ada', 1)` — o que cai de graça do
97: o número de slots é parte do TIPO, então o repr é concatenação decidida em
compilação, sem laço, sem adaptador e sem função de runtime.

> **Três coisas que o estresse do coletor achou nesse caminho**, todas do mesmo
> tipo — um lugar onde as referências dentro de um valor não estavam registradas:
> a variável de MÓDULO que é tupla (uma raiz por referência dentro), o corpo de
> uma COMPREHENSION (que não tinha frame próprio, então a tupla que ele constrói
> era invisível), e o contêiner criado pela comprehension (que não recebia o
> percurso). Nenhuma das três aparece sem coletar em todo ponto seguro.

### 98.4 O que entrou agora, e o que ficou esperando o coletor

**Entrou:** `t[0]` com índice LITERAL (cada slot tem o seu tipo, então `t[i]`
com `i` de runtime não teria tipo nenhum — é a diferença entre tupla e lista, e o
motivo de uma se escrever com `(` e a outra com `[`); `len(t)`, que é constante
porque quantos slots faz parte do TIPO; a tupla como CHAVE de dict (24.3), que
funciona porque uma tupla de bytes puros É um record (58.2) e o dict já copia e
compara por conteúdo; a imutabilidade da 38.2 recusada de verdade; e `a, b = 1,
2` — o lado esquerdo já funcionava (uma lista de vírgulas é uma tupla para o
parser), faltava o lado DIREITO, que terminava na primeira vírgula.

**Ficou** (e a 98.5 acima explica por que menos do que eu pensava): a tupla que
guarda referência DENTRO DE UM CONTÊINER, que é o que `d.items()` como valor
precisa, e o `==` dela. Como local, argumento, retorno e variável de módulo ela
já funciona — e como VALOR, sem cabeçalho.

**98.3 No P ela continua REMOVIDA**, a seu pedido, e isso não muda. É o caso
mais claro do contrato da 27.1: a tupla precisa de hash derivado e de igualdade
por conteúdo, que é runtime; o P é zero-runtime.

## Bateria 119 — o Grupo A rende: f-string e lambda no P (2026-08-22)

As duas pendências que a 117.5 isolou, decididas por você na forma (a) e feitas.
O critério da 65 é o que as escolheu: cada travessia converte síntese confiada do
`ps_lower` em código do P que a sema do P VERIFICA.

**119.1 f-string no P (65.2a) — a regra e a implementação são a MESMA coisa.**
Ela vale só como argumento de formato de função variádica, e o motivo não é
política: é onde a expansão acontece. Só no CALL se sabe as duas metades — a
assinatura do chamado (é variádica? esta é a posição do formato?) e o TIPO de
cada buraco, que é o que escolhe `%lld` em vez de `%s` em vez de `%p`. Uma
f-string em qualquer outro lugar não tem onde expandir, e a mensagem diz isso.

O tipo do buraco decide a conversão, e o **molde** (`cast`) é o que a torna exata
nos dois padrões: `long long`/`%lld` normalmente, `long`/`%ld` sob `--std=c89`,
onde 64 bits são política do back end (a `base_cname`) e não nossa. O que sai é o
C que uma pessoa escreveria:

```
printf(f"{s}, n={n}, hex={n:x}\n")
printf("%s, n=%lld, hex=%llx\n", s, (long long)n, (unsigned long long)n);
```

Três coisas que valem estar escritas:

- **método variádico também hospeda** — `b.printf(f"{x}")` é o caso que este
  repositório usa mais, e a regra é sobre a ASSINATURA, não sobre `printf` pelo
  nome. O receptor ocupa o primeiro parâmetro, então a posição do formato anda um;
- **`bool` imprime `True`/`False`**, com um ternário sobre dois literais — a
  grafia das duas linguagens, e continua zero runtime;
- **`%` literal no texto vira `%%`**, senão o printf leria o texto como conversão.

O que NÃO existe, dito e não descoberto depois: `^` (centrar) e `b` (binário) não
têm conversão em printf, e a f-string do P **é** um formato de printf. Recusa com
mensagem, não silêncio.

**119.2 lambda no P (65.4a) — sem captura, e é isso que a torna grátis.** Sem
nada para capturar, a lambda É um ponteiro de função, que o P já tinha. A sema dá
nome a ela, leva para o topo como `private` e deixa o nome no lugar:

```
apply(&a[0], 4, lambda v: v + 10)      →      apply(&a[0], 4, __lambda_1);
                                              static int32_t __lambda_1(int32_t v) { return v + 10; }
```

Os tipos vêm do CONTEXTO (68.7, a mesma regra do pscript), e o contexto é uma
destas cinco coisas: a variável declarada, o parâmetro, a atribuição, o retorno,
ou o campo que se inicializa (posicional ou por designador). Fora delas a
mensagem manda anotar quem recebe.

**Sem captura é PROVADO, não avisado:** antes de levantar, o corpo é varrido e um
nome que seja local da função envolvente é erro — com o nome dele na mensagem,
porque a correção (passar como parâmetro) só é óbvia quando se sabe qual era. Um
global não é captura: ele tem armazenamento estático, e lê-se de graça.

**Protótipo primeiro, corpo por último.** O C que emitimos não tem declarações
adiantadas — imprime o módulo em ordem — então uma lambda levantada precisa ser
anunciada antes da função que a nomeia e definida depois dos globais e structs que
o corpo dela lê. Prepender tudo dava `'g' undeclared`; foi o teste com um global
que mostrou.

**119.3 A peça compartilhada, e é a única que a 117 tinha achado ali.** A
gramática de chaves (`{e}`, `{e:spec}`, `{{`, `}}`) é a mesma nas duas linguagens
e virou `fstr_split`/`FStrParts` no `util.p`; o que difere é o que cada front end
FAZ com os pedaços (o pscript constrói um `str`, o P constrói um formato). Mesmo
arranjo do `LexSpec`: máquina compartilhada, linguagem própria. O `ps_parser`
passou a usar e a suíte do pscript (275) é a prova de que nada mudou de
comportamento.

**119.4 As duas são nós de AÇÚCAR que a sema apaga**, como o `EX_IN` da 97: o
`P_EXPRS` do `backend.p` as aceita (a impressora de superfície roda ANTES da
sema, de propósito), os geradores de código recusam com "internal:", e o
`roundtrip` — imprimir P de volta e exigir C idêntico — é o gate que prova o
conjunto. 236 casos.

E o `-Wswitch` do próprio compilador (102) cobrou o `EX_LAMBDA` que faltava num
`match` do `backend_c`: a checagem de exaustividade pagou-se sozinha nesta
bateria.

Gates: `cases/45_fstring.p` e `cases/46_lambda.p` (48 casos), mais onze recusas em
`tests/errors/p_fstring_*` e `p_lambda_*` (112). Três modos.

## Bateria 118 — `static` sai, `private` entra (2026-08-22)

*"vou substituir a keyword `static` pela keyword `private`, na própria linguagem
P e pscript. Primeiro deixa como alias, compila, e depois edita o código
trocando tudo por `private`... e depois remove de vez."*

A escada é obrigatória e não preferência: o seed comitado é o compilador que
compila os fontes, então trocar os fontes antes de o seed entender `private`
quebra o primeiro degrau. Feita na ordem — alias, reseed, 1 846 linhas editadas,
reseed, remoção.

**118.1 A troca CONSERTA a sobrecarga, não só renomeia.** Em pscript `static`
queria dizer duas coisas, e o que as separava era o `owner`: no topo, privado
(44.4); dentro de um `struct`, **método estático**. Depois desta bateria cada
palavra tem um sentido só:

| grafia | sentido |
|---|---|
| `private def f()` / `private x: T = ...` | privado ao módulo, nas duas linguagens |
| `static def f()` | método estático — só dentro de struct, só pscript |

E a árvore também: o `is_static` da `PsFunc` virou **`is_private`** e
**`is_smethod`**, dois campos em vez de um flag desambiguado por `owner`. O sítio
que mostrava a confusão era o `ps_lower`, onde estava escrito
`pf->is_static = f->is_static and owner == None` — a desambiguação feita à mão,
duas vezes no arquivo. Hoje é `pf->is_static = f->is_private`.

**118.2 O que a renomeação NÃO tocou, e por quê.** Não foi um `sed`: `static`
continua sendo `static` em quatro lugares, cada um por uma razão diferente.

- **O C que emitimos** — é a palavra do C para ligação interna, e ali ela é a
  verdade. Muda a linguagem de entrada, não a de saída.
- **O front end de C** (`cfront.p`) — tem lexer próprio; quando a entrada é
  `.c`/`.i`, `static` é `static`. As tabelas dele são literais no meio da linha,
  que a regra de reescrita não alcança.
- **O declarador C99 `T x[static N]`** — é qualificador de parâmetro, não
  privacidade. `static` segue palavra reservada no P só por causa dele, e é por
  isso que a remoção do degrau 5 é uma RECUSA com mensagem, e não a palavra
  virando identificador: código velho não muda de sentido em silêncio.
- **Os diagnósticos de paridade com o clang** — *"static declaration of 'x'
  follows non-static declaration"* é a frase do clang, medida pelos 155 casos do
  `clang-compare`. Renomear ali quebraria a paridade.

**118.3 A regra da reescrita, que é o que fez o `sed` ser seguro.** `static`
significa privacidade **no começo da linha** — com qualquer indentação em P, e só
na **coluna 0** em pscript, porque `static def` indentado ali é o método
estático. No meio da linha nunca é privacidade. Foi o censo que provou a regra
antes de rodá-la: 647 ocorrências na coluna 0 e 1 188 indentadas nos fontes P
(1 184 `def` e 4 `const`, todas privacidade), 8 na coluna 0 em pscript e 2
indentadas — exatamente os dois métodos estáticos do corpus, que ficaram.

Gates: as seis suítes de portão mais o `roundtrip`, que é o que prova a troca no
`backend_p` — ele imprime o P de volta e o C tem de sair idêntico, então a
palavra impressa tem de ser a palavra que o parser lê.

## Bateria 117 — o fork do front end, medido (2026-08-22)

*"vc consegue descobrir pra mim se mantermos 2 lexer, 2 asts etc 2 compiladores
dentro do selfhost ali vale a pena mesmo? [...] talvez valeria a pena ser apenas
1 compilador que compila 3 níveis de linguagens diferentes, uma ast de 3
níveis... já que não tenho planejamento de adicionar mais nenhuma linguagem, o
pscript é o auge"*

A tabela "o que é compartilhado / o que é fork" acima diz o DESENHO. Esta bateria
mede o CUSTO, porque a pergunta é sobre custo e não sobre desenho.

**117.1 Dois dos três itens da pergunta não existem.** O `selfhost` já é *um*
compilador com três front ends e um miolo só:

```
.c/.i  → cfront    ─┐
.p/.ph → parser    ─┼→  árvore do P → sema.p → backend C/QBE/P
.psc   → ps_parser → ps_sema → ps_lower ─┘
```

| | linhas |
|---|---|
| **compartilhado** (infra, lexer, árvore do P, `sema.p`, três back ends, driver) | **16 280** |
| front end do P (`parser.p`) | 1 723 |
| front end do C (`cfront.p`) | 2 845 |
| front end do pscript (spec léxico, parser, árvore, sema, lowering) | 19 479 |

Não há dois lexers: há uma máquina e duas tabelas, e a do pscript tem **46
linhas** (`ps_lexer.p` — palavras e três flags). Não há dois back ends nem duas
semas de codegen. O fork é a **árvore** (498 linhas de header), a **sema**
(6 360) e o **lowering** (10 219).

**117.2 Quanto código IGUAL existe, medido e não estimado.** Extraí toda função
com 6 linhas ou mais dos dois lados — 220 do lado P/C, 263 do lado pscript —
normalizei (fora comentário e indentação) e comparei os **57 860 pares**:

- com **70% ou mais** de linhas idênticas: **um** par, `parse_if` (22 vs 18);
- com **50% ou mais**: **oito** pares, e metade é falso positivo semântico
  (`is_lvalue` do C contra `borrowable` do coletor);
- total recuperável no melhor caso: **~89 linhas**.

Os nomes enganam, e é por isso que a inspeção a olho dá a resposta errada. Os
dois parsers têm **32 funções de mesmo nome** (`parse_add`, `parse_mul`,
`parse_or`…) e só **21% das linhas coincidem**: `parse_stmt` é 126 contra 71 com
10% em comum, `parse_func` é 79 contra 17 com 2%. As duas semas têm **6 nomes em
comum de 182 e 110**. No histórico, de 77 commits **um** implementou o mesmo
recurso nas duas linguagens (`const if`, 99).

**117.3 O que a fusão custaria, também em número.** A raiz é o reticulado de
tipos: `TypeKind` do P tem **quatro** kinds (`PTR`, `ARRAY`, `FUNC`, `NAME`)
porque um tipo do P é um tipo do C; `PsTypeKind` tem **22**. Uma árvore só
significa **52 kinds novos** (22 de expressão, 6 de comando, 19 de tipo, 5 de
declaração) nos enums que o código compartilhado percorre — e ali há **352 braços
de `case`** sobre kind, em ~55 `match`, dentro da sema e dos três back ends. Com
`-Wswitch-enum` ligado (a 102 fez o compilador cobrar isso de si mesmo), cada
kind novo bate em todos.

**117.4 E o custo que não é linha: a fusão apaga o verificador.** Hoje o
`ps_lower` produz árvore do P e o `main.p` roda `sema_run` em cima dela — a sema
do P é o **verificador do lowering** (49.1), o mesmo checador que guarda P
escrito à mão. Se a árvore do pscript FOR a do P, esse teste desaparece: erro de
lowering deixa de ser erro de compilação e passa a ser código errado emitido em
silêncio. Foi essa verificação que forçou o escopo de bloco na 64.1 e que apanhou
boa parte dos quinze defeitos que o porte do pstudio revelou (112-116).

**117.5 DECIDIDO (2026-08-22): o fork fica, e o esforço vai para o Grupo A.** Sua
escolha, com a medição na mesa. O que rende não é fundir árvore: é **empurrar
semântica de zero-runtime para baixo, para o P** — cada item convertido troca
*síntese confiada* por *código verificado*, que é o mecanismo da 65 e o que a
65.1 já provou (`record` com `==` por conteúdo e construtor no P: o lowering
emite `a == b` e `Vec(1.0, 2.0)` em vez de sintetizar temporário e comparação
campo a campo).

Estado real do Grupo A depois das baterias 67-69, que fecharam parte dele sem
que a seção fosse atualizada:

| item | estado |
|---|---|
| 65.1 `record` no P | **feito** (2026-08-14) — 106 linhas de síntese saíram do `ps_lower` |
| 65.3 `T?` no P | **fechado de outra forma** pela 69: `ref T` não-nulável, `*T` segue anulável, narrowing e `-Wnull-dereference`. `T?` no P não se repropõe |
| 65.5 interface estática no P | **feito** pela 67.1 (`trait` no P) + 68.1 (limite nominal) |
| 65.2 f-string no P | **feita** na 119.1 (forma (a): argumento de formato de variádica) |
| 65.4 lambda no P | **feita** na 119.2 (forma (a): sem captura, levantada para o topo) |
| 65.15 superset de fonte ou de capacidade | **aberto**, e (a) é o que vale na prática |

**117.6 Uma deriva que a medição achou, e é decisão sua.** A sema do P tem **40**
sítios de grupo de warning (`cdiag_at`); a do pscript tem **3**. Na prática o
pscript é erro duro em tudo, sem `-W` opcional. Pode ser exatamente o contrato
que se quer — linguagem segura não negocia — mas hoje é consequência da ordem em
que as coisas foram feitas, e não escolha registrada.

## Bateria 116 — o editor em P aposentado (2026-08-22)

*"pode remover o editor de P agora."*

Saíram **6448 linhas de P** — `core.p`, `pui.p`, `codeview.p`, `complete.p`,
`app.p`, `main.p` e `psys.p` com os seus headers — e os oito testes deles. O que
ficou em P é o que a 45.5 não deixa atravessar: **820 linhas** de driver
(`pgfx.p`, `pgfx_raster.p`, `font_atlas.p`, `shim.p`) mais o `hl.p`, a
ponte para o lexer do compilador.

O que a remoção obrigou a mexer, e é a parte que interessa:

**116.1 O passo 7/8 do `verify-all` mudou de significado — para melhor.** Ele
era *"compila o editor, que é o maior consumidor de P depois do compilador"*.
Agora ele **compila, LINKA e RODA**: o driver em P, o runtime do pscript e as
4200 linhas de pscript do editor num binário, e depois o `--selftest` dele (abre
um arquivo, digita, desfaz, usa a paleta, dobra, desenha). Deixou de ser um
teste de compilação e passou a ser um teste de programa.

> A medida que se perdeu — "o maior programa em P" — não era da compilação de P:
> o compilador tem 38 mil linhas de P e é construído QUATRO vezes nos passos 1 a
> 3, com ponto fixo por bytes. O editor era um segundo consumidor, não a medida.

**116.2 `make pstudio` é o editor em pscript**, e `pstudio-ps` ficou como apelido
(quem tinha o nome na memória continua achando). A suíte `tests/pstudio` foi de
15 gates para 7: dois do driver em P e quatro do editor em pscript, mais o
binário completo com SDL.

**116.3 O `psys` não tem substituto em pstudio** porque virou stdlib do pscript
na 111 (`os` e `path`) — o arquivo era a FONTE do porte, e sai agora que os dois
consumidores (o editor e, em breve, o pforge) usam a stdlib.

Ficou registrado o que a migração inteira custou e rendeu: quatro baterias
(111-116), **quinze defeitos do compilador** achados por escrever programa de
verdade na linguagem, e um editor que agora é 4200 linhas de pscript por cima de
820 de P — onde antes eram 6448 de P por cima de 820 de P.

## Bateria 115 — a paridade medida, e os três buracos que ela achou (2026-08-22)

Sua condição, e ela é a certa: *"o Editor P vai ser deprecado, só quero garantir
que o novo PScript vai fazer tudo o que o velho fazia"*.

**O método: varredura pelos HEADERS, não por memória.** Todo `def` público dos
cinco arquivos de interface do editor em P — `core.ph`, `pui.ph`, `codeview.ph`,
`complete.ph`, `app.ph` — contra o que existe em pscript. **197 métodos**, um por
um. A tabela completa está em `pstudio/DESIGN.md`; o resumo é que 24 deles
mudaram de FORMA (o `init`/`deinit` que o coletor tornou desnecessário, o I/O que
foi para o driver, as três `*_gutter()` que viraram `add_gutter(GUT_*, n)`) e
**três estavam FALTANDO de verdade** — nenhum aparecia por nome, os três
apareceram por comportamento:

**115.1 A dobra não se soltava ao editar dentro dela.** O `core.p` chama
`unfold_range` no INÍCIO de `raw_insert` e de `raw_delete`, e a razão está no
comentário dele: *uma edição que alcança um bloco recolhido o solta, porque
undo/redo alcança*. O porte tinha deixado o invariante atrás, e o efeito era
linha com conteúdo novo que a vista nunca mostrava. Entrou junto com o
`unfold_enclosing` de que ele depende — uma linha escondida sem cabeçalho acima é
REVELADA, porque nunca se deixa uma linha invisível.

**115.2 O zoom não fazia nada.** Os comandos 5/6/7 da paleta e o `ctrl+=`/`-`/`0`
caíam num ramo que só tratava 11..23 — silenciosamente. E o zoom é do DRIVER: o
passo é uma grade RASTERIZADA (11..29px), não um multiplicador. Entrou como as
outras funções de sistema, num campo que o `app.psc` preenche, e o shim passou a
expor o passo PADRÃO para o reset cair no mesmo lugar que no editor em P.

**115.3 O F2 não existia.** No editor em P ele é atalho SEM ctrl — F2 anda entre
marcadores, shift+F2 anda para trás, ctrl+F2 põe e tira a marca — e o meu
`key_shortcut` saía cedo quando não havia ctrl.

De passagem, quatro coisas menores que a mesma varredura cobrou: a linha de
comando ficou a do editor em P (vários arquivos em abas, `--size LxA`, `--shot`,
diagnóstico para opção desconhecida e para caminho que não existe), o título da
janela passou a acompanhar a aba, e os bits de marca passaram a ter os MESMOS
números (`MARK_BOOK`=1, `MARK_BREAK`=2) — estavam trocados, e trocado é o tipo de
diferença que ninguém vê até comparar.

O `app_test.psc` cresceu para medir tudo isso: 40 linhas de estado, incluindo o
clique de sarjeta **por pixel** (que é o caminho que o teste em P exercita, e não
o comando), o zoom mudando a célula, a dobra que a edição solta, o par que o
backspace tira, o candidato aceito e o F2. É o gate que autoriza a depreciação.

## Bateria 114 — o editor INTEIRO em pscript, e as cinco provas de não-nulo (2026-08-22)

O último passo da migração do pstudio. O `app.p` (1025 linhas: abas, árvore de
arquivos, paleta de comandos, busca, atalhos, laço de eventos) virou dois
arquivos: `lib_app.psc` (a lógica, 950 linhas) e `app.psc` (o driver, 250).

**114.1 O driver é uma página, e a lógica não conhece a janela.** O `lib_app`
recebe as funções do sistema em CAMPOS — `read_file`, `write_file`, `mtime_of`,
`clip_get`, `clip_set`, `confirm_close`, `confirm_reload` — e o `app.psc` as
preenche na partida. É a mesma decisão do `Painter` (112) e do `load_text` (113),
levada ao fim: com o driver de fora, o editor inteiro roda num teste headless, e
o que sobra no `app.psc` é tradução de evento e apresentação de quadro.

O gate é `pstudio/app_test.psc`, o gêmeo do `app_flow.p`: monta um projeto em
disco (com `os`/`path`, a camada da 111), abre arquivos, digita, desfaz, refaz,
põe dois cursores, usa a paleta de arquivos e a de comandos, vai para a linha,
busca duas vezes, clica numa aba, expande um diretório, dobra, marca, comenta,
duplica linha, fecha par automático, abre o popup de completamento, copia para a
área de transferência, e desenha UM QUADRO inteiro (29 retângulos e 190 glifos,
contados por um `Painter` de teste). 30 linhas de estado conferidas.

**114.2 A costura que o `async` cobrou, e onde ela está.** Ler e escrever arquivo
no pscript é `await` (76.2), e o `lib_app` é síncrono de propósito — um índice de
completamento que espera obrigaria todo chamador dele a esperar. A ponte:

  * LER: o app PEDE (`want_open`) e o driver atende — lê com `await` e chama
    `open_file` outra vez, com o texto em mão;
  * ESCREVER: entra numa fila que o laço drena, e a falha vai para a barra de
    estado.

É o único lugar do editor onde a divisão custa algo, e está no driver em vez de
espalhada. Registrado aqui porque é uma consequência de desenho, não um detalhe.

**114.3 O shim ganhou o que só o driver pode dar:** `shim_wait(ms)` (UM evento
bloqueando, com `SHIM_TIMEOUT` quando vence — é o que faz o cursor piscar sem
girar em vazio), a área de transferência, as duas confirmações modais, o título
da janela e o `--shot` em PPM. Tudo encaminhamento para o `pgfx`, que já tinha
todas. E o `psys` SAIU do link: a camada de sistema é a da stdlib desde a 111.

### As cinco provas de não-nulo, e por que elas apareceram todas de uma vez

A 43.1 dava UMA forma: `if x != None:` e dentro do ramo `x` é `T`. Escrever 950
linhas de lógica de editor cobrou as outras quatro no mesmo dia — cada uma
apareceu num idioma comum, nenhuma procurando buraco:

| forma | onde apareceu |
|---|---|
| `if x == None: return` e o resto da função | toda função que trata o caso ausente primeiro (`find_step`, `reload_cur`) |
| `if x == None: ... else:` | `update_status` |
| `if x != None and x.f > 0:` | `palette_accept`, `find_open` |
| `if x == None or x.f == 0: return` | `reload_cur` |
| `elif x != None:` | `run_command` |

As cinco entraram (`tests/pscript/run/narrow.psc` mede as cinco mais o `if`
aninhado que não desfaz a prova de fora). Duas notas do que NÃO se fez: a prova
é sobre LOCAL, nunca sobre campo (um campo pede análise de fluxo sobre campos,
que é outra bateria), e num `or` só o `==` prova — num `and` só o `!=`, porque é
o que o curto-circuito garante em cada caso.

> **O defeito que a implementação disso teve, e que os testes acharam.** A
> primeira versão restaurava, no fim de cada bloco, TODO local estreitado — e um
> `if` aninhado dentro do ramo desfazia a prova do bloco que o continha. Agora
> cada bloco só desfaz o que ELE provou.

### E os outros quatro defeitos que este porte cobrou

**114.4 `void` e "nada" não eram o mesmo tipo.** Um `def(int, int)` escrito num
tipo tem retorno NULO; o valor de uma função sem retorno tem retorno `PT_VOID`.
Os dois imprimiam igual e comparavam diferente, e a mensagem era `expects
def(int, int) -> nothing, found def(int, int) -> nothing` — que não diz nada a
ninguém.

**114.5 O nome que já existe é CONTEXTO.** `f = lambda v: v * 2` num nome de tipo
função dizia "não consigo inferir a lambda", com a informação ali do lado: a
64.1 diz que um nome que já existe é ASSIGNADO, então o tipo dele é quem manda.
Passou a valer para local e para variável de módulo — e com dois cuidados que os
testes cobraram: dentro de uma função não se procura global (um local `b` acharia
o `b` de outro módulo), e o tipo que vale é o DECLARADO, não o estreitado (num
`while x != None:`, `x = x.next` atribui um `T?`).

**114.6 `P(x) if c else None` para um RECORD.** A 112.7 fez a sema aceitar o
`None` num braço; o lowering ainda entregava ao P um record de um lado e um zero
do outro (a representação de `T?` de record é o par `{has, v}`, não um ponteiro).
Agora, quando o RESULTADO é opcional, cada braço vira o opcional.

**114.7 O arquivo nas mensagens era o do programa PRINCIPAL, com a linha do
módulo importado.** Um `Pos` tem linha e coluna, e o lowering usava o caminho do
módulo principal para tudo — então um erro em `lib_pui.psc` dizia `app.psc` com a
linha do lib_pui, o pior dos dois mundos. Agora cada função é baixada com o
arquivo do módulo que a ESCREVEU (41.3: o `ns` dela sabe qual é). Foi um aviso do
compilador apontando para a linha 424 de um arquivo de 250 linhas que o
desenterrou.

### O estado da migração

O editor em pscript tem agora TODAS as camadas: buffer, toolkit, realce,
completamento, widget de edição, app e driver. Em P sobrou o que a 45.5 não deixa
atravessar — SDL (`pgfx`, `pgfx_raster`, `font_atlas`, `shim.p`) e o lexer do
compilador (`hl.p`) — que é o que "totalmente em pscript" quer dizer num programa
que fala com uma placa de vídeo.

`make pstudio-ps` constrói o editor completo; `tests/pstudio` mede 15 gates (11 do
editor em P, 4 do editor em pscript). **O que NÃO decidi: aposentar o editor em
P.** Ele é o maior programa em P do projeto (8 mil linhas) e é o que o passo 7/8
do `verify-all` usa para medir a compilação de P; apagá-lo tira essa medida. É sua
decisão, e as duas versões convivem sem custo até você tomá-la.

## Bateria 113 — o lexer do compilador atravessando a fronteira, e o `codeview` em pscript (2026-08-21)

Sua pergunta e a sua aprovação: *"ou seja eu teria que fazer uma interface/header/
camada no compilador em P pra isso né"* → *"aprovado, faz o adaptador junto com o
porte do codeview"*.

**113.1 O adaptador: `pstudio/hl.p`, 141 linhas, e NÃO é mexer no compilador.**
O lexer já é um header (`selfhost/lexer.ph`), e o adaptador mora ao lado do
editor — do mesmo tipo que o `shim.p` é para o SDL. Duas correções ao que eu
tinha dito antes de olhar:

  * o texto atravessa INTEIRO numa chamada, porque o `CStr` (81/84/85) é
    ponteiro mais comprimento, como valor, e não aloca nada. Nada de codepoint
    por codepoint;
  * o que volta são NÚMEROS: `hl_lex(in text: CStr) -> i32` e cinco acessores
    (`linha`, `coluna`, `comprimento`, `classe`, `kind`), com a posição em base
    zero e em CODEPOINTS, que é a unidade em que o editor mede.

> **O que o adaptador NÃO faz, de propósito.** Não classifica comentário, não
> monta span por linha, não recupera declaração, não ordena candidato. Isso é
> LÓGICA e mora no pscript (`lib_hl.psc`, `lib_complete.psc`). E o TEXTO do token
> não volta: quem quer o nome de um identificador fatia o próprio buffer pela
> (linha, coluna, comprimento) — o buffer já está do lado de cá, e assim nenhuma
> cadeia atravessa de volta.

**113.2 O realce em pscript** (`lib_hl.psc`): spans por linha a partir dos tokens,
e a única regra que não é do lexer — o comentário, porque o lexer do compilador
come comentário — feita aqui, onde se sabe quais spans são cadeia.

**113.3 O índice de completamento em pscript** (`lib_complete.psc`, porte do
`complete.p`), com uma mudança de LAYERING: em P ele lia os `.ph` importados, ele
mesmo, com o `psys`. Aqui ele não faz I/O — `imports_of` DIZ quais arquivos são, e
quem tem o laço de eventos (que é quem pode esperar) lê e passa os textos. O
índice deixa de ter opinião sobre arquivo e continua SÍNCRONO: o `codeview` chama
sem ser `async`.

**113.4 O `codeview` em pscript** (`lib_cv.psc`, 1167 linhas; o original em P tem
1369). Três diferenças, todas de layering e todas para o mesmo fim — que a lógica
do editor rode sem driver, e portanto seja testável:

| em P | em pscript | por quê |
|---|---|---|
| `Gutter` com ponteiros de função | `enum GutKind` + `match` | é a 28.5 ("despacho é dado") onde ela cabe; as três sarjetas que existem são as três que o editor usa |
| `pgfx_clipboard_get/set` dentro do widget | `copy()` DEVOLVE o texto, `paste(texto)` RECEBE | quem fala com o sistema é o app, que é quem tem o driver — e o multi-cursor (N pedaços para N cursores) continua aqui |
| `load_file`/`save_file` com `vfs` | `load_text`/`text_to_save` | I/O no pscript é `await` (76.2), e quem espera é o laço de eventos |

**A prova é o mesmo diff da 112:** `pstudio/cv_test.psc` imprime as SETE
linhas de `tests/pstudio/cv_fold_scroll.expected` byte por byte — `top=20` que
não se move ao dobrar pela sarjeta, `fold_all: inner=22 -> top=20`,
`at_caret: top=24 caret=40 folded=1`. Mais o realce e o completamento pelo
adaptador: `kw=1 ident=0 num=3 comment=4`, e `soma` completado com a assinatura
inteira mais `owner_of(x)=i32`.

**113.5 O `lib_core` ganhou o que faltava** para o widget: o mapa de linhas
visíveis (`visible_count`/`next_visible`/`to_visible`/`from_visible`/
`visible_at_or_before`), `fold_all`/`unfold_all`, `next_mark`, `is_blank`,
`insert_each`, `move_lines`, `join_lines` e `find_re` (a ERE do POSIX, que é o
`re` do pscript).

### Os quatro defeitos do compilador que o porte cobrou

**113.6 Uma `const` num `.ph` atravessava por `include "x.h"` e desaparecia por
`import "x.ph"`.** As duas portas existem por razões diferentes — o `include` lê
o header com o C, o `import` lê com o front end do P (75.3) — e uma função de
`CStr` OBRIGA a segunda. Só que a ingestão de declarações reconhecia a constante
na forma que o C mostra (`static const i32 X = 0;`) e não na forma que o P
escreve (`X: const i32 = 0`, com o `const` no TIPO). Resultado: `HLC_TEXT` não
existia. Agora as duas grafias entram.

**113.7 Uma lambda que devolve um RECORD gerava P inválido.** A guarda de exceção
de uma função devolve um zero declarado (`return {0}` não é C), e o caminho da
lambda não o declarava — então `lambda ui, id: Size(a, b)` virava `return 0` numa
função que devolve record, e o P respondia `incompatible types in assignment`.

**113.8 O renome de nome reservado do C valia na DECLARAÇÃO e não nos usos.** Um
campo chamado `index` (ou `time`, `log`, `remove`, `rename`...) vira `index_` no C
emitido, porque a libc já tomou o nome. Mas só o `struct` era renomeado: o
CONSTRUTOR, o TRACE do coletor, o `repr` derivado, o `pack`, o acesso `a?.f`, o
argumento nomeado de record e a vtable de trait usavam o nome original. Um campo
com um desses nomes dava `has no member named 'index'` — e o do TRACE era pior,
porque um campo coletado que o trace não vê é objeto perdido. Oito sítios
corrigidos com a mesma função.

**113.9 E o grande: o par do `CStr` era baixado DUAS vezes.** O par é
`{ponteiro, comprimento}`, e o lowering escrevia a expressão do argumento uma vez
para cada metade:

```c
CStr __cs = {Buffer_text(b, ctx)->data, (size_t)Buffer_text(b, ctx)->len};
```

`b.text()` rodava duas vezes, o par ficava com os BYTES da primeira cadeia e o
TAMANHO da segunda, e — o pior — a alocação da segunda podia coletar a primeira.
O "zero cópia" da 84.1 virava ponteiro para o cemitério: `ptr` num endereço
desmapeado, `len = 2440`. Agora o valor vai para uma variável declarada primeiro
(que o frame recolhe como RAIZ, então o empréstimo vive) e as duas metades leem
essa variável.

> Isto valia para TODA chamada de fronteira cujo argumento não fosse uma variável
> simples — `text_length(nome + "!")`, `bytes_sum(build())`. Passava no teste da
> 84 porque lá o argumento é sempre uma variável, e uma variável avaliada duas
> vezes dá o mesmo endereço.

Gates: `tests/pstudio/ps_cv.expected` (o widget portado, headless, com o lexer do
compilador do outro lado da fronteira — a suíte do pstudio vai a 14) e as sete
linhas idênticas às do teste em P. Três modos: 273 no pscript.

## Bateria 112 — o `pui` em pscript, e os cinco defeitos que o porte cobrou (2026-08-21)

Segundo passo da migração do pstudio (a 111 foi o primeiro). O `pui.p` — 1158
linhas de P: a árvore de widgets, as duas fases do layout do Godot, o desenho
retido, a entrada — virou `pstudio/lib_pui.psc`, 1136 linhas de pscript.

**A prova é um diff.** `pstudio/pui_test.psc` é o gêmeo de
`tests/pstudio/pui_layout.p`, e as **oito linhas de retângulo são idênticas** —
`[4] 24,21 216x29` nos dois. Duas linhas diferem de propósito e o teste diz
quais: `changes=5` em vez de 3 (o evento de texto do shim carrega UM codepoint,
não uma cadeia — é a fronteira de escalares da 45.5) e `draw_cmds` em vez de
`draw_lit` (sem framebuffer não há pixel para contar; conta-se o comando).

**112.1 O que o porte SIMPLIFICOU, e por quê.** Não é estilo:

| em P | em pscript | o que sai |
|---|---|---|
| `BoxData`/`SplitData`/`TextData`/`ScrollData`/`InputData` | campos do próprio nó | cinco structs, cinco `malloc`, e o `node_release` que tinha de saber de todos |
| `flags: u32` com `UF_VISIBLE\|UF_DIRTY` | `visible`, `dirty`, ... | a máscara existia para caber num `u32`; um bool custa o mesmo e não se lê ao contrário |
| `font: PgFont` dentro do `Ui` | `cell_w`/`cell_h` passados no construtor | o toolkit deixa de conhecer o driver — e é isso que o torna MEDÍVEL sem janela |
| `draw(ref fb: PgFb)` | `draw(p: Painter)` (cinco funções) | o mesmo desenho retido serve tela, teste e o que vier |
| `UiSignal {fn, ctx}` | `def(int, int)?` | o `ctx` existia porque função livre não captura; uma lambda captura (28.1/19.2) |

**112.2 Função em CAMPO é chamável.** A 28.1 diz que função é valor e que valor
vive em contêiner; um campo é contêiner. `x.f(a)` era SEMPRE lido como método, e
`'lib_pui__Node' has no method 'c_min'` era o erro — num toolkit em que o
comportamento do widget do app mora justamente em campos do nó. Agora, quando o
método não existe e o campo existe com tipo de função, a chamada é do VALOR.

> **E o campo OPCIONAL não é chamável direto, de propósito.** A prova de não-nulo
> é sobre LOCAL (43.1): `if x.f != None:` não prova nada sobre a leitura seguinte.
> A mensagem diz o que fazer — `f = x.f` e depois `if f != None: f(...)` — e é o
> que o `lib_pui.psc` faz nos quatro lugares. Um campo que narrows precisaria de
> análise de fluxo sobre CAMPOS, que é outra bateria e não esta.

**112.3 Contexto de lambda: faltava em dois lugares.** Uma lambda não tem
anotação (a forma do Python), então o tipo vem de quem a recebe. Funcionava para
função livre; **não** para (a) parâmetro de MÉTODO — `check_expr` + `want` em vez
de `check_want`, e o `want` chega tarde demais — nem para (b) um `def(...)?`, que
é o tipo de um sinal que ninguém ligou. Os dois consertados; o (b) é o que faz
`ui.on_click(id, lambda i, a: ...)` compilar.

**112.4 `return <expressão sem valor>` gerava P inválido.** O corpo de uma lambda
de tipo `def(int, int)` não devolve nada, e o `return` implícito dela virava
`return print(...)` no P — que responde `void value cannot be assigned`. Agora a
expressão vira STATEMENT e o `return` fica nu. Sob a guarda de exceção, a guarda
vem depois dela (e não há `__ret` de tipo void, que C não declara).

**112.5 E o compilador MORREU: `None` sozinho tem tipo.** O tipo de um `None`
solto é `nothing?` — um opcional SEM dentro. Quando um argumento literal precisa
de temporário (o `bind_all` do `lower_ordered`, que ordena a avaliação), o
lowering pede o tipo C dele, e `option_record(None)` leu `inner->pos`: SIGSEGV,
sem mensagem nenhuma. Não havia record a sintetizar — não se sabe de quê — e a
representação certa é a que o valor já tem: o ponteiro nulo.

> **Como foi achado, que é a parte reusável.** O teste da 112 travou o compilador
> sem uma linha de saída. `gdb -batch -ex run -ex bt` sobre o binário de `-O2`
> deu a pilha em nomes de função (`option_record` ← `ty` ← `lower_ordered`), e um
> `cc -g -O0` sobre o mesmo C gerado deu a LINHA. Dois minutos, e nenhum palpite:
> o `plangc` compila para C, então o depurador de C é o depurador dele.

**112.6 E o gc-stress cobrou um defeito do COLETOR que já existia: opcional de
referência dentro de contêiner não era seguido.** O teste da 112 passava, e sob
`PSCRIPT_GC_STRESS=1` morria com SIGSEGV — o objeto que o `ps_forward` tentava
copiar estava com `0xdd` em todo campo, o veneno do cemitério.

A causa: `T?` de referência É o ponteiro nu (a representação que a 9.4 escolheu,
e que custa zero), mas o predicado que responde "isto é referência" não tinha
caso para `PT_OPT`. Então um `Dict<str, def(int,int)?>` nascia com `vref =
False`: o coletor não seguia os valores, e depois de uma coleta o dict devolvia
ponteiro para o cemitério. **Não é só função:** o mesmo predicado decide o
`eref` de `List<str?>`, o `kref`/`vref` de todo dict e set, e as marcas de
"grafo" das mensagens de worker. Um campo de struct escapava (aquele caminho
pergunta pelo tipo C, e `str?` já chegava lá como `PsStr *`).

> Um programa com `List<str?>` corrompia memória sob pressão de coleta desde que
> `T?` existe, e nenhum teste tinha as duas coisas ao mesmo tempo — opcional de
> referência num contêiner E alocação suficiente para coletar no meio. O
> `tests/pscript/run/optref.psc` agora tem: 200 opcionais em lista, dois dicts,
> uma lista encadeada de 200 structs, 3000 alocações de pressão, e a leitura de
> tudo depois. Ele vai para a suíte E para o gc-stress, que é onde ele fala.

**112.7 `None if x else "a"` passou a ser aceito.** Os dois lados de um
condicional tinham de ter o MESMO tipo, e o tipo de `None` é `nothing?` — então a
forma mais natural de escrever "isto pode não ter valor" era recusada, e o jeito
era um `if` de três linhas. Agora, se um lado é `None` e o outro é `T`, o
resultado é `T?`. Apareceu escrevendo o teste da 112.6, que é o tipo de coisa que
só aparece quando se escreve programa de verdade na linguagem.

Gates: `tests/pstudio/ps_pui.expected` (o pui portado, headless, na suíte do
pstudio — 13 agora), `tests/pscript/run/fnfield.psc` (campo chamado direto,
sinal opcional ligado e desligado, tabela de despacho em dict, lambda por
método) e dois `tests/pscript/bad/` (o campo opcional chamado direto, com a
mensagem que ensina; a aridade do campo), `tests/pscript/run/optref.psc`
(contêiner de opcional de referência sob o coletor). Três modos: 273 cada, e
gc-stress 113.

## Bateria 111 — a camada de sistema: `os` e `path` saem do editor e entram na stdlib (2026-08-21)

Sua decisão: *"o pstudio temos que migrar ele totalmente para PScript e a parte
de sistema vai pra lib/runtime do PScript onde for possível"* — que é a 1.1 do
`pforge/DESIGN.md`. Esta bateria é o primeiro passo dela, e o passo que os DOIS
projetos seguintes esperavam: o pforge precisa listar diretório e ler mtime, e o
pstudio migrado precisa das mesmas coisas.

**Nada aqui foi inventado.** O `pstudio/psys.p` já tinha a camada escrita em P —
`vfs_list_dir`, `vfs_stat` com mtime, `ps_path_join`/`dirname`/`basename` — e o
que a bateria faz é mudá-la de casa e dar-lhe a forma do Python. Onde o editor
tinha "quase" o comportamento do Python, o oráculo cobrou a diferença (ver
111.3).

**111.1 Dois módulos, com os nomes do Python: `os` e `path`.** `os` é o que MUDA
o sistema de arquivos — `listdir`, `mkdir`, `makedirs`, `remove`, `rmdir`,
`rename`, `getcwd`. `path` é o `os.path` do Python importado direto — `join`,
`dirname`, `basename`, `normpath`, `abspath`, `exists`, `isdir`, `isfile`,
`getsize`, `getmtime`.

> **Por que `path` e não `os.path`.** Um módulo aninhado seria a primeira
> hierarquia de módulos da linguagem, e ela não existe (48.3: um módulo é um
> arquivo, ou é builtin). `from os import path` daria o mesmo nome sem a
> hierarquia, mas `import path` é uma linha mais curta e já é como todo mundo
> escreve o alias. Se um dia houver hierarquia, `os.path` passa a existir sem
> quebrar isto — o nome curto continua valendo.

> **Por que NÃO tem um `stat` que devolve tudo de uma vez.** Quatro perguntas ao
> disco são quatro `stat`, e um build que percorre mil arquivos sentiria. Mas a
> forma de devolver "tudo" é um record novo ou um dict de tipos mistos, e nenhum
> dos dois é óbvio — então fica para quando o pforge MEDIR que dói. O que existe
> hoje é o que o editor usava.

**111.2 Sem `chdir`, e o motivo é o modelo de workers.** O diretório de trabalho
é do PROCESSO e um worker é uma THREAD (18.1): um `chdir` num worker mudaria o
caminho debaixo de todos os outros. Um caminho absoluto — que é o que `abspath`
dá — resolve o mesmo problema sem corrida. E rodar um processo (`os.run`) NÃO
entrou: é a pergunta 1.2 do pforge, e é sua.

**111.3 O `posixpath` conferido por VARREDURA, e o "quase" que ele pegou.** O
`ps_path_dirname` do editor devolvia `"."` para um nome sem barra; o Python
devolve `""`. Ninguém tinha notado porque o editor sempre lhe passava caminho com
diretório. `tests/oracle/py/paths.psc` monta **mil caminhos** — prefixo de zero a
três barras (`//a` é preservado, `///a` colapsa, e isso é POSIX), três
componentes tirados de `{vazio, ., .., a, b}`, com e sem barra final — e mais 729
combinações de `join` de dois e de três pedaços, e compara os 3813 resultados com
o `posixpath` do CPython. Batem todos.

> `normpath` é transcrito do `posixpath.normpath`, inclusive a parte que
> surpreende: `..` come o componente anterior, mas um `..` sem o que comer só
> desaparece se o caminho for ABSOLUTO (`/..` é `/`, e `../x` continua `../x`).
> A pilha de componentes é a pilha de OFFSETS no buffer de saída — empilhar é
> escrever, desempilhar é truncar — então não há segundo array nem cópia.

**111.4 O que a varredura desenterrou, e que NÃO é desta bateria: `f.close()`
sem `await` é uma task PENDENTE.** O primeiro teste que escreve um arquivo e
depois pergunta o tamanho dele viu `0`, de forma intermitente. Não é defeito do
`getsize`: `f.close()` devolve uma task, e sem `await` ela só roda quando alguém
entra no escalonador — no fim do programa, na drenagem. Até lá os bytes estão no
buffer do stdio e o `stat` vê o arquivo vazio.

Não há perda de dado (a drenagem do fim executa a task, e foi medido: um `write`
sem `await` também acontece), mas `f.close()` LÊ como "fechei agora" e não é isso.
Três saídas, e a escolha é sua:

  a) fica como está, e a documentação diz que quem escreve e depois LÊ precisa de
     `await f.close()` (é o modelo de tasks a funcionar, sem exceção nenhuma);
  b) `.close()` sem `await` vira o close BLOQUEANTE — que é o que o `with` já
     faz na limpeza, e o que `conn.close()` de socket já é hoje. A forma de
     statement passa a significar o que ela lê, e `await f.close()` continua
     existindo para quem não quer bloquear;
  c) descartar uma task vira AVISO do compilador (`-Wunawaited-task`), o que
     pega `f.write(...)` esquecido também — mas transforma em erro de compilação
     um idioma de fire-and-forget que hoje é legítimo.

O `syslayer.psc` desta bateria usa `await f.close()` para não depender da
resposta.

**111.5 O `listdir` devolve ORDENADO — divergência deliberada.** O Python devolve
na ordem do sistema de arquivos, que muda de máquina para máquina e de ext4 para
APFS. Um build e um editor querem a MESMA lista em toda máquina, e quem tem a
lista ordenada não pode recuperar a do disco — o contrário (`sorted(os.listdir())`)
é uma linha. Está aqui escrito porque é a única coisa em que estes dois módulos
não são o Python.

**111.6 O runtime passou a SEIS módulos** (`psrt_os.p`, camada 4 ao lado da
biblioteca portada), e isso custou **seis** listas de módulos editadas à mão:
`Makefile`, `tests/run.sh` (três lugares), `tests/psbuild.sh`, `selfhost/main.p`.
A 109 já tinha medido esse preço em quatro; agora são seis, e a primeira vez que
esqueci uma delas o QBE disse `can't open psrt_os.s`. **É o argumento da 1.5 do
pforge** (definição de módulo/TU na linguagem) medido pela terceira vez.

De passagem, uma corrente de dez `strcmp` que decidia quais módulos são builtin
virou `ps_builtin_mod()`, com a lista num lugar só: esquecer de acrescentar ali
dava `cannot find module 'os'`, que não diz nada a quem escreveu o import.

**111.7 O LINK do `pstudio-ps` cobrou o prefixo.** As funções de caminho nasceram
com o nome que tinham no editor — `ps_path_join`, `ps_path_dirname`,
`ps_path_basename` — e o `pstudio-ps` (o porte da 71, que junta o runtime do
pscript com o `psys.p` do editor no MESMO link) parou com `multiple definition of
'ps_path_join'`. Só ali, porque é o único programa do projeto que linka os dois
lados. Agora todo o módulo usa **um prefixo por módulo do runtime** —
`ps_os_join`, `ps_os_dirname`, ... — como `ps_random_`, `ps_json_` e `ps_str_` já
fazem. Vale como regra: um `.p` de aplicação e o runtime compartilham o espaço de
nomes do C, e o linker é o único que avisa.

Gates: `tests/pscript/run/syslayer.psc` (o que toca o disco, com os seis erros
que ele levanta), `tests/oracle/py/paths.psc` (as contas sobre o nome, mil
caminhos contra o CPython) e quatro `tests/pscript/bad/` (aridade, tipo, membro
que não existe, `join` de um pedaço só). Três modos verdes: 269 cada.

## Bateria 110 — os valores cravados: `-D` para o que dimensiona, chamada para o que se ajusta (2026-08-21)

Sua observação: *"alguns valores do gc e da linguagem poderiam ser constantes em
tempo de compilação e outros parâmetros em runtime chamados pelo próprio
usuário"*. Suas três respostas na bateria de perguntas fecharam o desenho.

**110.1 `defined(NOME)` no `const if` de topo.** O padrão de um knob é *"use o
valor de fora, senão o padrão"*, e ele não era escrevível: um nome desconhecido
num `const if` de topo é ERRO — de propósito, porque é o que pega
`__PLANG_LINUXX__` escrito errado. Agora o nome NU segue estrito e
`defined(NOME)` responde se o nome existe:

```python
const if defined(PSRT_GC_BYTES):
    const PS_GC_BYTES = PSRT_GC_BYTES
else:
    const PS_GC_BYTES = 1 << 21
```

`is_defined(NOME)` — como a sema chama a mesma pergunta dentro de uma função
(65.11) — vale também, para ninguém ter de lembrar qual é a grafia de cada lugar.
Nas duas linguagens.

**110.2 O que virou `-D PSRT_*`** (o que dimensiona array ou é limite estrutural,
porque tem de ser conhecido ao compilar):

| knob | padrão | o que é |
|---|---|---|
| `PSRT_BLOCK_BYTES` | 1 MiB | o bloco do heap |
| `PSRT_GC_BYTES` | 2 MiB | o piso do orçamento de coleta |
| `PSRT_GC_OBJECTS` | 200 000 | o disparo por contagem de objetos |
| `PSRT_TRACE_MAX` | 24 | frames no rastro de um erro (array DENTRO do `PsErr`) |
| `PSRT_POLL_MAX` | 64 | descritores num `poll` |
| `PSRT_POOL_MAX` | 8 | o TETO de threads de I/O |
| `PSRT_REPR_MAX` | 8 | a profundidade do `repr` |
| `PSRT_JSON_DEPTH` | 1000 | a profundidade que o json aceita |
| ~~`PSRT_RE_GROUPS`~~ | — | **RETIRADO na S2b.** Existia porque o `regexec` da libc queria um `regmatch_t[16]` fixo. O motor de Thompson aloca por padrão e não tem tecto de grupos — um botão que já não controla nada é pior do que não haver botão |
| `PSRT_GRAVE_MAX` | 16 | blocos envenenados no modo de estresse |

**110.3 O que virou CHAMADA** (o que depende da carga, e só o programa sabe):
o módulo **`gc`** — `gc.collect()`, `gc.tune(bytes=..., objects=...)`,
`gc.stats()` — e **`sys.pool(n)`**.

- **`gc.stats()` devolve `Dict<str, int>`** (live, alloced, objects,
  collections, budget, budget_objects). Um dict e não um record: nenhum tipo novo
  para a linguagem aprender, o `print` já sabe imprimi-lo, e acrescentar uma
  medida depois não quebra programa nenhum.
- **`gc.tune` afina o coletor DE QUEM CHAMA.** Cada worker tem heap e coletor
  próprios (18.1), então afinar num não afina no outro — e isso é a resposta
  certa: um worker que processa imagens e outro que serve texto não querem o
  mesmo orçamento. Zero em qualquer campo é "deixa como está".
- **`sys.pool(n)` tem de vir ANTES da primeira operação de I/O.** O pool sobe uma
  vez e não encolhe (76.3); depois de subir, a chamada LEVANTA com a frase que
  diz o que fazer, em vez de aceitar calada e não ter efeito. O que o programa
  pede vence o ambiente (`PSCRIPT_POOL`) e o número de CPUs, e o teto continua
  sendo o de compilação.

**110.4 Três defeitos no caminho.** Os dois primeiros são do mecanismo de `-D`,
que ninguém tinha exercitado com vários módulos:

> **A const de `-D` era injetada em toda unidade E no header**, e aí quem
> importava o header via a mesma definição duas vezes — "redefinition". Ela
> precisa estar no header (para um header poder USAR o valor) e não pode ser
> emitida nele (senão um `.c` que inclui dois headers define duas vezes em C).
> Agora ela é marcada, a repetição no escopo é a única permitida, e o back end de
> C não a escreve no `.h`.

E o terceiro é o achado da bateria, encontrado porque a suíte de estresse do
coletor rodou sobre o teste novo:

> **`ps_task_clear_recv` não zerava `is_io` nem `work`.** Toda task nascia com
> lixo nesses dois campos; quando o lixo tinha `is_io != 0`, o escalonador seguia
> `t->work` — um ponteiro que nunca existiu — e o programa morria dentro de
> `ps_recvs_poll`. Só aparecia com estresse E heap grande, porque só aí o lixo do
> bloco novo é o veneno `0xDD` do cemitério: `0xdddddddddddde35` foi o endereço
> que o valgrind mostrou. É a mesma família da 107.6 — campo acrescentado depois,
> não inicializado em todos os sítios — e desta vez o campo tinha ANOS. O
> conserto é uma linha em cada caso, no ÚNICO lugar que toda criação de task
> chama.
>
> Por que ninguém tinha visto: com o heap pequeno o lixo era zero, e o
> `gdb`/ASan mudam o layout o suficiente para o programa passar. Quem apontou o
> dedo foi `valgrind --fair-sched` sobre o binário de estresse.

**110.5 O portão.** `tests/knobs.sh` compila o MESMO programa três vezes — padrão,
com `-D PSRT_REPR_MAX=2` (a saída muda de `[[[[[1, 2]]]]]` para `[[...]]`, que é
knob visível sem medir nada) e com os dez knobs de fora ao mesmo tempo — e entrou
no `verify-all`. O que os outros knobs mudam é dimensão de array, e para eles o
teste é continuar compilando e rodando com o valor de fora.

## Bateria 109 — o runtime em cinco camadas, e o que a divisão desenterrou (2026-08-21)

A quebra que a 108 mediu e você aprovou. O runtime era um arquivo de 7 590
linhas; agora são cinco módulos numa PILHA, e a fronteira é o compilador que a
cobra: um módulo que não importa a camada de cima simplesmente não a alcança.

| módulo | linhas | o que é |
|---|---|---|
| `psrt_types.ph` | 775 | as 31 structs, enums e constantes — só tipos |
| `psrt_mem.p` | 539 | blocos, `ps_alloc`, o coletor, a pilha-sombra, o estresse |
| `psrt_val.p` | 3 166 | erro, aritmética, `str`, `list`, `dict`/`set`, `repr`, ordenação, tabelas Unicode, formatação, `any`, buffer, `pack` |
| `psrt_rt.p` | 3 026 | tasks, escalonador, multiplexador, `recv`, pool, socket, arquivo, workers, compartilhados |
| `psrt_std.p` | 833 | `json`, `re`, `random`, `bisect`/`heapq` |
| `psrt_top.p` | 79 | o epílogo: `ps_ctx_done`/`ps_ctx_free` |
| `psrt.ph` | 12 | o guarda-chuva — o programa gerado continua incluindo UM header |

**109.1 Por que os tipos ficam num header só.** O coletor percorre os CAMPOS de
cada tipo da linguagem, então a camada da memória precisa das declarações de
`PsStr`, `PsList`, `PsTask`... sem chamar nada delas. Fronteira de CHAMADA é o
que os módulos garantem; acesso a campo, não. Está dito para não parecer
descuido.

**109.2 As duas exceções, nomeadas.** A memória chama `ps_raise` (o orçamento de
um `nogc` estourado é um erro da linguagem, e erro carrega um `str`, que é da
camada de cima) — uma declaração antecipada com o motivo escrito ao lado. E o
epílogo conhece todo subsistema por definição, que é por isso que ele é uma
camada própria em vez de a memória chamar para cima.

**109.3 O que a divisão achou de código no lugar errado.** Nove funções, e cada
uma explica um susto passado: `ps_alloc`, `ps_new` e `ps_dup` moravam dentro da
seção do HANDLER DE CRASH; `ps_list_slice` e `ps_slice_bounds`, dentro da seção
do `recv`; `ps_buffer_gone`, dentro do `json`; `ps_task_of_int` e
`ps_report_lost`, dentro do multiplexador; `ps_sys_monotonic`, no `sys` (e o
`random` precisava dele, o que fazia a biblioteca chamar o runtime).

Sete funções que eram privadas do arquivo único tiveram de virar públicas
(`ps_dup`, `ps_hash_bytes`, `ps_free_blocks`, `ps_buffer_gone`, os três
comparadores) — de 140, o que confirma a medição da 108: a divisão quase não
alarga a superfície.

**109.4 Um defeito do back end QBE que só um segundo módulo podia mostrar.** Com
vários módulos numa invocação, o QBE morria com *"unknown struct type field"*
numa linha que não era a certa. A causa: `qbe_merge_types` copia para o TU de um
módulo as `static`/`inline` COM CORPO dos outros (§8.5, funções de header
emitidas por TU) — e copiava também as `static def` de um `.p`, que são privadas
DAQUELE TU. O corpo copiado lia uma global que não foi copiada, e o emissor não
tinha o tipo dela. O mesmo valia para uma `const` cujo inicializador nomeia um
ponteiro para função `static`.

A regra passou a ser a que o `.ph` já significava: **corpo de `static`/`inline`
atravessa TU só se vier de um header**. Com um arquivo só nunca houve um segundo
módulo para onde copiar, e por isso ninguém tinha visto.

**109.5 E o achado que valeu mais que a divisão: o cpp rodava repetido.** A
divisão fez o `P -> C` do runtime ir de 0,94 s para **4,08 s**, e cinco módulos
com ~0,55 s cada, todos iguais, não é tamanho — é custo fixo. Era o dump de
macros (`cc -E -dM`) de cada `include <h>`: o PARSE do header já era cacheado, o
DUMP não, e ele roda a cada registro de módulo.

Cacheado por caminho no `Cc`:

| | antes | depois |
|---|---|---|
| runtime em um arquivo | 0,94 s | — |
| runtime em cinco módulos | 4,08 s | **0,58 s** |

Ou seja: a divisão saiu **38% mais rápida que o arquivo único**, e o ganho vale
para todo programa de vários módulos (o pstudio tem seis camadas). E o `cc` das
cinco unidades ainda pode ir em paralelo: 0,72 s em série, 0,28 s com `&`.

> **E um defeito meu no caminho, registrado porque é fácil de repetir:** dois
> vetores paralelos crescendo com a MESMA variável de capacidade. `vec_grow`
> recebe a capacidade por referência; o primeiro cresce e escreve a capacidade
> nova, e o segundo se acha grande e nunca cresce. Virou um par num vetor só. A
> suíte pegou na primeira rodada — o compilador saía com status não-zero e
> stderr vazio.

## Bateria 108 — o runtime usando o P que ele mesmo compila (2026-08-21)

Sua pergunta: *"por que o runtime tem tantas linhas? se a gente usasse os
recursos da linguagem P poderíamos melhorar o código?"*. Medido antes de opinar.

### 108.1 O tamanho é SUPERFÍCIE, não gordura

`psrt.p` tinha 7 658 linhas — 5 831 de código e 1 298 de comentário (17%), 503
funções, **mediana de 6 linhas de código por função**, a maior com 82. Não há
função monstro nem código morto. Por assunto: escalonador+tasks+await 1 715,
strings+Unicode 1 251, stdlib portada 1 069, contêineres 624,
workers+serialização 522, coletor 463, I/O 450, erros/trace/crash 329. É um
coletor com cópia, um escalonador com epoll/kqueue/poll, workers com
serialização, UTF-8 com duas tabelas Unicode, dict compacto, json, MT19937,
sort/heap/bisect, traceback e handler de crash. Cortar linha ali é cortar
recurso. (Para escala: o compilador são 38 312 linhas.)

O que a medição mostrou de verdade é outra coisa: **o runtime estava escrito em P
como se fosse C**. Zero funções genéricas, 3 métodos, 0 traits, 0 `with`, 7
`defer` — contra 18 funções que trancavam mutex. E o C emitido tinha 1:1 com o
fonte, o que confirma: nenhuma abstração em uso.

### 108.2 `defer` nos mutex: 24 destrancadas explícitas viraram 7

Não é estética. Dez daquelas 18 funções trancavam e destrancavam em VÁRIOS
caminhos de saída, e um `return` novo no lugar errado é um mutex vazado — o
defeito que não dá para depurar, porque o programa simplesmente para. O `defer`
do P roda em toda saída do bloco (fim, `return`, `break`, `continue`), então o
par fica escrito uma vez.

Duas coisas aprendidas e registradas:

> **O `defer` do P avalia o que ele guarda na hora de RODAR**, não onde é
> escrito. Num laço que anda um ponteiro, `defer pthread_mutex_unlock(&b->mu)`
> destrancaria o mutex do PRÓXIMO — o local tem de ser amarrado por volta.
> Conferido com um programa de três linhas antes de usar.
>
> **Onde a seção crítica termina ANTES do fim da função, `defer` está errado.**
> `ps_pool_thread` destranca de propósito para rodar a operação de I/O fora do
> trinco; `ps_recvs_poll` liberta a memória fora dele. Esses ficaram explícitos —
> o que mudou é que agora são um lock e um unlock, com a decisão sob o trinco e o
> trabalho fora, em vez de duas destrancadas em dois caminhos.

E as quatro cópias de *"põe a mensagem na fila, avisa o outro lado"* viraram uma
função (`ps_queue_put`), que de passagem corrigiu uma assimetria: o `send_obj`
testava `done` FORA do trinco, e o worker pode terminar entre o teste e o push.

### 108.3 Um leitor para as duas tabelas geradas, e o formato que se descreve

`unicase.bin` (caixa) e `unicat.bin` (categorias) tinham **dois leitores quase
idênticos**: 154 linhas, cada um com o tamanho de entrada de cada tabela cravado
numa cadeia de ifs e três buscas binárias. Eu tive de manter a aritmética de
offset dos dois em sincronia à mão, e foi onde a 105 quase me pegou.

Agora os arquivos **se descrevem**: depois do cabeçalho vem um diretório com
`(quantas entradas, tamanho da entrada)` por tabela, e **toda entrada começa com
`lo` e `hi`** — um mapeamento de um-para-muitos repete o ponto de código, então
`lo == hi`. Com isso o leitor calcula os offsets a partir do arquivo e **uma**
busca binária serve as quinze tabelas dos dois arquivos.

| | antes | depois |
|---|---|---|
| funções de leitura | 11, em dois esquemas | 7, em um |
| buscas binárias | 6 (3 por arquivo) | 1 |
| linhas | 154 | 57 |
| bytes dos dois `.bin` | 50 296 | 50 968 (+672) |

Os 672 bytes são o `lo`/`hi` repetido nas entradas de um-para-muitos. É o preço
de ter uma busca em vez de três, e está pago.

### 108.4 A stdlib fica em P — sua decisão

Eu havia proposto mover `json`, `bisect`/`heapq` e a camada Python do `random`
(~600 linhas) para módulos em **pscript**, compilados junto do programa que os
importa. Você decidiu que **não**: eles ficam em P. Fica registrado para não ser
reproposto — e a consequência é que o runtime segue sendo o lugar da stdlib, com
o preço de cada programa levá-la (o que a 105.5 já mediu: com `--gc-sections` ou
LTO, quem não usa não paga).

### 108.5 O saldo, e o que NÃO valeu

−102 linhas de código, 24 destrancadas → 7, dois leitores → um. E o que eu
recusei, com o motivo:

- **trait/`dyn` para comparador de ordenação**: põe uma vtable no caminho quente
  do sort para trocar três funções por uma;
- **métodos no lugar de funções** (`l.len()` em vez de `ps_list_len(l)`): o nome
  é a ABI que o lowering emite — renomearia tudo para ganhar estética;
- **genéricos nos trios `_int`/`_float`/`_str`**: o P TEM funções genéricas
  (`def max<T>` com `inline max<int>` virando `max_int`, que é o mesmo esquema de
  nome que o lowering já usa), mas os trios só PARECEM duplicados: `ps_sum_int`
  carrega checagem de estouro que `ps_sum_float` não tem, `ps_abs_int` idem.
  Sobrariam umas 40 linhas em troca de uma indireção de instanciação. Fica
  anotado como possível, não como pendência.

## Bateria 107 — a varredura de worker + async, e os oito defeitos dela (2026-08-21)

Você pediu uma varredura das bordas e armadilhas da linguagem, **principalmente
worker e async ao mesmo tempo**. Foram ~40 programas adversariais, cada um com
timeout (um travamento não pode travar a varredura). O modelo se manteve — a
74.1 já tinha tirado o `recv` do condvar, e `timeout`, `race`, `cancel`,
`gather`, socket dentro de worker, worker aninhado, 64 workers, `shared` sob
contenção de 800 mil incrementos e o coletor em estresse passaram todos. O que
caiu foi outra coisa.

### 107.1 Os dois travamentos do canal

> **O pai acabava e o programa ficava pendurado para sempre.** Um worker parado
> em `await parent.recv()`, o pai chega ao fim, o `join` do 36.3 espera o worker
> e o worker espera uma mensagem que já não pode chegar. A fila de SUBIDA sempre
> teve fim (`done`, quando o worker termina); a de DESCIDA não tinha. Agora o
> fim do pai FECHA o canal antes de esperar, e o `recv` do worker termina — que é
> o desligamento cooperativo da 36.4 chegando por si, sem ninguém matar ninguém.
>
> **Os dois esperando um ao outro ficava pendurado calado.** Cada lado agora
> MARCA no bloco que está parado esperando o outro, antes de dormir; se ao marcar
> vê o outro também marcado e as duas filas vazias, nada pode acontecer nunca
> mais e o runtime diz isso. Só é declarado quando TODA espera do contexto está
> presa: com um segundo worker vivo, um socket ou um relógio, alguém ainda pode
> acordar, e acusar aí seria acusar um programa correto.

### 107.2 O `print` de vários workers saía costurado

`print` fazia duas chamadas de stdio — o texto e depois o `\n` — e cada uma
tranca o FILE por si. Cada worker tem heap, coletor e laço próprios (18.1), mas
**não** uma saída própria: stdout é o mesmo arquivo dos nove. Medido: oito
workers imprimindo 200 linhas cada davam **66 linhas costuradas ou vazias** em
1801 — `worker-0-linha-38worker-1-linha-14`. Agora o texto e o `\n` vão na mesma
chamada e o trinco do stdio cobre a linha inteira.

Isto virou gate: `tests/print-atomic.sh` roda a tormenta e confere a FORMA de
cada linha, porque a ORDEM é indeterminada por natureza e não cabe num
`.expected`.

### 107.3 O `for` dentro de `async def` não andava a variável

O pior da varredura, porque era **resposta errada em silêncio**:

```python
async def f() -> int:
    t = 0
    for i in range(3):     # o laço roda três vezes
        t += i             # e `i` vale 0 nas três
    return t               # devolvia 0
```

O laço andava um local do C e o corpo lia o campo do frame, que ninguém
escrevia. Só acontecia SEM `await` dentro do laço — com `await` o laço vai pela
máquina de estados, que já amarrava o campo — e é por isso que a suíte inteira
de async passava: um teste de async naturalmente põe um `await` no meio.

Consertar isso desenterrou o resto da família:

- **`for i in range(3)` deixava `i` valendo 3.** O `for` do P anda a variável
  DELE, e depois do laço ela fica com o cursor. Não é nem o último valor (2, que
  é o que o Python deixa) nem o de fora (que é o que a 64.1 pede). Agora o laço
  anda um cursor próprio e a variável é amarrada no topo do corpo, como os laços
  de lista, string e dict já faziam.
- **A variável de laço de um `async def` era a variável da função de mesmo
  nome.** O frame guarda um campo por NOME, e a 64.1 diz que a do laço é uma
  variável NOVA. Agora ela tem campo próprio, nomeado pela POSIÇÃO do laço — o
  mesmo truque do cursor da máquina de estados, em que as duas passadas chegam ao
  mesmo nome sem combinar nada.
- **A variável de uma comprehension era a homônima de fora**, nas duas máquinas:
  no caminho síncrono a comprehension ESCREVIA nela (e deixava 3 lá), e no async
  o elemento LIA a de fora — `[i * 2 for i in range(3)]` numa função com `i = 7`
  dava `[14, 14, 14]`. A comprehension tem escopo próprio (o do Python) e agora
  tem nome próprio.

> **O que ficou igual e é uma divergência DELIBERADA:** a 64.1 (escopo de bloco)
> diz que a variável do laço não sobrevive a ele, e o Python diz que sobrevive.
> As duas máquinas agora concordam entre si e com a 64.1. Um `x = 2` dentro de um
> bloco quando `x` já existe continua ATRIBUINDO o de fora, como no Python — é
> só o nome NOVO que morre com o bloco, e é para isso que existe o `nonlocal`.

### 107.4 Um erro que ninguém foi buscar desaparecia

Uma task captura o erro dela para o `await`. Se ninguém aguarda, o programa
terminava calado. O Python diz *"Task exception was never retrieved"* e o node
avisa da promessa rejeitada; a razão é a mesma nos três, e a 37.4 já tinha
tomado essa decisão para o worker. Agora sai uma linha no stderr, com posição.

E ela **não** sai quando o erro foi realmente colhido: por `await`, por
`gather_settled` (que devolve a lista de erros), por `first_ok` (que decide pela
falha das outras), nem quando a task foi CANCELADA — o erro de uma task
cancelada é a resposta ao pedido de parar, e `race` cancela os perdedores por
definição.

> **Ao consertar isso apareceu outro:** `raise error("x")` — que é como um
> programa relata a própria falha — chegava ao topo dizendo `?:0`, enquanto todo
> erro do runtime dizia arquivo e linha. `error(...)` não capturava posição
> nenhuma, e `raise e` preserva a original de propósito. Agora ela nasce na
> construção.

### 107.5 A fila de espera era uma pilha

Duas tarefas esperando a MESMA fila de mensagens: a segunda a estacionar recebia
a primeira mensagem. A lista de estacionados era montada pela cabeça e percorrida
pela cabeça. Duas leituras concorrentes do mesmo canal são o caso normal de um
servidor, e a ordem certa é a de chegada.

### 107.6 Um campo novo numa struct do runtime tem de ser inicializado

O alocador do runtime **não zera**: cada função que cria um objeto atribui campo
por campo. Acrescentar `lost` a `PsTask` e esquecer sete sítios de criação deu um
SIGSEGV bonito dentro de um `async def` sob pressão de coletor — o campo tinha
lixo e o `if t->lost != None` escrevia num endereço qualquer. Fica registrado
porque a próxima pessoa a acrescentar um campo vai cair no mesmo lugar.

### 107.7 As três mensagens que passaram a dizer o que fazer

- `unknown name 'x'` depois de um `if/else` que atribui `x` → agora diz que o
  nome morreu com o bloco (64.1) e que o opt-in é `nonlocal x`, que é
  exactamente o que a 64.1 desenhou.
- `unknown type 'worker'` → `Worker<T>`, com o T que atravessa o canal.
- `w.status()` → `status(w)`, função e não método, porque também responde por um
  worker que já foi.

### 107.8 Como o receptor sabe que o canal acabou — DECIDIDO: um predicado

O `recv` de um canal fechado (ou de um worker que terminou) devolve mensagem
VAZIA, e por isso `while True: v = await parent.recv()` girava sem fim e o
programa não terminava. A 45.3 decidiu o lado do `send` por escrito (*"nem
exceção, nem silêncio: o bool diz entregou na fila"*); o do `recv` faltava.

**Sua escolha: um PREDICADO ao lado**, simétrico ao bool do `send`, com o `recv`
intacto — nada do que já estava escrito muda de significado.

```python
while parent.open():          # de dentro do worker
    v = await parent.recv()
    total += v

while w.alive():              # de fora, do lado do pai
    v = await w.recv()
```

Os dois nomes valem nos dois lados (é a mesma pergunta — *ainda pode chegar
mensagem?*); cada um está no lado em que se lê melhor. **"Aberto" inclui a fila
NÃO VAZIA de um lado que já foi**: o que ele mandou antes de terminar continua
sendo mensagem, e um laço que parasse na hora perderia o fim da conversa.

**O predicado é um RETRATO do instante, e isso tem uma consequência que fica
dita:** se o `close` do outro lado acontecer entre a checagem e o `recv`, o laço
dá uma volta a mais e recebe uma mensagem VAZIA. É a corrida clássica de
"perguntar e depois agir" sobre um canal, e ela é inerente a separar as duas
coisas — o `v, ok := <-ch` do Go junta as duas justamente por isso. Quem precisa
de contagem exata combina que a mensagem CARREGUE o sentido (um zero soma zero),
ou fecha antes de o laço começar, que é o que o teste `worker_async` faz. Foi o
coletor em estresse que mostrou a volta extra — em velocidade normal o `close`
sempre chegava primeiro.

**E a outra metade, que o predicado obrigou:** `w.close()` — o pai diz que acabou
de mandar **sem ter de terminar**. Sem isso, `parent.open()` só fecharia quando o
pai saísse, e aí não haveria mais ninguém para ler a resposta do worker — o
predicado seria inútil justamente no laço que ele existe para escrever. Do lado
do worker não existe `parent.close()`: ele fecha ao RETORNAR, que é o `done` que
a fila de subida sempre teve, e a mensagem de erro diz isso.

O protocolo completo, que é o que o teste `worker_async` agora faz:

```python
w = spawn(somador, (0,))
w.send(3); w.send(4); w.send(5)
w.close()                      # acabei de mandar
print(await w.recv())          # e a resposta dele chega
```

### As outras duas respostas da varredura

- **A variável de laço continua com o escopo da 64.1** (ela não sobrevive ao
  laço), agora igual nas duas máquinas. A divergência com o Python fica, e fica
  DELIBERADA.
- **`await` continua só em `async def` e no topo do programa** (39.4). Um worker
  que precisa esperar declara a entrada como `async def`, e a mensagem de erro já
  diz onde `await` vale.

## Bateria 106 — ordenação estável, `bisect` e `heapq` (2026-08-21)

Três coisas que vieram do CPython, e uma que veio de olhar o que o `qsort`
prometia.

**106.1 O `sorted` simples não era estável — era estável NA GLIBC.** Os caminhos
com `key=` e `cmp=` sempre ordenaram ÍNDICES com um merge sort escrito aqui, que
é estável por construção. O caminho simples (list de int, float ou str) chamava
`qsort`, e a estabilidade do `qsort` **não é especificada**: o da glibc é um
merge sort e sai estável por acidente, o do macOS é um introsort e não sai. O que
se observa disso é pequeno e é real:

- `sorted([0.0, -0.0])` imprime `[0.0, -0.0]` aqui e podia imprimir o contrário
  no Mac — `0.0` e `-0.0` comparam IGUAIS e imprimem DIFERENTE;
- duas strings de mesmo conteúdo trocariam de identidade.

Uma ordem que depende de qual libc compilou é uma resposta diferente por
plataforma. Agora é um merge sort nosso, sobre os valores, com o empate sempre
para a esquerda.

**106.2 Metade do Timsort, e a metade que ficou fora.** O que entrou é a
DETECÇÃO DE CORRIDAS (com o `minrun` de 32 e insertion sort binário nas curtas):
uma lista já ordenada — ou já ordenada ao contrário — sai numa passada, que é o
caso comum de quem chama `sorted` sobre algo que já veio de um `sorted`. Medido
em um milhão de inteiros:

| | aqui | python3 |
|---|---|---|
| aleatório | 0,243 s | 0,306 s |
| já ordenado | 0,017 s | 0,011 s |

O que ficou fora é o **merge galopante**. Ele muda o CUSTO em padrões
específicos e não muda a ORDEM, que é o que se observa — e é onde vivia o defeito
de invariante que a verificação formal do Java achou em 2015. Se o custo
aparecer num programa de verdade, entra com medição.

**106.3 `bisect` e `heapq`, portados de `Lib/bisect.py` e `Lib/heapq.py`.** São
os dois módulos do Python que são algoritmo puro — não há nada de específico da
linguagem dentro deles, então portar é transcrever. `bisect_left`,
`bisect_right`/`bisect`, `insort_left`, `insort_right`/`insort`, `heappush`,
`heappop`, `heapify`.

**O teste é o ARRAY INTEIRO, não a ordem de saída.** Um heap correto pode ter
mil formas e só uma é a que o `heapq` do CPython produz; o oráculo
(`tests/oracle/py/algos.psc`) imprime o array a cada `heapify`, `heappush` e
`heappop` e o `python3` faz o mesmo. Eles batem passo a passo — o que prova que
a ordem de peneira é a de lá, e não um heap qualquer que acerta o mínimo.

**Sobre int, float e str**, e dito na mensagem de erro: a ordem que o `bisect`
assume é a que o `sorted` produz, e essa está definida para os três. Para os
seus tipos, o caminho é `sorted(xs, key=...)` — `Comparable` (62.1) resolve a
ordenação mas não dá um `<` que o heap possa chamar sem adaptador, e esse
adaptador é uma decisão sua.

**106.4 O que não entrou:** `heapreplace`, `heappushpop`, `nlargest`/`nsmallest`
(estes dois tomam `key=` e um iterável, e é meio módulo novo), `bisect` com
`lo`/`hi` (os dois recortes existem com fatia), `functools`, `itertools`.

## Bateria 105 — as categorias do Unicode, e a varredura que cobrou o `ǅ` (2026-08-21)

O que a 104.5 tinha deixado em aberto: `isalpha`, `isdigit`, `isdecimal`,
`isnumeric`, `isalnum`, `isspace`, `isupper`, `islower`, `istitle`, e os
mapeamentos `title`, `capitalize` e `swapcase`.

**105.1 São uma TABELA, e a decisão é a mesma da 89.** `"٣".isdigit()` é True
(três arábico-índico), `"³".isdigit()` também (sobrescrito), `"三".isnumeric()`
é True mas `.isdecimal()` é False. Nada disso segue de regra nenhuma — é a base
de caracteres do Unicode. Então: gerador ao lado (`tools/gen_unicode_cat.py`),
que pergunta ao **Python**, ponto de código por ponto de código, e escreve
`unicat.bin`; o runtime embute (63.1) e faz busca binária. 27 KB, Unicode 15.0.0
estampado no cabeçalho.

**A alternativa que NÃO foi tomada, dita:** responder só para ASCII. Um
`isdigit` que acerta `"7"` e erra `"٣"` em silêncio é pior do que um que não
existe — o programa parece certo e a resposta está errada exatamente onde
ninguém testa.

**105.2 A varredura EXAUSTIVA, e o que ela cobrou.** O par de oráculo
(`tests/oracle/py/unicat.psc`) não escolhe exemplos: percorre todo ponto de
código até U+3000 e depois de 31 em 31 até o fim do último plano, imprimindo os
nove predicados e os cinco mapeamentos de cada um, e o `python3` roda o mesmo
programa. Foi assim que apareceu o defeito que nenhum exemplo escolhido à mão
teria mostrado:

> **Os caracteres de TÍTULO (categoria Lt)** — `ǅ`, `ǈ`, `ǋ`, `ǲ` e uns trinta
> outros — não são maiúsculos nem minúsculos. `"ǅ".isupper()` é False,
> `"ǅ".islower()` é False, `"ǅ".istitle()` é True. Sem um conjunto próprio para
> eles, `isupper` os aceitava (não achava minúsculo nenhum) e `istitle` os
> recusava. Dez faixas na tabela, 84 bytes, e 62 linhas de diff a menos.

**105.3 As definições do Python, que não são as óbvias.**

- **A string VAZIA é False em todos.** Não há contraexemplo, mas também não há
  exemplo, e o Python escolheu False.
- **`isupper` não é "todo caractere é maiúsculo"**: é "nenhum é minúsculo nem de
  título, e ao menos um é maiúsculo". `"ABC1"` é True e `"1"` é False.
- **`istitle`** é sobre o caractere ANTERIOR ter caixa: depois de um com caixa,
  um maiúsculo é erro; depois de um sem caixa, um minúsculo é erro. É por isso
  que `"O'Neill"` é título e `"Hello world"` não é.
- **`title()` não quebra em espaço**, quebra onde o caractere anterior não tem
  caixa — o `do_title` do CPython. Daí `"hello-world".title()` ser
  `"Hello-World"` e `"o'neill".title()` ser `"O'Neill"`.
- **O mapeamento de TÍTULO é um terceiro mapeamento**, nem maiúscula nem
  minúscula: `ǳ` sobe para `Ǳ` e titula para `ǲ`; `ß` titula para `Ss` (dois
  caracteres) e sobe para `SS`. Está na mesma tabela gerada.

**105.4 `casefold` NÃO entrou.** Ele é o `lower` de COMPARAR e difere dele em
uns poucos lugares (`ß` dobra para `ss`, `ﬁ` para `fi`), o que pede a tabela
`CaseFolding.txt`. Oferecer `casefold` como apelido de `lower` seria prometer
uma comparação que ele não faz — o mesmo erro que a 105.1 recusou. Fica fora
até virar decisão sua, e o nome não é aceito (a mensagem lista o que existe).
Também ficaram fora `isprintable` (711 faixas para algo que ninguém pediu — o
formato tem espaço) e `isidentifier` (é uma gramática, não um conjunto).

**105.5 O custo, MEDIDO.** As duas tabelas somam 50 KB de dado só-leitura, e o
runtime é compilado junto de todo programa (16.4) — então um programa que não
usa nenhuma delas parecia pagar as duas. Medido em `dictorder`, que não toca em
caixa nem em categoria:

| como foi compilado | binário |
|---|---|
| `-O0` (o padrão dos testes) | 226 KB |
| `-Os -ffunction-sections -fdata-sections -Wl,--gc-sections` | 41 KB |
| `-Os -flto` | 40 KB |

Ou seja: quem não usa não paga, desde que o build peça — e é o mesmo par de
flags que a 90 já tinha medido para o resto. O `-O0` continua pagando, e isso é
aceitável porque `-O0` é o modo de depurar.

## Bateria 104 — o ferramental de sequência, e quatro defeitos que ele desenterrou (2026-08-21)

A resposta a *"o que falta"*: não era um recurso da linguagem, era o ferramental
que todo programa Python usa na primeira página — `enumerate`, `zip`, `sum`,
`xs.pop()`, `d.update()`, `a | b`, `s.count()`. Tudo aqui é **paridade com o
Python medida contra o Python**: `tests/oracle/py/iterate.psc` e
`tests/oracle/py/toolkit.psc` rodam duas vezes, aqui e no `python3`, e as saídas
são diffadas.

### 104.1 `enumerate`, `zip`, `reversed` e o desempacotar são AÇÚCAR

Os quatro viram o laço de índice que já existia. Não há objeto iterador, pela
mesma razão que `range` e `d.items()` são reconhecidos por FORMA (3.2/61.4): um
cursor mutável precisaria de `struct` — coletado — e o par que o `enumerate`
rende precisaria da tupla como valor dentro de contêiner. A reescrita custa zero
de runtime e dá o mesmo resultado:

| escrito | vira |
|---|---|
| `for i, v in enumerate(xs)` | `for i in range(len(xs))` + `v = xs[i]` |
| `for i, v in enumerate(xs, 1)` | idem, com `i = __k + 1` |
| `for a, b in zip(A, B)` | `for k in range(min(len(A), len(B)))` + os dois índices |
| `for v in reversed(xs)` | `for k in range(len(xs))` + `v = xs[len(xs) - 1 - k]` |
| `for k, v in pares` | o laço da lista + `k = p[0]`, `v = p[1]` |

E valem os dois lugares: statement e **comprehension** — para a comprehension o
parser passou a aceitar `for i, v in ...`, e a sema guarda as amarrações no nó
(tipadas) para o lowering só as emitir.

**Onde eles NÃO são valor, e por quê.** `zip(a, b)` fora de um `for` é recusado
com essa frase: não existe objeto para guardar. `enumerate(reversed(xs))` também
— açúcar não aninha. O iterável de um `for` pode ser qualquer expressão (a sema
guarda um temporário antes do laço, então `enumerate(txt.split())` chama uma
vez); numa comprehension tem de ser um nome, porque não há statement anterior
onde pôr o temporário.

**A divergência, dita:** sobre um dict, `enumerate` é recusado (um dict não
indexa por posição) com a saída à mão — `enumerate(d.keys())`.

### 104.2 Os builtins que faltavam

`sum(xs[, start])`, `any(xs)`, `all(xs)`, `round(x[, n])`, `divmod(a, b)` e
`min`/`max` de UMA lista. As bordas são as do Python e estão no oráculo:
`sum([])` é 0, `all([])` é True (não há contraexemplo), `min([])` LEVANTA.

- **`any`/`all` tomam `List<bool>`**, não uma lista de números: não há
  veracidade implícita (39.3), então `any([x > 0 for x in xs])` é a forma — e a
  mensagem de erro diz isso.
- **`round` é meio para o PAR** (`round(2.5)` é 2), e sem casas devolve **int**.
  Com casas devolve float e o valor é o do arredondamento DECIMAL: escalar por
  10^n e arredondar em binário dá 2.68 para `round(2.675, 2)`, e a resposta é
  2.67, porque o double mais próximo de 2.675 é 2.67499999...  O caminho é o do
  CPython quando ele não tem o dtoa de David Gay: imprimir com n casas (a libc
  arredonda pelo valor exato) e ler de volta.
- **`divmod` é `(a // b, a % b)`** construído no lowering, com cada lado
  amarrado uma vez — a tupla é valor desde a 98.5, então não há função de
  runtime nem par de saída por ponteiro.

### 104.3 Os métodos que faltavam

- **lista**: `pop([i])`, `extend`, `clear`, `copy`, `index`, `count`, `remove`,
  `sort`, e os operadores `a + b` e `a * n`. `index`/`count`/`remove` procuram
  por CONTEÚDO, com a regra do `in` (55.4). `pop` LÊ antes de tirar, e a ordem
  importa: normalizar o índice (onde a lista vazia levanta), ler, e só então
  fechar o buraco.
- **`xs += ys` ESTENDE no lugar**, não é `xs = xs + ys` — a diferença aparece
  com dois nomes para a mesma lista, e o Python estende.
- **dict**: `pop(k[, d])`, `setdefault`, `update`, `clear`, `copy`. `pop(k)`
  levanta e `pop(k, d)` não, a mesma divisão de `d[k]` contra `get`.
- **set**: `discard`, `update`, `clear`, `copy`, e os operadores `|`, `&`, `-`,
  `^`, `<=`, `<`, `>=`, `>` (subconjunto, estrito nos dois abertos).
- **str**: `count`, `rfind`, `index`, `rindex`, `find(sub, start)`, `split()`
  sem separador (corridas de espaço, sem pedaço vazio — outra função, porque
  `" a  b ".split()` dá dois pedaços e `.split(" ")` dá cinco), `splitlines`
  (com TODAS as fronteiras de linha do Python, `\r\n` e as do Unicode),
  `removeprefix`, `removesuffix`, `strip(chars)` nas três direções, `ljust`,
  `rjust`, `center` e `zfill`. Todo índice que sai é de CARÁCTER, como `s[i]`
  indexa (3.4).
- **`center` tem uma regra torta e ela foi copiada**: o CPython faz
  `left = folga // 2 + (folga & largura & 1)`, então `"hi".center(7, "*")` é
  `***hi**` e não `**hi***`. Metade para cada lado erra metade dos casos ímpares.
- **`zfill` põe o sinal antes dos zeros**: `"-42".zfill(5)` é `"-0042"`.

### 104.4 Quatro defeitos que a reescrita desenterrou

Nenhum deles era novo, e três davam RESPOSTA ERRADA em silêncio:

> **1. Uma expressão-vírgula como limite de `for` no back end de C.** As três
> partes do `for` são impressas dentro de uma expressão maior (`v = <from>`,
> `v < <to>`, `v += <step>`) e eram emitidas com precedência 0. Uma vírgula ali
> reassocia: `v < (a, b)` sai como `(v < a), b`, cujo valor é `b` — o laço
> compara com a coisa errada e **não para**. O `zip` produz exatamente essa
> forma (`min(len(a), len(b))` amarra os argumentos primeiro). O QBE não tinha o
> problema: é texto de C, e só o back end de C reassocia.
>
> **2. Uma comprehension cujo ITERÁVEL é outra comprehension perdia o corpo.**
> `[x for x in [y * 2 for y in ys]]` devolvia `[]`. O campo com o corpo já
> lowerado era ZERADO no fim em vez de reposto, então a de dentro apagava o da
> de fora e o laço externo saía vazio. Sem erro nenhum — lista vazia.
> `{v: k for k, v in d.items()}` é a mesma coisa depois da reescrita da 61.4.
>
> **3. Um limite de laço com temporário dentro de um `async def`.** O `pre` (as
> declarações que o limite precisa) não era despejado no ESTADO da máquina, e o
> C saía com `__ord2` sem declaração — erro de compilação, não resposta errada,
> mas apontando para um arquivo que ninguém escreveu.
>
> **4. Uma tupla com `struct` dentro era classificada como PURA.** Um `PT_NAME`
> é record (bytes puros) ou struct (referência que o coletor move), e a pureza
> olhava só o kind. A tupla nascia `record` com um ponteiro dentro: o P recusou
> com uma mensagem sobre pureza — e se não tivesse recusado, o coletor não veria
> a referência.

E um quinto, no P e não no pscript: **um nome que é palavra-chave do C** (`signed`,
`register`, `union`) era declarado sem reclamação e o `cc` recusava o arquivo
gerado. Agora o P recusa no lugar onde a pessoa escreveu.

### 104.5 O que ficou de fora, e por quê

- **`isdigit`/`isalpha`/`isspace`/`isupper`/`islower`/`isalnum`, `title`,
  `capitalize`, `swapcase`, `casefold`**: precisam das CATEGORIAS do Unicode, que
  são uma tabela — a mesma decisão da 89, que gerou `unicase.bin` do Python com
  um script ao lado. Fazer metade (só ASCII) daria uma resposta diferente da do
  Python para o primeiro dígito arábico, em silêncio. Fica como bateria própria,
  com gerador e oráculo. (`ps_str_is_space_cp` existe e está completo: o
  conjunto do Python são 29 pontos de código, conferidos contra ele.)
- **`partition`/`rpartition`** (devolvem tupla de três), **`rsplit`**,
  **`expandtabs`**, **`translate`**: ninguém pediu ainda.
- **`map`/`filter`**: são preguiçosos no Python e a comprehension faz o mesmo
  sem objeto intermediário — se entrarem, entram como açúcar, e isso é decisão
  sua.
- **`sort(key=...)`** no lugar: `sorted(xs, key=...)` existe e devolve outra
  lista; ordenar no lugar com chave pede o mesmo adaptador com uma escrita de
  volta, e o valor disso ainda não apareceu.

## Bateria 103 — `random`, `math` e `time`: portados, não inventados (2026-08-21)

Os três primeiros módulos da biblioteca, e o primeiro caso em que a resposta foi
**buscar o código do CPython** em vez de escrever o nosso. Você levantou isso
textualmente: *"algumas coisas dessas talvez conseguimos até mesmo portar do
cpython né"*.

**103.1 `math` não tem nada a portar, e isso é o resultado.** É a libm, que já é
a implementação de referência do Python — `math.sqrt` do CPython é `sqrt(3)`. As
22 funções descem para a chamada direta, sem função de runtime no meio. O que
sobrou para DECIDIR ali é o contrato, não o cálculo:

- **`floor`, `ceil` e `trunc` devolvem `int`**, como no Python, e é por isso que
  `xs[math.floor(2.7)]` indexa. As outras devolvem `float`. Devolver float em
  todas seria mais simples e transformaria todo índice num cast à mão.
- **`inf` e `nan` vêm do RUNTIME**, não de um literal. Escrevê-los como um
  trecho de C (`((double)(1.0/0.0))`) funcionou no back end de C e saiu no IL do
  QBE como `d_((double)(1.0/0.0))`, que não é um número — o back end de C
  perdoou o que o outro não perdoa, que é exatamente o defeito que validar nos
  três modos existe para pegar. `INFINITY` e `NAN` da libm não servem porque
  estão sob feature macros que o `-std=` do C gerado pode não ter.
- **`pi`, `e` e `tau` são literais** com os dígitos que um double aguenta.

**103.2 `random` é o MT19937 do CPython, transcrito.** `Modules/_randommodule.c`
(que é o download de Matsumoto e Nishimura, BSD de três cláusulas) mais a camada
de `Lib/random.py` — `_randbelow_with_getrandbits`, `randint`, `randrange`,
`choice`, `shuffle`, `uniform`, `gauss`, `expovariate`. Atribuição no cabeçalho
do arquivo: PSF-2.0 e a licença do MT.

**O motivo de portar em vez de escrever um gerador qualquer** é que ele fica
TESTÁVEL: com a mesma semente a sequência tem de ser a MESMA do Python, e aí
`tests/oracle/py/rng.psc` compara número por número — 10 doubles crus, cada
largura de `getrandbits`, `randint`, as três formas de `randrange`, `shuffle` de
seis tamanhos, `choice`, `uniform`, `gauss`, `expovariate`, semente grande,
negativa e zero. Um gerador escrito à mão passaria em qualquer teste que eu
mesmo escrevesse.

E foi o que aconteceu na prática — três defeitos que só um oráculo pega:

> **`k = n.bit_length()` é de `n`, não de `n-1`.** Contar os bits de `n-1`
> distribui perfeitamente e diverge do Python exatamente na POTÊNCIA DE DOIS:
> `bit_length(4)` é 3, então o Python sorteia 3 bits e descarta metade dos
> sorteios. A minha versão sorteava 2 bits e nunca descartava. Passa em qualquer
> teste de aleatoriedade; foi pega pelo primeiro `shuffle` de uma lista de
> quatro.
>
> **O `gauss` guarda o par.** O método polar produz DOIS normais de uma vez e o
> Python devolve um e guarda o outro. Jogar o segundo fora consome o dobro de
> uniformes e diverge da segunda chamada em diante — e `seed()` tem de jogar o
> par pendente fora, senão a mesma semente dá números diferentes conforme o que
> foi sorteado antes dela.
>
> **`time.time()` estava devolvendo tempo de máquina ligada.** O `ps_sys_time`
> que já existia era `CLOCK_MONOTONIC` — certo para os prazos do laço de
> eventos, que é para o que ele foi escrito, e errado para `time.time()`, que
> respondeu 32 mil em vez de 1,7 bilhão. Agora são dois relógios com dois nomes:
> `ps_sys_monotonic` (o de dentro, todos os prazos, `time.monotonic()`) e
> `ps_sys_time` (`CLOCK_REALTIME`, só `time.time()`). Nenhum substitui o outro:
> medir duração com o de parede dá tempo negativo no dia em que o ntp corrige a
> máquina.

**103.3 O estado do gerador é POR CONTEXTO**, alocado na primeira chamada e
semeado de `time`+`pid` se ninguém semeou. Cada worker tem heap, coletor e laço
próprios (18.1); compartilhar 624 palavras de estado entre threads seria uma
corrida de dados com aparência de número aleatório.

**103.4 `getrandbits` acima de 63 bits é RECUSADO** em tempo de execução, e não
truncado: o Python devolve um inteiro grande e aqui `int` são 64 bits (7.2).
`randrange` com passo zero ou intervalo vazio também levanta, como no Python.

**103.5 O que ficou de fora e por quê.** `sample` e `choices` (devolvem lista
nova, entram com a varredura do toolkit de sequências), `normalvariate` (no
CPython 3.11+ é o método da razão de Kinderman-Monahan, um algoritmo diferente
do `gauss`, e portar por metade não dá paridade), `betavariate` e companhia. A
semente aceita só `int` — o Python aceita `str`/`bytes` passando por sha512, o
que arrastaria hash criptográfico para dentro do runtime por causa de
`random.seed("abc")`.

## Bateria 102 — `epoll` e `kqueue`, finalmente (2026-08-20)

A 18.4 pediu os dois e recusou `poll()` por escrito, em julho. Chegou agora
porque o que faltava não era o código: era o `const if` da 99.

**102.1 Um `ps_mux_wait`, três corpos.** O que muda por plataforma é só COMO se
dorme; o que se espera é o mesmo, e por isso a coleta do conjunto de interesse
(`ps_mux_collect`) é escrita UMA vez, fora dos blocos de plataforma.

  * **Linux, `epoll`:** o conjunto é PERSISTENTE. Cada volta marca o que ainda
    interessa, o que ninguém pediu sai (`EPOLL_CTL_DEL`), e o que é novo entra —
    então uma volta em que nada mudou custa **zero** syscall de contabilidade,
    contra a cópia do vetor inteiro para o kernel que o `poll` paga sempre.
  * **macOS, `kqueue`:** o mesmo, com changelist. **NÃO foi rodado**: esta
    máquina é Linux, então este ramo foi escrito para ser LIDO — uma changelist,
    uma espera, a mesma regra de drenagem. Se estiver errado, erra de um jeito
    que a primeira execução num Mac mostra na hora, e isso está dito em voz alta
    em vez de implícito no silêncio.
  * **Onde nenhum dos dois existe: `poll`**, que é o que havia — e fica, porque
    "a plataforma que ainda não encontramos" também tem de rodar.

**102.2 O teto de 64 descritores era do `poll`, e sai com ele.** A espera com
`poll` olhava `PS_POLL_MAX` de cada vez e voltava em 2ms para ver o resto; com
`epoll`/`kqueue` não há vetor para copiar, então não há teto. Metade do motivo
pelo qual a 18.4 pediu isso era exatamente essa.

**102.3 Um multiplexador por CONTEXTO** (22.3), criado na primeira espera e
fechado no `ps_ctx_free` — um worker que veio e foi não deixa descritor atrás.

> **E o que estava escondido atrás do `poll`:** a bateria 101. Fui ler o
> multiplexador antes de trocá-lo e o achei comendo o dado do socket. O `epoll`
> tem a mesma regra de drenagem, escrita agora uma vez para os três caminhos.

Portões: os mesmos de sempre, agora rodando sobre `epoll` — a suíte pscript nos
três modos (223), `net-late.sh`, e o `gc-stress` com 100 programas, dos quais os
de socket, timer, worker e servidor HTTP são os que exercitam esta espera.

## Bateria 101 — o laço estava COMENDO o dado do socket (2026-08-20)

Achado ao ir implementar o `epoll` que a 99 destravou: antes de trocar o
multiplexador, li o que o atual faz.

**101.1 O defeito.** O laço esperava com `poll` e, ao acordar, DRENAVA todo
descritor que tivesse disparado — `read` até EAGAIN, num buffer de 64 bytes que
é jogado fora. Isso está certo para o cano de uma fila (o byte lá dentro é só
uma batida na porta: o dado real está na memória compartilhada) e é destrutivo
para um SOCKET, onde o que está dentro do descritor É o dado que o programa
pediu. O servidor perdia a mensagem inteira e via só o fim da conexão.

**101.2 Por que a suíte inteira escondia.** Todo cliente dos nossos testes
escreve LOGO depois de conectar. Aí o dado já está no socket quando o `read` é
emitido, o syscall acerta na primeira tentativa, e o laço nunca estaciona
naquele descritor — o caminho do defeito não é tocado. Basta o cliente pausar
antes de escrever, que é o que um cliente de verdade faz.

E não dá para reproduzir com o cliente na MESMA thread: qualquer coisa que ele
faça acontece ENTRE dois polls, então o dado sempre chega antes de o laço
estacionar. O portão (`tests/net-late.sh`) são por isso dois PROCESSOS, os dois
em pscript, e o cliente pausa 0,4s depois de conectar. Sem o conserto ele
imprime `got 0`; com ele, `got 22 data that arrives late`.

**101.3 O conserto.** Cada descritor que entra na espera diz se pode ser
drenado: cano de fila sim, socket NÃO. É uma linha por caso na coleta e uma
condição no laço da drenagem — e é a distinção que o código nunca tinha feito
explícita, porque o único descritor que existia quando ela foi escrita era cano.

## Bateria 99 — `const if`: o P ganha condicional de compilação (2026-08-20)

A 18.4 recusou `poll()` por escrito e pediu `epoll`/`kqueue`; o loop usa
`poll()`. A varredura mostrou que isso não era trabalho pendente, era decisão
travada: escrever os dois exige escolher no C EMITIDO, e o P não tinha como.

**99.1 `const if`, com a condição avaliada em compilação.** Sua formulação:
*"um const if ou comptime if... que eu me lembre ele já avalia if constantes
durante o processo"*. Fica `const if`, porque a palavra já existe no P para
exatamente esta ideia (`const def` é função de comptime) e o que ela qualifica é
a CONDIÇÃO. O ramo não tomado **não é checado** — é isso que permite a um
caminho nomear símbolo que a outra plataforma não tem.

**99.2 Vale no TOPO também**, não só dentro de função (decisão sua): `include` e
declaração entram por plataforma, e os layouts vêm do sistema em vez de serem
copiados à mão. `struct epoll_event` e `struct kevent` são estáveis há quinze
anos, mas copiar layout é o tipo de erro que o compilador não avisa — e a única
saída que não copia é deixar o header entrar.

**99.3 De onde vem a plataforma.** Um predefinido do compilador, no formato dos
que já existem (`__FILE__`, `__DATE__`, `-D`): a máquina que GERA o C é a que vai
compilá-lo no fluxo normal, então a resposta é a do host. O seed do compilador não
depende disso — o plangc não usa `epoll`.

**99.4 Consequência aceita:** é construção nova numa linguagem que se quer
estável, e serve a toda diferença de plataforma futura, não só a esta. É o
contrário de uma flag de build, que tira a decisão da linguagem e a põe num
lugar que alguém tem de lembrar.

**99.5 Vai para o pscript também** (decisão sua, 2026-08-20). Mesma grafia, mesma
regra, mesmo lugar: instrução dentro de função e declaração no topo. No pscript
os predefinidos de plataforma dobram para BOOL e não para inteiro, porque lá uma
condição toma bool e nada mais (40.1) — "estou no linux" é um sim ou um não.

### 99.6 Como ficou, e o que já existia

O `if` comum do P **já** dobrava condição constante e **já** checava só o ramo
vivo (`if_sel`, na sema). Então o trabalho não era a poda: era a GARANTIA. Sem
ela, um erro de digitação na condição a torna de runtime, os dois ramos passam a
ter de compilar, e o erro sai do compilador C três camadas adiante.

  * **Dentro de função:** `const if` é a mesma poda, com a sema recusando
    condição que não dobra — e recusando também um `label`/`case` dentro (esses
    são alcançáveis por `goto` de fora, então o ramo não pode ser descartado).
  * **No topo:** respondido no PARSER, porque o que um ramo guarda é o
    `include <sys/epoll.h>` que o outro sistema não tem — quando a sema roda, o
    header já foi lido. O que a condição pode olhar é, por isso, restrito ao que
    o parser sabe: os predefinidos e os `-D`. Um nome, `not`, `and`, `or`, e
    `__PLANG_OS__ == "..."`.
  * **De onde vem a plataforma:** `uname`, não `#ifdef` — este arquivo é
    compilado de C gerado que não tem preprocessador próprio, então a resposta
    tem de vir de onde não precisa de um. `-D` sobrescreve, que é o que um build
    cruzado precisa.

Portões: `tests/cases/constif.p` e `tests/pscript/run/constif.psc` — os dois com
saída IGUAL nas duas plataformas de propósito (um teste de plataforma que só
passa numa é um teste que a outra não roda), cada um incluindo o header do seu
sistema e chamando a API que só existe nele; mais
`tests/errors/p_constif_runtime.p` e dois programas em `tests/pscript/bad/`.

## Bateria 100 — release por padrão, `-g` para o rastro inteiro (2026-08-20)

**100.1 Três coisas, e o padrão é o rápido.** Sem flag: sem frame de folha (a
otimização da 49.4), `assert` LIGADO, e o rastro nomeia quem tem frame. `-g` (ou
`--debug`): frame em TODA função de pscript, e o rastro nomeia todas. `-O`: tira
o `assert` (46.4). É a divisão que o C tem, e por isso a que quem compila já
espera — e o número do placar é o do padrão.

Medido no fib(35), que é nada além de chamada: 0,03s sem `-g`, 0,05s com.

**100.2 Pendente de MEDIÇÃO, ideia sua: inlinar função de pscript.** Uma função
inlinada não tem frame, então o custo do `-g` cai junto — e o do padrão também.
Não é decisão ainda: é para medir e voltar com número. O que já se sabe é que a
shadow stack complica o caso (38.3: o endereço de todo local coletado escapa, e
inlinar move esse endereço para o frame de quem chamou), e que o `cc -O3` já
inlina o C gerado — então a pergunta real é se inlinar ANTES, no P, tira frame
que o C não consegue tirar.

## Bateria 96b — o tamanho de `T[N]` vindo de um `const` (2026-08-20)

Achado ao escrever o teste da 96: `const N: int = 4` seguido de `xs: int[N]`
emitia um array de tamanho NENHUM, e o C falava três camadas adiante ("flexible
array member in a struct with no named members"). A 33.4 diz que `T[N]` é tipo
completo; escrever o tamanho como um nome é o que um programa de verdade faz.

**A causa é uma regra do C que o C++ não tem:** o tamanho de um array é
*constant expression*, e um `static const int` NÃO é uma delas — em C++ é, e é
daí que vem a intuição errada. Então o nome tem de ser dobrado para o número
aqui, onde o valor é conhecido, em vez de sair como identificador que o C
recusaria.

Agora um `const` com literal inteiro serve de tamanho, e qualquer outra coisa é
recusada com a razão: `xs: int[n]` com `n` variável diz que o tamanho tem de ser
conhecido em compilação, em vez de deixar o C reclamar de outra coisa.

Portões: a linha do `const WIDTH` em `tests/pscript/run/byref.psc` e
`tests/pscript/bad/array_size_var.psc`.

## Bateria 96 — `const` no topo, e o congelamento que faltava (2026-08-20)

Duas metades de uma decisão (61.3), e só uma existia.

**96.1 Um `const` que precisa ser CONSTRUÍDO agora existe.** `const NAMES =
["ada"]` era recusado com "a module-level value that has to be built at run time
is not compiled yet": um const de módulo virava um `static` do C, e um static
não segura uma lista. Mas uma variável de módulo MUTÁVEL já mora no conjunto do
próprio contexto e é construída na ordem do programa — então um const também. O
que `const` SIGNIFICA é assunto da sema; ONDE ele mora é pergunta sobre o
contexto, e a resposta já estava escrita ao lado.

O inicializador roda antes das instruções do programa, na ordem da declaração —
então qualquer instrução pode ler um const, que é o motivo inteiro de existir, e
o inicializador de um const só pode olhar consts declarados antes dele, que é a
regra que o P tem para um static.

**96.2 E `const` congela FUNDO.** A 61.3 diz que const proíbe rebinding E
mutação. Rebinding era recusado; `NAMES.append(x)` não era, nem `NAMES[0] = x`.
Agora os dois são, onde o const estiver — módulo ou local — e a checagem anda até
a RAIZ da expressão, porque `cfg.rows.append(x)` muta o que `cfg` tem tanto
quanto `cfg.append(x)` mutaria.

> **A marca de congelado tem de ser SEPARADA de `is_const`, e descobrir por quê
> custou um build quebrado.** `self` num método de `struct` é const no sentido de
> não poder ser reapontado, e mutar o que ele aponta é a razão inteira do método
> existir (20.1). Com uma marca só, o porte do pstudio parou de compilar na
> primeira linha que escrevia num campo. O `in self` de um `record` é congelado
> nos dois sentidos (57.1), e agora a mensagem para esse caso diz isso em vez de
> falar de const.
>
> **E o campo novo tinha de ser inicializado à mão**, porque o vetor de locais
> vem de `vec_grow`, que devolve memória não inicializada — o comentário que
> avisa isso está três linhas acima do lugar onde eu esqueci. O sintoma foi um
> local chamado `out` reportado como const no meio do pstudio.

Portões: `tests/pscript/run/const_deep.psc` e quatro programas em
`tests/pscript/bad/` (append, escrita indexada, um const local e o `in self` de
um record).

## Bateria 95 — `run`, e o cache que a 15.3 tinha pedido (2026-08-20)

**95.1 `plangc run x.psc [args...]`, e `pscript x.psc [args...]` sob o alias.**
A 6.3 pediu "compilado, mais um comando que roda"; a 15.3 pediu o cache; a 16.2
pediu que só o que mudou recompile; a 50.3 pediu o alias com CLI própria. Nada
disso existia — compilava-se com o `plangc` e linkava-se com o `cc` à mão, que é
o que o `tests/psbuild.sh` faz há meses.

Tudo DEPOIS do arquivo é do PROGRAMA, como em `python -O x.py args`: flag de
compilador vem antes. O `run` faz `execv`, então o status de saída do programa É
o do processo e nenhum shell precisa ser confiado com os argumentos.

**95.2 O cache é de CONTEÚDO, com manifesto.** A promessa da 15.3 é "guarda por
hash do fonte e recompila só o que mudou", e o que a torna real é o manifesto:
uma chave feita do arquivo pedido, dos BYTES do compilador e das flags que mudam
o que ele emite; e, sob essa chave, a lista de todo arquivo que a última
construção leu, cada um com o hash do seu conteúdo. Se todos ainda batem, nada é
gerado — o binário nomeado na primeira linha é exec'd direto.

Tem de ser todo arquivo e não só o da linha de comando, porque `import` traz
módulos: um cache que os ignorasse rodaria o binário de ontem depois da edição de
hoje, que é o único modo de falhar que importa num cache de build.

> **Os bytes do compilador, e não o tamanho com a data.** `st_mtime` é MACRO no
> glibc e no macOS, então o membro atrás dele depende das feature macros com que
> o header foi lido — e este arquivo é lido com umas e compilado com outras (foi
> o que aconteceu na primeira tentativa). Ler um megabyte custa um milissegundo e
> não pode estar errado.

**95.3 Medido:** 2,9s na primeira vez (o `cc` compila o runtime inteiro) e
**4 ms** nas seguintes. É a diferença entre "linguagem compilada" e "linguagem de
script", e ela mora inteira nesse cache.

Portão: `tests/run-cmd.sh`, dentro do 6b do `verify-all`. Ele não compara uma
saída, compara COMPORTAMENTOS — que os argumentos chegam, que a segunda vez não
chama o `cc` (medido, não presumido), que editar o fonte invalida, que editar um
módulo IMPORTADO invalida, que o status de saída é o do programa, e que o alias
faz o mesmo.

## Bateria 94 — o rastro de pilha, e o NULL que ele desenterrou (2026-08-20)

**94.1 O erro carrega a pilha (15.2/34.2), capturada no RAISE.** Tinha de ser no
raise: quando alguém reporta, a pilha já desenrolou. Cada frame que pertence a
uma FUNÇÃO leva o nome e o arquivo; frame de bloco não leva nada, porque um
rastro que repetisse a mesma função uma vez por bloco seria ruído. Vinte e
quatro frames num vetor fixo dentro do erro — texto estático, nada para o
coletor seguir, e reportar não pode precisar de memória.

```
prog.psc:26: error: integer division by zero
  in raises (prog.psc)
  in deeper (prog.psc)
  in middle (prog.psc)
```

**94.2 E o crash também diz onde estava (12.4).** Um handler de
SIGSEGV/SIGBUS/SIGFPE/SIGILL lê a shadow stack, imprime os frames e MORRE do
mesmo jeito que morreria — o status de saída e o core ficam iguais. Não captura
nada; diz onde. Era exatamente a frase da 12.4 ("crash e debugável não são
opostos") e faltava.

> **O que ele não faz, dito em voz alta:** um crash que acabou a PILHA (recursão
> infinita) não é reportado — o handler rodaria na pilha que acabou de estourar.
> Reportar isso exige pilha alternativa, que exige `sigaction`, cujo membro do
> handler é um MACRO sobre uma union com nome diferente no glibc e no macOS. E
> macro que não é número não atravessa a fronteira de header (72.4). Sem
> `#ifdef` de plataforma no meio do runtime.

**94.3 O que escrever o teste do 94.1 desenterrou, e é mais grave que ele: o
ZERO de um tipo coletado era NULL.** Uma função que LANÇA devolve o zero do seu
tipo, e para `str`/`list`/`dict`/`struct` esse zero era NULL. Só que quem chamou
está no MEIO de uma expressão quando recebe: `t + deep(n)` entrega o resultado
direto ao `ps_str_concat`. A promessa da 49.2 — "com exceção pendente, toda
chamada seguinte volta sem fazer nada" — vale para chamada que CHECA, e uma
função de runtime que dereferencia o argumento não checa. Então o NULL era um
segfault em vez de uma exceção pendente. Um programa de sete linhas derrubava o
processo, e o defeito era anterior a tudo o que esta bateria fez.

**Agora o zero de um tipo coletado é um OBJETO VAZIO válido** — uma alocação de
bump num caminho que já está desenrolando, e o invariante cabe numa frase. Vale
para `str` (vazia), `list` e `dict` (vazios) e `struct` (zerado pelo `ps_new`).

**94.4 RESPONDIDA na bateria 100: `-g` liga, e o padrão é o rápido.** O texto
abaixo fica porque é a medição que decidiu.
Uma função sem nada coletado dentro não tem frame nenhum (a otimização de folha
que a 49.4 deixou anotada), então não pode ser nomeada. `-g` dá frame a
toda função de pscript e nomeia todas — e o preço, medido no fib(35), que é
nada além de chamada: **0,03s viram 0,05s**. Em código de verdade é ruído; num
benchmark de chamada é metade.

Sua escolha: **release por padrão, `-g` liga** (100.1) — e o `-g` também pede
`-g -O0` ao compilador C no `run`, porque um rastro completo com o binário
otimizado ainda deixa metade da pergunta sem resposta.

Portões: `tests/pscript/run/trace.psc` (o rastro e o zero que não crasha),
`trace_full.psc` (o mesmo com `-g`, para ver o que a flag ACRESCENTA) e
`crash_stack.psc` (o handler, com uma escrita selvagem em P e saída 139).

## Bateria 93 — a varredura, segunda leva: o que estava decidido e não existia (2026-08-20)

Continuação da 92, mesma regra: nada de novo foi decidido. Cada item abaixo era
decisão fechada sem implementação, e o que a varredura achou de aberto continua
listado como pergunta no fim do `AUDIT.md`.

**93.1 `sorted` ganhou as duas formas que faltavam.**

  * **`key=len` (28.4, escrito lá com esse nome).** Um builtin não é valor — a
    29.3 separou os dois universais de propósito, e `len` não tem fechamento
    para entregar. Então a resposta é escrever a lambda que a pessoa escreveria:
    `key=len` vira `key=lambda __k: len(__k)`, e toda a máquina que já existia
    (o fechamento, o adaptador emitido por sítio de chamada) funciona sem
    mudança.
  * **`Comparable` (62.1), que era a trait declarada para isso e não fazia
    isso.** `sorted(xs)` sobre um tipo que a implementa ordena pelo `cmp` DELE,
    por um adaptador emitido por sítio de chamada — o runtime continua sem
    saber o que é um elemento. Vale para `record` (valor no array) e para
    `struct` (referência no array), e a diferença entre os dois mora no
    adaptador, que é o único lugar que sabe o que os bytes são.

**93.2 E o `sorted(key=)` era QUADRÁTICO.** A ordenação dos índices era por
inserção — estável e O(n²), o que é razoável para os dez elementos que alguém
tinha em mente e é uma armadilha numa linguagem que diz competir com o Python,
cujo sort é O(n log n). Agora é um merge sort estável de baixo para cima,
compartilhado pelas duas formas (`key=` e `Comparable`), e a estabilidade é
teste: chaves empatadas mantêm a ordem de chegada, igual ao Python.

**93.3 O comptime da 65.11 e o `-O` da 46.4.** `__FILE__`, `__LINE__`,
`__func__` e `__COUNTER__` são dobrados para literal pelo front end, exatamente
como o `fold_predefined` do P faz — não há preprocessador em nenhuma das duas,
então quem LÊ o nome tem de responder. `is_defined`, `typestr` e `hasfield`
respondem em compilação, e o primeiro nunca CHECA o argumento: o motivo de
perguntar é que o nome pode não existir. E `-O` (ou `--no-assert`) tira o
`assert` do build, como o `-O` do Python.

> Para o `-O` ter portão foi preciso um mecanismo: um `<nome>.flags` ao lado do
> programa, lido pelo `tests/run.sh` e pelo `gc-stress.sh`. Uma flag que muda o
> que é EMITIDO só se vê construindo o mesmo programa com ela.

**93.4 `out` e `ref` no pscript (65.12), os dois terços que a 55.4 deixou fora.**
O motivo de voltarem é o `record`: ele é valor (52.1), então um grande é copiado
na ida e na volta, e `ref` corta as duas cópias. São palavras CONTEXTUAIS,
reconhecidas só quando um identificador as segue — quem tem uma variável
chamada `out` continua tendo, e isso é teste.

Três coisas são recusadas, cada uma por um motivo que a mensagem diz:

  * chamar sem a palavra (`bump(n)` onde `n` é `ref`) — uma chamada que pode
    escrever na sua variável avisa onde a chamada é LIDA, que é a regra do P;
  * `str`, `list`, `dict` ou `struct` — já são referências, então escrever
    através é o que mutar faz, e reapontar o nome do chamador é para o que
    serve o valor de retorno;
  * um CAMPO ou um elemento (`ref h.v`) — esse endereço aponta para DENTRO de um
    objeto que o coletor move, e a 17.2 recusa isso de tabela. Variável simples
    tem endereço que não anda: local mora na pilha do C, variável de módulo mora
    no conjunto do contexto.

**93.5 E o `T[N]` estava dois terços quebrado.** A 33.4 diz "tipo completo —
local, parâmetro, campo" e a 60.2 diz que ele atravessa por `in`. Três defeitos,
achados por escrever o teste do 93.4:

  1. **`xs[i] = v` sobre um `T[N]` era ESCRITA SELVAGEM.** A atribuição indexada
     não tinha caso para array e caía no caminho de LISTA: lia um cabeçalho de
     `PsList` dos bytes do próprio array e escrevia através do inteiro que
     encontrasse lá. Não crashava — parecia "a atribuição não fez nada".
  2. **Um array LOCAL com literal não compilava.** `ys: int[3] = [1, 2, 3]`
     dentro de função tentava inicializar um array a partir de um `PsList`. Só
     o caso de módulo estava escrito.
  3. **`in xs: int[3]` não compilava.** O `in` embrulhava o tipo num ponteiro, e
     um array já É um ponteiro quando é parâmetro — decaimento é isso. Agora o
     `in` sobre array só diz "não escrevo", que é o que a 60.2 pede.

E daí sai a regra que faltava dizer: **`ref` sobre array é recusado por não
dizer nada** — um parâmetro de array já é referência nas duas linguagens, e
escrever nele alcança o array do chamador. Isso agora tem teste também.

## Bateria 92 — a varredura da especificação, e o que ela cobrou (2026-08-20)

Pedido antigo seu, na 88: *"alem disso veja se implementamos toda a
especificacao"*. Na hora foi respondido pela metade — os corpora mediram o que
eles medem e os oráculos mediram o que o Python e o node sabem responder, e
nenhum dos dois lê este documento. A varredura lê, decisão por decisão, e mora
em `pscript/AUDIT.md`.

**92.1 Nada de novo foi decidido aqui.** Tudo o que a varredura fechou era
decisão já tomada e não cumprida; o que ela achou de aberto está listado como
pergunta no fim do AUDIT, sem implementação nem palpite. Uma varredura que
decide sozinha é a pior forma de decidir.

**92.2 As três comprehensions, fechando a 8.1.** A 8.1 prometeu comprehension e
`set`; o que existia era a de LISTA, e as outras duas formas do Python não
davam erro honesto:

  * `{x for x in xs}` **devolvia uma lista** — com as duplicatas que a chave de
    set existe para tirar. Silenciosamente, e com a contagem certa para o
    contêiner errado, que é pior que recusar. A causa era o parser jogar fora
    QUAL fecho terminou a comprehension: as duas formas de chave viravam a
    mesma árvore. Agora o fecho é parte do significado.
  * `{k: v for x in xs}` não parseava.
  * `[i for i in range(n)]` — a comprehension mais comum que existe — dizia
    "unknown function 'range'", porque `range` só era reconhecido no `for`
    statement. Agora é reconhecido pela FORMA nos dois lugares, pelo mesmo
    motivo: não há objeto range para guardar, nunca houve.
  * `[c for c in s]` sobre string também não ia; agora vai e itera caracteres,
    fechando a 72.3 no outro lugar onde ela vale.

**92.3 Nove diagnósticos que explicam uma DECISÃO em vez de acusar um token.**
`class`, `yield`, `del` e `except` não são palavras reservadas aqui — então um
programa que as usa chegava ao parser como identificador comum e saía como
"expected end of line, found identifier", que não diz nada a quem vem do
Python. Cada uma dessas é uma decisão fechada, e agora cada uma diz qual: a 5.3
(`class`), a 5.4 (`def` dentro de `def`), a 17.4 (`yield` e a expressão
geradora), a 5.1 (`except` é `catch`), o `else` de laço, o `del`, a comparação
em cadeia e o desempacotamento.

> **A comparação em cadeia merece nota**, porque é a única que era um erro de
> semântica e não de vocabulário. `0 <= i < n` em Python é `0 <= i and i < n`;
> lido da esquerda para a direita é `(0 <= i) < n`, que compara um bool com um
> número. Antes disso a sema dizia "cannot order bool and int" — verdade, e
> inútil. Agora o parser recusa a segunda comparação do mesmo nível e escreve o
> `and` na mensagem.

Cada palavra é reconhecida pelo que VEM DEPOIS, então nenhuma delas para de ser
um nome usável: `del = 3` continua sendo uma variável chamada `del`, e isso tem
teste (`tests/pscript/bad/py_word_names`).

**92.4 O que a varredura achou e NÃO fechou** — as quatro estão no fim do
AUDIT, com o que cada uma custa: o `print` de um contêiner (que é promessa
pública e portanto sua), a tupla no pscript (meio caminho entre decidida e
tirada), o `poll()` onde a 18.4 disse `epoll`/`kqueue`, e o `pscript run` com
cache (6.3/15.3/16.2), que continua sendo `plangc` mais `cc` à mão.

## Bateria 91 — 4.4 respondida: o dict itera em ordem de INSERÇÃO (2026-08-20)

Sua resposta: *"implemente. eu concordo."*

**91.1 A resposta é (a): sim, e é GARANTIA da linguagem.** Não "sim mas é detalhe
de implementação" — se não for garantia, um programa não pode se apoiar nela, e o
motivo inteiro de responder sim é que os programas se apoiam.

A pergunta estava aberta desde a quarta bateria e **a tabela hash tinha
respondido (c) por não ter sido perguntada**. O oráculo do Python foi quem
desenterrou isso: um par que iterava um dict divergiu, e a divergência não era
bug nem escolha — era uma decisão que ninguém tomou.

> **Por que sim.** O Python garante ordem de inserção desde a 3.7 e há uma década
> de código que se apoia nisso: JSON que precisa voltar na ordem em que foi lido,
> configuração, saída de teste. O `Map` do JS garante o mesmo. Uma linguagem que
> diz "ergonomia de Python" e itera em ordem de hash surpreende exatamente onde
> menos deveria — e a surpresa aparece como teste que passa na sua máquina e
> falha na do outro, que é a pior forma dela.

**91.2 Como, e por que isso deixa o dict MENOR.** A tabela hash deixa de guardar
as entradas e passa a guardar ÍNDICES para um vetor DENSO de entradas na ordem em
que chegaram — o layout do CPython desde a 3.6. A iteração anda por esse vetor, e
é por isso que a ordem não é *mantida*: ela simplesmente É a ordem.

O tamanho lê ao contrário até a gente contar. Antes: cada um dos `cap` slots
carregava uma chave inteira e um valor inteiro, e a tabela roda a 3/4 de carga —
um quarto daquilo era ar. Agora a parte esparsa é um inteiro por slot e só a
parte densa tem o tamanho do dado. O que se paga é uma indireção a mais na busca:
hash para o slot, lê o número da entrada, compara a chave. É a troca que o
CPython fez e é a certa aqui pela mesma razão.

**91.3 Os três casos onde uma implementação ingênua erra**, e os três batem com o
Python exatamente:

  * **reatribuir mantém a posição** — `d["z"] = 99` sobre um `z` que já existe é a
    mesma entrada, não uma nova;
  * **remover e reinserir manda para o FIM** — é uma entrada nova;
  * **crescer não reordena.** A reconstrução COMPACTA as entradas na ordem em que
    estão em vez de reespalhá-las por slots, o que também é o único lugar onde uma
    entrada morta desaparece — e é isso que mantém a iteração proporcional ao que
    está vivo, e não a tudo o que já esteve.

Uma tabela cheia de entradas MORTAS é compactada no lugar, sem crescer. Sem isso,
apagar-e-reinserir num laço cresceria para sempre.

Gates: `tests/pscript/run/dictorder.psc` (os três casos, mais crescimento por
várias reconstruções e um `set`, que é a mesma tabela sem valores) e
`tests/oracle/py/collections.psc`, que agora compara a ORDEM contra o Python em
vez de esperar pela decisão.

## Bateria 90 — o orçamento do coletor, e as flags do C (2026-08-20)

Sua pergunta: *"vc testou o benchmark usando as flags de otimizacao do
llvm/gcc certo?"* e depois *"e pq nao -O3"*. As duas respostas mudaram números.

**90.1 O padrão do placar é `-O3 -flto`, e o LTO é a metade que importa.**
Medido, melhor de cinco:

| flags | fib | crivo | concat |
|---|---|---|---|
| `-O2` | .0189 | .0837 | .1986 |
| `-O3` | .0170 | .0839 | .1806 |
| **`-O3 -flto`** | **.0050** | **.0487** | .1774 |
| `-O3 -flto -march=native` | .0068 | .0489 | .1752 |

`-O3` sozinho quase não faz nada. O `-flto` faz 3,4× no fib e 1,7× no crivo, e a
razão é estrutural: um programa e o runtime são DUAS unidades de tradução (16.4),
então todo `ps_add`, `ps_list_at` e `ps_gc_poll` é chamada atravessando essa
fronteira — e este gerador de código emite muitas. O LTO é o que as inlina.

`-march=native` fica FORA de propósito: não compra nada mensurável, faz um
binário que só roda na máquina que o construiu, e o node e o python do lado são
builds genéricos — medir o nosso nativo contra o portável deles seria inclinar a
mesa.

**90.2 O gatilho do coletor passa a ser PROPORCIONAL ao conjunto vivo. REVISA a
14.2.** A 14.2 pedia "colete a cada 2 MiB alocados ou 200.000 objetos", os dois
FIXOS. Um gatilho fixo torna um coletor que copia **quadrático** em qualquer
programa cujo conjunto vivo cresce: cada coleta copia tudo o que está vivo, e com
uma quantidade constante alocada no meio, a cópia se repete uma vez por 2 MiB
para um conjunto que só aumenta.

Medido, construindo uma lista de n strings e juntando — custo por item:

    n =    50.000   0,49 us          n =   400.000   1,27 us
    n =   100.000   0,61 us          n =   800.000   1,87 us
    n =   200.000   0,83 us

O Python fica plano em ~0,2. A curva era o coletor, não as strings.

Agora o orçamento é `max(piso, o que está VIVO)` — um programa pode alocar tanto
quanto já está segurando antes da próxima coleta. É a regra padrão de um heap
copiador e faz a cópia amortizar para constante por byte alocado. **Os DOIS
limites escalam**: um contador fixo de objetos é a mesma quadrática na outra
dimensão, e uma lista de um milhão de strings pequenas bate nele primeiro — o
degrau em n = 800.000 era exatamente esse.

Depois: 0,46 / 0,39 / 0,37 / 0,43 / 0,37 us por item numa faixa de 16×. Plano. E
a razão contra o Python parou de crescer: era 4,9× e divergindo, virou 2,2–2,4×
constante.

> **O que isso custa.** Um heap que pode dobrar antes de coletar usa mais memória
> em pico — é a troca clássica, e é a que todo coletor copiador faz. O piso de
> 2 MiB continua sendo o que impede um programa pequeno de coletar a cada poucos
> quilobytes.

## Bateria 89 — `upper`/`lower` de verdade, e o que MEDIR mudou (2026-08-19)

Sua pergunta: *"o que precisamos para o upper completo?"* — e depois a saída:
*"agora a gente tem a ferramenta pra incluir binario aqui no codigo do aplicativo
em tempo de compilacao podemos resolver isso"*.

**Eu tinha escrito no runtime que a tabela era "centenas de kilobytes". Estava
errado, e a diferença entre chutar e medir é toda esta bateria.** Dos 1.114.112
pontos de código, **1423** têm maiúscula diferente de si mesmos, e eles caem em
**678 faixas contíguas com o mesmo deslocamento**. Com os 102 que viram MAIS de
um caractere (`ß`→`SS`, `ﬁ`→`FI`) e os dois conjuntos que o sigma final precisa,
a tabela inteira dá **22 KB**.

**89.1 A tabela é GERADA e EMBUTIDA.** `tools/gen_unicode_case.py` produz
`pscript/runtime/unicase.bin`, e o runtime a embute com `embed_bytes` (63.1). O
custo é 22 KB de dados só-leitura e nada em tempo de execução: não há
inicialização e não há alocação, só busca binária sobre os bytes. Todo número no
formato é big-endian, para o leitor não depender da máquina.

> **Por que gerada.** Mapeamento de caixa é TABELA, não algoritmo: `é` sobe por
> deslocamento, `ß` sobe para dois caracteres, e nenhuma regra produz nenhum dos
> dois. A tabela muda uma vez por ano, quando o Consórcio publica uma versão. Um
> arquivo gerado com o gerador ao lado é o único arranjo em que "que Unicode é
> este?" tem resposta — a versão está estampada no cabeçalho do blob.

**89.2 Os dados vêm do PRÓPRIO ORÁCULO.** O gerador lê o `str.upper()`/
`str.lower()` do Python, que são os mapeamentos PADRÃO do Unicode — os mesmos que
o `toUpperCase` do JavaScript. É o comportamento que se está copiando, então é
também a fonte certa; e `tests/oracle/py/unicase.psc` depois compara **todos os
1,1 milhão** de mapeamentos, dos dois lados, e bate.

**89.3 O sigma final ENTRA.** Aqui houve uma segunda correção minha: eu tinha
classificado o `Σ`→`ς` como regra de locale. Não é — é condicional mas faz parte
do mapeamento padrão, e Python e JS a fazem. Ela precisa dos conjuntos `Cased` e
`Case_Ignorable`, e esses também são **derivados perguntando ao oráculo** em vez
de lidos de um arquivo de propriedades: se um caractere depois do sigma impede
que ele seja final é exatamente a definição de "é cased", então a pergunta é
feita ao Python, uma vez por ponto de código. 150 faixas e 437, 4,6 KB.

**89.4 O que fica FORA, dito e não descoberto depois:** as regras sensíveis a
LOCALE — o i sem ponto do turco, o ponto acima do lituano. O `str.upper()` do
Python também não as faz (é para isso que existe o `toLocaleUpperCase`), então os
dois oráculos continuam honestos. Um programa que precise delas precisa de um
locale, que é outra decisão.

Gates: `tests/pscript/run/unicase.psc` (os casos que mostram POR QUE uma tabela é
necessária) e `tests/oracle/py/unicase.psc` (o espaço inteiro, contra o Python).


## BATERIA 118 — `os.run`: rodar um processo (a 1.2 do pforge, implementada)

A peça que faltava na camada de sistema, e a única que o `pforge` não tinha como
escrever por fora. A decisão era 1.2 do `pforge/DESIGN.md` — *task com `await`,
sobre o laço de eventos* — e isto é ela.

**118.1 A forma.** `await os.run(argv, env=, cwd=, stdout=)` devolve um processo
que já terminou, com `status()` e `output()`.

**118.2 SEM shell.** O comando é um `List<str>` e é o `execvp` que o recebe. Não
há aspas para escapar, não há `&&`, não há glob, e nada do que o programa
escreveu pode virar sintaxe — que é a decisão 1.6 do pforge vista de dentro. Uma
`str` no lugar da lista é recusada com a forma certa na mensagem, e o teste
`tests/pscript/bad/os_run_shell.psc` prende isso.

**118.3 Status != 0 NÃO é exceção.** Um `cc` que recusa o programa é RESULTADO, e
quem chamou decide. Levantar ali obrigaria todo build a envolver toda compilação
num `try`. Morto por sinal vira `128+sinal`, a convenção que todo shell usa.
Levantar acontece só quando o processo não chega a começar.

**118.4 O stderr vem JUNTO com o stdout**, um cano só, na ordem em que saíram —
porque é assim que um relatório de erro se lê. `stdout=<caminho>` manda a saída
padrão para um arquivo sem passar pela memória (o que um build quer quando a
saída É o artefato) e o stderr continua vindo em `output()`.

**118.5 `env=` SUBSTITUI o ambiente, não mescla.** O hash de uma aresta de build
cobre o ambiente efetivo, e "mesclar" não tem resposta única. O ambiente do filho
é montado ANTES do `fork` e entra por uma atribuição a `environ` — que é
seguro entre o fork e o exec, ao contrário de `setenv`, que aloca (e alocar ali é
o travamento clássico de um programa com threads).

**118.6 Um tipo novo, `proc`, e não um dict.** A 110 escolheu `Dict<str,int>`
para o `gc.stats()` com um bom argumento ("nenhum tipo novo para a linguagem
aprender"), mas aqui o resultado é heterogéneo — um número e uma str — e um
`record` não pode carregar `str` (58.2: record é bytes puros). Então é um OBJETO
do runtime, como `file` e `socket` já são, com membros que são chamadas
(`r.status()`), que é a forma que `conn.port()` tinha. O nome é escrevível
(`-> proc`) porque um programa precisa anotá-lo para passar a função ao
`gather_map`.

**118.7 O `waitpid` mora no POOL.** É a mesma decisão que o `getaddrinfo` já
tinha (76.3): esperar um filho é bloquear, e não há descritor que o `poll` possa
vigiar por ele. N processos em voo são N trabalhos no pool, e o limite de
concorrência é de quem chama — `gather_map(um, cmds, at_most=n)`.

**118.8 Duas medidas que o build pediu junto.** `path.getmtime_ns` (o mesmo
mtime, sem jogar fora a parte de baixo: num build rápido dois arquivos escritos
no mesmo segundo são indistinguíveis, e é assim que um incremental esquece de
refazer alguma coisa) e `os.nproc` (quantos processos manter em voo).

Portões: `tests/pscript/run/os_run.psc` (o comportamento inteiro, incluindo oito
processos em paralelo com limite), três recusas em `tests/pscript/bad/os_run_*`,
e `tests/oracle/py/proc.psc` — o mesmo programa contra o `subprocess` do
python3, porque nenhuma dessas promessas é conferível por leitura.

---

## BATERIAS 135-140 — o NIO, à nossa maneira (2026-08-24)

> *"sabe o que eu estava pensando que falta no nosso runtime.. um equivalente ao
> JAVA NIO (o pacote completo), mas de uma forma que faça sentido para o nosso
> modelo de paralelismo e nativo com P/C, shared etc"*

### O diagnóstico: o NIO são três pacotes colados

E nós temos o melhor deles, temos meio-construído o segundo, e não temos o
terceiro.

**1. O `Selector` — não se copia, e copiá-lo era andar para trás.** É a manchete
do NIO e existe porque as threads do Java eram caras e a I/O era bloqueante: o
programador monta o laço de multiplexação à mão. Aqui o escalonador já é isso
desde a 74.1 — epoll/kqueue/poll, tarefas estacionadas, `await c.read(n)` — e
ninguém escreve um laço de selecção. **Nada do `Selector` entra.**

**2. O `buffer` já É um ByteBuffer directo — só que nenhuma chamada de I/O fala
com ele.** O `buffer(n)` da 52.3 é malloc'd, **nunca se move**, é partilhado
entre workers, transfere-se com zero cópia (18.2) e já tem vistas tipadas. Em
Java chama-se *direct ByteBuffer*, e é a resposta que um coletor **copiador**
obriga: um ponteiro para o monte não sobrevive a uma coleta, portanto os bytes
que uma chamada de sistema vê têm de estar fora dele.

O problema é o caminho que a I/O faz hoje:

```
recv → malloc(w->buf) → memcpy → List<u8> coletada → fatiar → mais cópias
```

Um proxy que mova um megabyte copia-o quatro vezes.

**3. O `java.nio.file` falta inteiro.** Não há `mmap`, `pread`/`pwrite`,
`readv`/`writev`, `sendfile` nem vigilância de ficheiros, e `listdir` devolve a
lista toda em vez de a percorrer. E falta a descodificação **incremental** de
UTF-8: o widget de terminal da F8 do pstudio teve de escrever à mão a máquina de
estados de bytes porque `str(b)` descodifica tudo de uma vez e levanta. O
`CharsetDecoder` é exactamente essa peça.

### As decisões

**135.1 — Fatias explícitas, sem cursor.** `b[off:off+n]` é uma VISTA sobre os
mesmos bytes, sem copiar. Nenhum estado escondido dentro do buffer. O
`position`/`limit`/`flip` do `ByteBuffer` é o erro clássico do Java — o próprio
Java desistiu dele no `MemorySegment` da FFM API — e é a origem de metade dos
defeitos de quem usa NIO.

**135.2 — O `Buffer` substitui o `List<u8>` NA I/O — e só aí.**

> *"eu não sou contra o `list<u8>`, totalmente contra ele, mas ele estava
> quebrando galho onde não existia solução melhor antes."*

É a leitura certa e vale a pena estar escrita, porque a decisão lê-se facilmente
como uma condenação e não é uma. O `List<u8>` **não sai da linguagem** e não é um
erro a corrigir: ele estava a fazer o trabalho de uma coisa que não existia, e
fê-lo bem durante todo o tempo em que era a única.

O que muda é que deixa de ser a **moeda da I/O**. `c.read(n)` deixa de existir
porque agora há uma resposta melhor para aquela pergunta — não porque a antiga
fosse má.

E continua a ser o tipo certo para o que ele realmente é: uma lista de números
pequenos, com todas as operações de lista. As conversões existem e são
**explícitas nos dois sentidos** — `bytes(xs)` e `list(b)` — porque cada uma
copia, e uma cópia que acontece sozinha é uma cópia que ninguém vê.

Medido antes de decidir: **14 ficheiros, 66 sítios**, dos quais os pesados são o
`tar` (16) e o `repo` (15).

**135.3 — Dois tipos, e a linha entre eles é visível na grafia.**

| | é | vive | fatia-se em |
|---|---|---|---|
| `bytes` | um VALOR imutável e coletado | fora do monte, num bloco que não se move | `bytes` (só de leitura) |
| `Buffer` | uma COISA mutável e partilhada | malloc'd, fecha-se | vistas mutáveis |

Uma leitura que PRODUZ bytes (`f.read_all()`, `R.fetch()`, um membro de um tar)
devolve `bytes`: não se fecha, não se gere, atravessa para P sem cópia. Uma
leitura para dentro de memória que já tens escreve num `Buffer`.

**135.4 — `b.freeze()` passa de um ao outro com zero cópia**, e invalida o buffer
— a mesma regra do `transfer` da 18.2, e o mesmo erro que ela previne: dois donos
a escrever o mesmo bloco vira um erro em vez de uma corrida. `bytes(b)` copia,
para quem quer ficar com os dois.

**135.5 — Todas as operações valem nos dois.** `len`, indexar, iterar, comparar,
`str()` para descodificar. O código que migra muda a ASSINATURA e mais nada.

**135.9 — O que muda num FICHEIRO, e o que não muda.** `text()` e `readlines()`
**ficam** — devolvem `str` e `List<str>`, não são I/O de bytes, são conveniência
de texto, e ninguém os quer trocar por um buffer. Muda só o que devolvia bytes:
`read_all()` passa a dar `bytes`, e `read(n)` vira `read_into(buf, off, n)`.

**135.10 — O `read_all()` não tem tecto, e não precisa: o tamanho é sabível.**
Ler um ficheiro de 4 GB aloca 4 GB, e está certo — foi o que se pediu. Um tecto
seria um número mágico que alguém um dia teria de aumentar por uma razão
legítima, e a alternativa a trazer tudo para a memória não é ler menos, é o
`os.mmap`, que é literalmente a ferramenta de "quero o ficheiro sem o trazer".

O que faltava era saber o tamanho de um ficheiro **já aberto**: o `path.getsize`
existe, mas obriga a guardar o caminho depois de se ter o `File`. Entra
**`f.size()`** na F4 — um `fstat` no descritor, sem segunda procura do caminho e
sem a janela entre o `stat` e a leitura em que o ficheiro pode mudar.

**135.6 — Onde o `List<u8>` continua a ser a resposta certa: CONSTRUIR e
MEXER.** Acrescentar, inserir, ordenar, remover — é uma lista, e faz isso bem. O
`bytes` é o que ATRAVESSA: I/O, hash, uma fronteira para P. `bytes(xs)` e
`list(b)` nos dois sentidos, sempre explícitos, porque cada um copia.

E é por isso que **não há um `Writer`**: construir uma saída de tamanho
desconhecido faz-se num `List<u8>` e converte-se no fim.

> *"isso até me lembrou o stringbuilder"* — e é mesmo, mas não por analogia: é o
> padrão que a linguagem **já tem para strings**, e já medido. O `core.psc:154`
> do editor diz *"`join`, and not `+=` in a loop, for a measured reason: the loop
> is quadratic. 8 000 lines cost 672 ms that way and 0 ms this way; 32 000 cost
> 16 972 ms against 3 ms"*. O `join` é o StringBuilder desta linguagem, e
> `List<u8>` + `bytes(xs)` é a mesma forma para bytes.

Um `Writer` seria isso mais uma optimização — o `freeze()` a entregar o bloco sem
copiar. Um tipo novo por uma cópia que só se nota em megabytes: fica de fora até
uma medição o pedir, que é como este repositório decide estas coisas.

**135.7 — Um `bytes` nasce de quatro sítios:** de uma leitura, de `bytes(xs)`, de
`s.encode()`, e de um **literal `b"..."`**. O literal ganha o lugar por causa dos
números mágicos e das constantes de protocolo, que são metade do que ler um
formato binário é — sem ele, a intenção mais óbvia seria a que ficaria mais
ruidosa:

```python
if src[0:4] == b"\x7fELF":   ...      # e não "\x7fELF".encode()
```

**135.8 — `b[0:8]` é a VISTA que já existe.** O `PsBufView` da 18.3 já está no
runtime, com um campo `owner` documentado exactamente para manter o dono vivo, e
as vistas tipadas (`view_u8`, `view_f64`) já são a mesma coisa com outro
elemento. Portanto `b[0:8]` é açúcar para `b.view_u8(0, 8)` e o tipo é `View<u8>`
— **não um `Buffer`**.

O que se ganha em ser um tipo diferente: uma `View` **não tem `close`**. Fechar
uma vista deixa de ser um erro que levanta em tempo de execução e passa a ser
uma coisa que não se consegue escrever.

### 136 — os finalizadores, e a regra que diz quando usar cada coisa

O coletor ganha **finalizadores**: uma lista de objetos com um gancho de
libertação, e quem não for reencaminhado numa coleta é libertado. É maquinaria
nova e é a única maneira honesta de ter um `bytes` que ninguém fecha.

Mas a pergunta certa não é "finalizador ou `with`" — é **para quê cada um**, e as
duas respostas saem de uma comparação que vale a pena ter escrita:

| | `with` (determinístico) | finalizador (na coleta) |
|---|---|---|
| **quando liberta** | num ponto que se aponta no código | quando o coletor calhar |
| **funciona para** | um recurso com **um dono e um escopo** | um **valor que circula** — devolvido, guardado num `Dict`, enviado a um worker |
| **esquecer** | não liberta | impossível esquecer |
| **custa** | uma linha em cada uso | maquinaria no coletor |

A desvantagem decisiva do `with` é a segunda linha: **ele não compõe com
valores.** Um `bytes` devolvido por uma função e metido numa lista não tem escopo
nenhum — só tem alcançabilidade, que é a única coisa que um coletor sabe medir.

A desvantagem decisiva do finalizador é a primeira: **não se sabe quando.** Para
memória isso não faz mal — o coletor corre exactamente quando há pressão de
memória. Para tudo o resto faz, e é o erro do `MappedByteBuffer` da 137: mil mapas
não são pressão que o coletor veja, e descritores esgotam-se muito antes do monte.

> **136.1 — Determinístico para o que é ESCASSO. Coleta para o que é MEMÓRIA.**

| | é | como se liberta |
|---|---|---|
| `bytes` | memória, e mais nada — a sua escassez É a pressão do monte | **só finalizador**, e nenhum `close`. É isso que o deixa ser um valor |
| `Mapping` | espaço de endereçamento, um inode, e no Windows o próprio ficheiro | **`with`** é o plano; o finalizador é a rede |
| `Buffer` | memória partilhada entre threads e transferível | **`close` explícito**: o tempo de vida é uma decisão, não um facto |

**136.2 — O gancho é do RUNTIME, nunca do utilizador.** Só `free`, `munmap`,
`close`. Não aloca, não levanta, não chama código escrito por ninguém. Corre
**depois** da coleta, com a lista do que não sobreviveu — nunca vê um monte a
meio de mover. Não há `__del__` e não há `Drop`: um gancho de utilizador traz a
ressurreição, a ordem entre objetos e um finalizador que levanta a meio de uma
coleta, que são as três perguntas que assombram o Java há vinte anos.

**136.3 — Correm à SAÍDA, numa última passagem.** O `runFinalizersOnExit` do Java
foi retirado por ser perigoso — mas era perigoso porque corria código do
utilizador, noutra thread, sobre objetos possivelmente vivos; com a restrição da
136.2 isso não existe. O que se ganha é o que decidiu: **as fugas passam a ser
mensuráveis.** Um portão que conte quantos ganchos correram e compare com quantos
foram registados é um teste de fugas, e é o género de portão que este repositório
constrói. O custo é a saída demorar proporcionalmente ao que ficou vivo, e isso é
ruído.

**136.4 — Um finalizador liberta um RECURSO; nunca termina um TRABALHO.** Ele faz
`close(fd)` — não esvazia um `Buffer` que estava a ser montado, e não corre de
todo se o processo for morto com `SIGKILL`. O que *tem* de acontecer continua a
ser do `with` e de quem escreve. Isto fica dito porque "a limpeza é garantida à
saída" lê-se ao contrário com uma facilidade perigosa.

### 137 — o mapa de disco

> *"não temos um tipo idiomático que mapeia do disco? como outras linguagens
> resolve isso?"*

| | o que devolve | quem desmapeia |
|---|---|---|
| **Java** | `MappedByteBuffer`, tipo próprio | **só o GC** — não há `close`. É o bug mais votado da história do JDK (JDK-4724038); o `MemorySegment`/`Arena` do JDK 14+ nasceu para o corrigir |
| **Rust** (`memmap2`) | `Mmap`, que faz `Deref` para `&[u8]` | `Drop`, determinístico. Criar é `unsafe`, de propósito |
| **Go**, **Zig** | um `[]byte` | à mão |
| **Python** | `mmap.mmap`, sequência e ficheiro ao mesmo tempo | `with` |
| **.NET** | `MemoryMappedViewAccessor` | `IDisposable` |

Dois campos — "é só uma sequência" e "é um tipo próprio" — mas **a divisão que
interessa não é essa**: é quem desmapeia. E aí só há um veredicto: o modelo do
Java, libertar só na coleta, é o que toda a gente considera um erro. A razão é
que **um mapa não é pressão de memória que o coletor consiga ver**: um programa
que mapeia mil ficheiros tem mil mapas e um monte minúsculo, e o coletor não tem
motivo nenhum para correr.

**137.1 — `os.mmap` devolve um `Mapping`: um tipo próprio, fechável, que se fatia
em `bytes` sem copiar.**

> *"o map do sistema operacional te dá recursos e opções certo? o tipo também
> poderia?"* — e é isso que justifica o tipo próprio. Nada disto cabe num
> `bytes`: `madvise(SEQUENTIAL/RANDOM/WILLNEED)`, `msync`, `mlock`,
> `MAP_POPULATE`, `PROT_*`, `MAP_SHARED/PRIVATE`.

O nome foi decidido por eliminação: `Map` colide com a estrutura de dados
(*"tem que ter um nome do tipo que não indique que é uma estrutura de dados
Map"*), `MappedMemory` foi proposto e ficou como `Mapping` — que a **regra dos
nomes da 139** depois confirmou em maiúscula, por ser uma coisa e não um valor.

**137.3 — Mapeia o ficheiro inteiro, ou uma REGIÃO.** `os.mmap(p)` é o caso
comum; `os.mmap(p, off, n)` lê um membro de um arquivo enorme sem mapear os
outros gigabytes. É o que o `FileChannel.map` do Java também dá, e custa dois
argumentos. (Uma fatia `m[off:off+n]` dá a região *dentro* de um mapa que já
existe; o que isto dá é não mapear o resto de todo.)

O finalizador da 136 fica como REDE, não como plano: o `with` é que fecha.

```python
with os.mmap(tar, "r") as m:
    m.advise(os.SEQUENTIAL)
    sha = sha256(m[:])          # bytes, zero cópia
# munmap AQUI
```

**137.2 — O SIGBUS é apanhado, e o guarda é o `with`.** Se outro processo truncar
o ficheiro, tocar na página que desapareceu mata o processo — é por isso que o
Rust marca a criação como `unsafe`. Apanhá-lo é o que a JVM, o V8 e o Postgres
fazem, e tem uma condição que muda o desenho: **um `siglongjmp` a partir do meio
de código gerado deixa a pilha-sombra do coletor a meio**. O `try` do pscript é
de bandeira, sem `goto`, exactamente porque o P proíbe saltar por cima de um
`defer`.

Então entrar no `with` grava um ponto de retorno **e a profundidade da
pilha-sombra**. O manipulador confirma que o endereço caiu num mapa NOSSO,
desenrola até àquela profundidade e levanta; se não caiu, re-levanta o sinal,
para que um defeito a sério continue a matar. É o modelo do `PG_TRY` do Postgres.

### 138 — o P também mapeia, e as duas já estavam casadas

> *"o P também poderia ter um mapa de memória, que funcione lá, e não sei como
> casaria com o mapa do PScript"*

Em P um mapa **não precisa de tipo novo nenhum**: é um ponteiro e um tamanho, com
`defer` a libertar — o que o `PgFb.init`/`deinit` já faz.

E a ponte já estava desenhada: o **`CBytes` (84.1)** é *"um struct de exactamente
um ponteiro e um tamanho"*. O que torna um `Mapping` o **melhor** valor possível
para atravessar essa fronteira é a propriedade que ele já tem por construção:
está fora do monte e nunca se move. Um `List<u8>` coletado, para ir para P, ou
copia ou precisa de ser fixado; um `Mapping` não precisa de nada.

```python
with os.mmap(tar, "r") as m:
    n = tar_count(m[:])        # uma função em P: `in b: CBytes`
```

**138.1 — O `Mapping` materializa-se em P com `declare`/`implement`**, e não por
injecção automática:

> *"no P o compilador pode inlinar structs, mas o usuário deve fazer
> explicitamente, com a keyword inline assim igual com o genérico. ou poderia ser
> o declare também declarar Mapping"*

O mecanismo já existe e a segunda forma ganhou por isso: `declare StrMap<i64>` já
quer dizer "materializa este tipo nesta unidade". `declare Mapping` lê-se igual,
não precisa de palavra nova, e o `implement` continua a ser o sítio único onde o
corpo sai. O ganho não é evitar um `import` — é que a **disposição da struct passa
a ser garantida idêntica dos dois lados por construção**, em vez de por um header
que pode derivar.

**138.2 — O guarda do SIGBUS NÃO atravessa para P, de propósito.** A segurança
vive na linguagem gerida; a primitiva vive na não-gerida. Um mapa aberto pelo P
não está no registo do runtime, portanto o manipulador vê um endereço que não é
dele e re-levanta: o processo morre, como morreria com qualquer biblioteca em C.

### 139 — a regra dos nomes dos tipos

> *"o certo acho q todos os tipos deveriam ser maiúsculos né"* / *"exceto os
> primitivos"*

A convenção estava dividida sem regra: `str`, `list`, `socket`, `buffer`
minúsculos; `Task<T>`, `Worker<T>`, `Error` maiúsculos. A regra que a arruma:

> **minúsculo = um VALOR. maiúsculo = uma COISA com identidade e tempo de vida.**

| minúsculo | maiúsculo |
|---|---|
| `int` `float` `bool` `str` `bytes` `u8` `i32` `f64` `usize`… | `List<T>` `Dict<K,V>` `Set<T>` |
| | `Socket` `Buffer` `File` `Mapping` `Watcher` |
| | `Task<T>` `Worker<T>` `Error` `Timer` |

E repara no que ela faz de graça: separa o `bytes` (imutável, coletado, um valor)
do `Buffer` (mutável, partilhado, fecha-se) — a distinção da 135.3 passa a estar
na própria grafia.

**139.1 — A travessia é em TRÊS commits, e cada um compila.** O compilador passa
a aceitar os dois nomes, com um `-W` no velho; a árvore migra; o velho deixa de
existir. Sem isso, o commit do meio é um estado em que nada compila — e um commit
que não compila não se revê, porque uma falha esconde as outras.

Os dois nomes coexistem durante exactamente um commit. Deixá-los coexistir para
sempre seria a linguagem ficar com duas grafias para tudo, que é a coisa que a
regra queria acabar.

**Medido**, e em quatro categorias que não se tratam da mesma maneira:

| onde | quantos | como |
|---|---|---|
| anotações em `.psc` | `list<` 753, `dict<` 154, `set<` 12, `socket`/`buffer` 14 | `sed` |
| **as mensagens e comentários do próprio compilador**, em `.p` | 61 (`ps_sema` 28, `ps_lower` 8, `ps_parser` 4…) | `sed`, mas é o que o utilizador LÊ |
| a prosa dos `.md` | 9 ficheiros | **à mão** |
| o `bootstrap/` | regenerado | o portão do ponto fixo |

A segunda linha é a que mais dói esquecer: `self->expect(TK_LT, "list<T>")` é uma
cadeia dentro do compilador, e sem ela ele passa a dizer `list<T>` numa linguagem
onde se escreve `List<T>`.

**Vai numa FASE própria e ANTES do NIO**, para que o diálogo de cada commit seja
sobre uma coisa de cada vez, e para que o `Mapping` não nasça ao lado de um
`list<u8>`.

### 140 — o resto do pacote

**`os.watch` é uma tarefa aguárdavel**, como um socket: `w = os.watch(dir)` e
`ev = await w.next()`. O descritor do inotify/kqueue entra no mesmo `poll` do
escalonador — sem thread, sem sondagem, e igual a tudo o resto que espera.

#### 140.1 — o `Watcher`, e o que dele ainda não está decidido

O tipo que o `os.watch` devolve. Estava nomeado na tabela da 139 e indefinido em
todo o lado, que é precisamente o que a releitura das specs apanha — fica aqui
com superfície antes de ser um buraco.

```python
with os.watch("src", recursive=True) as w:
    while True:
        ev = await w.next()          # WatchEvent
        print(ev.path, ev.kind)
```

Um `WatchEvent` é `path`, `kind` (`CREATED`, `MODIFIED`, `DELETED`,
`MOVED_FROM`, `MOVED_TO`) e um `cookie` para emparelhar as duas metades de um
`moved` — sem ele, mover um ficheiro dentro da árvore lê-se como apagar um e
criar outro, que é a diferença entre um `git mv` e uma perda.

**Decidido:**

* é aguardável e entra no `poll` do escalonador — sem thread e sem sondagem;
* fecha-se com `with`, como todos os recursos da 139;
* **o transbordo é um EVENTO e não um silêncio.** Quando a fila do núcleo enche,
  o que se perdeu perdeu-se, e a única resposta honesta é `OVERFLOW` — "não sei o
  que mudou, relê tudo" — em vez de continuar a entregar eventos como se nada
  faltasse. É o `IN_Q_OVERFLOW` do inotify, e escondê-lo é a diferença entre um
  vigia e um vigia que mente.

* **vigia-se o DIRECTÓRIO, e filtra-se pelo nome — nunca o ficheiro.** É uma
  armadilha e é exactamente o caso que o editor tem: um editor não escreve por
  cima de um ficheiro, escreve num temporário e faz `rename`. O inode que estava
  a ser vigiado morre, chega um `IN_MOVE_SELF`, e a partir daí **não chega mais
  nada** — o vigia ficou agarrado a um inode que já não é o ficheiro. Toda a
  gente tropeça nisto uma vez; fica escrito para ser zero.
* **e não vigia sockets, de propósito.** Vigiar um socket já é `await` — um
  `Watcher` que os aceitasse seria voltar a expor o `Selector` que a 135 recusou.
  São três perguntas diferentes: "há bytes neste socket?" responde o escalonador
  (sondado), "há bytes neste ficheiro?" responde o pool (um ficheiro regular não
  se sonda — o `epoll` recusa-o com `EPERM`, porque está *sempre* pronto e o que
  bloqueia é o disco), e "este caminho mudou?" é a única que não tinha resposta.
  A linha não é ficheiro contra socket: é **stream contra ficheiro regular**, e a
  F8 prova-o — um pty é um `Socket` aqui não por ser rede, mas por se sondar.
  O que fecha o círculo: o descritor do próprio `inotify` é um stream, e é por
  isso que o `Watcher` pode ser aguardado. Ele não é uma segunda maneira de
  esperar; é mais um stream a usar a única que existe.

**Em aberto, para decidir quando a F5 chegar** — escrito como aberto de propósito,
para não ser resolvido por engano:

1. **A recursão não é do sistema.** O `inotify` vigia UM directório. Uma árvore
   são N vigias, e um directório criado depois de começar precisa de um vigia
   novo — que é uma corrida contra os ficheiros criados lá dentro nesse
   intervalo. O `recursive=True` é trabalho nosso, não uma opção do núcleo.
2. **O macOS não tem `inotify`, e o `kqueue` não serve para isto.** Ele vigia
   DESCRITORES: uma árvore são N descritores abertos, e o limite de ficheiros
   abertos chega depressa. A resposta real do macOS é o **FSEvents**, que é uma
   API completamente diferente — chamada de volta numa run loop, e já coalescida
   por directório. **É a maior distância entre as duas plataformas em todo este
   plano**, e vale mais dizê-lo agora do que descobri-lo na F5.
3. **Coalescer, ou entregar cru.** Um editor a gravar um ficheiro produz três ou
   quatro eventos (escrever num temporário, renomear, mudar atributos). Um vigia
   que os entrega crus faz com que cada consumidor escreva o mesmo anti-ressalto.
   O `WatchService` do Java não coalesce, e é uma queixa conhecida dele.
4. **O `inotify` é só do sistema de ficheiros local.** Uma alteração feita noutra
   máquina sobre NFS é invisível. Não afecta nada aqui — as árvores são locais —
   e é melhor estar dito do que ser descoberto por alguém com o `$HOME` em rede.
5. **Um evento de cada vez, ou um lote.** Uma construção que toca em oitocentos
   ficheiros produz oitocentos eventos, e `await` oitocentas vezes são oitocentas
   voltas ao escalonador. Um `w.drain()` que devolve o que houver é a
   alternativa, e muda a forma de quem consome.

**Tudo cresce dentro do `os`/`net`/`Buffer` que já existem** — `os.mmap`,
`os.watch`, `c.read_into`, `b.freeze()`. Sem módulo novo para aprender, e cada
nome fica ao lado do irmão: é a regra que o `os.spawn_pty` já seguiu na F8.

### O que fica de fora, e porquê

| não entra | porquê |
|---|---|
| o `Selector` | o escalonador já é isso, e melhor: ninguém escreve o laço |
| `position`/`limit`/`flip` | o erro que o próprio Java foi corrigir |
| `mmap` de escrita (`MAP_SHARED`) | é uma segunda história de durabilidade para contar ("quando é que chega ao disco?"), e nada aqui precisa dela ainda |
| `FileLock` | v2. Não há dois processos a disputar o mesmo ficheiro neste ecossistema |
| `sendfile`/`transferTo` | v2. Vem de graça depois do `Mapping` + `writev` |

### Riscos, ditos antes de doerem

1. **Os finalizadores são maquinaria nova no coletor.** Um gancho que corre
   durante uma coleta e que liberta memória do sistema. Mitigação: só objetos com
   gancho entram na lista, e o teste de estresse do coletor (`gc-stress`) ganha um
   caso que abre e larga dez mil `bytes`.
2. **O guarda do SIGBUS mexe na pilha-sombra.** É a parte mais delicada de tudo
   isto. Mitigação: o desenrolamento é até uma profundidade GRAVADA, não uma
   adivinhada, e o teste trunca um ficheiro debaixo de um mapa aberto e exige a
   excepção.
3. **A 135.2 quebra 6 pacotes publicados.** É um evento de semver — e a F10 do
   pstudio acabou de destrancar o `0.x` a poder partir num `minor`, com aviso.
4. **A renomeação da 139 toca em tudo.** Mitigação: fase própria, `sed` sobre
   código, mãos sobre os `.md`, e o `verify` verde antes de o NIO começar.
5. **O `mmap` só é seguro onde o ficheiro é imutável.** O armazém de tarballs
   (nomes que são hashes) sim; uma fonte que alguém está a editar não. O guarda da
   137.2 transforma isso numa excepção em vez de uma morte — mas a regra continua
   a ser não mapear o que outro processo reescreve.

---

## BATERIA 141 — o contrato da fronteira, e a linha entre runtime e pacote (2026-08-24)

> *"existe algum contrato de garantia que eu possa fornecer via interface, uma
> struct P passe a ser segura em PScript?"*

### 141.0 — o que se descobriu a responder: a fronteira não é um muro

Um `.psc` **já chama C directamente**. Medido:

```python
include <math.h>
print(int(sqrt(16.0)), int(pow(2.0, 10.0)))   # → 4 1024
```

Portanto a segurança do pscript **não vem de não se conseguir chegar ao C** — vem
de quase ninguém precisar. A regra que se segue é uma convenção sobre onde a
encapsulação vive, não uma parede que o compilador levanta, e vale mais dizê-lo.

### 141.1 — a linha entre RUNTIME e PACOTE

> *"coisas que são de médio nível e que são base para as de alto nível… coisas
> que precisam encapsular manipulação insegura, abstração crua das funções do
> sistema operativo. o runtime em si vai conter as abstrações do OS que
> estragariam a linguagem se implementadas nesse nível"*

É uma regra melhor do que "precisa do sistema", porque decide os casos que essa
não decidia:

| fica no RUNTIME | porquê |
|---|---|
| `os`, `net`, `time`, `gc`, `sys` | encapsulam chamadas de sistema e o coletor |
| `json` | *"renderiza coisas reflexivas"* — percorre os descritores de tipo que o compilador emite. Não se escreve isto ao nível da linguagem |
| `re` | embrulha o `regex.h` da libc: ponteiros e buffers |
| `math` | os tipos nativos usam-no |
| **`bytes`, `Buffer`, `View`, `Mapping`, `Watcher`, os finalizadores** | é tudo o que a 135-140 acrescenta, e é tudo abstração crua do sistema ou do coletor |
| o descodificador incremental de UTF-8 | *"se o tipo nativo já usa vai pro runtime"* — o `str(b)` já valida e descodifica; o incremental é o mesmo com o estado guardado |

| vai para um pacote `stdlib` | porquê |
|---|---|
| `bisect`, `heapq`, `random` | algoritmos puros, sem nada de inseguro |
| a metade pura do `path` (`join`, `dirname`, `basename`, `normpath`) | manipulação de cadeias — a mesma espécie que o `url`, que já é um pacote |

E a metade de sistema do `path` (`exists`, `isdir`, `isfile`, `getsize`,
`getmtime`) junta-se ao `os`, onde o `listdir` já está.

**E há uma segunda cláusula, que não é sobre segurança mas sobre QUANDO:**

> *"os contentores padrão do Python e da linguagem ficam internos, porque eles são
> o coração da linguagem: devem ser resolvidos em tempo de compilação do próprio
> compilador e não do programa."*

`str`, `List`, `Dict`, `Set` ficam no runtime — não por serem inseguros, mas
porque um programa que escreve `[]` **não pode depender de um pacote existir, ser
encontrado, ser instalado e estar na versão certa**. Um compilador de C não
distribui o `int` num header. O que é o coração resolve-se quando o COMPILADOR é
construído; o que é conveniência resolve-se quando o PROGRAMA é construído.

E é isso que separa o `psrt_val.p` (fica) do `bisect`/`heapq`/`random` (saem): um
programa que não usa `bisect` não precisa dele, e um que usa tolera bem uma
dependência. Um programa que usa `[]` não tolera nenhuma.

**Medido antes de decidir, e o resultado mudou o argumento:** mover coisas para
fora do runtime **não poupa nada**. O `pcode` carrega 6 650 bytes de
json+re+random+heapq+bisect+math que não usa, num binário de 1 530 312 — **0,43 %**.
Portanto a linha não é sobre custo; é sobre o que cada lado compra. Um pacote tem
versão, lê-se, substitui-se. Um módulo do runtime importa-se sem caminho e o
compilador valida-lhe os nomes.

E a razão pela qual isto valia a pena: **a linha de hoje é história, não
princípio.** O `json` e o `url` são a mesma espécie de coisa — um analisador de um
formato com a sua suíte de conformidade (318/318 e 890/891) — e estão em lados
opostos porque um entrou cedo e o outro tarde. Agora estão em lados opostos por
uma razão que se pode dizer em voz alta.

### 141.2 — o contrato: um trait, declarado DENTRO da struct

Metade do mecanismo já existia: o `CStr`/`CBytes` (84.1) **já é um contrato, por
FORMA** — o compilador reconhece *"um struct de exactamente um ponteiro e um
tamanho"*. O que falta é poder declarar um.

```
struct Mapping implement Foreign, Shared:
    data: *u8
    len: usize

    def release(ref self):
        munmap(self.data, self.len)
```

**Dentro da própria definição, e isso é mais forte do que o que o Rust faz.** O
`unsafe impl Send for TipoDeOutraPessoa {}` permite prometer em nome de um tipo
cujas invariantes não se controlam, e é um pé-de-cabra conhecido. Exigir que a
promessa viva no corpo da struct significa que **só o autor pode prometer** — e
que ler a struct é saber tudo sobre ela, sem procurar um bloco noutro sítio.

O preço, dito: um pacote deixa de poder acrescentar uma promessa a um tipo de
outro pacote. Que é exactamente a vantagem, vista do outro lado.

**Sem `unsafe` na grafia:** o nome do trait é que avisa. `Foreign` e `Shared` não
se escrevem por acidente.

### 141.3 — as três promessas, e a quarta que não precisa de nome

| trait | promete |
|---|---|
| `Foreign` | tudo o que ela aponta está **fora do monte coletado**, e ela sabe libertar-se (`release`, que é o gancho da 136) |
| `Shared` | dois workers podem segurá-la ao mesmo tempo |
| `Transfer` | pode mudar de dono, pela regra do `transfer` da 18.2 |

São três e não um porque quem só consegue prometer uma não deve ser obrigado a
mentir para passar — é a razão por que o Rust tem `Send` e `Sync` separados. Um
`Mapping` é `Foreign, Shared` e **não** `Transfer`: um mapa tem um dono. Um
`Buffer` é os três.

**E POSSUIR não é EMPRESTAR.** Isto sai sem inventar um quarto nome:

> **Sem trait nenhum → só atravessa como ARGUMENTO.** Um empréstimo, válido
> durante a chamada. É o `CStr`/`CBytes` de hoje, e não muda.
> **Com `Foreign` → o pscript pode SEGURÁ-LA.**

A razão é concreta: um `CStr` aponta para uma `str`, que vive no monte **e o
coletor move**. Se o pscript o guardasse, a coleta seguinte deixava-o a apontar
para o vazio. Já um `Mapping`, um `Buffer` ou um `bytes` estão fora do monte por
construção e nunca se movem — e é exactamente por isso que uma struct de P que
aponte para eles pode ser guardada.

### 141.5 — e o sentido contrário NÃO existe

> *"Não deve. No máximo receber uma cópia."*

O P **não segura** um valor do pscript através de uma coleta. Nada de raízes
registadas, nada de `luaL_ref`, nada de referências globais como as do JNI. Um
tipo de P recebe um empréstimo durante a chamada (`in s: CStr`, sem cópia) ou
recebe uma **cópia** que passa a ser sua — e mais nada.

A costura fica assimétrica de propósito: **o pscript pode segurar coisas do P
(`Foreign`), e o P não pode segurar coisas do pscript.** É a direcção que não
precisa de o coletor aprender nada sobre quem está lá fora, e é a que não tem
maneira de vazar: não há `unroot` para esquecer, porque não há `root`.

O preço, concreto: o `hl.p` do editor recebe o texto outra vez em cada chamada em
vez de o guardar entre elas. Como o `CStr` é um endereço e não uma cópia, isso
custa zero — o que custaria era guardar.

### 141.6 — a MECÂNICA fica em ABERTO, e o bloqueio tem nome

O que está decidido acima é a FORMA do contrato: um trait, dentro da definição,
três promessas. **Como é que isto funciona por baixo não está decidido**, e fica
dito para o documento não se ler como pronto a implementar.

Medido: hoje uma função livre em P com tipos escalares **já atravessa** para o
pscript; uma que mencione uma struct de P não — e o erro é `unknown function`,
porque o que falta não é a função, é o **tipo não ter nome do lado de cima**.

E o bloqueio é este:

> **Objecto dentro de objecto.**

Uma struct `Foreign` só com escalares é fácil: a fronteira copia-a para um bloco
malloc'd, o `release` liberta-a, e o coletor não percorre nada — que é
literalmente a promessa. Assim que ela tem **um ponteiro para outro objecto**,
tudo isso cai: o `release` teria de libertar em cadeia (e não pode saber se o de
dentro é partilhado), e se o de dentro for um valor coletado o coletor teria de
percorrer memória do P — que é exactamente o que o `Foreign` prometia não ser
preciso.

A única resposta real que alguém encontrou para isto é o autor escrever a função
de percurso à mão — é o `tp_traverse` do CPython, e é a razão por que escrever uma
extensão em C para o Python é o que é. Toda a API de embebimento acaba aqui.

Portanto: **parado de propósito**, e não por falta de ideia.

### 141.7 — quando é que um conceito pode ser UM, e quando não pode

> *"o que eu não quero é ter duas `File` por exemplo."*

Medido primeiro, porque o exemplo não existe: **não há duas `File`.** O P não tem
abstracção de ficheiro nenhuma — usa o `*FILE` do stdio (19 usos) e
`fopen`/`fread` directamente, que é exactamente o que a regra *"a libc é o
runtime"* (27.1) manda. Uma linguagem tem a abstracção, a outra chama a
biblioteca. Isso não é duplicação; é a regra a funcionar.

A duplicação a sério é uma só, e são as colecções:

| conceito | pscript | P |
|---|---|---|
| lista | `List<T>` | **`Vec<T>` — 428 usos** |
| dicionário | `Dict<K,V>` | `StrMap<T>` — 87 |
| conjunto | `Set<T>` | `StrSet` — 55 |

E o `str`/`Str` **não é duplicação, é um nome mal escolhido**: o `str` do pscript é
imutável, coletado e conta codepoints; o `Str` do `stl` é um buffer mutável que
cresce. É um *StringBuilder* com nome de string, e passa a chamar-se **`StrBuf`**
na FE (22 ocorrências, e o `stl` já lá vai para dentro do compilador de qualquer
maneira).

**A regra que decide os casos futuros:**

> **Um conceito pode ser UM quando é só DADOS. Não pode quando envolve o
> ESCALONADOR, nem quando o coletor tem de PERCORRER lá dentro.**

| | é um só? | porquê |
|---|---|---|
| `Mapping` | **sim** | fd, ponteiro, tamanho. É por isso que o `declare Mapping` da 138.1 funciona |
| `Watcher`, `Buffer`, `bytes` | **sim** | idem — só dados, e nada lá dentro que o coletor tenha de seguir |
| `File` | **o punho sim, as operações não** | o punho é um fd; o `await f.read()` é o pool de threads e as tarefas |
| `Socket` | idem | |
| `List`/`Vec` | **não, e é a mesma pedra da 141.6** | os dados são ponteiro+tamanho+capacidade e podiam ser um. O que impede é o coletor ter de percorrer os ELEMENTOS — que é literalmente *objecto dentro de objecto* |

A última linha é o que torna isto um critério e não uma observação: **as duas
coisas que apareceram em conversas separadas — unificar as colecções, e a
mecânica do contrato — estão bloqueadas pela mesma pedra.** Enquanto o coletor
não souber percorrer memória que não é dele, nenhuma das duas anda.

**E o que isto diz sobre o plano do NIO:** os tipos que ele acrescenta são todos
só dados. **Nenhum deles vai virar dois.**

### 141.4 — o preço, dito antes de doer

O compilador **não consegue verificar** nenhuma destas promessas. Ele regista-as.
É o que o `unsafe impl` do Rust, o `@unchecked Sendable` do Swift, o `SafeHandle`
do C# e as regras de ponteiros do cgo fazem — toda a gente chegou aqui pela mesma
porta, e a conclusão é sempre a mesma: **a falha passa de "impossível de exprimir"
para "culpa de quem prometeu, e encontra-se com um grep"**.

É uma boa troca, mas é uma troca. E o portão que a torna aceitável é o mesmo que
este repositório já constrói: `grep -rn "implement Foreign"` dá a lista completa
das promessas que o sistema faz sem prova.

---

## BATERIA 142 — o `stl` entra para dentro do compilador (2026-08-24)

> *"vc consegue jogar nossa stl do P pra dentro do compilador do P, pra pessoa
> poder simplesmente importar ou declarar algo da stl sem precisar do pacote?
> (…) isso é possível pq todos eles são `ph`"*

A observação está certa e é ela que torna isto barato: **são 11 cabeçalhos
genéricos e uma implementação de 15 linhas**, 1 337 linhas ao todo. Nada disto se
linka — tudo se materializa no sítio do uso com `declare`/`implement`. Não há
objecto para distribuir; há **texto**.

### 142.0 — o problema, medido

Um recém-chegado que escreve um `.p` com um `Vec` bate em duas falésias de
configuração antes de compilar o que quer que seja:

```
exemplo.p:2:1: error: import <stl/vec.ph>: not found in any package root
                      (none was given: `--pkg-path <dir>`, repeatable)

# e depois, com --pkg-path absoluto e a fonte relativa:
exemplo.p:2:1: error: … the package root and the sources have to be named the
                      same way — both relative, or both absolute …
```

### 142.1 — e o compilador já resolveu isto uma vez, para o pscript

O `ps_prelude.psc` é um ficheiro REAL em `selfhost/`, embebido com `embed()` e
**analisado como um módulo qualquer**. A justificação está escrita ao lado dele e
serve palavra por palavra para o `stl`:

> *"`embed` é o que lhe permite ser um ficheiro de verdade e não custar nada em
> tempo de execução: os bytes são lidos em tempo de COMPILAÇÃO e viram um vector
> estático, portanto **não há ficheiro para encontrar, não há caminho para
> configurar**, e o prelúdio que um compilador carrega é exactamente o que foi
> compilado para dentro dele."*

Então: **o `stl` passa a viver em `selfhost/`, embebido, e `packages/stl/`
desaparece.** Deixa de ser um pacote e passa a ser parte do compilador — que é o
que ele já era na prática, porque o maior consumidor dele é o próprio compilador
(`parser.p`, `main.p`, `api.p`, `backend_c.p`, `ps_lower.p`, `vecs.p`).

Custa ~40 KB no binário do compilador, e um `plangc foo.p` passa a funcionar
sozinho.

### 142.2 — a grafia passa a ser `import <vec>`

Não por ser mais curta: porque depois da 142.1 o `<stl/vec.ph>` nomeia **um
directório que não existe e uma extensão de um ficheiro que ninguém vai abrir**.
Seria um fóssil apontado para o vazio.

E não é uma forma nova — é a mesma do `import <pui>`, que já quer dizer "a raiz
de um módulo que não está ao meu lado". As setas continuam a distinguir o que é
meu (`import "vec.ph"`) do que não é.

A travessia é a da 139.1, em três commits e cada um compila: o compilador aceita
os dois com um `-W` no velho → os ~30 imports da árvore migram → o velho sai.

### 142.3 — o embebido ganha SEMPRE, e não há como substituir

Um `stl` instalado é simplesmente ignorado. A razão é a mesma frase do prelúdio:
*"o que um compilador carrega é exactamente o que foi compilado para dentro
dele"*. Um ficheiro que pudesse substituí-lo em silêncio traz de volta a classe
de erro que o `embed` existe para matar — a de duas cópias e ninguém saber qual
correu.

### O que vigiar

**O compilador passa a embeber a biblioteca que ele próprio usa.** Mudar o
`vec.ph` muda o compilador, que muda o que ele embebe — um efeito em dois tempos.
Não é um problema novo: é exactamente o que o `ps_prelude.psc` já faz, e o portão
do ponto fixo (`s2 == s3`) mais a regeneração do `bootstrap/` cobrem-no. Mas é a
coisa a olhar quando a fase correr.

E o `cstr.p` é a excepção da excepção: é o único com implementação, e embeber um
`.p` quer dizer que o código vai compilado para dentro do programa de quem
importa — o mesmo que já acontece com um genérico materializado, só que sem o
`implement` à vista.

---

## BATERIA 143 — o pscript já se apaga em P, e o que isso fecha (2026-08-24)

> *"isso por acaso também permitiria que uma linguagem fosse superset da outra
> directamente?"* / *"o ideal seria que o runtime fosse escrito em P, e o pscript
> descesse pra esse runtime"*

**O ideal descrito é o que já existe**, e vale ficar escrito porque é fácil de
não ver. A primeira linha do `ps_lower.p` di-lo:

```
# ps_lower.p — pscript's tree becomes P's tree (49.1).
```

O runtime é P (`psrt_*.p`), o pscript desce para P, e o P gerado **importa o
runtime com um `import` normal**. Os dois encontram-se em P, no mesmo ficheiro:

```
import "../pscript/runtime/psrt.ph"          ← e este ficheiro é P

def soma(__ctx: *PsCtx, a: i64, b: i64) -> i64:
    if ps_has_exc(__ctx):
        return 0
    __ret: i64 = ps_add(__ctx, a, b, "…", 2)
    ...
```

**A fronteira não é uma fronteira de LINGUAGEM.** Há P escrito à mão e P gerado,
ligados por um `import`. É a relação que o TypeScript tem com o JavaScript — com
uma diferença: o TypeScript apaga-se para **nada**, e o pscript apaga-se para um
**runtime**.

### 143.1 — o preço é da PROMESSA, não de atravessar

`a + b` em dois inteiros vira `ps_add(ctx, a, b, ficheiro, linha)` porque o `+` do
pscript **promete** verificar transbordo e poder levantar. A chamada é o custo
dessa promessa.

**Medido, em `url.psc` — análise de cadeias pura, 890 testes de conformidade:**

```
linhas de C geradas:      6 984
chamadas ao runtime:      2 387
   destas, aritmética:      161   →  6,7 %
```

Se se desligassem TODAS as promessas, poupavam-se 6,7 %. Os outros 93 % são
`ps_str_concat`, `ps_list_append`, `ps_dict_get` — **não são a segurança do
pscript, são o pscript**.

> **Portanto "pscript sem runtime" não é um modo. Levado ao fim, é o P com outra
> sintaxe** — ter-se-ia renomeado em vez de unificado.

Fica escrito para não ser voltado a devanear: a ideia foi considerada, medida, e
o número é que a fecha.

### 143.2 — e o P não tem um tipo `str`

Uma correcção a uma coisa que eu tinha afirmado sem verificar. Não há colisão
entre as duas linguagens sobre a palavra `str`, porque o P não a usa:

```
const *char   1 645 usos        Str    11   (o StrBuf da 141.7)
*char           248             CStr   30
```

O `str` do pscript é minúsculo por ser um valor; o `StrBuf` do `stl` é maiúsculo
por ser uma coisa. A regra da 139 já os separava correctamente, e o "bloqueio
duro" que eu tinha levantado entre as duas linguagens **não existe**.

### 143.3 — a propriedade que um superset destruiria

```sh
plangc --backend p foo.psc     # e sai o P que o teu pscript virou
```

**Dá para LER a descida.** Um superset não teria nada para mostrar — a linguagem
de cima *seria* a de baixo, e não haveria tradução nenhuma para ver. É uma
propriedade de ensino e de depuração que se perde no instante em que as duas
linguagens passam a ser uma.

O precedente mais próximo do que foi imaginado é o **Nim** — uma linguagem só,
com o coletor opcional — e a lição dele é a que se esperaria: **os dois regimes
entornam um no outro**, e os modos de gestão de memória do Nim têm sido uma fonte
recorrente de instabilidade. Duas linguagens com uma costura tipada não têm esse
problema, porque nenhuma finge ser a outra.

## BATERIA 144 — um programa pode chamar `Buffer` ao seu tipo? (2026-08-24)

> **PENDENTE DE DECISÃO — segui com (b) para não travar.** Só o utilizador
> decide; o que está abaixo são as opções e o preço de cada uma.

Isto não foi imaginado: apareceu ao COMPILAR a FN, e o primeiro programa a
tropeçar nele foi o nosso.

```
pstudio/core.psc:1191: error: the return value expects Buffer, found core.Buffer
```

O editor tem um `struct Buffer` desde que existe — linhas, cursores, marcas e um
registo de desfazer — e a 139 acaba de dar esse nome ao bloco de bytes que os
workers partilham. O mesmo aconteceu num teste, com `struct File`. **A regra dos
nomes tira ao programa dois nomes que ele tinha o direito de usar**, e a tabela
de consequências da FN não apanhou isto porque contou GRAFIAS a mudar e não
NOMES a perder.

E a pergunta tem precedente directo neste repositório: a **68.3** decidiu que,
quando o programa declara um nome que o prelúdio também declara, **o do programa
ganha, com aviso, e só o item colidido cai** — porque `TYPE`, `VALUE` e `KEY` são
palavras que um programa tem direito de usar. `Buffer` e `File` são exactamente
o mesmo caso, com a mesma frase a defendê-las.

### As opções

**(a) O programa ganha, como na 68.3.** `struct Buffer:` sombra o embutido, com
aviso, e dentro desse módulo `Buffer` é o do programa.
*Consequência:* é a resposta que a 68.3 já deu para o prelúdio, portanto a
linguagem passa a ter UMA regra de sombra em vez de duas. **Custa maquinaria**: o
parser decide o tipo pela grafia e ainda não conhece as declarações, então o nome
embutido teria de ser resolvido na sema — que é onde a 68.3 já vive. É a opção
certa se a resposta for "sim".

**(b) O embutido ganha, e o programa renomeia.** ← *seguido, por ser o que não
decide nada sobre a linguagem*
*Consequência:* os nomes da 139 tornam-se reservados de facto. Aqui custou dois
renomes, e um deles foi uma melhoria por si: o tipo central do editor passou a
`TextBuffer`, que é o que ele é — um buffer de TEXTO, com linhas e cursores, e
não o bloco de bytes que a 139 chama `Buffer`. O preço real não é este; é o de
quem chegar de fora com um `struct File` seu.

**(c) Só os genéricos são reservados.** `List`, `Dict`, `Set` levam `<` e são
inconfundíveis; `Buffer`, `File`, `Socket`, `Timer` seriam nomes de biblioteca
como outro qualquer, alcançáveis por um módulo.
*Consequência:* separa o núcleo da biblioteca, que é como o Python o faz
(`list` é embutido, `Path` vem do `pathlib`). Mas obrigaria um `import` para
anotar um ficheiro aberto, e hoje `open()` devolve um `File` sem importar nada.

### O que já se sabe, e não depende da escolha

**Os nomes que a 139 reserva são poucos e todos maiúsculos**, portanto a colisão
só acontece com um tipo do utilizador — nunca com uma variável, um campo ou uma
função. Foram dois em 376 ficheiros `.psc`, o que dimensiona o problema: é real,
e é raro.

## BATERIA 145 — o guarda do SIGBUS, e a fronteira que o trava (2026-08-25)

A 137.2 desenhou o guarda inteiro: *"entrar no `with` grava um ponto de retorno
e a profundidade da pilha-sombra; o manipulador confirma que o endereço caiu num
mapa NOSSO, desenrola até àquela profundidade e levanta; se não caiu, re-levanta
o sinal."*

**Ao implementá-lo, ele esbarra duas vezes na mesma fronteira** — a 72.4, *"uma
macro que não é número não atravessa"* — e é a mesma que o manipulador de crash
da 12.4 já tinha documentado para o `SA_ONSTACK`:

1. **O ENDEREÇO da falha.** `siginfo_t.si_addr` só chega por `sigaction` com
   `SA_SIGINFO`. O membro que guarda o manipulador é uma **macro sobre uma
   união** cujo nome difere entre a glibc (`__sigaction_handler`) e o macOS
   (`__sigaction_u`), e o offset de `sa_flags` difere com ela porque o
   `sigset_t` do meio tem 128 bytes num e 4 no outro. E o próprio `si_addr` está
   em offsets diferentes nos dois `siginfo_t`. Escrever qualquer uma das
   grafias seria um `#ifdef` de plataforma no meio do runtime.

2. **Um `setjmp` no frame que vai ser retomado.** Um `setjmp` chamado por uma
   função do runtime deixa de valer no instante em que ela retorna — e o bloco
   `with` está no frame de quem o escreveu. O salto teria de ser EMITIDO pelo
   lowering para dentro da função do utilizador.

### O que ficou feito

Enquanto houver um mapa aberto, um SIGBUS deixa de morrer mudo:

    pscript: SIGBUS: a page of a mapping went away — the file was very likely
    truncated by somebody else while it was mapped (137.2)
      in go (analise.psc)

Mais a pilha do pscript que o manipulador da 12.4 já imprimia. Portão:
`tests/mmap-truncate.sh`, que trunca mesmo o ficheiro debaixo de um mapa aberto.

**É estritamente melhor do que nada e é menos do que a 137.2 pediu**, e a
diferença é essa: quem trunca lê a causa em vez de a adivinhar, mas o programa
continua a morrer em vez de levantar.

### O desenho que fecharia isto, para quando se decidir

> **O corpo do `with` passa a ser uma CLOSURE que o runtime chama.**

Aí o `setjmp` vive no frame do RUNTIME — que é o dono dele — durante todo o
bloco, e o problema (2) desaparece. O problema (1) desaparece com ele: sem
precisar do endereço, o guarda pode ser "estou dentro do `with` DESTE mapa",
que é exactamente o modelo do `PG_TRY` do Postgres que a 137.2 nomeou.

O preço é que `break`, `continue`, `return` e `await` dentro do bloco passam a
atravessar uma fronteira de função, e cada um deles precisa de resposta. É uma
bateria própria, e não uma linha.

**PENDENTE DE DECISÃO — segui com o guarda que diz a causa, para não travar.**

## BATERIA 146 — as quatro perguntas do `Watcher`, respondidas (2026-08-25)

A 140.1 deixou-as escritas como abertas de propósito, *"para não serem
resolvidas por engano"*. Foram decididas na execução da F5, com o utilizador a
dormir e com a instrução de tomar a melhor decisão. Cada uma abaixo diz o que
foi escolhido **e o que se perde com a escolha**, que é a parte que permite
reabrir.

### 146.1 — a recursão é nossa, e a corrida fecha-se com uma VARREDURA

`os.watch(dir, True)` percorre a árvore ao abrir e põe um vigia por directório.
Um directório criado depois recebe o seu quando o evento de criação chega — e
entre o `mkdir` e o `inotify_add_watch` cabem ficheiros que ninguém viu.

**A corrida não se evita; fecha-se.** Ao pôr o vigia num directório novo,
LÊ-SE o directório e sintetiza-se um `CREATED` por cada coisa que já lá está.
Um evento a mais é ruído; um evento a menos é um ficheiro que o build não
recompila, e a diferença entre os dois é toda.

*O que se perde:* um `CREATED` duplicado para o que chegou entre as duas coisas.
É o preço certo, e é o que o `chokidar` e o `watchman` também pagam.

### 146.2 — no macOS, `os.watch` LEVANTA, e diz o que falta

O `inotify` é do Linux. O `kqueue` vigia DESCRITORES — uma árvore são N
descritores abertos, e o limite chega depressa — e a resposta real do macOS é o
**FSEvents**, uma API diferente, com chamada de volta numa run loop.

**Não se escreve meio vigia.** No macOS, `os.watch` levanta com a mensagem a
dizer que o FSEvents é o caminho e que não está escrito. É honesto, e é a única
saída que não entrega um vigia que às vezes vê.

*O que se perde:* o `pforge dev` e o `check_external` do editor não têm vigia no
macOS até alguém escrever o FSEvents. Continuam a sondar, como sondam hoje.

### 146.3 — COALESCE, e a unidade é o par (caminho, espécie) CONSECUTIVO

Gravar um ficheiro num editor produz três ou quatro eventos. Entregá-los crus
faz com que cada consumidor escreva o mesmo anti-ressalto, que é a queixa
conhecida do `WatchService` do Java.

Mas coalescer demais MENTE: um `CREATED` seguido de um `DELETED` não é nada, e
colapsá-los perderia a única coisa que interessava. Então a unidade é a mais
pequena que ajuda e não pode mentir: **duas entregas CONSECUTIVAS do mesmo
caminho com a mesma espécie são uma**. A ordem fica intacta, e um par
`MOVED_FROM`/`MOVED_TO` nunca se junta, porque as espécies diferem.

*O que se perde:* nada que se consiga nomear. Um consumidor que quisesse contar
escritas contaria menos — e não há consumidor desses.

### 146.4 — os DOIS, porque são duas perguntas

`await w.ready()` espera até haver alguma coisa. `w.pending()` diz quantos estão
à espera AGORA, e `w.take()` tira um.

    with os.watch("src", True) as w:
        while await w.ready():
            while w.pending() > 0:
                caminho, especie, cookie = w.take()

Uma construção que toca em oitocentos ficheiros é um laço sobre `pending` em vez
de oitocentas esperas — e não custa oitocentas voltas ao escalonador, porque
`ready()` sobre uma fila não vazia devolve uma tarefa JÁ PRONTA, e uma tarefa
pronta não estaciona. **Nenhuma das duas é uma versão pior da outra.**

**A superfície mudou em relação ao esboço da 140.1**, que escrevia
`ev = await w.next()`, e a razão é de implementação e vale a pena estar dita: um
evento é um TRIO que segura uma `str`, portanto é uma tupla com referência (98.4)
— e o RUNTIME não sabe montar um record que o compilador sintetizou. `take()` é
síncrono e monta-o no lowering, exactamente como o `recv_from` da F7 faz.

Um `drain()` que devolvesse `List<(str, Change, int)>` obrigaria o runtime a
construir uma lista de records cuja disposição ele não conhece — e `pending()`
com `take()` dá o mesmo desempenho sem essa maquinaria. Não é um atalho: é o
desenho mais simples que cumpre o requisito.

### 146.5 — a espécie do transbordo chama-se `RESCAN`

A 140.1 decidiu que o transbordo é um evento e não um silêncio. O nome que ela
usava era `OVERFLOW` — que já está tomado, pela `Category` do prelúdio (54.3).

`RESCAN` é melhor de qualquer maneira: diz ao consumidor o que FAZER — *"não sei
o que mudou, relê tudo"* — em vez de lhe dizer o que aconteceu ao núcleo. O
nome de um evento vale pelo que ele manda fazer.

---

## 147 — a S3: o que a concorrência ainda não tinha nome para dizer

A `STDLIB.md` §4.1 decidiu as três peças; implementá-las obrigou a decidir mais
quatro coisas que ela não podia ter previsto, e é isso que esta bateria fixa.

### 147.1 — `ch.recv()` devolve `T?`, e a razão é a 4.2

O vocabulário proposto era o do worker: `while ch.open():` e depois
`await ch.recv()`. **O predicado fica** — é a forma mais curta e é a que já se
escreve com um worker — mas ele sozinho não chega, e a razão é concreta: com
DOIS receptores, os dois podem passar o `open()` com um único valor na fila, e o
segundo fica preso para sempre num canal que já ninguém vai alimentar.

Fechar um canal acorda todos os receptores parados, e então há uma pergunta que
tem de ter resposta: **o que é que um `recv` acordado num canal fechado e vazio
devolve?** Levantar seria fazer do fim de um fluxo uma excepção — exactamente o
que a 4.2 proíbe, porque chegar ao fim de um canal É parte do algoritmo.

> **`await ch.recv()` devolve `T?`: o valor, ou None quando o canal fechou e
> não sobrou nada.**

E então o laço completo, o que funciona com qualquer número de receptores, não
precisa de predicado nenhum:

```
while True:
    v = await ch.recv()
    if v == None:
        break
    usa(v)
```

O `open()` continua lá para o caso de um receptor só, que é o comum.

### 147.2 — o canal não é sondado: a entrega é DIRECTA

Um socket precisa do multiplexador porque quem o alimenta é o núcleo. **Um canal
não**: quem o alimenta é outra tarefa do mesmo heap, e o instante em que o
estado muda é uma linha de código nossa. Portanto um `send` que encontra um
receptor parado **escreve o valor no quadro dele e põe-no na fila de prontos ali
mesmo** — sem passar pelo `poll`, sem uma volta ao escalonador, sem um descritor.

Isto tem uma consequência boa e não óbvia: as tarefas paradas num canal ficam
**fora de `ctx->waiters`**, na fila do próprio canal. Então quando toda a gente
está parada num canal, o `ps_sched_progress` vê a fila de prontos vazia, nenhum
prazo e nenhuma espera — devolve falso, e o `await` de quem está por cima
levanta *"deadlock: awaiting a task that nothing can finish"*. **O travamento de
canal é diagnosticado pela maquinaria que já existia**, e não por um detector
novo.

### 147.3 — a saída do `taskgroup` ARRASTA o escalonador, e não é `await`

A §4.1(b) escreveu *"a saída do `with` faz o `gather`"*, e um `gather` é um
`await`. Mas a libertação de um `with` é um `defer` de P — uma chamada
**síncrona** — e pôr um ponto de espera dentro de um `defer` que corre também no
caminho do erro é a peça de compilador mais cara deste plano inteiro.

Não é preciso, e a razão é que a peça certa já existe: **o `ps_task_wait`**, que
é como um `await` num `def` normal e no topo do programa já funciona. Ele não
para a thread — arrasta o escalonador até a tarefa acabar, e no caminho corre
toda a gente. A saída do grupo faz isso por cada filho.

O que se perde, dito para não ser descoberto depois: dentro de um `async def`, a
tarefa que sai de um grupo **não estaciona** enquanto espera pelos filhos, portanto
quem a estiver a aguardar não a vê parada. O que ela promete — *o bloco não
acaba antes dos filhos* — cumpre-se na mesma, e todas as outras tarefas correm.

E o caso mau já tem diagnóstico: um filho que espere pelo pai faz o
`ps_task_wait` chegar ao *"nothing can finish"* que ele sempre teve.

### 147.4 — um grupo não recolhe VALORES, e é de propósito

O `gather` é homogéneo: `List<Task<T>>`, um T só. Um grupo em que `g.spawn`
aparece dentro de um `for` e de um `if` não pode ser — as tarefas de um bloco
não têm razão nenhuma para devolver todas a mesma coisa.

A saída é a que o `race` já tinha escrito: **o grupo é sobre TEMPO DE VIDA, não
sobre resultados.** `g.spawn(t)` aceita um `Task<T>` de qualquer T, o grupo
guarda-o como tarefa e mais nada, e quem quiser o valor lê-o da variável que
guardou — que é o que o `race` diz por extenso (*"o valor lê-se dessa tarefa
depois"*). Recolher continua a ser trabalho do `gather`, e as três garantias que
a §4.1(b) pediu são todas sobre tempo de vida, nenhuma sobre valores.

### 147.5 — o canal não tem `with`, e o `close` é um SINAL

Tentador, e errado. Fechar um canal não liberta recurso escasso nenhum — é
memória, e a 136.1 manda a memória para o coletor. O que `close()` faz é dizer
**"não mando mais"**, que é protocolo e não limpeza: quem fecha é o produtor, e
o produtor quase nunca é o dono do bloco onde o canal nasceu.

Um `with Channel<int>(4) as ch:` fecharia no sítio errado com uma cara de
correcto, e é o género de conveniência que só se paga uma vez, tarde.

### 147.6 — a marca de um `T?` passa a ser de oito bytes

Descoberta ao implementar o `recv` da 147.1, e é uma daquelas em que a coisa
certa a mudar não é a que parecia.

Um `T?` de referência **é o ponteiro** e None é o nulo — de graça, e o runtime
sabe escrevê-lo. Um `T?` de valor é um registo `{has, v}`, e o deslocamento de
`v` depende do enchimento que o compilador de C escolher para aquele T. O
runtime não pode adivinhá-lo, e mandar-lho de fora obrigaria a emitir um
`offsetof` — que o QBE trata por um nome e o C por outro.

A saída foi mudar o registo: **`has` passa de `bool` a `i64`.** Com uma marca de
oito bytes à frente, o valor cai **sempre no deslocamento 8**, porque nada no
pscript se alinha para lá de oito. Custa quatro bytes num tipo que na maioria
dos casos já estava enchido até lá, e compra uma coisa que não se tinha:

> **o runtime passa a saber escrever um `T?` sem que o compilador lhe mande a
> disposição.**

### 147.7 — o `sched.stats()` apanhou um defeito no primeiro dia

Ele existe para responder *"quem está à espera de quê"*, e a primeira coisa que
respondeu foi que havia uma tarefa parada no relógio que já não tinha dono.

O `timeout(t, 0.05)` sobre um `await sleep(5.0)` **cancelava a tarefa em 50ms e o
programa saía cinco segundos depois na mesma**: o `ps_task_cancel` acordava quem
estava parado, mas o PRAZO ficava na fila do relógio, e o laço de eventos não
acaba antes do último prazo. Um `race` perdido deixava o mesmo rasto.

Agora o prazo morre com a tarefa que o pediu. E vale a pena dizer o que isto é:
uma métrica que aponta para um defeito no dia em que nasce é exactamente para o
que ela serve — e é o argumento a favor do item 44 da interseção, feito por si
próprio.

---

## 148 — a S2, e o que a medição mudou no que estava escrito

A `STDLIB.md` decidiu a forma da S2; implementá-la obrigou a medir a fronteira, e
a medição corrigiu uma promessa que aquele documento faz e não se pode cumprir.

### 148.1 — o `Hash` como TRAIT não dá, e o bloqueio já tinha nome

A `STDLIB.md` §5 escreve que o `sha2` *"já prova o caminho"* e que o trait
`Hash` se declara com `implement Hash for sha2.Sha256:`. **Não dá**, e a razão
está na 141.6, escrita meses antes.

Medido em `selfhost/ps_sema.p`, na função `c_type`: o que atravessa a fronteira
da 45.5 são **escalares por nome**, e mais nada — nem ponteiro, nem array, nem
struct. A excepção que funciona é o `CStr`/`CBytes` da 84.1, que é um ponteiro e
um comprimento **como valor**, e é assim que o `sha256_of(in data: CBytes) ->
CStr` do `packages/sha2/sha2.ph` já é chamado do pscript hoje.

O que isso permite e o que não permite é nítido:

| | atravessa? | |
|---|---|---|
| `sha256_of(in data: CBytes) -> CStr` | **sim** | um tiro só, e é o que quase toda a gente quer |
| `sha256_init/update/final` sobre `Sha256` | **não** | a `struct Sha256` não tem nome do lado de cima — é exactamente o `Foreign` que a 141.6 parou de propósito |

Portanto **a S2 entrega o hash de um tiro**, e o trait `Hash` com estado
incremental fica **atrás da 141.6**, escrito aqui para não voltar a ser
prometido por engano. O `hmac` que sai agora é HMAC-SHA256 concreto e em P —
onde o estado incremental do `sha2` está do mesmo lado e portanto é livre.

Quando a 141.6 andar, o `hmac` ganha um parâmetro de tipo e não perde nada.

### 148.2 — o `hash` é um pacote NOVO, e o `sha2` fica onde está

O plano lista um pacote `hash` com os módulos `sha2`, `sha1`, `md5`, `crc32`.
Mas o `sha2` **já é um pacote**, e o `pforge` depende dele **pelo nome** — está
nos `pack.json`, nas fixtures do lockfile e no descritor de build. Mudá-lo de
sítio custaria mais do que vale.

Então: o `sha2` fica; nasce um pacote `hash` com o que faltava (`crc32`, `sha1`,
`md5`); e o metapacote `crypto` reúne os dois com o `hmac`, o `csprng` e o
`ed25519`. **O metapacote existe precisamente para isto** — dar um nome ao
conjunto sem obrigar as peças a mudar de morada.

### 148.3 — o que este pacote diz de si próprio

Um ficheiro que contém CRC32, SHA-1 e MD5 tem de dizer, onde se lê, o que cada um
vale, senão alguém escolhe o primeiro que reconhece:

> **O CRC32 é uma soma de verificação** — apanha um bit trocado num fio ou num
> disco, e não apanha nada de quem está a tentar. **O SHA-1 e o MD5 estão
> partidos**, os dois, com colisões publicadas. Estão aqui para **LER o que já
> existe**: um id de objecto do git é SHA-1, e meio mundo ainda publica MD5.
> **Nada aqui decide se se confia em alguma coisa** — isso é o `sha2`, e o
> gestor de pacotes já o usa.

E o `hmac_equal` compara em tempo que não depende de ONDE os dois diferem, pela
razão de sempre: uma comparação que pára no primeiro byte diferente diz a quem
está a tentar quantos bytes acertou, e isso chega para descobrir o resto um byte
de cada vez.

### 148.4 — os temporários CRIAM, e não têm os nomes do Python

`os.tempdir()` diz ONDE; `os.tempfile(prefix, suffix)` e `os.tempdir_new(prefix)`
**criam** e devolvem o caminho do que criaram.

Devolver um nome que ainda não existe é a corrida clássica do `mktemp`: entre a
resposta e o `open` de quem chamou, qualquer um põe ali um link simbólico
apontado ao ficheiro dele. Aqui o `O_EXCL` já reservou o nome quando a função
volta, com modo 0600 — e o directório nasce com 0700, porque o que se escreve num
temporário é justamente o que ainda não está pronto para ser lido.

**Os nomes não são `mkstemp`/`mkdtemp` de propósito.** O `mkstemp` do Python
devolve um descritor E um nome; o nosso devolve só o nome. Dar o mesmo nome a
duas coisas diferentes é como se aprende o errado.

E há um preço a dizer: o `errno` é macro e o P não o vê (72.4), portanto estas
funções **não distinguem** "o nome estava tomado" de "não há permissão de
escrita". Tentam sessenta e quatro nomes e depois levantam, com uma frase que
pergunta o que provavelmente é — sessenta e quatro colisões seguidas não
acontecem.

### 148.5 — dois defeitos que a S2 desenterrou, e os dois eram silenciosos

**(a) Um `await` dentro de uma limpeza dava SIGSEGV.** O `defer` recusava-o com
uma frase; o `finally` não, porque a recusa morava em quem chamava e havia três
chamadores. O que ele emitia era a METADE DE TRÁS de um `await` — a leitura do
resultado de uma tarefa que nunca chegou a existir — logo `ps_task_ret(NULL)`.

A recusa mudou-se para dentro do `ab_arm`, que é por onde os três passam. Uma
limpeza que precisa de suspender é uma peça que falta; ir-se abaixo em silêncio é
outra coisa, e a diferença entre as duas é a frase que diz o que escrever.

**(b) Um literal com campos NOMEADOS não baixava as conversões.**
`{.n = usize(64)}` saía em C tal e qual — uma chamada a uma função `usize` que
não existe — e o erro aparecia no LINKER, longe do sítio e sem posição. A forma
posicional sempre funcionou, o que fazia da diferença entre as duas uma armadilha
em vez de uma escolha de estilo.

A causa era uma linha: o `check_expr` de uma lista de chaves percorria os
argumentos, e um `.campo = valor` é um nó DESIGNADOR cujo valor está lá dentro —
portanto nunca era visitado. Vale para o `[i] = valor` de um array pela mesma
razão. Portão em `tests/cases/desig_convert.p`.

**E o que os dois têm em comum vale a pena dizer**: nenhum apareceu ao escrever a
funcionalidade, e os dois apareceram ao escrever o TESTE dela. É o argumento a
favor de o portão vir junto e não depois.

---

## 149 — a S4: o `datetime`, e onde os fusos moram

### 149.1 — o `ZonedDateTime` não guarda o NOME do fuso, e é melhor assim

O `record` do pscript é bytes puros (58.2), portanto uma `str` não cabe lá
dentro. Isso obrigou a decidir, e a decisão é a certa por uma razão que não é a
da restrição:

> **um nome de fuso sem as REGRAS não vale nada.** `Europe/Lisbon` não diz que
> horas são; diz onde ir perguntar.

O que um `ZonedDateTime` precisa de carregar para ser um ponto na linha do tempo é
o **deslocamento**, e é isso que ele carrega. Quem souber as regras converte o
nome num deslocamento e constrói um; quem só tiver o deslocamento (que é o que
qualquer RFC 3339 escreve) já tem tudo.

### 149.2 — o `tzdata` LÊ O DO SISTEMA, e não traz uma cópia

A `STDLIB.md` §5 põe o `tzdata` como pacote com gerador próprio, ao lado do
`psl`. **Revisto**, e o argumento é o que ela própria usa para o `tls`:

> *"a confiança vem do sistema (…), pela mesma razão do `tzdata`: uma autoridade
> revogada corrige-se com `apt upgrade` e não com uma recompilação nossa."*

As regras de fuso mudam **várias vezes por ano** — um país adia o horário de
verão, outro muda de fuso, e a decisão é publicada com semanas de antecedência.
Uma cópia nossa estaria errada em produção antes de a tinta secar, e a única
maneira de a corrigir seria uma versão nova do pacote.

E o sistema já tem a resposta certa: `/usr/share/zoneinfo`, em TZif (RFC 8536),
actualizado pelo mesmo `apt upgrade` que corrige tudo o resto.

**Diferente do `psl`**, e por isso ele fica como está: a lista de sufixos
públicos **não tem cópia do sistema**. Não há de onde a ler; ou se traz, ou não
se tem.

**O que ele faz quando não há `/usr/share/zoneinfo`: LEVANTA.** Nunca recua para
UTC. Um programa que pede `Europe/Lisbon` e recebe UTC em silêncio marca reuniões
à hora errada durante meio ano — que é a mesma família de erro do CSPRNG que
recuasse para o Mersenne Twister.

**O nome é `tz` e não `tzdata`**, porque o que o pacote tem não é dado: é o
leitor. `TZDIR` sobrepõe-se ao caminho, que é a variável que o próprio zoneinfo
define para isso.

### 149.3 — o que o portão do `tz` escolheu, e porquê cada um

Os seis fusos do portão não são uma amostra: cada um apanha uma classe de erro
que os outros não apanham.

| fuso | o que apanha |
|---|---|
| `Europe/Lisbon` | o caso comum — e o instante zero apanha quem assume que Portugal sempre esteve em WET (em 1970 estava a +1) |
| `UTC` | **nenhuma mudança**: o caminho onde a busca binária não corre de todo |
| `America/New_York` | deslocamento negativo, onde o sinal invertido do POSIX morde |
| `Asia/Kathmandu` | **quarenta e cinco minutos** — que uma API a contar horas não saberia escrever — e uma mudança de fuso em 1986 que **não é** horário de verão |
| `Australia/Sydney` | o **hemisfério sul**, onde o verão atravessa o Ano Novo e a condição da regra POSIX inverte-se |
| `Pacific/Chatham` | os dois ao mesmo tempo: sul **e** quarenta e cinco minutos |

E dois dos seis instantes são **para lá do fim do ficheiro** (2050 e 2100), que é
onde deixam de existir transições listadas e passa a mandar a regra POSIX do
rodapé. Sem a ler, uma implementação apressada devolve o último deslocamento
conhecido e erra **todas** as datas futuras — em silêncio, que é o pior de tudo.

O oráculo é o `zoneinfo` do CPython, varrido: 36 pares (fuso, instante), mais o
horário de verão e as cinco recusas.

### 149.4 — o nome de um fuso vem de fora, e é tratado como tal

`tz.load(name)` recusa um nome vazio, um caminho absoluto e qualquer `..`. Não é
zelo: um nome de fuso chega quase sempre de um cabeçalho HTTP, de um campo de
formulário ou de uma variável de ambiente, e `../../etc/shadow` é um nome
perfeitamente válido para quem não olha.

---

## 150 — a S6: o `compress`, e a metade que importa

### 150.1 — ler primeiro, e a `deflate` diz que não comprime

O `deflate` deste pacote **guarda em blocos literais**: comprime zero, e é válido
para qualquer leitor do mundo — o formato tem um tipo de bloco para exactamente
isto.

Não é um atalho escondido; está escrito no docstring da função. E a razão é uma
ordem de valor:

> **Ler o que os outros escreveram é o que desbloqueia consumidores.** O `tar`
> quer isto, e o cliente HTTP quer `Accept-Encoding: gzip` — que é onde a
> descompressão deixa de ser um extra e passa a ser o que faz metade da web
> responder. Escrever BEM é uma optimização que se pode adiar sem que nada fique
> por fazer, e quando ela chegar é uma função que muda e mais nada.

O que o `gzip_compress` produz hoje o `gunzip` abre. É maior do que o original;
é correcto.

### 150.2 — o portão prova que lemos o que os OUTROS escrevem

Os vectores são feitos pelo `zlib` do CPython com nível 9 — Huffman dinâmico,
referências para trás, blocos que a nossa própria `deflate` nunca produziria. É
de propósito: um portão que comprimisse e descomprimisse com o nosso código
provaria que ele é consistente consigo próprio, que não é a pergunta.

E os cinco casos são escolhidos, não amostrados. O que importa nomear é o
terceiro: **trezentas vezes o mesmo byte** produz uma referência para trás com
`distância < comprimento` — ela lê o que ela própria acabou de escrever. É o
caso que uma cópia em bloco partiria, e é o mais comum de todos.

### 150.3 — três formatos, três pares de funções

`inflate`/`deflate` (RFC 1951), `zlib_decompress`/`zlib_compress` (RFC 1950),
`gzip_decompress`/`gzip_compress` (RFC 1952). **Não é um parâmetro**, e não é
falta de arrumação: confundi-los é o erro mais comum de quem usa a `zlib` pela
primeira vez, e três nomes tornam-no impossível.

E um fluxo que mente sobre si próprio **levanta**: o complemento do comprimento
num bloco literal, o Adler-32 do zlib, o CRC-32 e o tamanho do gzip. Nenhum deles
é uma condição do algoritmo (4.2) — é o ficheiro a dizer uma coisa e a ser outra.

---

## 151 — a S8 e a S9, e a regra que elas descobriram duas vezes

### 151.1 — um PACOTE não pode ter estado, e isso muda dois desenhos

A §4.1 do `STDLIB.md` decidiu que o `log` seria **global** — `log.info("...")` sem
passar nada — apoiada na 42.2: uma global mutável no pscript é privada do worker,
portanto cada worker teria o seu logger sem contenção e sem cadeado.

**Não dá.** Um módulo IMPORTADO não pode ter estado no topo: só um programa pode,
porque só ele tem uma ordem de execução definida. Um pacote é um conjunto de
definições. E a mesma pedra apareceu logo a seguir no `ptest`, que queria
acumular as falhas de um caso numa lista do módulo.

Havia duas saídas, e a escolhida diz mais do que a outra:

* pôr o `log` no RUNTIME, ao lado do `gc` e do `sched`, e ganhar a global. Isso
  seria meter uma escolha de **política** — para onde vão os registos, a partir
  de que nível — dentro da linguagem, e a linguagem é o sítio errado para
  política;
* **um punho que o programa cria e guarda**, que é o que o `slog` do Go e o
  `tracing` do Rust fazem.

O que se perde é uma palavra por chamada. O que se ganha é que **a história dos
workers deixa de ser magia**: um worker que precise de outro nível recebe o punho
dele na entrada, à vista, em vez de alguém descobrir mais tarde que o `set_level`
do principal não chegou lá. E dois `Runner` deixam de se ver, o que a global
nunca permitiria.

**A metade boa da decisão original mantém-se inteira: não há cadeado nenhum.**
Uma linha sai inteira porque o `print` já garante isso (107.2), e um logger que
escreva por linhas herda a garantia em vez de a reconstruir.

### 151.2 — os pares alternados, e porque não é `key=value`

`log.info(lg, "started", "port", 8080)` — a forma do `slog`. A §4.1 escreveu
`key=value` no sítio da chamada, e isso não pode ser: os argumentos nomeados do
pscript são de tempo de compilação e quem os recebe tem de os **declarar**,
portanto uma chave arbitrária não cabe lá.

Um número ímpar de argumentos levanta, e a verificação é feita **antes** do
nível: um par mal escrito é um erro de programa, e um erro de programa que só
aparece quando alguém baixa o nível em produção é o pior sítio possível para ele
aparecer.

### 151.3 — o `any` passa a ter forma escrita, e o `json.stringify` aceita-o

Duas coisas que faltavam e que só se notam quando se precisa delas — e foi o
`log` a precisar:

* **`str()` de um `any` não compilava**, portanto `print(x)` de um `any` também
  não. Agora rende: um número, um bool ou None vão numa caixa com a espécie
  escrita, um objecto tem o cabeçalho dele, e uma `List<any>`/`Dict<str, any>`
  recorre. E cita as strings aninhadas, como o caminho estático faz — se não o
  fizesse, o mesmo valor sairia de duas maneiras conforme o tipo com que foi
  anotado;
* **`json.stringify` recusava um `any`**, com a frase *"o que não é uma dessas
  formas teria de ser inventado"*. Mas um `any` só pode conter números, texto,
  bools, None, `List<any>` e `Dict<str, any>` — que é **exactamente** a lista de
  formas do JSON. Recusá-lo era recusar o tipo cuja forma é a do próprio formato.

Nasce um `PS_T_ANY` na tabela de tipos, e o que ele quer dizer é *"pergunta ao
valor"*. É graças a isso que uma linha de registo em JSON sai com `"n":42` e
`"b":true`, em vez de `"42"` e `"True"` — que era o que a torna útil a uma
máquina.

### 151.4 — o `csv` não adivinha tipos, e isso é a decisão

Tudo o que sai é `str`. Um leitor que decidisse que `007` é o número sete perderia
o zero à esquerda de um código postal — que é o defeito mais caro que esta família
de bibliotecas tem, e o mais difícil de descobrir porque só aparece nos dados de
outra pessoa.

E lê as três coisas que a norma não tem e os ficheiros têm: o separador (`;` em
meia Europa, porque a vírgula é o separador decimal), os três fins de linha, e o
BOM que o Excel põe à frente.

---

## 152 — a S2b: o motor de regex, e o que ele custa de propósito

### 152.1 — a razão cabe numa linha, e é de coerência

Um motor com retrocesso **pode ser feito parar por uma cadeia de entrada**.
`(a+)+b` contra sessenta `a` são 2^60 caminhos, e o processo não volta.

> Uma linguagem que promete quatro eixos de segurança de memória (9.1) e depois
> oferece um regex que uma entrada consegue travar está a prometer com uma mão e
> a tirar com a outra.

O portão mede-o: quatro padrões catastróficos, com sessenta, duzentos e cem
caracteres, e a asserção de que os quatro juntos demoram menos de cinco segundos.

### 152.2 — o preço está pago à cabeça, e é matemática

Um motor de tempo linear **não pode** ter retrocesso (`\1`) nem lookaround
(`(?=…)`). O autómato não guarda o texto que já casou — é essa a razão de ele ser
linear. Não é uma peça que falta; é a mesma propriedade dita ao contrário.

E é por isso que **as duas mensagens de recusa dizem PORQUÊ**:

> *"a backreference does not exist in this engine, and cannot: a linear-time
> automaton does not keep the text it already matched. That is the price of
> `(a+)+b` never hanging"*

Uma mensagem que dissesse "não suportado" faria alguém esperar que um dia
viesse.

**E o `\1` na SUBSTITUIÇÃO continua a existir**, que não é contradição: ali o
texto já está todo casado.

### 152.3 — a garantia mora em três linhas

```
if l->seen[pc] == l->gen:
    return
l->seen[pc] = l->gen
```

Num dado passo, cada instrução entra na lista no máximo **uma vez**. Sem isso,
duas linhas de execução que chegam ao mesmo sítio duplicam-se, e a duplicação é
exponencial — que é exactamente o que faz `(a+)+b` parar um motor com retrocesso.
Com isso, o trabalho por caractere é no máximo o tamanho do programa.

### 152.4 — o oráculo é o `re` do CPython, varrido

Cinquenta e um padrões contra cinquenta e um textos, com os grupos todos, mais as
funções novas e os casos de canto. **O que se prova não é que o motor é
consistente consigo próprio** — isso não é a pergunta — é que ele responde o
mesmo que o motor que toda a gente usa.

Dois casos merecem nome:

* **o casamento VAZIO avança uma posição.** `findall("a*", "bb")` casa o vazio em
  cada sítio e tem de acabar. Uma implementação que não o faça pendura o
  programa no primeiro padrão que possa casar nada;
* **um separador vazio não separa.** O `re.split` do Python mudou de
  comportamento na 3.7 por causa disto, e a escolha certa é ignorá-lo em vez de
  partir o texto entre cada dois caracteres.

### 152.5 — dois defeitos que o motor encontrou no caminho

* **a busca não ancorada parava cedo.** O laço saía assim que uma posição não
  deixava nenhuma linha viva — e uma busca não ancorada tem de continuar até ao
  fim do texto. Só DEPOIS de haver casamento é que uma lista vazia quer dizer
  "acabou", porque aí semear outra vez daria um resultado mais à direita;
* **um campo novo no `PsCtx` ficou com lixo.** O `ps_ctx_init` inicializa campo a
  campo e o `recache` foi esquecido, portanto a primeira chamada usou um ponteiro
  inventado. Vale a pena dizer que isto é o desenho a funcionar: um `memset`
  teria escondido o esquecimento, e campo a campo fez-lhe doer no primeiro
  programa que o tocou.

### 152.6 — o Unicode entra, e a 105.4 fica REVISTA em vez de reaberta

`\p{L}`, `\p{Lu}`, `\p{Ll}`, `\p{Lt}`, `\p{N}`, `\p{Nd}`, `\p{Alnum}` e
`\p{Space}` — mais a forma curta `\pL` e a negada `\P{...}`. As tabelas já
existiam, geradas e conferidas por um oráculo que varre todo o ponto de código
(105); o que faltava era uma **porta**, porque o motor mora na camada da
biblioteca e os leitores eram privados da dos valores.

Uma categoria é um **predicado** e não intervalos: `\p{L}` são cento e trinta mil
pontos de código em milhares de faixas, e expandi-los daria uma tabela por
padrão quando ela já existe uma vez só.

**E o `(?i)` dobra a caixa do Unicode — mas a dobra SIMPLES.** A `STDLIB.md`
escreveu *"o `(?i)` é Unicode completo (…) entra a tabela de case folding (…) é
ela que faz `(?i)` casar `İ` com `i` e `ß` com `ss`"*, e marcou a 105.4 para
REABRIR. **Fica revista em vez disso**, e a razão não é economia:

> a dobra COMPLETA mapeia `ß` para `ss` — **um caractere para dois**. Um autómato
> que anda um caractere de cada vez não tem como casar dois de entrada contra um
> do padrão sem guardar o que já leu, que é exactamente a propriedade que ele não
> tem e a razão de ele ser linear.

**O RE2 e o `regexp` do Go fazem o mesmo**, e pela mesma razão. Portanto a 105.4
mantém-se: a tabela de `casefold` continua de fora, e não é uma falta — é uma
consequência da garantia. O que entrou foi a de MINÚSCULA, que já lá estava.

### 152.8 — o que ainda falta, dito para não parecer feito

Um objecto `Pattern` de `re.compile` que se guarde numa variável. Hoje a cache
faz o trabalho dele — um padrão num laço compila uma vez — mas quem quiser passar
um padrão como valor ainda não tem tipo para isso.

### 152.7 — o `re.match` antigo PROCURAVA, e o novo não

O `regexec` da libc, chamado sem `REG_NOTBOL`, encontra um casamento **em
qualquer sítio**. Portanto o `re.match` da 41.2, apesar do nome, era uma BUSCA —
e havia código a contar com isso: a procura do `pstudio` (`core.psc`) chama-o e
logo a seguir faz `s.find(hit)` para descobrir ONDE casou, que é uma linha que só
faz sentido se o casamento pudesse ser no meio.

O motor novo faz o que o nome diz: **`match` exige o princípio, `search`
procura.** É a mesma correcção que a 139 fez aos nomes dos tipos, aplicada a uma
função — e o único consumidor passou a chamar `re.search`, que é o que ele
sempre quis dizer.

Vale a pena registar porque é a única mudança de comportamento desta fase: tudo o
resto — o dialecto, os grupos, o valor de retorno — é igual ou maior.

---

## 153 — a S7: o TLS, e a promessa perigosa que tem de estar escrita

### 153.1 — um MODO de uma ligação, e não um tipo novo

`net.starttls(c, "example.com")` promove um `Socket` já aberto. Tudo o que está
por cima — `read_into`, `write_from`, os traits `Reader`/`Writer`, o cliente
HTTP — continua a falar com um `Socket` e **não sabe a diferença**.

Um `TlsSocket` à parte obrigaria cada camada acima a ter duas versões de tudo, e
é assim que uma biblioteca de rede duplica. A `STDLIB.md` já dizia que o cliente
HTTPS sairia "quase de graça"; é esta decisão que o torna verdade.

### 153.2 — duas funções, e não uma bandeira

> **Não existe `verify=False`.** Existe `net.starttls_insecure(c, host)`.

É a jogada da 141.4 aplicada à segurança em vez de à memória: a promessa perigosa
tem de estar **visivelmente escrita**. Uma bandeira que se desliga é uma bandeira
que alguém desliga "só para testar" e esquece; um nome com `insecure` dentro
aparece num `grep` e não sobrevive a uma revisão.

**E a verificação é DUAS coisas**, e as duas fazem falta: `SSL_VERIFY_PEER`
confere a CADEIA, e `SSL_set1_host` confere o NOME. Sem a segunda, um certificado
válido para outro domínio passa — que é o buraco clássico, e é por isso que ele
não é opcional aqui.

### 153.3 — o aperto de mão entra pela porta que o socket já tinha

O `SSL_connect` sobre um socket não bloqueante devolve `WANT_READ`/`WANT_WRITE`,
que é literalmente *"ainda não"* — e "ainda não" é o que o `ps_fd_try` já sabia
dizer devolvendo falso. **Não há maquinaria nova**: nem uma thread do pool, nem
uma segunda maneira de esperar. O TLS é mais um estado do mesmo `poll`.

### 153.4 — compilado só com `-D PSRT_TLS`

O OpenSSL é uma dependência de SISTEMA, e um runtime que a arrastasse sempre
obrigaria todo o programa a linkar `-lssl` para nada. É a mesma forma do
`inotify` fora do Linux (99/146.2): sem ela, `net.starttls` **levanta com a frase
que diz o que fazer** — em vez de faltar em silêncio.

### 153.5 — o portão é HERMÉTICO, e é ele que prova as duas metades

Um portão de TLS que fosse à Internet mediria a rede tanto quanto o código, e
falharia numa máquina sem saída. `tests/tls.sh` levanta um `openssl s_server`
ao lado, com um certificado auto-assinado gerado na hora — e um certificado
auto-assinado é exactamente o que separa os dois caminhos:

* `net.starttls` **tem de o recusar** (a cadeia não bate);
* `net.starttls_insecure` **tem de o aceitar** — e é para isso que ele tem esse
  nome.

Um portão que só testasse o caminho feliz não provaria nada: a recusa É a
funcionalidade.

### 153.6 — e o P passou a ler o `<openssl/ssl.h>`

O cabeçalho não compilava, com um erro que não apontava para nada: *"invalid
expression (found ')')"*. A causa era pequena e vale a pena registá-la porque
alarga o que o P consegue ler de qualquer cabeçalho de sistema:

> **um `typedef` com o declarador entre parênteses** — `typedef T (X)(args);`,
> que é C legal e quer dizer o mesmo que `typedef T X(args);` — era SALTADO, e o
> nome nunca era registado. Um `(X *)algo` mais abaixo deixava então de ser um
> cast e passava a ser uma multiplicação.

O OpenSSL escreve-o assim no `core_dispatch.h`, e foi ele que o desenterrou.

---

## 154 — a FE feita: o `stl` vem DENTRO do compilador

A **142** decidiu isto e desenhou-o em três commits com uma mudança de grafia
(`import <stl/vec.ph>` → `import <vec>`) e o `packages/stl` a desaparecer.
Implementá-lo mostrou que **o problema medido resolve-se sem nada disso**, e o
que se segue é porquê a versão que ficou é menor e melhor.

### 154.1 — há um FUNIL, e ele é uma função

O compilador lê ficheiros por quinze sítios — o `pkg_find`, o colector de
entradas do driver, as duas sema, o `embed` —, e **todos passam por
`read_entire_file_opt`**. Portanto o `stl` embebido não precisa de tocar em
nenhum deles: precisa de três linhas ali.

```
emb: const *char = stl_builtin(path)
if emb != None:
    ...devolve uma cópia do texto embebido
```

E uma **raiz virtual** (`__plang_builtin`) que o `pkg_find` procura PRIMEIRO. A
partir daí tudo o resto do compilador — o back end, as dependências, o espelho do
`--out-dir` — continua a ver um caminho e um ficheiro, e não aprende nada sobre
isto.

### 154.2 — a raiz virtual É o caminho real, e é isso que faz o resto desaparecer

A primeira tentativa deu à raiz virtual um nome próprio (`__plang_builtin`), e ele
apareceu imediatamente em quatro sítios que não têm nada que ver com isto: o
espelho do `--out-dir`, o `bootstrap/`, o `reseed.sh` e o motor de build — que
passou a ver uma entrada que *"não existe e ninguém produz"*.

Com a raiz a ser `packages`, **nada disso muda**: os includes do C emitido
continuam a ser `../packages/stl/x.h`, o seed continua onde estava, e o que muda
é só isto —

> quando alguém LÊ `packages/stl/vec.ph`, o texto vem de dentro do compilador em
> vez de vir do disco.

O preço, dito porque é real e porque a 142 já o tinha visto: mexer num ficheiro
do `stl` só tem efeito depois de o compilador ser reconstruído. É um efeito em
dois tempos, é o mesmo que o `ps_prelude.psc` já tem, e o portão do ponto fixo
(`s2 == s3`) mais a regeneração do `bootstrap/` cobrem-no.

### 154.3 — a grafia NÃO muda, e o motivo dela desapareceu

A 142.2 queria `import <vec>` porque, depois de o `packages/stl` desaparecer, o
`<stl/vec.ph>` nomearia *"um directório que não existe e a extensão de um ficheiro
que ninguém vai abrir"*.

**Mas o directório não desaparece**, e é isso que muda o argumento: os ficheiros
continuam em `packages/stl/` como a **fonte única**, e é de lá que o `embed` os
lê em tempo de compilação. A grafia continua a nomear uma coisa que existe.

O que se ganha em não mudar: **zero migração** — os 47 `import <stl/…>` da árvore
ficam como estão —, e o `pforge` continua a ver o `stl` como um pacote do espaço
de trabalho, com o `pack.json` dele.

### 154.4 — e o `cstr.p` deixa de ser a excepção da excepção

A 142 marcou-o como o caso difícil: é o único com implementação, e embebê-lo
quereria dizer compilar um `.p` que não está em lado nenhum.

Com a raiz virtual isso resolve-se sozinho: o driver procura o `.p` irmão do
header pelo caminho virtual, o funil devolve-lhe o texto, e ele vira uma unidade
de compilação como outra qualquer — que sai para o espelho, ao lado das outras.

### 154.5 — o embebido GANHA, e o portão prova-o

`tests/builtin-stl.sh` compila fora da árvore, sem `--pkg-path` e sem
`--out-dir`, nas duas formas (`-o` e `--out-dir`) — e as duas últimas
verificações são as que interessam: **uma raiz com um `stl` que mente é
ignorada**, e um directório `packages/stl` mesmo ao lado também não substitui.

Um ficheiro que pudesse substituir o embebido em silêncio traria de volta a
classe de erro que o `embed` existe para matar: a de duas cópias e ninguém saber
qual correu.

---

## 155 — o `codec` entra para o runtime, e a linha que impede o resto de entrar

> *"o pacote de base64 é tão minúsculo que dá para incluir no runtime direto da
> linguagem. Simplesmente porque o custo de manter o pacote com funções
> minúsculas é maior do que levar elas dentro do compilador."*

Aceite. E o argumento fica mais forte do que foi dito, porque há um precedente
que o decide sozinho:

> **o `json` já está no runtime.**

base64 e hex são a mesma espécie de coisa que ele — uma **codificação de fio com
especificação congelada** — e são MENORES. Ter o `json` dentro e o base64 fora
não é uma distinção que se consiga explicar a ninguém.

### 155.1 — o custo medido, que é o que a pergunta apontava

O pacote são **116 linhas de código** (145 com a prosa). À volta delas: um
`pack.json` com uma versão para subir, uma entrada no espaço de trabalho, uma
dependência no metapacote, um directório de testes e uma linha no lockfile de
quem o usar.

**A moldura é maior do que o quadro**, e o quadro não vai mudar — a RFC 4648 é de
2006 e está fechada.

### 155.2 — A LINHA, para isto não virar "tudo o que é pequeno entra"

O tamanho **não** é o critério, e usá-lo abriria a porta ao `csv` a seguir. O
critério é este:

> **entra no runtime uma codificação com especificação CONGELADA e sem
> POLÍTICA.** Fica pacote tudo o que tem dialecto, formato à escolha, dados que
> envelhecem, ou uma decisão que o programa queira configurar.

Confere contra o que existe hoje, e não sobra nenhum caso a explicar:

| | onde | porquê |
|---|---|---|
| `json` | runtime | uma norma, nenhuma escolha |
| `base64`, `hex` | **runtime** | RFC 4648, fechada em 2006. As quatro variantes são PARÂMETROS (alfabeto, enchimento), não política |
| `csv` | pacote | tem dialectos — separador, aspas, fins de linha —, e cada um é uma escolha de quem lê |
| `datetime` | pacote | um MODELO inteiro mais três formatos |
| `compress` | pacote | três formatos, streaming, níveis |
| `tz` | pacote | dados que envelheceram ontem |
| `crypto` | pacote | algoritmos entre os quais se escolhe, e uma história de confiança |

### 155.3 — e não é um MÓDULO: são métodos

> *"nem precisa ligar o módulo `codec` no compilador, dá para inlinar a função
> direto na string."*

Também aceite, e é a metade que faltava. Um módulo `codec` obrigaria a um
`import` que ninguém se lembra de escrever, e a um espaço de nomes para quatro
funções. Métodos não obrigam a nada:

```
d.hex()                 # bytes -> texto
token.from_base64()     # texto -> bytes?
```

**O sentido está no TIPO**, e é isso que torna a escolha óbvia em vez de
arbitrária: escrever uma codificação sai dos BYTES, ler sai do TEXTO. E
`d.hex()` é literalmente o que se escreveria em Python.

O nome fica ao lado dos que o `str` e o `bytes` já têm — que é onde alguém o vai
procurar — e as duas que LEEM devolvem `bytes?`, com None a querer dizer *"isto
não é aquilo"* (4.2): o texto veio de fora, e não analisar é uma resposta.

### 155.4 — o que se perde, dito porque é real

O que entra no runtime **toda a gente paga e ninguém pode recusar**, e deixa de
ter versão. Por 116 linhas de aritmética sobre seis bits isso é barato; a linha
da 155.2 existe precisamente para que continue a ser.

## Bateria 156 — o `stl/utf8`, e o P ganha UTF-8 (2026-08-25)

*"a gente só precisava de um completo embutido no runtime da linguagem e todos
os outros pacotes usavam o mesmo"*

### 156.1 — eram CINCO, e o P não tinha nenhum

Contar a sério deu pior do que a pergunta sugeria:

| onde | o que era |
|---|---|
| `psrt_val.p` `ps_utf8_put` | o encoder |
| `psrt_val.p` `ps_str_chr` | o mesmo, outra vez |
| `psrt_std.p` `js_utf8` | o mesmo, terceira vez — cópia byte a byte |
| `url.psc` `utf8_bytes` | um quarto, num pacote |
| `url.psc` `pct_encode_cp` | um quinto, fundido com o escape |
| `selfhost/utf8.p` `utf8_encode` | um sexto — **e sem um único chamador** |

E o `packages/stl` não tinha UTF-8 nenhum. Um programa em P que precisasse
escrevia-o à mão, que é exactamente o que os pacotes faziam — e três dos que
escreveram nem UTF-8 produziam, produziam Latin-1.

### 156.2 — o `stl/utf8.ph` tem DUAS funções, e nenhuma aloca

```
def utf8_put(buf: *char, k: usize, cp: u32) -> usize
def utf8_next(buf: const *char, n: usize, i: usize, out cp: u32) -> usize
```

`k` é onde escrever e o retorno é onde vai o seguinte; o `utf8_next` devolve a
LARGURA lida, e **zero** quando o que lá está não é UTF-8 — zero e não `-1`
porque o laço de quem chama é `i += w`, e zero é o único valor que não se soma
por engano.

O `utf8_next` recusa o que tem de recusar, e cada recusa é um defeito real: a
sequência truncada, a continuação que não é uma, a codificação **overlong**
(`0xC0 0x80` é o NUL disfarçado, o furo clássico de filtro), a metade de
substituto, e o que passa de U+10FFFF.

### 156.3 — o que NÃO entrou, e é a razão de o `utf8_decode` ficar onde está

O `utf8_decode` do compilador não é um descodificador: é um transcodificador de
buffer inteiro que aloca dois arrays paralelos de um `*Arena`. Descodificar um
buffer precisa de um sítio para pôr o resultado, e "um sítio" é uma decisão de
quem chama. Um módulo do `stl` que exigisse o `Arena` do compilador não era do
`stl`. O lexer continua a fazer essa escolha — agora **por cima** do `utf8_next`.

### 156.4 — `private` no `.ph`, e é requisito e não recuo

A primeira tentativa pôs os corpos num `packages/stl/utf8.p`. O `pcode` não
ligou: **`multiple definition of 'utf8_put'`**.

A razão é estrutural e vale a pena por escrito. O `pcode` liga o lexer do
compilador E o runtime do pscript no mesmo binário, e ambos lêem UTF-8. Os dois
lados compilam com conjuntos de definições diferentes, portanto o mesmo `.c` sai
em dois objectos — e os dois chegam ao mesmo `ld`. É a colisão que o comentário
do `cstr.p` descreve e que o `implement` resolve **para tipos**; funções livres
não têm `implement`.

A resposta é `private` — que em P é `static`. Os corpos vivem no `.ph` e cada
unidade de tradução leva a sua cópia; nenhum símbolo chega ao linker e a colisão
deixa de ser possível. **Custa doze linhas de código-máquina por binário**, e é o
modelo header-only a fazer aquilo para que existe.

### 156.5 — o embutido da 154 vale para o módulo novo sem uma linha de encanamento

`stl_builtin` ganhou `utf8.ph` e o compilador passou a trazê-lo dentro. Foi a 154
a pagar por isto adiantado: um módulo novo do `stl` é uma constante `embed` e um
`strcmp`.

**Resultado.** Uma implementação em toda a árvore. Consumidores: o lexer do
compilador, o runtime do pscript, e qualquer programa em P — que até agora não
tinha nenhum. O portão está em `tests/stl/main.p` (roundtrip 8/8 nas fronteiras
da codificação, 6/6 recusas), e o WPT do `url` continua em 890/890.

---

## Bateria 157 — a varredura do decidido-e-não-feito (2026-08-26)

Pedido teu: *"implementa http2 e também tudo o que está decidido e ainda não
está implementado"*. A segunda metade obrigou a uma varredura, e a varredura
achou o de sempre: **metade do que estava escrito como por fazer já estava
feito, e uma coisa que ninguém tinha escrito estava errada.**

Por isso o método aqui não foi ler as caixas — foi **executar cada uma**. Uma
caixa por marcar é uma afirmação sobre o passado; um programa que corre é uma
afirmação sobre agora.

### 157.1 — a LINHA por frame, e a fusão que a torna precisa

A 34.2 pedia `função + arquivo:linha`; o que existia era `função + arquivo`. A
metade que faltava era a que interessa — o ficheiro é a parte que o leitor já
sabia.

**A linha vive no frame, escrita directamente.** Um store num campo de uma
struct local: sem chamada, sem desvio, e nada que o coletor tenha de percorrer.
Só é emitida dentro de um bloco que TEM frame, portanto uma função folha sem
nada coletado continua a não pagar nada.

**Todas as instruções, e não só as que CHAMAM.** A nota original falava de "uma
escrita por instrução que contém chamada", e isso estava a pensar só em quem
empilha um frame novo. Mas a linha mais interna é onde o erro é LEVANTADO, e
`xs[5]`, uma divisão por zero e um transbordo levantam sem chamar coisa nenhuma.

**E a fusão, que é o que a torna correcta.** A instrução a correr está no bloco
mais interno, e o frame que ela alcança é o DESSE bloco, não o da função. Um
frame de bloco não tem nome e por isso não aparece no rastro — então o
`ps_trace_capture` leva a linha para fora, até haver um frame com nome onde a
pousar. É por isso que o portão mostra a linha de dentro do `if`, e não a do
`for` que o contém.

### 157.2 — medida antes, porque a própria nota mandava

> *"É trabalho pequeno com custo mensurável, e vale medir antes."*

| | antes | depois | |
|---|---|---|---|
| laço patológico (corpo todo com frame, quase nenhum trabalho) | 0,1671 s | 0,1742 s | **+4,2 %** |
| carga realista (`dict`/`str`/`list`, 200 k palavras) | 0,0980 s | 0,0980 s | **0** |

Fica **ligada por omissão**. No pior caso construído de propósito custa 4 %; no
caso que alguém escreve de verdade não custa nada — porque o custo é por
instrução com frame, e um programa real passa o tempo dentro das chamadas, não
entre elas.

### 157.3 — o frame que desaparece NÃO era defeito, e eu tinha-o chamado assim

Ao medir, `def b(): c()` não aparecia no rastro. Escrevi que era um achado novo.
Não era: é a **optimização de folha** da 49.4 — o frame é o do coletor, e uma
função sem nada coletado não tem nenhum — está documentada no `ps_lower.p`, e
`--trace` liga-a. Com ela a pilha sai inteira, `<main>` incluído.

Fica registado porque o erro tem uma forma que se repete: **medir uma coisa e
concluir sobre outra.** O que eu tinha medido era a ausência de um frame; o que
concluí foi a ausência de uma decisão.

### 157.4 — `int[3]` deixa de se chamar `int[]`

`ps_type_str` imprimia `%s[]` para um `PT_ARRAY`. `int[3]` e `int[4]` são dois
tipos diferentes, e uma mensagem que imprime os dois como `int[]` enuncia o
desencontro e a seguir esconde-o. O tamanho já lá estava — a sema normaliza o
`count` para literal (33.4) — e só não estava a ser escrito.

Antes do fim da sema não há número para imprimir, e aí a forma nua é a honesta.

---

## Bateria 158 — o HTTP/2, dentro do pacote que já existia (2026-08-26)

Pedido teu, e a correcção a meio que mudou o desenho:

> *"http2 não precisa ser um pacote novo, dá pra melhorar o pacote que já temos"*

Está certo, e a razão só aparece ao escrever: **qual das versões foi falada é um
RESULTADO, não uma escolha.** Quem pede um URL quer o corpo; se o par respondeu
com uma linha de estado ou com um frame HEADERS é coisa que o ALPN decidiu uma
camada abaixo. Dois pacotes empurrariam essa decisão para cima, para quem não
tem como a tomar.

E há uma segunda razão, que é o que o `h2.psc` acaba a devolver: o **mesmo
`Response`** que o HTTP/1 produz. Um pacote à parte teria o seu próprio tipo, e
todo o código acima passaria a ter duas versões de tudo — que é exactamente o
argumento da 153.1 sobre o TLS, aplicado outra vez.

### 158.1 — dois módulos, e a fronteira entre eles é o RFC

`packages/http/hpack.psc` (RFC 7541) e `packages/http/h2.psc` (RFC 9113). São
dois documentos e são dois ficheiros; o HPACK não sabe o que é um stream e o h2
não sabe o que é um código de Huffman.

### 158.2 — as tabelas foram EXTRAÍDAS do RFC, e conferidas

Escrever à mão 61 entradas estáticas e 257 símbolos de Huffman é como um
descodificador ganha uma linha errada que só alguns pares tropeçam. Aqui foram
lidas do texto da RFC 7541 e verificadas antes de virarem código:

* 61 entradas estáticas, índices 1..61 sem furos;
* 257 símbolos, comprimentos 5..30, **livre de prefixos**;
* o exemplo do próprio RFC reproduzido (`/` é 0x18 em seis bits);
* e a verificação que valeu mais do que todas: **a reconstrução CANÓNICA dá os
  257 códigos exactamente**, zero divergências. É isso que permite descodificar
  com 31 entradas de contabilidade em vez de uma tabela de 65 536 — e é uma
  propriedade que se confere, não uma que se assume.

### 158.3 — as recusas, e cada uma tem um CVE atrás

Nenhuma destas é pedantismo:

* **CONTINUATION não pode ser interrompida.** O descodificador HPACK é estado da
  LIGAÇÃO, portanto um bloco de cabeçalhos partido por outro tráfego não tem
  significado definido. Quem o permite pode ser alimentado com CONTINUATION para
  sempre num stream que nunca abre — um ataque de memória sem pedido nenhum por
  trás (a família CVE-2024-27316). A verificação está **antes** do despacho de
  propósito: colocada depois, já teria deixado passar um PING;
* **`WINDOW_UPDATE` de zero é erro, e `DATA` de zero bytes é legal.** A
  assimetria é a parte que se esquece;
* **enchimento maior do que o frame** é erro de protocolo e não leitura curta.
  Ao contrário é como se convence um analisador a ler para lá do fim;
* **o EOS não aparece dentro de uma string Huffman**, e o enchimento final tem de
  ser os bits altos do EOS e ter menos de oito bits — oito bits de enchimento são
  um byte que podia não lá estar;
* **índice 0 não nomeia campo nenhum**, e um índice além do fim também não. As
  tabelas já divergiram: continuar é decodificar lixo numa ligação ainda aberta.

### 158.4 — um defeito que a releitura apanhou antes de o corpus o apanhar

O `find` do codificador tratava um `value` vazio como "qualquer valor serve", o
que servia para a busca só-por-nome. Mas **um valor vazio é um valor**: um
`:path` vazio casava com a entrada 4 e ia para o fio como `:path: /` — um pedido
diferente, sem nada nos registos. Passou a haver `find_pair` e `find_name`, com
os nomes a dizer qual é qual.

### 158.5 — o oráculo: 47 142 vectores, catorze codificadores

O corpus do `http2jp/hpack-test-case` entra como quarto corpus externo, ao lado
do JSON, do llhttp e do WPT. Duas coisas fazem dele um teste a sério:

* **a tabela dinâmica é da HISTÓRIA, não do caso.** Cada `story_NN.json` é uma
  ligação: os casos partilham uma tabela por ordem de `seqno`, e um defeito de
  despejo aparece como o caso 40 a decodificar lixo depois de 39 perfeitos.
  Decodificar cada caso com tabela nova passa e não mede nada;
* **catorze implementações codificaram os mesmos cabeçalhos de catorze
  maneiras** — com Huffman e sem, com a tabela redimensionada a meio, só com a
  estática. O nosso descodificador encontra todas as estratégias que alguém
  achou que valia a pena publicar, e não só a que o nosso codificador produz.

### 158.6 — o algoritmo foi validado ANTES de compilar, e isso separou duas buscas

O `verify-all` da fase anterior estava a correr, e a árvore não se toca com um
arreio a ler. Em vez de esperar parado, transcrevi o algoritmo — linha a linha,
o mesmo laço canónico, a mesma tabela dinâmica, as mesmas recusas — para Python
e corri-o contra o corpus: **47 142 de 47 142, zero falhas.**

Isso não é uma curiosidade de método. Separa duas buscas que de outra forma se
confundem: um caso que falhe depois disto é um erro de TRADUÇÃO para pscript, e
não um erro de DESENHO — e essas duas coisas procuram-se em sítios diferentes. É
a mesma jogada do oráculo rápido que a bateria do QBE registou.

### 158.7 — o defeito que o corpus achou não era do HTTP/2, era do COMPILADOR

O portão passou a compilar e morreu com SIGSEGV. Como o algoritmo já estava
validado em Python (158.6), a busca era estreita — e o que ela encontrou não
estava no HPACK.

`PSCRIPT_GC_STRESS=1` tornou-o determinístico, o rastro deu a linha (a 157, no
mesmo dia), e o ASan deu o resto: **`heap-use-after-free` dentro do
`ps_forward`**, a seguir um slot do frame. Uma instrumentação temporária no
coletor nomeou-o: *slot 0 de `hpack__decode`* — o primeiro argumento.

O C gerado diz o resto:

    hpack__Table *__ord275 = NULL;
    PsBytes    *__ord276 = NULL;
    PsList *__it274 = ((__ord275 = __fr->t,
                        __ord276 = unhex(__ctx, __fr->hx)),
                       hpack__decode(__ctx, __ord275, __ord276));

O compilador **liga cada argumento a um temporário com nome** exactamente para
que ele sobreviva a uma colecção dentro do argumento seguinte — o comentário do
`lower_ordered` explica-o em vinte linhas e diz que foi o corpus do WPT que o
ensinou. Mas aqui os temporários **não estão em frame nenhum**: o `__ord276`
aloca, o coletor corre, actualiza o `__fr->t` e deixa o `__ord275` a apontar
para a morada que o objecto teve.

A causa é de uma linha. O `lower_try` embrulha CADA instrução do corpo num
`if <bandeira>:`, e construía esse bloco à mão:

    blk: *Block = self->a->alloc(sizeof(Block))
    blk->stmts = one.data

Sem `frame_wrap`. E é para dentro dele que os temporários da instrução caem.

O mais instrutivo é que o ficheiro já tinha sido mordido por isto: o bloco do
`try` PASSA pelo `frame_wrap`, com um comentário a explicar que sem ele *"um
local coletado de um `try` era um local que o coletor nunca via"*. A correcção
anterior tratou o bloco de fora e deixou os de dentro — e a diferença só aparece
quando a colecção calha na janela entre dois argumentos.

**O alcance é geral e não é do HTTP/2:** qualquer `f(a, g(b))` dentro de um
`try:` em que `a` seja coletado e `g` aloque. Silencioso até uma colecção calhar
ali — que é a definição de um defeito que espera.

Depois da correcção: **47 142/47 142 concordam**, o `GC_STRESS` passa, e o
llhttp (202/202) e o WPT (890/890) não mexeram.

### 158.8 — o `https` do pforge existia e não estava ligado

O `fetch_http` levantava *"https not yet: TLS is missing"*. O TLS chegou na 153;
o que faltava era a ligação, e a frase envelheceu no sítio onde ninguém a lê
até precisar dela.

São quatro linhas, e o motivo de serem quatro é a **153.1**: o `starttls` promove
a MESMA ligação, portanto tudo o que está por cima — `read_into`, `write_from`, o
analisador de respostas — continua a falar com um `Socket` e não sabe a diferença.

**Fica OPCIONAL, e isso é a posição honesta e não uma limitação.** A 2.9 decidiu
o índice ASSINADO, portanto a integridade vem do hash e não da ligação: um
`pforge` construído sem OpenSSL continua a funcionar contra um espelho `http://`.
O que o TLS acrescenta aqui é **privacidade** — qual pacote é que pediste — e a
mensagem passou a dizer exactamente isso em vez de dizer que o TLS não existe.

### 158.9 — `Str` passa a `StrBuf`, e o ficheiro com ele

A 141.7 tinha-o decidido: *"o `str` do pscript é imutável, coletado e conta
codepoints; o `Str` do `stl` é um buffer mutável que cresce. É um *StringBuilder*
com nome de string."*

Medido antes de mexer, e a medida foi melhor do que a nota dizia: **quatro sítios
fora do próprio ficheiro**, não vinte e dois. O `traits.ph` (a assinatura do
`Printable`) e três no `tests/stl/main.p`. O tipo não tinha consumidor nenhum na
árvore — o que torna esta a última hora barata para o renomear, não a primeira.

O ficheiro foi com ele (`str.ph` → `strbuf.ph`), porque um `str.ph` que declara
`StrBuf` é a mesma confusão com uma indirecção a mais. O `stl_builtin` da 154 e o
`build.ninja` seguiram; o `README` do `stl` foi reescrito à mão, e agora diz o que
o nome antigo escondia: quem CONSTRÓI texto por pedaços usa isto, quem só o
carrega usa `const *char`.

---

## Bateria 159 — as duas que estavam decididas e não feitas (2026-08-26)

A varredura da 157 deixou-as no topo da lista da `AUDIT.md`: *"nenhum destes
precisa de bateria, só de trabalho"*. São as duas maiores dessa lista, e cada uma
custou uma descoberta.

### 159.1 — `Sequence<T>` não é um tipo: é uma função genérica escrita sem cerimónia

A 60.3 prometeu que `def total(xs: Sequence<float>)` aceitaria `List<float>` e
`f64[N]` **sem duplicar código nem copiar**. O que faltava não era um tipo — era
perceber que ele não é um.

`Sequence<float>` vira, na sema e antes de mais nada,

    def total<__seq: Sequence<float>>(xs: __seq)

e daí em diante a maquinaria é a que existe desde a 66.3: o parâmetro é inferido
do argumento, o limite é conferido onde o tipo concreto está, e o corpo é
monomorfizado. **Zero vtable e zero cópia** — e nenhum backend, nenhum coletor e
nenhuma parte do lowering ouviu falar de `Sequence`.

**O limite é NATIVO e não nominal**, e é a diferença para uma trait que alguém
escreve: ninguém declara `implement Sequence for List<T>`, porque `List` não é um
tipo onde se abra um bloco `implement`. O que se confere é que o contentor é um
que a linguagem sabe percorrer — `List<T>`, `T[N]`, `View<T>`, `bytes` — e que o
elemento é o pedido.

**Duas restrições, assumidas e escritas na mensagem de erro:**

* vários parâmetros `Sequence` **partilham um** parâmetro de tipo, portanto
  `def dot(a: Sequence<float>, b: Sequence<float>)` exige que os dois sejam o
  mesmo contentor. A alternativa era um parâmetro de tipo por argumento, e o
  `ps_instantiate` compila um;
* `Sequence` só se escreve no tipo de um **parâmetro**. Num retorno ou numa
  variável é erro, porque **nenhum valor tem este tipo**: ele diz o que uma
  função aceita, não o que existe.

### 159.2 — `const def`, e a promessa que obriga o avaliador a ser total

A 65.10 pedia *"função avaliada em compilação, zero runtime"*. A promessa é que
ela **não existe em tempo de execução**, e é isso que decide o desenho todo: o
avaliador ou devolve um literal, ou dá um erro com uma posição. **Nunca cai para
uma chamada.** Uma que caísse tornaria a promessa num acaso — a função existiria
ou não conforme os argumentos, e ninguém saberia qual dos dois sem ler o C.

Medido no fim: das seis `const def` do portão, **zero** aparecem no C gerado, e
no lugar das chamadas estão `42`, `3628800`, `6765`, `4096` e `16`.

O `const` já estava na linguagem e já queria dizer *conhecido em compilação*;
pô-lo à frente do `def` diz a mesma coisa da função e não custa palavra nova.

**A divisão é a do Python e não a do C**, e isto tem de estar escrito porque é a
diferença entre uma constante certa e uma errada: em C o `-7 / 2` trunca para -3
e o resto fica negativo; aqui o piso é -4 e o resto tem o sinal do divisor,
exactamente como em tempo de execução. **Uma constante que mudasse de valor por
ser dobrada era pior do que não haver dobra nenhuma.**

**Números e booleanos, e o texto não** — e é recusa, não esquecimento. O `text`
de um literal é a GRAFIA da fonte (aspas e escapes), e devolver um literal novo
exigiria reconstruí-la ao contrário, que é onde um escape mal posto vira um valor
diferente sem ninguém dar por isso. A 65.10 nasceu para o `T[N]` e para a
f-string, que são números; o texto entra quando alguém o precisar, com o
codificador escrito e conferido.

### 159.3 — três defeitos meus, e o segundo é o que vale a pena guardar

1. **os argumentos eram avaliados no ambiente errado** — no do corpo em vez de no
   de quem chama, o que punha `fib(n - 1)` a procurar o `n` do próprio `fib` que
   ainda não tinha nenhum. Uma recursão a olhar para dentro de si em vez de para
   fora;

2. **o corpo de um `const def` não pode ser verificado como função normal.** Ao
   verificar o tipo de `fib(n - 1)` dentro do `fib`, a dobra disparava — com o
   `n` sem valor. Quem confere um `const def` é a chamada que o usa; o corpo não
   é código que corre, é uma receita que o avaliador percorre. É a mesma forma da
   regra que já existia para um genérico (*"o que é verificado é cada
   instância"*), e não foi por acaso: as duas dizem que um TEMPLATE não se
   verifica sozinho;

3. **o `T[N]` não dobrava a chamada** — que é literalmente o caso que a 65.10
   nomeou ao ser decidida, e que estava a faltar no sítio onde o tamanho de um
   array é resolvido.

E uma armadilha que não é minha e volta sempre: **o teste foi escrito antes do
reseed**, e o seed comitado não conhecia `Sequence`. A ordem é a de sempre —
mudar o compilador, `./reseed.sh`, e só então acrescentar os testes.

---

## Bateria 160 — o `Pattern`, e o aviso que estava escrito no sítio (2026-08-26)

A 152.8 tinha-a deixado dita em três linhas: *"Hoje a cache faz o trabalho dele —
um padrão num laço compila uma vez — mas quem quiser passar um padrão como valor
ainda não tem tipo para isso."*

### 160.1 — o que muda é o VALOR, e não a compilação

A cache das 24 entradas continua onde estava e continua a servir quem escreve o
padrão no sítio. O que isto acrescenta é **um valor**: um padrão que mora num
campo de `struct`, se passa a uma função, se devolve, entra numa lista. E com ele
a garantia que a cache não dá — a compilação está **ali dentro**, e não depende de
o padrão não ter sido despejado por outros vinte e quatro pelo meio.

**Os nomes são os do módulo, de propósito**, e os tipos de retorno também até ao
fim: quem sabe `re.search(p, t)` sabe `p.search(t)`, e a única coisa que muda é de
onde vem o padrão. Nenhuma das seis funções do runtime foi duplicada — elas
passaram a aceitar **ou** o padrão escrito **ou** um programa já compilado, com um
ajudante de cinco linhas a decidir qual.

**E um padrão que não compila levanta em `re.compile`** — onde foi escrito, e não
três funções à frente na primeira vez que alguém o usar.

### 160.2 — o aviso estava escrito, e eu passei por ele duas vezes

O portão sob `PSCRIPT_GC_STRESS` rebentou duas vezes, e as duas causas eram a
mesma coisa dita de dois sítios:

1. **o coletor não percorria o `src`.** Um `PsPattern` guarda a grafia como
   `*PsStr`, que é uma referência coletada — sem a linha que a reencaminha, um
   `p.pattern()` depois de uma colecção lê um cabeçalho já deitado fora;

2. **e o `is_collected` do lowering não conhecia o `PsPattern`.** Este é o que
   vale a pena guardar, porque o comentário dessa função **já dizia exactamente o
   que ia acontecer**:

   > *"Todo objeto que o runtime aloca com `ps_alloc` mora no heap COLETADO e tem
   > de estar nesta lista: um que falte não é rastreado, o coletor o move, e quem
   > o segurava fica com o endereço antigo. O defeito é silencioso até o dia em
   > que uma coleta acontece no meio — e foi assim que `PsConn`, `PsTimer` e
   > `PsProc` apareceram."*

   `PsPattern` foi o quarto. A lista é uma lista escrita à mão, e uma lista
   escrita à mão esquece — o comentário sabe-o, nomeia os três anteriores, e
   mesmo assim o quarto passou. **O que a salvou foi o `GC_STRESS` ser um portão
   e não uma sugestão**: sem ele isto ia para o repositório e aparecia meses
   depois, num programa de outra pessoa, sob pressão de memória.

O `gdb` deu-o em três linhas depois de o ASan não ver nada — porque não era um
erro de heap que o ASan reconhece, era um ponteiro para um objecto que o coletor
tinha movido debaixo dele.

### 160.3 — e o hóspede que ainda não tem nome

Três vezes nesta sessão o `psrt_os.p` apareceu com **as mesmas 92 linhas
duplicadas**, byte a byte iguais, durante uma corrida de arreio. Ficou medido:

* **não é nenhum dos dezanove sub-arreios** — corri-os um a um, com o `md5` do
  ficheiro antes e depois de cada um;
* **não é o `make build`** — testado à parte;
* **não é um restauro**: o conteúdo não existe como objecto no repositório nem no
  histórico de ficheiros do editor;
* **nenhum dos commits foi contaminado** — todos com uma cópia de cada definição;
* e o efeito é o runtime **não compilar**, portanto produz falhas FALSAS e nunca
  aprovações falsas.

Fica registado com a recuperação, que é uma linha:

    git checkout -- pscript/runtime/psrt_os.p pscript/runtime/psrt_os.ph

**Um `verify-all` que falhe em muitos sítios ao mesmo tempo merece um `git status`
antes de qualquer diagnóstico.** Foi o que custou a primeira hora desta sessão.

---

## Bateria 161 — o blob partilhado, e o `const` que era uma placa (2026-08-26)

Pergunta tua: *"como um código P e um código PScript podem gerir um mesmo blob de
bytes? digo um manipular dos dois lados"* — e depois, quando expliquei o que
faltava: *"é seguro?"*

### 161.1 — a medição que reformulou a pergunta

Antes de propor o que quer que fosse, escrevi isto em P contra um `bytes`, que é
**imutável por contrato**:

    def escreve(in b: CBytes, v: i64) -> i64:
        p: *u8 = (*u8)(b.ptr)      # tirar o const, à moda do C
        for i in range(b.len):
            p[i] = u8(v)

    escreveu em 3 bytes de um `bytes` IMUTAVEL
    e agora vale: 9 9 9

**Já se escrevia.** O `const` no `CBytes.ptr` documenta a intenção; não a impõe
contra ninguém. E não é um furo que alguém deixou aberto — é o que *"o P fala com
o C sem runtime"* quer dizer, levado até ao fim: uma linguagem com ponteiros
crus, conversões e `memcpy` não consegue prometer a ninguém que uns bytes não
mudam.

O que me incomodou não foi o furo. Foi a **prosa**: o `mapbridge.psc` e o
`cstr.ph` deixavam o leitor inferir uma garantia que ali não estava. Quem lê "só
de leitura" ouve *impossível escrever*, e o que era verdade é *não é suposto
escrever*. Os dois ficheiros passaram a dizê-lo.

Portanto a escolha nunca foi *seguro contra inseguro*. Era:

* **antes** — a coisa perigosa é possível e **invisível**, uma conversão no meio
  de um ficheiro em P;
* **agora** — a coisa perigosa é possível e **está escrita na assinatura**.

É a jogada da 141.4 e da 153.2 outra vez (*"a promessa perigosa tem de estar
visivelmente escrita"*), com uma coisa por cima que a conversão nunca deu.

### 161.2 — `CBuf`, e o que ele RECUSA é o que o torna melhor

O terceiro membro da família do `cstr.ph`. A diferença é uma palavra — o `ptr`
não tem `const` — e o que ela compra é a assinatura dizer qual dos lados é
escrito antes de alguém ler o corpo.

**O que o torna sólido é de onde ele pode vir.** A costura só o constrói sobre um
`Buffer` ou uma `View<u8>` dele, e **recusa** os outros dois com a razão escrita:

| | |
|---|---|
| `bytes` | *"a `bytes` is immutable by contract, and a `CBuf` is the pair that writes"* |
| `List<u8>` | *"lives in the collected heap and the collector MOVES it; write through it and you write where it no longer is"* |

Antes da 161 escrevia-se nos dois com aquela conversão de duas linhas, sem
ninguém se queixar. **Recusar estes dois é a parte que a conversão nunca poderia
fazer.**

E não VOLTA: um `CBuf` como tipo de retorno faz a função não atravessar. Devolvê-lo
seria dar ao pscript um ponteiro cru cujo tempo de vida é do outro lado.

**O índice cru continua cru**, como no `CStr.at` e no `CBytes.at` — isto é P, e o
P não confere limites. O que está lá em vez disso são as três que NÃO conseguem
sair fora: o `slice` limita, o `fill` anda o seu próprio comprimento, e o
`copy_from` pára no mais curto dos dois e diz quantos coube. Ler para lá do fim
dá lixo; escrever para lá do fim estraga o alocador, e por isso as operações que
não pedem um índice à mão são as primeiras a que se pega.

### 161.3 — o `Buffer` atravessa, e devia ter atravessado sempre

O `cbytes_ok` aceitava `bytes` e `List<u8>`, e mais nada. Mas o teste real desta
travessia é **"o ponteiro fica quieto?"**, e o `Buffer` é quem melhor o passa:
`calloc` no header E no bloco, fora do monte coletado, feito assim em 19.4/52.3
**precisamente para outra thread o segurar**. É mais estável do que o `List<u8>`
que já atravessava — cujo armazenamento o coletor possui e move.

Ficara de fora porque aquela lista foi escrita quando o `bytes` era a novidade, e
ninguém voltou lá. Omissão, e não decisão.

### 161.4 — e o defeito que apareceu ao usar o que eu tinha acabado de escrever

O meu `copy_from` não compilava: `CBuf_copy_from(d, *s)`, um ponteiro e um valor.
E não era meu — o `CBytes_eq(&a, b)` que já lá estava tem exactamente a mesma
forma.

**Numa chamada de MÉTODO, um `in` em falta no sítio da chamada não era
diagnosticado.** O receptor é implícito e leva o `&` sozinho; um argumento não é,
e a verificação que uma chamada de função comum já fazia — *"parameter '%s' of
'%s' is declared 'in', so the call site says it too (65.12)"* — não existia no
caminho dos métodos. O compilador emitia C partido em silêncio, e quem tentasse
recebia um erro do compilador de C sobre um argumento que nunca escreveu.

Medido: **nada na árvore chama `.eq`, `.starts_with` ou `.find` de um `CStr` ou
`CBytes`.** Foram escritos, e nunca foram chamáveis. A queixa agora existe, e
`a.eq(in b)` compila.

Portões: `tests/pscript/run/blobbridge.psc` (a travessia nos dois sentidos, mais
uma vista), duas recusas em `tests/pscript/bad/cbuf_*`, e o tipo em si no
`tests/stl/main.p` — onde o `slice(6, 99)` limita a 2 e o `copy_from` de três
bytes para dois devolve 2.
