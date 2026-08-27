# O que um porte real cobrou do pscript

Levantamento aberto em 2026-08-27, portando o **cliente do Desbravacraft** (um
clone de Minecraft: ~16 mil linhas de JavaScript em `client/`, ~9 mil no núcleo
isomórfico `shared/`, WebGL por TWGL) para pscript nativo com SDL2 e OpenGL.

Cada item traz o programa mínimo que o reproduz, medido nesta máquina (Debian 13,
gcc 14.2.0, `plangc 0.1.0`). O critério para entrar: **o porte esbarrou**. Gosto
pessoal não entra.

Estado: **CONSERTADO** (neste commit) · **ABERTO** · **DECISÃO** (é escolha de
desenho, não defeito — está aqui porque quem chega esbarra).

---

## 0 — CONSERTADO · o estouro de `*` NÃO levantava em build otimizado

O achado mais grave, e não veio de uma lacuna: veio de uma garantia.

A 7.2 promete que estouro de inteiro **lança**, e é um dos quatro eixos de
segurança da linguagem. Para `+` e `-` a promessa vale. Para `*` e `**`, não
valia em nenhum build otimizado:

```python
def mul(a: int, b: int) -> int:
    return a * b

print(mul(9223372036854775807, 2))
```

| flags | resultado |
|---|---|
| `-O0` | levanta (correto) |
| `-O1` | **-2, em silêncio** |
| `-O2` | **-2, em silêncio** |
| `-O2 -flto` | **-2, em silêncio** |
| `-O2 -fwrapv` | levanta |

`MAX * MAX` dava `1`. `2 ** 100` dava `0`.

**A causa.** O C gerado chamava `ps_mul` corretamente — a baixada estava certa. O
defeito estava dentro do runtime:

```python
def ps_mul(ctx, a, b, file, line) -> i64:
    if a != 0:
        r: i64 = a * b                      # <- estouro de signed: UB em C
        if b != 0 and (r / a != b or ...):  # <- o compilador apaga isto
```

A matemática do teste está **correta** — conferi a forma antiga contra aritmética
exata e ela acerta todos os casos, inclusive o `a == -1 and b == MIN` que ela
tratava à parte. O que a derruba não é a conta: é que `a * b` de signed que
estoura é comportamento indefinido, então o gcc tem o direito de assumir que não
estoura, provar que `r / a == b` sempre vale, e remover o `if`. A `-O1` ele já
exerce esse direito.

`ps_add` e `ps_sub` sempre perguntaram ANTES de somar, e por isso estavam certos.
Só a multiplicação calculava primeiro.

**E havia um segundo defeito, pior, na mesma linha.** `-1 * MIN` não dava resultado
errado: **derrubava o processo.**

```
pscript: SIGFPE (arithmetic fault)
exit=136
```

Em *qualquer* nível de otimização, `-O0` incluído. O autor sabia do caso — a
guarda para ele está escrita ali. Está do lado errado do `or`:

```python
if b != 0 and (r / a != b or (a == -1 and b == (-9223372036854775807 - 1))):
                ^^^^^^^^^ avaliado PRIMEIRO
```

`MIN / -1` é armadilha de hardware no x86 (o quociente não cabe), então a divisão
mata o processo antes de a guarda ser consultada. Uma guarda correta, escrita na
ordem errada, protege exactamente nada.

Isto é uma queda de processo alcançável por `a * b` em pscript puro, sem `unsafe`
— numa linguagem cujos quatro eixos garantidos dizem que isso não pode acontecer.
O conserto trata os dois de uma vez, porque nunca chega a multiplicar nem a
dividir por `a`: divide sempre por um operando cuja divisão não pode armadilhar.

**O conserto** pergunta sobre os operandos, com divisão — que nunca estoura —,
nos quatro quadrantes de sinal:

```python
    if a == 0 or b == 0:
        return 0
    if a > 0:
        over = a > MAX / b if b > 0 else b < MIN / a
    else:
        over = a < MIN / b if b > 0 else a < MAX / b
```

Validado por força bruta contra aritmética exata: todas as bordas
(`MIN`, `MIN+1`, `±1`, `MAX`, `±2³¹`, `±3037000499`, `±3037000500`), uma varredura
densa de −200 a 200, e 800 mil pares aleatórios — zero divergência. O caso especial
da forma antiga desaparece sem exceção: `MAX / MIN` é 0 e `-1 < 0`.

