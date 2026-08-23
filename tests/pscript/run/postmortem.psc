"""O POST-MORTEM: a pilha com os VALORES, e não só com os nomes (F6).

Uma pilha diz ONDE o erro aconteceu. A pergunta a seguir é sempre PORQUÊ, e é
por causa dela que se abre um depurador. Aqui ela responde-se sem depurador
nenhum: com `-g`, cada moldura imprime o que estava em cada variável.

Isto só é possível por causa da tabela de campos (F5): a pilha-sombra já
carregava as referências — o coletor precisa delas —, e o que faltava era o
TIPO de cada uma. Sem ele o runtime vê um ponteiro e não sabe se é uma lista de
inteiros ou um dicionário.

Os valores são copiados no `raise` e não no relatório, porque quando o relatório
acontece a pilha já desenrolou e não há lá nada para ler. E são copiados como
REFERÊNCIAS, com o erro a mantê-las vivas: renderizar no `raise` seria formatar
um grafo inteiro a cada erro, incluindo os que alguém usa como fluxo de
controlo.

Sem `-g` nada disto existe — nem os arrays estáticos, nem a cópia, nem uma linha
a mais no relatório.
"""

record Pt:
    x: int
    y: int

struct Caixa:
    nome: str
    pts: list<Pt>

enum Cor:
    VERDE
    AZUL

def fundo(c: Caixa, quantos: int) -> int:
    etiqueta = "no fundo"
    tags: list<str> = ["a", "b"]
    mapa: dict<str, int> = {"k": 1}
    raise error("estourou de propósito")

def meio(c: Caixa) -> int:
    quem = c.nome
    return fundo(c, 3)

c = Caixa("caixa-um", [Pt(1, 2), Pt(3, 4)])
print(meio(c))
