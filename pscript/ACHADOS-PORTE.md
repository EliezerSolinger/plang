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

## 0b — CONSERTADO · `int(x)` de NaN, de infinito ou fora da faixa era UB

O gêmeo do 0, achado quando o dono perguntou "tem um furo na nossa linguagem
pscript no NaN?".

`int(x)` emitia `(int64_t)x`, que em C é comportamento indefinido quando `x` é
NaN, infinito, ou finito mas fora da faixa do i64. O mesmo programa, na mesma
máquina:

| flags | `int(nan)` | `int(inf)` | `int(1e300)` |
|---|---|---|---|
| `-O0` | `-9223372036854775808` | `-9223372036854775808` | `-9223372036854775808` |
| `-O2` | `-9223372036854775808` | `-9223372036854775808` | **`9223372036854775807`** |

O `1e300` muda de resposta com a otimização, e não é NaN: é um float finito que
não cabe em i64, ou seja ESTOURO, que a 7.2 promete que levanta.

E há o eixo da arquitetura, que é o mais grave para uma linguagem que promete o
mesmo programa em todo o lado: no x86 o `cvttsd2si` devolve o "integer
indefinite" (INT64_MIN) e no ARM64 o `fcvtzs` **satura**. A mesma linha dá
INT64_MIN num Linux de mesa e INT64_MAX num Apple Silicon — e o porte para macOS
é recente.

Os oráculos concordam que ninguém devia dar INT64_MIN: o Python levanta
`ValueError` no NaN e `OverflowError` no infinito; o JavaScript dá `0` ou `NaN`.

**O detalhe que dói: a checagem já existia.** `ps_f_to_iw` confere NaN e faixa —
mas só é chamada ao ESTREITAR. `i32(nan)` sempre levantou; era a largura PADRÃO
que passava sem conferir. O motivo provável de não a reusarem para i64 é a borda:
`f64(2^63-1)` arredonda para `2^63`, então `v > f64(hi)` aceitaria `2^63`, que não
cabe. A faixa certa é `-2^63 <= x < 2^63`, com `>=`.

**O conserto** é `ps_f_to_i`, usado nos quatro sítios que convertiam sem conferir:
`int(x)`, `math.floor`, `math.ceil`/`trunc` e `round(x)`. As mensagens são as
palavras do Python. Resultado idêntico em `-O0`, `-O2` e `-O2 -flto`:

```
int(nan)    cannot convert float NaN to integer
int(inf)    cannot convert float infinity to integer
int(1e300)  this float does not fit int
floor(nan)  cannot convert float NaN to integer
round(inf)  cannot convert float infinity to integer
```

`round(x)` deixou de chamar `ps_round` e passa a emitir `rint` da libm envolvido
na travessia checada — de propósito, para não mudar a assinatura de uma função do
runtime: o SEED em C commitado ainda a chama com a antiga, e mudá-la obrigaria a
re-semear. `ps_round` ficou no runtime com um comentário a dizer que sai na
próxima semeadura.

Portão: `tests/pscript/run/f2i.psc`.

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

## 13 — ABERTO · `u8 << 8` fica preso em 8 bits, e em SILÊNCIO

Achado ao portar o conector MySQL. Ler um inteiro little-endian de um pacote é o
idioma mais comum de um protocolo binário:

```python
b = bytes([0x78, 0x56, 0x34, 0x12])
x = b[0]
y = b[1]
print(x | (y << 8))       # 120, e o certo é 22136
```

`b[i]` devolve `u8`, e `u8 << 8` **fica em `u8`** — a largura estreita mascara à
largura (68.2), então o byte alto some. `typestr(y << 8)` confirma: o resultado é
`u8`. E `int(x)` DEPOIS não recupera nada, porque o valor já foi truncado.

