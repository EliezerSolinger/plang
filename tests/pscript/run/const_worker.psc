"""Um `const` CONSTRUÍDO existe dentro de um worker (148).

Um `const` cujo valor tem de ser construído — uma lista, um dicionário — vive no
conjunto do contexto (61.3), e o inicializador dele era código emitido dentro do
`main`. Portanto num WORKER ele nunca corria: a tabela ficava `None`, e o primeiro
`TABELA[i]` lá dentro era um SIGSEGV numa thread sem pilha para ler.

**Não era um caso de nicho.** Quebrava qualquer pacote com uma tabela: o
`datetime` (os nomes dos meses), o `compress` (as tabelas do DEFLATE), e o próprio
`httpd` (os nomes dos dias, no cabeçalho `Date`). E o sintoma não apontava para
lado nenhum: um servidor com quatro workers falhava uma resposta em trinta — a
primeira que cada worker formatava num segundo novo — e as outras vinte e nove
funcionavam.

Correr o inicializador de um `const` POR CONTEXTO é o certo e não um remendo: ele
é imutável, portanto N cópias são indistinguíveis de uma, e nenhuma referência
atravessa heaps (18.1). Partilhá-las seria justamente o contrário disso.

O ficheiro também prende a outra metade: um `const` que É uma constante do C
(números, um literal) continua a ser um `static`, e esse sempre funcionou. As duas
formas estão aqui lado a lado porque a diferença entre elas é o defeito.
"""

# construídos: vivem no contexto, e é destes que se trata
const DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
const PESOS = {"leve": 1, "medio": 5, "pesado": 20}
const MATRIZ = [[1, 2], [3, 4]]

# estáticos do C: um número e um literal, que sempre funcionaram
const LIMIT = 4096
const TAG = "psrt"


async def inside(k: int) -> int:
    # a leitura que era um SIGSEGV
    print("dia:", DAYS[k], "de", len(DAYS))
    print("peso:", PESOS["medio"])
    print("matriz:", MATRIZ[1][0])
    print("estaticos:", LIMIT, TAG)
    parent.send(len(DAYS) * 100 + PESOS["pesado"])
    return 0


print("no topo:", DAYS[0], PESOS["leve"], MATRIZ[0][1], LIMIT, TAG)
w = spawn(inside, (3,))
print("o worker respondeu:", await w.recv())

# e um SEGUNDO worker tem a SUA cópia: escrever nela seria impossível (é const),
# mas o ponto é que ele a tem
w2 = spawn(inside, (5,))
print("o segundo tambem:", await w2.recv())