`ps_pow` delega a `ps_mul`, então foi consertado junto.

**O que isto deixa por fazer, e é maior que o conserto.** Um teste que rodasse
`MAX * 2` teria pegado isto no primeiro dia — se rodasse **com otimização**. A
suíte prova a linguagem, e este defeito só existe no binário que o usuário
compila. O portão existe agora: **`tests/overflow-opt.sh`**. Ele compila os mesmos casos em
seis níveis (`-O0 -O1 -O2 -O3 -Os` e `-O2 -flto`) e compara a saída inteira, e foi
conferido contra a árvore defeituosa — falha nela, passa aqui. Os operandos
atravessam um valor de função para que nada possa ser dobrado em compilação: o que
se mede é a checagem do runtime, não a do front end.

Falta ligá-lo ao `make verify`, que é uma linha no descritor.

E fica a razão pela qual ele precisava existir: **o corpus do pscript compila a
`-O0`** (só o `perf_test` do pstudio pede `-O2`), enquanto o `pforge` constrói
tudo de verdade com `-O2`. O `run.sh` já diz isto sobre velocidade — *"measuring
speed on an unoptimised build measures the wrong binary"* — e a mesma frase vale
para SEMÂNTICA, que é o que este defeito custou. O modo em que ninguém testa é o
modo em que todos rodam. Enquanto ele não existir, a mesma
classe pode estar viva noutro lugar: **todo sítio do runtime que calcula primeiro
e confere depois é suspeito.**

## 1 — CONSERTADO · `const R(0.0, -1.0)` não compilava

```python
record V:
    x: float
    y: float

const D = V(0.0, -1.0)
```

```
error: use of undeclared identifier '__ord0'
```

A varredura que o isolou:

| forma | antes |
|---|---|
| `const D = V(0.0, -1.0)` | **erro** |
| `const D = V(-1.0, 0.0)` | **erro** |
| `const D = V(0.0, 0.0 - 1.0)` | ok (menos binário) |
| `const D = V(x=0.0, y=-1.0)` | ok (nomeado, outro caminho) |
| `const N = -1` | ok (sem record) |
| `record V: a: int` + `const D = V(-1)` | ok |
| `D = V(0.0, -1.0)` sem `const` | ok |

**A causa.** `is_trivial` não conhecia `PE_UNARY`, então `-1.0` contava como
expressão com efeito; `lower_ordered` amarrava um `__ord0` para garantir ordem de
avaliação; e o inicializador de um `const` de módulo vira **dado estático em C**,
que não tem bloco onde declarar o temporário. O `pre` era descartado e o nome
saía sem declaração.