Isto é a regra da linguagem (68.2 é deliberada), não um defeito do lowering. Mas
é uma armadilha silenciosa: **o programa compila, roda, e dá o número errado.**
`read_uint32` de um pacote MySQL devolvia `120` em vez de `305419896`, e o
sintoma só apareceu quando um valor de protocolo veio absurdo. O idioma correto é
`int(b[i])` ANTES do shift, e é o que `packages/mysql/packet.psc` faz.

A pergunta que fica é se o compilador deveria avisar. Um `<<` cuja largura do
resultado não cabe o que o deslocamento produz — `u8 << 8` desloca todos os bits
para fora — é, com certeza prática, engano. Um `-Wshift-overflows-width` custaria
uma checagem e mataria a classe. É a mesma forma dos outros achados desta série:
uma operação de largura estreita que faz silenciosamente menos do que parece.

## 14 — os dois bugs do conector, e por que um `.expected` não bastava

O porte do MySQL teve exactamente dois bugs, e os dois são instrutivos porque
NENHUM apareceria numa checagem de tipos — os dois compilam e rodam:

1. o `u8 << 8` acima, no `read_uint32`;
2. um byte a menos no salt do handshake (8 + 12 bytes de desafio, e o NUL
   terminador vem DEPOIS dos 12; eu tirei um a mais e o servidor recusou com
   "Access denied", sem dizer que o problema foi o desafio).

O segundo só se pega falando com um servidor de verdade, e o primeiro só se pega
com um valor que o teste saiba prever. Ambos estão agora presos em
`packages/mysql/test/`, contra os vetores oficiais do SHA-1 e o scramble do
próprio pymysql — a mesma disciplina de oráculo que o resto do repositório usa.

## 15 — FEITO · `any` agora guarda `bytes`

O conector MySQL desenterrou isto, e é ganho de linguagem, não do conector: um
valor de coluna vira `any` (carrega o seu tipo), e um BLOB é `bytes` — mas o
`any` do core só guardava números, bools, strings, listas e dicts. `x as bytes`
dava *"is not compiled yet: an `any` holds numbers, bools, strings, lists and
dicts so far"*.

`bytes` é `PS_TY_BYTES`, um objeto com cabeçalho, exactamente como `str`. Então
a mudança seguiu o `str` em cinco pontos, todos os que enumeram o que cabe num
`any`:

1. o boxing na sema (o valor CABE): `PT_BYTES` no case de `PT_STR`;
2. o `as` na sema (pode ser LIDO de volta): `PT_BYTES` no conjunto permitido;
3. a mensagem do que cabe;
4. o boxing na baixada: `bytes` vai como cast (já é objeto), com `str`/`list`/`dict`;
5. o unbox na baixada: a tag `PS_TY_BYTES` no `ps_as_ref`.

Conferido: ida e volta (`b"\x00\x01\xff" as bytes` devolve os mesmos bytes),
numa `List<any?>`, e a tag errada (`"texto" as bytes`) levanta — o mesmo
`ps_as_ref` que protege `str`. E o adjacente ficou bem-comportado: `json.stringify`
de um `any` com bytes RECUSA limpo (`VALUE`), porque bytes não é JSON, em vez de
emitir lixo. Caso no corpus: `anyval.psc`.

O que fica de fora, e é a próxima peça se alguém precisar: um `record` num `any`
(um `LocalDateTime`, por exemplo). Um record é VALOR, não tem cabeçalho, então
boxá-lo exige alocar — não é o cast que `bytes` e `str` são. Por isso o conector
lê data por um getter dedicado (`get_datetime`), que a parseia sem passar pelo
`any`.

## 16 — CONSERTADO · defaults não valiam numa chamada de `async def`

```python
async def g(a: int, b: int = 2, c: int = 3) -> int:
    return a + b + c

await g(1)          # error: 'g' takes 3 argument(s), 1 given
```

Numa função síncrona `g(1)` preenche `b` e `c` com os defaults; num `async def`,
não. A causa é uma assimetria clara em `ps_sema.p`: o caminho síncrono chama
`bind_call_args` (que preenche os defaults e ordena os nomeados) antes de
conferir a aridade; o caminho async conferia `e->nargs != f->nparams` DIRETO,
sem passar por ele.

