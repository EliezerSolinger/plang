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

## 3 — CONSERTADO · um método estático não era alcançável pela sua própria grafia

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

## 4 — CONSERTADO · aridade NEGATIVA numa mensagem

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

## 5 — RESOLVIDO · `def` sem `self` dentro de um record já NÃO exige `static`

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

## 18 — ABERTO · a f-string recusa o que o `str()` ao lado já sabe fazer

| | `f"{x}"` | `str(x)` |
|---|---|---|
| `any` | **erro** | ✓ funciona |
| `bytes` | **erro** | ✓ funciona |
| `int?`, `bytes?` | erro | erro |

```
an f-string cannot format any yet
an f-string cannot format bytes yet
```

O `any` é o caso que mais dói, e é pura inconsistência: `str(a)` de um `any`
funciona — o runtime rende o valor pelo descritor que ele carrega (151.3) — mas a
f-string ao lado recusa. São o mesmo trabalho; a f-string só precisa de baixar
para o `str` que já existe.

`bytes` é o mesmo: `str(b)` decodifica e valida UTF-8, e a f-string não o chama.

O opcional é outra pergunta, e é DECISÃO e não lacuna: o Python imprime `None`
para um `T?` vazio. Se seguirmos (e o `math`, o `round`, o `int()` já seguem o
Python), `f"{x}"` de um `int?` passa a escrever o número ou `None`, e uma prova de
não-nulo deixa de ser exigida só para imprimir.

**Custo do que isto obriga hoje**: em todo sítio onde um valor pode faltar — que
num conector de banco e num parser é em toda a parte — escreve-se

```python
v = row.get("nome")
if v != None:
    print(f"{v}")        # e só aqui
```

Contei quinze vezes num só porte.

## 19 — ABERTO · `b'...'` com aspas simples não existe, e a mensagem não diz isso

```python
s = 'texto'        # ok — uma str aceita as duas aspas
b = b"bytes"       # ok
c = b'bytes'       # error: expected end of line in statement, found char literal
```

Uma `str` aceita aspa simples e dupla; um literal de `bytes` só aceita a dupla. No
Python os dois funcionam, e é de lá que vem a mão de quem escreve. A mensagem fala
de *char literal* — porque o `'b'` do P é um caractere — e não do que a pessoa
escreveu, então ela procura o erro no sítio errado. Custou-me três iterações num
teste.

## 20 — ABERTO · `import <pkg/x.ph>` de um pscript não aceita `as`

```python
import <ed25519/ed25519.ph>          # ok — e as funções vêm para o escopo
import <ed25519/ed25519.ph> as ed    # error: expected end of line in import, found 'as'
```

Um pacote pscript (`.psc`) importa-se com `as` e ganha um espaço de nomes; um
pacote P (`.ph`) não, e as funções dele entram no escopo global do módulo. A
fronteira 45.5 explica a diferença de MECANISMO, mas quem escreve vê duas
gramáticas para a mesma linha — e o `as` é justamente o que evita colisão quando
se importam dois pacotes P.

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

## 21 — `str()` e f-string de um `T?` não compilavam  ✅ corrigido

O buraco tinha uma forma estranha: um `T?` **dentro** de uma lista já saía
escrito (`[None, 'z']`), porque quem percorre um contentor é o runtime guiado
pela tabela de tipos. Mas `str(x)` e `f"{x}"` sobre o **mesmo** valor recusavam
compilar. O mesmo valor tinha forma escrita num sítio e não tinha no outro.

Três peças:

* **compilador** — `repr_value`/`to_str` ganharam o caso `PT_OPT`, rendido pela
  pergunta que a linguagem já faz (`!= None`, 43.1): as duas metades do ternário
  são o valor e a palavra `None`;
* **runtime** — espécie nova no descritor (`PS_T_OPT`), porque o runtime precisa
  de saber ler as DUAS representações da 9.4, e o `width` diz qual: `1` é a
  referência nua, `0` é o registo `{has, v}` (aí a marca de oito bytes da 147.6
  põe o valor sempre no deslocamento 8);
* **`sh_mangle`** — respondia `"v"` a *qualquer* opcional. Enquanto o opcional
  era opaco isso não se via; com um descritor que carrega `inner` e `width`,
  `List<str?>` e `List<int?>` passariam a pedir o **mesmo** descritor, e o
  primeiro a ser emitido serviria os dois.

Gate: `tests/pscript/run/optstr.psc`, conferido linha a linha contra Python.

A única divergência deliberada é `f"{x:>6}"` sobre um opcional: aqui alinha o
TEXTO (`"None"` e `"42"` na mesma coluna), enquanto Python levanta. É a única
regra que serve aos dois lados do `?`.

## 22 — construtor posicional não embrulhava um valor num campo `T?`  ✅ corrigido

`P("Ana", None, 3)` com `i: int?` não compilava; `P(n="Ana", e=None, i=3)`
compilava. A assimetria era a pista: em `check_ctor`, o `a->type = campo` escreve
no nó do designador na forma nomeada — mas na posicional o designador e o valor
**são o mesmo nó**, e o carimbo tapava o `int` do literal com `int?`. A baixa lê
esse tipo para decidir se embrulha (`coerce`), via "já é opcional", e deixava
passar cru: o C saía com um `__PsOpt_i` a receber um escalar.

Só se via nos opcionais de VALOR — num de referência o embrulho é a identidade,
e por isso `str?` funcionava e `int?` não.

## 23 — uma função não atravessava para um worker  ✅ corrigido (L1/D3b)

