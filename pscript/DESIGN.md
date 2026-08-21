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

**3.1 Contêineres genéricos.** `list` escrito sem parâmetro **é** `list<any>`.
Para elemento desboxeado, anota-se: `list<int>`.
*(Esclarecido na 4.1: `x = [1, 2, 3]` sem anotação recebe `list<any>`.)*

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
recebe **`list<any>`** — encaixota por padrão. `list<int>` é o opt-in de
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
coletados; o mesmo buffer é visto como `list<i32>` ou `list<f64>` sem cópia, com
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
`list<int>` (4.1) já é genérico.

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

O que muda: o dict é tipado, então a chave tem tipo estático — `dict<int, V>`,
`dict<str, V>`, `dict<Ponto, V>`. A pergunta deixa de ser "quais tipos a linguagem
permite" e passa a ser **"o que torna um tipo hasheável"**, e no caso de
`dict<any, V>` o despacho é pela etiqueta em runtime.

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

E `dict<any, V>` nunca falha na inserção, porque não há chave inválida.

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

Minha provocação: `list<any>` por padrão faz o laço mais comum da linguagem
(`for x in [1,2,3]: soma += x`) pagar caixa no heap por elemento **mais** checagem de
etiqueta por acesso (11.3) — velocidade de Python com passos extras, apagando a
vantagem que os tipos estáticos compraram.

**Aceita.** Se todos os itens do literal forem do mesmo tipo — **primitivo ou
`record`** — o array infere o tipo do elemento corretamente. Só heterogêneo vira
`list<any>`.

> Revisa a 4.1, que dizia `list<any>` sempre. Pequeno ponto a esclarecer: e literal de
> `struct` homogêneo (`[ed1, ed2]`)? Ali não há caixa a economizar, porque `struct` já
> é referência — mas há tipo a checar, então inferir `list<Editor>` ainda paga.

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
3. `list<def(int) -> int>` é escrevível?

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
> `list<any>`, que é o contêiner padrão (4.1) — ou encaixotar função custaria uma
> **alocação a mais**, um objeto no heap só para guardar `{fp, env}` que já eram valor.
> Separados, cada um fica no seu tamanho e nenhum compromete o outro.
>
> **Dois efeitos colaterais bons:** a tabela de despacho passa a ser visível no tipo
> (`dict<str, any>` é dado por chave; `dict<str, def>` é callback por nome), o que dá
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
> homogêneo inferindo `list<int>`, uma lista de mil inteiros não tem objeto nenhum —
> são mil `int64_t` num array. A conta de "mil caixas × 24 bytes" só valia quando o
> padrão era `list<any>`.

**32.4 `set` de `struct` é impossível, e isso é aceito.** Quem quer conjunto de objetos
usa `dict<int, Struct>` indexado por um id próprio. Mantém o contrato hash/igualdade
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

**33.4 `list<T>` é o padrão; `T[N]` é opt-in.** Suas palavras: *"em pscript por padrão
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
> tamanho é conhecido e não cresce (zero alocação, fora do coletor), `list<T>` quando
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
`any` que guarda int não aloca **nada** — mata a pressão de GC de `dict<str, any>` com
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
> `T??`** — com `next() -> T?`, iterar `list<int?>` não distinguia fim de elemento-None
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
- `shared d: dict<str, Config>` — a tabela ETS de verdade, para estado nomeado
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

**44.2 `*args` existe, como açúcar sobre `list<T>`.** O call site constrói a lista; a
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
usa `list<X>` recebe sua cópia estática — o mecanismo `inline Vec<int>` que o P já tem
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
- **`list<Vec>` é array plano contíguo** de valores de 24 bytes — sem ponteiro por
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

**52.3 Framebuffer: `shared buffer` com vista `list<f64>`.** Cada worker escreve seu
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
- Casts genéricos na saída de `any`: `list<any>(x)`, `dict<str, any>(x)`, `str(x)`, e
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
- `x as list<any>`, `m as Estat`, `v as int` — **desencaixota checando** (lança
  categoria TYPE se a etiqueta não bate). Mesma forma do `as def(...)` da 29.4 —
  agora uniforme.
- `int("42")`, `float(n)` — **converte valor** (parse, alargamento). `T(campos...)`
  continua sendo o construtor (54.2).

O rascunho precisa de ajuste: `list<any>(bruto)` → `bruto as list<any>`, etc.

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

> Suposição registrada à espera de bênção (não decidida): `pack` devolve `list<u8>` e
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

> Consequência prática: `def total(xs: Sequence<float>)` aceita `list<float>` e
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
  `list<T>` e `T[N]` sem cópia, 60.3);
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

**62.4 `pack` devolve `list<u8>`, abençoado.** Sem tipo `bytes` novo.

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

**65.2 f-string no P, resolvida inteiramente em compilação.** No pscript ela constrói
um `str`; no P ela teria de baixar para o que o C tem — uma string de formato mais os
argumentos. Forma possível: `printf(f"{n} itens")` vira `printf("%d itens", n)`.
- (a) Sim, só em posição de argumento de função variádica (printf/snprintf).
- (b) Sim, e também produzindo `const *char` num buffer que o chamador dá.
- (c) Não: formatação é assunto de runtime, o P usa printf à mão.

> Consequência de (a): resolve o caso que dói (mensagem de erro, log) sem inventar
> alocação nenhuma. Consequência de (b): precisa de um buffer, e aí a assinatura fica
> estranha para uma expressão. Consequência de (c): a divergência de superfície entre
> as duas linguagens fica maior justo no lugar mais visível do dia a dia.

**65.3 `T?` não-nulo por padrão, com `??` e `?.`, no P.** Zero runtime — é um teste de
nulo e um sistema de tipos. Seria o maior ganho de segurança que o P pode ter sem
runtime, e o maior acréscimo de superfície.
- (a) Sim, igual ao do pscript (9.4, 43.1-43.3), com narrowing por fluxo.
- (b) Só `??` e `?.` como açúcar, sem tipo anulável (sem garantia, só ergonomia).
- (c) Não: o P interopera com C, onde todo ponteiro é anulável, e a garantia seria
      falsa na fronteira.

**65.4 Lambda sem captura no P.** A 20.3 já diz que o compilador escolhe entre ponteiro
puro e `{fp, env}`; a forma SEM captura é literalmente um ponteiro de função, que o P já
tem. `sorted(xs, key=lambda v: v.x)` sem alocar nada.
- (a) Sim, e capturar vira erro de compilação com mensagem que diz por quê.
- (b) Não: o P tem `def` aninhado nenhum, e uma função nomeada resolve.

**65.5 Interfaces estruturais estáticas no P.** No pscript elas têm vtable (runtime); a
versão estática — "este tipo tem estes métodos, checado em compilação" — é o que os
genéricos do P já fazem por monomorfização, sem nome.
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
> `list<int?>` não distingue fim de elemento-None).

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
qualificado (`g.Kind`) e `static` privando o nome do módulo (44.4). A
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
`d.items()` passa a ser um valor de verdade (`list<(K, V)>`), `for k, v in
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
  * **dentro de contêiner** (`list<(str, int)>`, que é o que `d.items()` como
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

- **`any`/`all` tomam `list<bool>`**, não uma lista de números: não há
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