Foi o conector MySQL que o encontrou: o `connect` é `async` e ganhou parâmetros
com default (`db=""`, `tls=False`, `tls_verify=True`), e de repente a API pública
exigia os sete argumentos sempre. O conserto é fazer o async usar o MESMO
`bind_call_args` — três linhas movidas —, e com ele veio de graça o argumento
NOMEADO numa chamada async (`connect(..., tls=True)`), que também não compilava.

## 17 — CONSERTADO (no runtime) · TLS 1.3 travava um `read` logo após o handshake

Não é do compilador, é do runtime de rede, e vale por qualquer cliente TLS e não
só o MySQL.

Um cliente que sobe TLS e lê logo a seguir — o MySQL manda o OK do login
imediatamente — travava para sempre. O proxy que capturou o tráfego mostrou o
handshake TLS COMPLETO (ClientHello, ServerHello, Finished) e a resposta do
servidor a chegar em 89 ms; e o cliente a fechar por timeout 12 s depois, sem a
ter lido.

A causa é o clássico dos dados bufferizados no OpenSSL. Em TLS 1.3 o
`SSL_connect` do handshake lê do fd MAIS do que o handshake (o NewSessionTicket,
e com ele o que o servidor já mandou a seguir), e esse excedente fica DECIFRADO
no buffer interno do `SSL` — não no fd. O `ps_fd_try` do runtime esperava sempre
o `poll` do fd dizer que há dados antes de chamar `SSL_read`; mas os dados não
estavam no fd, estavam no `SSL`, e o `poll` nunca acordava.

O conserto é `SSL_pending` antes do `poll`: se o buffer do `SSL` já tem bytes
decifrados, lê-se sem esperar o descritor. `SSL_pending` não existia no runtime;
entrou como `ps_tls_has_pending`, no escopo onde o `<openssl/ssl.h>` é visível,
com o stub correspondente no caminho sem TLS.

O `tests/tls.sh` não o apanhava porque o seu servidor de teste não fala logo
depois do handshake — é justamente o padrão do MySQL (responder já) que o expõe.

# O que a linguagem ganhou, e o que cada coisa custou

Três features, todas nascidas de o porte esbarrar, todas seguindo um precedente
que já estava no código.

## `Tipo.metodo()` — um estático alcançável pela sua grafia

Era o item 3 deste documento. O modelo estava completo (`is_smethod` no AST,
`nrecv` na checagem, e chamar pela instância FUNCIONAVA), e faltava só resolver o
nome do tipo no sítio da chamada.

A baixada não precisou de **nada**: ela já decide o receptor pelo parâmetro
chamado `self` (`recv`, em `ps_lower`), então um método sem receptor já emitia
`Mat4_identity(&__ctx, ...)` sem tocar no lado esquerdo. A sema ganhou um
`type_smethod` ao lado do `try_mod_qual`, de quem é irmão — a mesma pergunta
("este nome é um módulo?" / "este nome é um tipo?") no mesmo sítio.

Um valor de mesmo nome ganha do tipo, porque uma variável sombreia um tipo em
toda a parte.

## `static` deixou de ser obrigatório

`f->is_smethod` vinha da PALAVRA, e o resto do compilador já discordava disso: o
comentário do `ps_ast.ph` diz "a def inside a struct with no receiver", e a
baixada decide pelo parâmetro. Três lugares, duas definições.

O sintoma da discordância era uma aridade NEGATIVA — o item 4:
`'M.identity' takes -1 argument(s), 0 given`. Agora a ausência do receptor
decide, `static` é a mesma coisa dita em voz alta, e o item 4 morreu com isso.

A rede de segurança continua: um método que esqueceu o `self` numa implementação
de trait é apanhado pela conformidade, com a mensagem certa
(`'Quadrado.area' takes 0 parameter(s); the trait declares 1`).

## `Tipo.CONSTANTE` — uma constante do tipo, copiável

