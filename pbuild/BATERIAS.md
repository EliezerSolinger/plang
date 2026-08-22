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
