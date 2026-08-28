"""`import "x.ph"` DENTRO de um módulo importado (1.5d).

O programa não menciona nenhum módulo P: ele importa `lib_bottom`, e é o
`lib_bottom` que importa `"pmod_bottom.ph"`. Até a 1.5(d) isso era honrado pela
metade — as declarações entravam, o `#include` saía no C, e o `.p` não era
compilado: o link falhava, e quem construía compensava nomeando o arquivo à mão
(era o que o alvo `pstudio` do Makefile fazia com o `hl.p`).

Agora a varredura é do FECHAMENTO: o compilador segue os imports de módulo,
acha os `import "x.ph"` de cada um, e puxa o `.p` irmão. Uma consequência que se
mede: a lista de arquivos que o descritor do editor precisava nomear caiu de
dezanove para dois — e os dois que ficaram não são falha de fechamento, são
`plang.ph` declarando o que `util.p` implementa, dois nomes sem aresta entre si.

Isto vale também para a resposta 3 do protocolo (`--outputs`), e tem de valer
SEM rodar a sema: um sistema de build pergunta o que vai ser emitido antes de
mandar emitir.
"""
import lib_bottom

print("dobro:", lib_bottom.double_v(21))
print("impar:", lib_bottom.odd(7), lib_bottom.odd(8))

sum_v = 0
for i in range(4):
    sum_v += lib_bottom.double_v(i)
print("soma:", sum_v)