```python
record Vec3:
    x: float
    y: float
    z: float

    const UP   = Vec3(0.0, 1.0, 0.0)
    const ZERO = Vec3(0.0, 0.0, 0.0)
```

Zero palavra nova: `const` distingue isto de um campo (`x: float`) exactamente
como `static` distinguia um método. E zero maquinaria nova para declarar ou
emitir — o que sai do parser é um `const` de MÓDULO com o nome manjado
`Tipo_NOME`, a mesma convenção com que um método já vira `Tipo_metodo`. Só a
LEITURA é nova, e é o irmão do `try_mod_qual` outra vez.

**Não custa memória no tipo**, medido: o `struct` em C continua a carregar só os
campos declarados, e a constante sai como `static Vec3 Vec3_UP = {0.0, 1.0, 0.0}`
— uma cópia no programa. E é copiável de verdade: `v = Vec3.UP` seguido de
`v.y = 42.0` muda a cópia e não o original, que é o que um tipo de valor promete.

Escrever nela é recusado, e a recusa teve de ficar no topo da atribuição: a
reescrita apaga o ponto, e o teste de const que já existia só conhece locais —
sem isso `Vec3.UP = ...` passava e MUDAVA a constante.

No JavaScript essas constantes eram FUNÇÕES (`Vec3.UP()`, `Mat4.IDENTITY()`), e
eram funções por necessidade: devolver um objeto compartilhado e mutável seria
bug de aliasing. Aqui o valor não pode ser aliasado, então volta a ser o que
sempre quis ser.

## `nocheck:` — o bloco que não confere

Pedido para o laço quente, depois de a medida mostrar que a aritmética checada
custa **+16%** num laço que quase só multiplica (1278 ms contra 1100 ms em 200
milhões de operações).

É **açúcar sobre a 54.1**: dentro do bloco, `+ - *` sobre int passam a ser
`%+ %- %*`, que já existem e já dão a volta. Medido:

| | 200M multiplicações |
|---|---|
| checado | 1128 ms |
| `nocheck:` | **753 ms** (1,50×) |
| `%*` escrito à mão | 764 ms |

Ou seja o bloco entrega exactamente o que os operadores entregam, e existe para
poupar o `%` em cada operador num laço de índices de voxel — onde o estouro é
impossível por construção, porque o índice é mascarado.

**O que ele NÃO é: a operação signed crua.** O dono pediu "UB mesmo"; a medida
diz que UB não compra nada. As duas formas geram as MESMAS instruções:

```
raw:   movq %rdi,%rax ; imulq %rsi,%rax ; ret
wrap:  movq %rdi,%rax ; imulq %rsi,%rax ; ret
```

O que o UB compra é o compilador reescrever a guarda ao lado. Três linhas de C:

```c
int guarda(int a) { return a * 2 < 0; }
```
```
guarda:  movl %edi,%eax ; shrl $31,%eax ; ret      /* virou "o bit de sinal de a" */
```

O gcc assumiu que `a*2` não estoura e trocou a pergunta. É o mecanismo do achado
0, em três linhas — e é a razão pela qual o comentário da 54.1 já dizia que a
forma que dá a volta tem de passar por unsigned.

Com `-g` (a metade de depuração dos dois modos da 100.1) o bloco **mantém** as
checagens, sem bandeira nova: um bloco que promete não levantar é exactamente o
que se quer ver levantar num teste.

Portão: `tests/nocheck.sh`, que compila o mesmo ficheiro nos dois modos.

## E um conserto de uma linha: o `repr` contava o renomeamento

```
simple__Ponto(x=1.0, y=2.0)      # um record que veio de um módulo importado
```

O descritor do tipo levava `d->name`, o nome já renomeado. O campo para isto
existia: `src_name`, que o próprio AST documenta como "the name AS WRITTEN,
before the module rename (41.3) — what a diagnostic has to say back". É a mesma
razão pela qual o `ps_disp` existe.

Agora diz `Ponto(x=1.0, y=2.0)`.

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