`spawn(servir, (porta, handle))` não compilava: *"an argument to a worker is
def(Request) -> Response, and a message crosses heaps as BYTES"*. Sem isto o
desenho do httpd multi-worker não existia.

Parece violar a 18.1 e não viola. O que a 18.1 isola são HEAPS; dois workers são
threads do MESMO processo e partilham o espaço do BINÁRIO. **Um `def` de topo é
um símbolo** — o mesmo endereço em toda a thread, nada dele no heap. O ambiente
de uma lambda mora no heap e copia-se como qualquer mensagem, desde que seja POD.

E a prova de "POD" já existia sem ninguém a ter pedido: **o compilador só escreve
um `trace` no descritor quando há uma referência para seguir**, portanto
`env->desc->trace == None` É a condição. A recusa é por isso a correr e não a
compilar — e tinha de ser, porque `def(int) -> int` não distingue o símbolo da
lambda.

Vale nos dois sentidos: `spawn` (bloco malloc'd, `ps_closure_export/import`) e
`send` (a forma `PS_SH_FUNC`). Gate: `tests/pscript/run/worker_func.psc`.

## 24 — a mensagem VAZIA de um tipo que é referência dava um SIGSEGV  ✅ corrigido

Anterior a este trabalho e geral. A 107.8 escolheu "`recv` devolve mensagem vazia
quando não há mais nada", e estava certo quando uma mensagem era bytes: o vazio de
um número é um zero, e um zero é um valor. A escada da 34.3 depois deixou passar
`str`, listas, dicionários e `struct` — e para esses o vazio passou a ser o
**ponteiro nulo**, que não é valor nenhum:

```
async def servo(n: int) -> str:
    for i in range(3):
        s: str = await parent.recv()
        print(len(s))          # <- SIGSEGV na terceira volta
```

A janela existe mesmo com o predicado à frente: `parent.open()` responde "ainda
pode chegar mensagem", e entre a resposta e o `recv` a fila pode esvaziar.

Agora levanta, com a frase que explica a corrida. O guarda vive no `ps_des_run`
porque há DUAS portas — o caminho síncrono (a mensagem já estava na fila) e o
assíncrono (a tarefa dorme e é enchida depois) — e só esse corredor é comum.
Pelo caminho, o `recv` de um tipo-grafo passou a marcar `raised`: sem isso o
valor nulo seguia para a instrução seguinte, que era onde o programa morria em
vez de parar.

## 25 — um `spawn` arrancava a thread com o contexto já a desenrolar  ✅ corrigido

Os argumentos de um `spawn` são preenchidos por atribuições ANTES da chamada, e
uma delas pode levantar. A verificação da exceção só chega no fim da instrução —
portanto a thread partia na mesma, com um argumento por preencher. A recusa saía
certa e logo a seguir vinha um SIGSEGV noutra thread: o pior de dois mundos.
`ps_worker_new` recusa agora arrancar quando `ctx->exc != None`, devolvendo um
worker já terminado.

## 26 — `SO_REUSEPORT` (L2/D2)  ✅ feito

`net.listen(porta, True)`. Não é o `SO_REUSEADDR`, que já lá estava sempre: esse
deixa RELIGAR um porto em TIME_WAIT (é sobre o passado), este deixa N descritores
escutarem ao mesmo tempo (é sobre o presente), e o kernel reparte os accepts por
uma dispersão da quádrupla. É o que faz N workers servirem um porto sem um
aceitador único no meio e sem *thundering herd*.

O valor por omissão é escrito na SEMA e não no runtime — assim a baixa continua a
ser a genérica dos `__net_*`, que passa os argumentos tais como estão. E a recusa
do `setsockopt` é silenciosa: um kernel sem a opção continua a servir com um
worker, e levantar tornaria o servidor inarrancável por causa de uma optimização.

**L5 (`net.unix`) já existia** desde a F7 do plano NIO — `net.unix` e
`net.unix_listen` — e o que faltava era um portão. Tem-no agora no mesmo ficheiro.

Gate: `tests/pscript/run/net_reuseport.psc`. O que ele deliberadamente NÃO afirma
é qual descritor recebe qual conexão: é a hash do kernel, e com duas conexões
mandar as duas ao mesmo é uma resposta correcta. Chegou a estar escrito assim, e
o teste pendurou-se no `accept` do outro.

## 27 — `bytes + bytes` não existia  ✅ corrigido

Um servidor não faz outra coisa senão juntar bytes: a linha de estado mais os
cabeçalhos mais o corpo, o cabeçalho de um quadro mais a carga. Sem isto o
caminho era `bytes -> List<u8> -> bytes`, que é duas cópias e uma travessia byte
a byte para fazer o que um `memcpy` faz. `a + b` sobre bytes agora existe, pela
mesma razão que `str + str` existe, e o resultado é sempre um bloco NOVO e dono
do que tem — juntar dois pedaços de um `Mapping` não pode devolver uma janela,
porque não há janela que cubra os dois.

## 28 — `json.stringify` recusava um `any` DECLARADO  ✅ corrigido

`Dict<str, any>` é a forma exacta de um objecto JSON, e é o que sai de um
`json.parse`. Não voltava a atravessar para texto: `stringify(parse(x))` não
fechava o círculo. O caminho por dentro de um `any` já existia — é o que trata
os valores de um dicionário guardado num —, mas quando o TIPO ESTÁTICO dizia
`any` caía-se na recusa. Uma linha em `ps_json_ty`. Junto foi o `T?`, que agora
sai `null`, que é a palavra que o JSON tem para isso.

## 29 — o `sh_mangle` dava a MESMA chave a espécies diferentes  ✅ corrigido (era grave)

O fundo do `sh_mangle` respondia `"v"` a tudo o que não tivesse caso próprio —
`any`, `bytes`, `Task`, `Socket`, `Channel`. Quem chegasse primeiro num módulo
registava o descritor `__ty_v`, e todos os outros recebiam o dele.

Enquanto todos eram opacos no descritor isso não se via, porque o corpo era
igual. Deixou de o ser quando o `any` passou a ter espécie própria: num módulo
onde um `bytes` fosse visto primeiro, o `any` ficava com o descritor OPACO dele —
e `httpd.json({...})` recusava um dicionário perfeitamente válido, num sítio sem
relação nenhuma com o `bytes`. Silencioso, dependente da ORDEM em que os tipos
aparecem no ficheiro, e diferente entre módulos.

O fundo passa a encodificar o número da espécie (`k12`), o que é total por
construção: uma espécie nova ganha chave própria sem ninguém se lembrar dela.

## 30 — um `def` de topo com nome de POSIX era capturado pela libc  ✅ corrigido

`def listen(porta, cfg)` em pscript nascia com o nome `listen` no C emitido, e
ERA o `listen(2)` a partir daí. O erro que saía falava de conversões de inteiro
para ponteiro num sítio sem relação. Havia uma lista de nomes reservados
(`PS_TAKEN`) e ela estava certa para quando o runtime só incluía `<stdio.h>`;
hoje ele inclui `<unistd.h>`, `<sys/socket.h>`, `<netdb.h>`, `<signal.h>` e
`<pthread.h>`, e cada um traz nomes curtos e comuns. A lista cresceu com os
nomes desses cabeçalhos — o critério é "o que o runtime inclui", e não "tudo o
que a libc tem": um nome que ninguém declara não captura nada.

## 31 — um `def` de topo não tapa um embutido, e o erro não diz isso  ⬜ aberto

`def status(code: int)` no `httpd` não compilou: `status(w)` é uma função da
linguagem (a de perguntar por um worker, 107.8) e ganha. O módulo renomeou para
`status_code` e segue.

O que fica por decidir é de desenho, não de implementação: **um nome do programa
deve ganhar a um embutido?** Em Python ganha. Se a resposta for não, o erro tem
de o dizer — hoje sai uma queixa de tipos vinda da baixa, que não menciona
sequer a palavra "embutido".

## 32 — um método LIGADO não é um valor  ⬜ aberto

`mapa.handle` não se escreve: o campo não existe. O `run` do servidor quer um
`def(Request) -> Task<Response>` para chamar a cada pedido, e um encaminhador é
exactamente a coisa que devia poder dar-lho.

A volta é de duas linhas e o `packages/httpd/router.psc` dá-a por escrito — o
despacho é uma FUNÇÃO LIVRE e o programa escreve o adaptador:

```python
async def despacha(req: httpd.Request) -> httpd.Response:
    return await rt.dispatch(mapa, req)
```

Não é um remendo mau, mas é uma volta. Um método ligado é uma closure sobre o
`self`, e a linguagem já tem closures com captura — o que falta é a forma
escrita. Fica registado como coisa de desenho.

## 33 — `def(...) -> T?` e `(def(...) -> T)?` escrevem-se quase igual  ⬜ nota

Não é um defeito: é uma ambiguidade real da gramática de tipos, e os parênteses
resolvem-na. Fica registada porque custou uma leitura: o primeiro é a função que
devolve um opcional, o segundo é a função opcional, e a mensagem de erro mostra
os dois quase iguais. Um campo `on_upgrade` escrito sem parênteses aceita `None`
como **valor de retorno** e não como valor do campo.

## 34 — os TÓPICOS entre contextos (L4/D6)  ✅ feito

O pub/sub é a peça que o desenho chamou de "a feature assassina", e é onde o
modelo de concorrência aparece: N workers com heaps isolados, e uma difusão que
os alcança a todos sem que nenhum objecto atravesse.

Quatro funções e **nenhum tipo novo**, o que é a decisão central: um `Topic` como
objecto seria coletado, e um objecto coletado não atravessa heaps (18.1). O que
atravessa é o NOME, que é uma string, e a inscrição vive numa tabela do PROCESSO
— `malloc`'d, pela mesma razão que o bloco de controlo de um worker já era: outra
thread lê-a, e um coletor que move não pode mover o que outra thread está a ler.

Três coisas que a implementação decidiu e que valem a pena estar escritas:

* **a caixa de tópicos é SEPARADA da fila de mensagens do worker.** Aquela é
  entre pai e filho e tem um tipo combinado; esta é entre quaisquer dois
  contextos e carrega bytes opacos. Misturá-las faria um `parent.recv()` receber
  uma publicação que não sabe ler;

* **o cano abre-se na primeira inscrição**, e não no arranque do contexto: um
  programa que nunca use tópicos não paga dois descritores, e um servidor com N
  workers não paga 2N;

* **a publicação não volta para quem publicou.** Quem publica tem o valor na mão,
  e devolvê-lo por um cano seria uma cópia e um acordar para nada. É também o que
  faz os dois degraus da D6 encaixarem sem uma linha de política: a biblioteca
  entrega às conexões locais sem serializar nada, e o runtime trata dos outros
  workers.

E o `ps_topic_leave_all` no fim de um contexto não é higiene: a tabela guarda um
ponteiro para ele, e um worker que morresse inscrito faria a publicação seguinte
escrever num cano fechado — o género de defeito que só aparece quando um worker
termina antes dos outros, portanto sob carga e nunca no teste.

Gates: `tests/pscript/run/topics.psc` (entre workers, com encontro explícito para
não ser uma corrida) e `tests/ws.sh` (dentro do worker, com três clientes e a
dessubscrição do fecho).


## 35 — `with await ...` num `async def` nao compilava  OK corrigido

    async def ler(p: str) -> int:
        with await open(p, "r") as f:      # <- erro num campo do frame
            ...

E a forma NORMAL de abrir um ficheiro numa funcao assincrona, e o erro que saia
falava de um campo do frame que nao existe, num sitio sem relacao nenhuma com o
`await` -- porque a causa estava noutra passada.

A maquina de estados guarda no frame uma MARCA por limpeza armada, para saber a
cada saida do bloco o que ja foi libertado. Quem a escreve arma-a **sempre**; quem
monta o frame so a declarava quando o **corpo** do `with` suspendia. Um `with
await open(...)` suspende no CABECALHO, e entao uma escrevia numa marca que a
outra nao tinha declarado.

As duas condicoes passam a ser a mesma. Vale a pena notar o que ja estava certo:
os dois lados calculam o NOME da marca a partir da posicao, precisamente para nao
poderem divergir -- o que faltava era a condicao, nao o nome.

Gate: `tests/pscript/run/async_with.psc`.

## 36 — ficheiros estaticos (F8/D13/D21)  OK feito

`packages/httpd/files.psc`: MIME por extensao, ETag forte, 304, `Range` (com
`If-Range`), 416, `index.html`, e **nunca listar o directorio**.

A defesa contra travessia e a que importa, e o que ela **nao** faz e procurar
`..` no texto do pedido. Essa rompe-se, porque ha sempre mais uma grafia --
`%2e%2e`, `..%2f`, `.%2e/`, `..;/`, a dupla codificacao. A que nao se rompe e
juntar a raiz, NORMALIZAR, e comparar o resultado com ela; e a comparacao e por
prefixo **mais separador**, porque sem ele uma raiz `/srv/www` deixaria passar
`/srv/www-privado`.

O portao tenta doze grafias e nao afirma o codigo de estado -- um 403 e um 404 sao
os dois respostas certas conforme o caminho saia da raiz ou simplesmente nao
exista la dentro. Afirma que o conteudo do ficheiro de fora **nunca aparece**.

O ETag e forte (e nao `W/`) porque a comparacao que o `Range` precisa exige um
validador forte (RFC 9110 s13.1.3): com um fraco, um cliente que retoma uma
descarga de um ficheiro que mudou coseria dois ficheiros diferentes.


## 37 — streaming: o corpo por cursor (F2/D5)  OK feito

`httpd.stream_of(fn, tipo)` e `httpd.sse(fn)`. O cursor devolve `bytes` a cada
chamada e `b""` quando acabou -- a mesma forma do cursor do MySQL, para nao haver
duas maneiras de ler algo aos bocados nesta base de codigo.

Sai em `chunked` e NAO com `content-length`, porque o comprimento nao se sabe --
e e essa a diferenca. Um servidor que juntasse os pedacos para o poder anunciar
teria feito exactamente o trabalho que o streaming existe para evitar.

**A contrapressao nao foi escrita: ela vem do modelo.** O `write` e um `await`,
portanto um cliente lento faz a tarefa esperar no socket, e o cursor so e chamado
outra vez quando o pedaco anterior saiu. A memoria nao cresce, e o worker corre
as outras conexoes enquanto isto espera. E o que a D5 previa, e verifica-se: nao
ha uma linha de codigo de contrapressao no ficheiro.

Duas coisas que o portao prende e que um `curl` normal nao veria:

* **os pedacos chegam EM PEDACOS.** Um `curl` junta tudo e mostra o resultado,
  indistinguivel de uma resposta comum -- o teste mede os TEMPOS de chegada;

* **cada linha de dados de um SSE leva o seu `data:`**. Uma quebra de linha crua
  dentro do campo TERMINA o evento, e e o engano de sempre: serializar JSON numa
  linha so nao chega quando ele tem um `\n` la dentro.

E o `X-Accel-Buffering: no` do SSE nao e para nos -- e para um nginx a frente.
Sem ele o proxy junta os eventos num tampao e entrega-os todos no fim, o que
transforma um fluxo em tempo real numa resposta longa. E o problema mais
reportado de SSE atras de um proxy, e cabe num cabecalho.


## 38 — um `const` CONSTRUIDO era `None` dentro de um worker  OK corrigido (era grave)

Um `const` cujo valor tem de ser construido -- uma lista, um dicionario -- vive no
conjunto do contexto (61.3), e o inicializador dele era codigo emitido dentro do
`main`. Portanto num WORKER ele nunca corria: a tabela ficava `None`, e o primeiro
`TABELA[i]` la dentro era um SIGSEGV numa thread sem pilha para ler.

**Nao era um caso de nicho.** Quebrava qualquer pacote com uma tabela: o
`datetime` (os nomes dos meses), o `compress` (as tabelas do DEFLATE), o `httpd`
(os nomes dos dias, no cabecalho `Date`).

E o sintoma nao apontava para lado nenhum. Um servidor com quatro workers falhava
UMA resposta em trinta -- a primeira que cada worker formatava num segundo novo,
porque a data e memorizada por segundo (D42) -- e as outras vinte e nove
funcionavam. A depuracao levou uma hora e passou por tres hipoteses erradas
(tarefa coletada, escrita parcial, accept perdido) antes de o diagnostico
aparecer, e o que o revelou foi um `print` no `catch` do `write`.

A correccao e uma funcao `__ps_consts_init(ctx)` que o `main` e o arranque de cada
worker chamam. Correr o inicializador de um `const` POR CONTEXTO e o certo e nao
um remendo: ele e imutavel, portanto N copias sao indistinguiveis de uma, e
nenhuma referencia atravessa heaps (18.1) -- partilha-las seria o contrario disso.

A chamada fica DEPOIS de os descritores dos tipos e os tamanhos das formas serem
preenchidos, e nao junto ao `__ps_globals_init`: um `const` pode ser uma lista de
records, e o `repr` de um record precisa do descritor.

Gate: `tests/pscript/run/const_worker.psc`.

## 39 — um contentor AUSENTE segfalhava em vez de levantar  OK corrigido

O outro lado da mesma pedra. Uma global MUTAVEL continua a nascer no seu valor por
omissao dentro de um worker -- e isso e o que a 42.2 promete, nao um defeito --,
portanto uma `List<int>` global e `None` la dentro. Indexa-la era um `l->len` no
endereco zero.

Agora levanta, com uma mensagem que diz *porque* e que ele esta nulo e o que
fazer. E o sitio onde a verificacao NAO pode ficar merece nota: no `ps_list_base`.
Um `xs[i] = v` sai como `base(xs)[at(ctx, xs, i)] = v`, e o C nao define qual dos
dois corre primeiro -- se o `base` corresse antes, o acesso ao endereco zero
acontecia antes de o `at` ter a chance de levantar. Portanto quem levanta e o `at`
(que tem contexto e posicao) e o `base` devolve um sitio seguro para a escrita ir
morrer, que e o mesmo padrao do indice fora de limites.

Gate: `tests/pscript/run/nil_container.psc`.

## 40 — `aprint(...)` sem `await` nao imprime nada  OK corrigido no nosso codigo

O `aprint` devolve uma tarefa, e uma tarefa que ninguem arranca nao corre. O
registo de erros do `httpd` e do `ws` estava escrito com ele sem `await`, portanto
nunca saiu uma linha -- e foi isso que fez a depuracao do `const` levar uma hora,
porque o diagnostico que eu punha nao aparecia.

Passou a `sys.err.write`, e isso e melhor por duas razoes independentes: o registo
de um servidor pertence ao **stderr**, e o stderr nao e tamponado -- o `stdout` de
quem escreve para um cano e tamponado por blocos, e uma linha de erro que so
aparece quando o tampao enche e um registo que nao serve para nada.

Fica em aberto se a linguagem devia avisar: uma tarefa cujo resultado e deitado
fora e legitima (e o modelo da 35.3), mas `aprint` e um caso em que isso quer
dizer "sem saida" -- e isso surpreende.


## 41 — o DEFLATE do repositorio nao comprimia  OK corrigido

O `packages/compress` sempre foi honesto sobre isso: o docstring do `deflate`
dizia "comprime zero e e valido para qualquer leitor do mundo -- o formato tem um
tipo de bloco para exactamente isto", e prometia que quando o compressor a serio
chegasse seria essa funcao a mudar e mais nada. Chegou, e foi.

**LZ77 mais Huffman FIXO.** A escolha do fixo em vez do dinamico e de custo: uma
arvore dinamica ganha cerca de dez por cento em texto e obriga a contar
frequencias, construir duas arvores canonicas e emiti-las com o terceiro alfabeto
do RFC -- umas tres vezes o codigo, para dez por cento. Num servidor o que se
poupa e a viagem pela rede, e nao o ultimo byte.

Razao medida no `SPECS.MD`: 28 246 -> 14 756 (52%), contra 42% do `zlib -6`. A
diferenca e exactamente o que se espera de fixo contra dinamico.

**A armadilha que custa a todos**: o fluxo do DEFLATE escreve-se do bit menos
significativo para o mais, MAS um codigo de Huffman escreve-se do bit MAIS
significativo para o menos. O RFC diz as duas coisas em paragrafos diferentes.
Sao por isso duas funcoes diferentes no escritor -- `put` e `put_code` -- e trocar
uma pela outra da um ficheiro que nenhum leitor abre.

**A segunda, que era minha e nao do RFC**: na cadeia de dispersao, o
`anterior[at]` tem de guardar a cabeca ANTIGA e so depois e que a cabeca passa a
ser `at`. Ao contrario, `anterior[at]` fica igual a `at` -- um laco sobre si mesmo,
e a busca seguinte gira para sempre.

O portao (`tests/compress.sh`) nao usa o nosso `inflate` como prova: os dois
podiam ter o mesmo defeito e concordar. Quem confere sao o `zlib` do CPython e o
`gunzip` da linha de comando -- dois leitores que nao partilham uma linha com este
repositorio. Nove casos, incluindo o classico de erro: um casamento que se sobrepoe
a si mesmo, com distancia 1 e comprimento 200.

## 42 — compressao no servidor (F9/D16)  OK feito

`httpd.comprime(resposta, pedido)`. Tres condicoes, e nenhuma e opcional:

* o cliente **pediu** (`Accept-Encoding`), e um `gzip;q=0` e uma recusa;
* o tipo **ganha** com isso -- comprimir um JPEG, um PNG ou um MP4 gasta CPU e
  **cresce**, porque eles ja estao comprimidos e o DEFLATE acrescenta a moldura
  dele. E o erro mais comum de quem liga a compressao por omissao;
* o corpo passa do **minimo** (1 KiB). Abaixo disso a moldura do gzip e o CPU dos
  dois lados nao se pagam, e um pacote TCP leva mil e quinhentos bytes: comprimir
  de 400 para 380 nao poupa uma viagem.

E o `Vary: Accept-Encoding` sai SEMPRE que se comprime, e nao e cortesia: sem ele
uma cache intermediaria entrega a versao comprimida a um cliente que nao a pediu,
e esse ve lixo binario. E o defeito classico de por compressao atras de um proxy.

Medido no fio: 6000 bytes de texto viajam em 80.

Um FLUXO (F2) nao se comprime -- o corpo ainda nao existe, e comprimi-lo pedaco a
pedaco precisa de um DEFLATE com estado entre chamadas, que e o mesmo que o
permessage-deflate do ws vai precisar. Fica dito em vez de feito pela metade.


## 43 — `remove()` num `shared dict` nao estava ligado  OK corrigido

O `ps_sdict_del` existia no runtime; o que saia era um `ps_dict_del` a receber um
`PsSDict`. Portanto **nao havia como apagar de uma tabela partilhada** -- e isso
nao e um pormenor: uma sessao que nao se pode revogar e um contador que nunca
esquece sao os dois casos em que a tabela existe para ser usada.

E a CHAVE vai pelo `sd_arg` e nao pelo `key_ptr`: a tabela partilhada copia os
bytes de uma string e recebe-a como ela e, ao passo que um dicionario coletado
recebe o ENDERECO do lugar onde a chave esta. Passar um pelo outro le um endereco
que nao e uma chave.

## 44 — `x[k] if k in x else 0` sobre um `shared dict` levanta  aberto (contornado)

Sobre um dicionario normal funciona; sobre uma tabela partilhada, nao. A leitura
e hasteada para uma instrucao ANTES do ternario (ela precisa de um sitio onde o
valor caia) e portanto corre mesmo quando a chave nao esta la.

O contorno e um `if` explicito, e o `packages/httpd/sessao.psc` escreve-o assim
com a razao ao lado. Mas o defeito e real e a forma dele e desagradavel: o mesmo
codigo funciona numa tabela e nao na outra, o que faz dele um engano que so
aparece quando se troca um `Dict` por um `shared Dict`.

## 45 — percorrer um `shared dict` nao esta ligado  aberto (desenho)

`for k in tabela:` sobre uma tabela partilhada nao compila. Nao e um esquecimento:
e uma pergunta de desenho que precisa de uma resposta. Um INSTANTANEO (copia as
chaves sob o cadeado e percorre a copia, que pode estar velha ao ser lida) ou AO
VIVO (mantem o cadeado durante o laco inteiro, e ai um laco lento para os outros
workers)?

O `packages/httpd/sessao.psc` nao precisou dela: o rate limit guarda UMA entrada
por IP com o numero da janela DENTRO do valor, e quando a janela roda a entrada e
sobrescrita em vez de acumulada. A tabela cresce com o numero de IPs distintos --
o mesmo tecto de qualquer estrutura por IP -- e nao com o numero de janelas.

## 46 — sessao, cookies, proxy e rate limit (F8b/F8d)  OK feito

`packages/httpd/sessao.psc`. E o sitio onde a resposta da linguagem aparece: onde
o Bun manda subir um Redis, a tabela esta na linguagem, e o portao prova-o lendo
uma sessao criada num worker a partir de conexoes que caem noutros.

Quatro decisoes que valem a pena estar escritas:

* **o cookie leva um ID assinado e mais nada.** Revogar funciona (apagar a entrada
  mata a sessao na hora, coisa que um cookie assinado nao sabe fazer), o tamanho
  nao e o dos 4 KiB de um cookie, e nada sensivel viaja. O custo, dito: a sessao
  morre com o processo -- um `shared dict` e memoria, nao e uma base de dados;

* **assinar um ID que ja e aleatorio** parece redundante e nao e: sem assinatura
  um atacante pode SONDAR, e com ela um ID que nao bate e recusado antes de a
  tabela ser consultada. A comparacao e em tempo constante (`hmac_equal`), porque
  um `==` de strings conta quantos bytes bateram pelo tempo que leva;

* **os atributos de seguranca do cookie sao o PADRAO** e nao a opcao. Um cookie de
  sessao sem `HttpOnly` e legivel por qualquer XSS, um sem `Secure` viaja em claro
  na primeira ligacao HTTP que o browser fizer, e um sem `SameSite` vai em pedidos
  de outros sitios -- que e o CSRF. E o `set_cookie` RECUSA um valor com
  caracteres de controlo em vez de os limpar: limpar esconde a injeccao de
  cabecalho, recusar mostra-a;

* **do `X-Forwarded-For` toma-se o ULTIMO e nao o primeiro**, e e ao contrario do
  que a intuicao diz. A cadeia e `cliente, proxy1, proxy2` e o cliente controla o
  PRINCIPIO dela: escrever `X-Forwarded-For: 1.2.3.4` faz o primeiro elemento ser
  o que ele quiser. O ultimo foi posto pelo proxy em que confiamos -- e so se le
  quando a ligacao vem de um proxy DECLARADO, que e o que impede qualquer cliente
  de forjar o proprio IP.

Pelo caminho o runtime ganhou `ps_conn_peer` (o endereco de quem ligou, via
`getpeername`): sem ele nao ha como validar o `X-Forwarded-For` nem contar por IP,
e as duas defesas passavam de defesa a enfeite.

## 47 — multipart e `Expect: 100-continue` (F8c/D30/D40)  OK feito

O multipart tem dois pormenores traicoeiros, e os dois estao no portao: a
fronteira no corpo leva DOIS hifens a frente (quem procura a fronteira nua
encontra-a dentro dela mesma), e o corpo de uma parte acaba DOIS bytes antes da
fronteira seguinte -- o `\r\n` pertence a moldura. Levar-lhos faz cada ficheiro
carregado chegar com dois bytes a mais.

E o `Expect: 100-continue` **paga-se, e da-se a medir**: um corpo de tres
megabytes acima do tecto e recusado com 413 e **ZERO bytes subidos**. Sem ele os
tres megabytes subiam para serem deitados fora.

Ele tambem nao e opcional: um cliente que o mande ESPERA pela resposta antes de
enviar. Sem responder, o `curl` espera um segundo e manda de qualquer maneira --
um segundo por pedido, que num teste passa por lentidao da rede.

A janela onde isso acontece precisou de uma pergunta nova no parser
(`headers_done()`): e o unico momento em que os cabecalhos chegaram e o corpo
ainda nao.


## 48 — TLS do lado SERVIDOR (L3+F4/D8)  OK feito

A terceira e ultima das tres coisas que o desenho deu ao runtime (D11). O
`starttls` que ja havia era o lado CLIENTE, e a assimetria e real: um cliente
CONFERE uma cadeia que vem do sistema, um servidor APRESENTA um certificado e uma
chave que vem de dois ficheiros. Sao contextos diferentes do OpenSSL, e nao o
mesmo com uma bandeira.

**O passo do aperto de mao passou a ser um so para os dois lados**, e sem estado
novo: o `SSL_connect` e o `SSL_accept` sao, cada um, um `set_*_state` seguido de um
`do_handshake`. Como o estado ja e posto no `begin` — de conexao no cliente, de
aceitacao no servidor —, o passo e a mesma funcao, e nao ha bandeira a manter em
sincronia com nada.

Tres conferencias no arranque, e as tres existem porque o erro que elas apanham
aparece tarde de mais sem elas:

* a **CADEIA** e nao so o certificado (`use_certificate_chain_file`). Um servidor
  que mande apenas a folha funciona no browser de quem ja tem a intermediaria em
  cache e falha em todos os outros — e ai o erro aparece "as vezes", que e o pior
  modo de aparecer;
* a chave, do ficheiro dela;
* e que a chave **e daquele certificado** (`check_private_key`). Sem isso o erro
  sai no primeiro aperto de mao de um cliente, e nao no arranque — portanto em
  producao e nao no `deploy`.

No httpd sao **dois campos na mesma `Config`**, e isso e a decisao da S7 aplicada:
o TLS e um MODO da ligacao e nao um tipo novo, portanto as rotas, o keep-alive, a
compressao e o WebSocket nao sabem a diferenca. Um `TlsSocket` a parte obrigaria
cada camada acima a ter duas versoes de tudo.

Os oraculos sao o `openssl s_client` e o `curl` — dois clientes TLS que nao
partilham uma linha com este repositorio. E o portao prova os DOIS lados: eles
apertam a mao com `-k`, e **sem** `-k` recusam o certificado auto-assinado. A
segunda metade e a que garante que a verificacao nao foi desligada em nenhum
sitio.

O que fica de fora, dito: **SNI do lado do servidor**. Um processo serve UM
certificado, porque o contexto e um por processo — servir varios nomes com
certificados diferentes pede um retorno de chamada por ligacao. Para o jogo, que
tem um dominio, nao faz falta.


## 49 — uma ligacao ACEITE nascia com o `ssl` por inicializar  OK corrigido (o pior desta sessao)

Encontrado pelo banco de ensaio, e e a razao de ele valer mais do que a tabela
que produz: a coluna dos erros dizia **26** para nos e **0** para o Bun, com o
mesmo gerador. Vinte e seis respostas em cem mil a desaparecer, sem uma linha de
erro em sitio nenhum.

O `ps_alloc` NAO zera (223), e o caminho do `accept` tinha uma segunda
inicializacao a mao, campo por campo, ao lado da do `ps_conn_new`. Faltava-lhe o
`ssl`. Uma conexao em claro cujo `ssl` herdasse lixo nao nulo de uma coleta
anterior entrava no caminho do `SSL_read`; o primeiro `read` falhava, o servidor
fechava com o pedido ainda por ler, e do lado do cliente isso chegava como um RST.

O comentario que estava nessa lista ja dizia que ela tinha custado o mesmo engano
duas vezes antes (`is_std`, `pty_slave_fd`). A correccao nao foi acrescentar-lhe o
terceiro nome — foi **nao haver lista**: o `accept` passou a chamar o
`ps_conn_new`, que e o construtor que ja inicializava tudo. Uma lista de campos
duplicada e uma lista que envelhece, e esta envelheceu tres vezes.

## 50 — EAGAIN num socket era lido como "a ligacao partiu-se"  OK corrigido

Apanhado no caminho para o de cima. Um `write` num socket nao bloqueante devolve
-1 quando o tampao de envio esta cheio — o que e o NORMAL sob carga — e o codigo
punha `err = 1`. O mesmo do lado do `read`.

A pergunta que o `errno` responderia nao se pode fazer em P (ele e uma macro e e
por thread), e o ficheiro ja dizia isso. A resposta vem do `poll`: tentou-se
porque ele disse que dava, e se falhou pergunta-se outra vez com espera zero.

**A primeira versao dessa correccao tinha uma corrida**, e vale a pena estar
escrita: ela lia um `POLLIN` de volta como "esta pronto e a falhar, logo e um erro
de verdade" — mas entre o `read` que devolveu EAGAIN e o `poll`, os dados podem
ter chegado. Sob carga chegam. A unica prova de fim sao POLLERR, POLLHUP e
POLLNVAL; tudo o mais e "tenta outra vez", e nao ha risco de laco infinito porque
um descritor genuinamente partido responde sempre com um dos tres.

## 51 — o banco de ensaio (F12)  OK feito

`tests/bench-httpd/`, com os resultados e a leitura em `RESULTADOS.md`. O resumo:
**o Bun ganha** (24 mil contra os nossos 19,5 mil com a maquina inteira), e
**ganhamos ao Node por 1,7×** com um worker so.

Duas coisas ditas la que valem a pena estar aqui: os quatro workers dao 1,43×
sobre um e nao 4×, porque o gerador tem quatro threads a disputar os mesmos quatro
nucleos — para medir o teto do servidor faria falta gerar a carga de outra
maquina. E o gerador e escrito em C de proposito: um escrito na linguagem que esta
a ser medida seria a pior escolha possivel, porque se ele fosse o gargalo os tres
servidores dariam o mesmo numero.


## 52 — permessage-deflate no WebSocket (F9b/RFC 7692)  OK feito

Para um servidor de jogo que difunde estado em JSON sessenta vezes por segundo,
esta extensao e a diferenca entre mandar oitocentos bytes e mandar sessenta.
Medido no fio, no mesmo servidor: **888 bytes sem ela, 60 com ela**.

O compressor precisou de uma peca nova, e vale a pena dizer qual. O
`deflate_fixed` produz um fluxo COMPLETO -- um bloco com a marca de final -- e
isso serve um ficheiro e nao serve uma conversa: o permessage-deflate manda uma
mensagem de cada vez pelo mesmo fluxo logico, e nenhuma delas e a ultima. A forma
que toda a gente usa e a do `Z_SYNC_FLUSH`: bloco sem marca de final, seguido de
um bloco armazenado vazio -- o que obriga a alinhar ao byte e produz a sequencia
`00 00 ff ff`, que o s7.2.1 manda cortar ao enviar e repor ao receber.

Do outro lado fez falta um `inflate` que PARE LIMPO quando a entrada acaba num
limite de bloco: o normal le ate encontrar a marca de final, e num fluxo de
conversa ela nunca vem.

**O que se recusa, e porque:** exige-se `no_context_takeover` dos dois lados. Com
a janela partilhada, a mensagem N comprimiria contra o que a N-1 disse — e isso
pede um LZ77 que guarde os ultimos 32 KiB **por conexao e dos dois lados**, que e
o que o desenho chamou de "onde ele morde". O nosso compressor e de uma passagem.
A consequencia esta quantificada acima; o que nao se faz e fingir que se suporta e
mandar quadros que o outro lado nao consegue ler.

Tres regras do RFC que o portao prende e que sao faceis de perder:

* o **RSV1 vem no PRIMEIRO quadro** de uma mensagem fragmentada e vale para ela
  inteira (s6.1) — portanto e guardado quando ela comeca, e a descompressao
  acontece depois de a mensagem estar montada: o fluxo do DEFLATE atravessa a
  fragmentacao, e um fragmento sozinho nao e um fluxo que se possa ler;
* um **quadro de CONTROLO nunca e comprimido**, e o RSV1 nele e um erro de
  protocolo mesmo com a extensao combinada;
* e sem extensao negociada o RSV1 continua a ser um erro — o parser aprendeu a
  distinguir "combinamos isto" de "estas a falar de uma coisa que nao combinamos".

E o **tecto da descompressao** nao e uma afinacao: uns poucos quilobytes de zeros
comprimidos expandem para gigabytes, e uma extensao de compressao sem tecto e uma
bomba de descompressao a espera de um atacante que sabe disto — que e toda a gente.

Oraculo: a `websockets` do Python, que oferece a extensao por omissao. O portao
mede tambem o fio em cru, porque a biblioteca entrega a mensagem ja
descomprimida e a parte que interessa nao se veria.


## 53 — um teste do corpus de oraculos tapava a biblioteca padrao do Python  OK corrigido

O `tests/oracle/py/proc.py` falhava a IMPORTAR, e o diff mostrava a saida de outro
teste no meio da dele. A causa: o directorio do script entra no `sys.path` do
Python, e ha la um `collections.py` — o par do `collections.psc`, que e um teste
legitimo sobre dicionarios e conjuntos. O `import subprocess` do `proc.py`
acabava a importar ESSE, o que executava a saida dele e depois falhava no
`namedtuple`.

So apareceu com o Python 3.13, porque foi nele que o `subprocess` passou a puxar
o `functools` no arranque — e o `functools` importa o `collections`.

O nome do ficheiro esta certo (o teste e sobre `collections`); o que estava errado
era o caminho. `PYTHONSAFEPATH=1` no arreio, e o directorio do script deixa de
entrar no `sys.path`.

## 54 — o oraculo do Unicode comparava duas bases DIFERENTES  OK corrigido

Os casos `unicat` e `unicase` perguntam a mesma coisa a duas bases de dados: a
nossa, gerada e comitada (o cabecalho de `unicat.bin` diz **15.0.0**), e a do
python3 da maquina (**15.1.0** no Python 3.13). Quando as versoes diferem, um
desacordo nao diz nada sobre o nosso codigo — diz que uma delas conhece
caracteres que a outra nao tem. O Unicode 15.1 acrescentou a extensao I do CJK, e
e exactamente ai que eles divergiam.

O arreio passa a SALTAR esses dois casos quando as versoes nao batem, **com as
duas nomeadas**. Um salto silencioso seria pior do que a falha; e uma falha por
causa da versao e ruido que ninguem consegue corrigir sem decidir primeiro qual
Unicode a linguagem segue.

**Essa decisao fica em aberto e e do dono**: subir a tabela para a 15.1 fa-la
seguir o Python desta maquina e diverge da de outra; mante-la na 15.0 e uma versao
escolhida, que e defensavel — mas entao o portao tem de dizer isso, e agora diz.