É a terceira aparição desta mesma classe. As outras duas estão comentadas no
próprio código: o `-Wint-conversion` do `unary()` ("o compilador morria com
'use of undeclared identifier `__ctx`'") e a do `for` assíncrono em
`ps_lower.p:9872` ("o C saía com `__ord2` sem declaração nenhuma"). O padrão é
sempre o mesmo: **um lowering que empurra declaração para `pre` sendo usado num
sítio que não tem onde despejar `pre`.**

**O conserto** (`selfhost/ps_lower.p`, `is_trivial`): um `PE_UNARY` sobre operando
trivial é trivial — não chama, não aloca, não pode coletar. A exceção é o menos
INTEIRO, que baixa para `ps_neg` porque negar o inteiro mais negativo estoura e
estouro levanta (7.2); o literal de largura padrão não, que é o que `unary()` já
dobra no sinal.

Semântica preservada, conferido:

```python
n = -9223372036854775807 - 1
try:
    print(-n)
catch e:
    print(f"levantou: {e.message}")     # levantou: integer overflow in unary -
```

Ponto fixo de três estágios refeito e verde.

## 2 — CONSERTADO · faltavam `view_u16` e `view_i16` no `Buffer`

```python
b = Buffer(1024)
v = b.view_u16()
```

```
error: a Buffer has ... the typed views (view_f64, view_f32, view_i64, view_i32,
view_u8) — not 'view_u16'
```

Dezesseis bits não é largura exótica: é o formato de voxel deste jogo
(`id` de 12 bits + um nibble de estado, 65 536 por chunk) e é qualquer amostra
de áudio. Sem a vista, um formato de 16 bits tem de ser lido como dois `u8` e
remontado à mão em **toda** travessia — que é precisamente o que uma vista
tipada existe para evitar.

**O conserto** é de tabela, e por isso caberia em três pontos: `ps_view_esize`
(nome → 2), `ps_view_elem` (largura 16, com e sem sinal) e a mensagem que lista
o que existe. O lowering já era genérico (passa o tamanho do elemento ao
runtime) e o runtime também (`ps_buffer_view_at` só guarda `l->esize`), então
nada mais precisou mudar. É o desenho por tabela pagando.

## 3 — ABERTO · um método estático não é alcançável pela sua própria grafia

O modelo está **completo**: `is_smethod` existe no AST, o parser o marca, o
`nrecv` da checagem já desconta o receptor, e chamar pela instância **funciona**
em tempo de execução (o `self` é ignorado, como manda um estático):

```python
record M:
    a: float

    static def identity() -> M:
        return M(1.0)

z = M(7.0)
print(z.identity().a)     # 1.0 — funciona, mas é absurdo escrever assim
print(M.identity().a)     # error: unknown name 'M'
```

Falta só resolver o nome do TIPO no sítio da chamada. O que sobra é ter uma
instância para chamar um construtor — que é o contrário de um construtor — ou
desistir e escrever função livre com prefixo. **Foi o que o porte fez:**
`mat4_identity()`, `mat4_mul()`, `mat4_perspective()`, `vec3_lerp()` onde o
JavaScript escrevia `Mat4.IDENTITY()`, `Mat4.mul()`, `Mat4.perspective()`,
`Vec3.lerp()`. Um módulo de álgebra inteiro com prefixo à mão, e o prefixo é a
lacuna.

O precedente para o conserto já está no código: um enum resolve `Cor.VERMELHO`
pelo `enumof` na resolução de nomes. E o idioma para o sítio também: `check_call`
já abre com `try_mod_qual(e->lhs)` — um `try_*` que pergunta "isto é chamada
qualificada por módulo?". O irmão natural é um `type_smethod()` ali ao lado,
**antes** de `rt = self->check_expr(e->lhs->lhs)` (`ps_sema.p:1801`), com um
valor de mesmo nome tendo precedência sobre o tipo.

## 4 — ABERTO · aridade NEGATIVA numa mensagem

```python
record M:
    a: float

    def identity() -> M:        # sem `self` e sem `static`
        return M(1.0)

z = M(0.0)
print(z.identity())
```

```
error: 'M.identity' takes -1 argument(s), 0 given
```

`-1` porque a checagem da chamada faz `nparams - 1` e `nparams` é zero. O
compilador tem a mensagem certa para este caso e ela é boa — *"'M.identity' has
no receiver: write `in self` first, or `static def` for a function that needs
none"* —, mas ela mora na checagem da DECLARAÇÃO, e a da CHAMADA corre primeiro.
Nenhum número negativo devia poder sair numa contagem de argumentos.

## 5 — DECISÃO · `def` sem `self` dentro de um record exige a palavra `static`

Consequência do item 4, e é escolha e não defeito: `f->is_smethod = no_recv and
owner != None`, onde `no_recv` vem da palavra `static`. Um `def` sem `self` não é
inferido como estático — a mensagem manda escrever `static def`.

Fica registrado porque o comentário do `ps_ast.ph` descreve a *outra* semântica
("a def inside a struct with no receiver"), e porque a inferência é possível: a
ausência de um primeiro parâmetro chamado `self` é decidível no parser, logo
depois de `f->nparams = ps.len`. Se a inferência entrar, o item 4 morre com ela e
`static` fica redundante.

## 6 — ABERTO · campo de array fixo não aceita literal de lista, e o erro é em C

Array fixo solto funciona; como campo de record, não — de nenhuma das formas:

```python
m: f32[4] = [1.0, 2.0, 3.0, 4.0]      # ok

record M4:
    m: f32[4]

z = M4([1.0, 2.0, 3.0, 4.0])          # error: incompatible pointer to integer conversion
z = M4(m=[1.0, 2.0, 3.0, 4.0])        # error: incompatible pointer to integer conversion
z = M4()
z.m = [1.0, 2.0, 3.0, 4.0]            # error: invalid initializer (an array cannot be
                                      #        initialized from a scalar expression)
```

Não depende do tipo do elemento (`int[4]` dá o mesmo). Contorno: `M4()` e depois
elemento a elemento — é como `src/core/math.psc` monta as matrizes.

São **duas** coisas, e a segunda é a mais grave: o diagnóstico é do back end de C
vazando com a posição do pscript. Ele fala de *ponteiro*, e o pscript não tem
ponteiros — não há nada que quem escreve possa fazer com essa frase. Uma
linguagem com coletor não devia poder imprimir a palavra "pointer".

## 7 — ABERTO · a posição do erro sai no arquivo de quem IMPORTA

Duas vezes, com números além do fim do arquivo apontado:

```
src/main.psc:261:27: error: use of undeclared identifier '__ord0'
```

`src/main.psc` tem **4 linhas**. A linha 261, coluna 27, é o `-1.0` do
`VEC3_DOWN` em `core/algebra.psc`, o módulo importado. O mesmo em
`rep/p1.psc:6:20` num arquivo de 2 linhas.

Isso custou tempo real: procurei o defeito no programa de quatro linhas antes de
desconfiar do arquivo apontado. O erro é do módulo; a posição devia ser dele.

## 8 — ABERTO · `import math` dentro de um módulo chamado `math.psc` importa a si mesmo

O módulo `core/math.psc` do porte fazia `import math` para ter `sqrt`. Resultado:

```
core/math.psc:116:15: error: module 'math' declares no 'sqrt'
```

O nome resolve para o próprio arquivo. Renomear para `algebra.psc` resolveu. A
mensagem não é falsa, mas manda para o lado errado: quem lê procura o `sqrt` na
stdlib. Um módulo que se importa a si mesmo é sempre engano, e é detectável.

## 9 — ABERTO · `def main()` é aceito e nunca chamado, em silêncio

```python
def main():
    print("nunca sai")
```

Compila, liga, roda, não imprime nada, sai com 0. O ponto de entrada do pscript é
o código de topo, como no Python — mas quem chega do P (onde `def main() -> int`
**é** o ponto de entrada), do C ou do Java escreve isso no primeiro arquivo. Foi o
meu primeiro programa.

Um programa cujo topo não tem comando executável nenhum e que define uma `main` de
zero argumentos é, com certeza prática, esse engano. Um `-Wmain-never-called`
custaria uma checagem e mataria a classe inteira.

## 10 — ABERTO · o `pforge` acha o compilador por caminho fixo

`pforge run x.psc` **funciona** fora da árvore do compilador — desde que ache
`build/bin/plangc_s2`, caminho relativo ao diretório atual escrito em
`pforge/src/build_plang.psc:38`. Aqui é um symlink, e com ele roda.

Sobram duas coisas.

**A mensagem.** Sem esse arquivo, o `cmd_run` cai no `else`, chama
`BP.assemble()` — o descritor do **plang** — e o erro é:

```
packages/pforge/targets.psc:983: error: cannot list the directory 'bootstrap/selfhost'
  in build_plang__ladder (pforge/src/main.psc:46)
```

Quem lê isso no primeiro dia não chega em "falta um compilador neste diretório".
O programa acabou de avaliar `path.isfile(PLANGC_S2)` como falso e sabe
exactamente o que faltou.

**Só o script solto atravessa.** `pforge build` e `pforge test` não abrem o
`pack.json` do projeto: caem no mesmo `assemble` e morrem no mesmo lugar. Um
projeto de fora tem lançador de script, e não tem build system nem suíte.

A boa notícia é que a biblioteca já tem tudo: `T.psc_program_with(ctx, src, out,
objdir, p_srcs, flags, cflags, libs)` é exactamente a assinatura de que um
projeto precisa (é como o pstudio declara SDL2 com `pkg-config`), e o
`manifest.psc` já lê `pack.json` com erro posicionado e já tem `csources` e
`cflags`. Falta a fiação: um `"targets"` no manifesto e um `assemble_project()`
que chame `psc_program_with` por alvo.

## 11 — ABERTO · não há import de subdiretório do próprio projeto

`import x` acha um irmão no mesmo diretório; `import <pkg/f.psc>` acha um pacote.
Um módulo em `src/core/` visto de `src/` não tem grafia:

```
src/main.psc:1:12: error: expected end of line in import, found '.'
```

O pstudio contorna mantendo tudo num diretório só — 24 `.psc` lado a lado. Para
um porte de 25 mil linhas isso não escala.

Contorno que funciona, e vale documentar porque não é óbvio: **`--pkg-path`
aceita repetição**, então o próprio projeto pode carregar um diretório de
pacotes seus (`--pkg-path packages --pkg-path pkg`), um `pack.json` por
subdiretório, e aí `import <core/algebra.psc>` resolve.

## 12 — DECISÃO · `{0}` do P é `Set<int>` no pscript

```python
z: M4 = {0}     # error: 'z' expects M4, found Set<int>
```

Correto e inevitável — chaves são literal de conjunto. Mas as duas línguas moram
no mesmo repositório e a inicialização zerada do P é `{0}`. A mensagem podia
dizer a frase que resolve: *no pscript o valor zerado de um record é `M4()`*.

---

# Desempenho: `inline` não é o que falta, LTO é

Vinte milhões de voltas de `acc.add(d.scale(1/i))` + `acc.dot(d)` com um `record`
de três `float`:

| | `-O2` | `-O2 -flto` | |
|---|---|---|---|
| record no mesmo módulo | 828 ms | **445 ms** | 1,86× |
| record importado de outro módulo | 829 ms | **426 ms** | 1,95× |

Duas leituras, e as duas surpreenderam:

**Os métodos do record já são inlinados.** A `-O2`, `nm` no binário não acha
símbolo nenhum de `add`, `scale` ou `dot`. E atravessar módulo pscript não custa
nada: 829 ms contra 828 ms. Uma palavra-chave `inline` no pscript não teria o que
fazer aqui.

**O que o LTO come é o runtime.** No C gerado do laço quente:

```
      3 ps_gc_poll(      ponto seguro do coletor
      6 ps_has_exc(      "levantou?" depois de cada operação checada
      2 ps_add(          soma inteira com checagem de estouro
```

`psrt_*.c` é outra unidade de tradução, então a `-O2` cada uma é chamada de
verdade, opaca. É a mesma lição que o README já registra ("LTO, worth 3.4× on
recursion, because a program and the runtime are two translation units") — e ela
vale para o código de APLICAÇÃO também, não só para recursão. Vale dizê-lo no
README ao lado da receita de `cc`, que hoje não traz `-flto`.

As duas alavancas que a linguagem já tem para o resto: `%+` no contador tirou um
`ps_add` e levou 828 → 771 ms (~7%); `nogc:` é o que apaga os `ps_gc_poll`, e
entra quando o mesher chegar.

---

# O que o porte ganhou de graça, e vale registrar

Não é só cobrança. O `record` como tipo de VALOR apagou duas famílias de métodos
inteiras do `shared/engine/math.js`, e o original diz por que elas existiam:

- os mutadores `addEq` `subEq` `mulEq` `divEq` `scaleEq` `addScaledEq` `set`
  `setScalar` `copyFrom` `clone` — dezesseis entre `Vec2` e `Vec3`;
- e a família `mulInto` `rotationInto` `translationInto` `corpoInto` do `Mat4`,
  que escreve num destino do chamador.

O comentário do JavaScript é a justificação delas, e a conta é dele: um mob de 13
peças custa ~143 objetos por quadro, a hidra de 139 peças custa 1.529, e com vinte
bichos à vista a 60 fps passa de 150 mil objetos por segundo — *"o sintoma não é
fps baixo constante, é TRANCO"*.

Em pscript `Vec3` e `Mat4` vivem na pilha e copiam na atribuição. `mul(a, b)`
aloca zero. As duas famílias não foram portadas: foram **dispensadas**, e o que
sobrou é a álgebra. É o mesmo resultado que a bateria 71 mediu no porte do editor
(914 linhas de pscript onde o P precisava de 1.505), pela mesma razão — o que
desaparece não é estilo, é trabalho que a linguagem passou a fazer.
