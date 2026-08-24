"""O repr derivado (44.3) e o de contêiner (97), que é o mesmo `str`.

Uma string DENTRO de qualquer coisa sai com aspas — `Named(label='origin')`,
`['a', 'b']` — e no topo `print(s)` é a string. O motivo é que `['a, b']` e
`['a', 'b']` imprimem igual sem as aspas, e uma das duas é mentira. Qual aspa
segue a regra do Python (simples, salvo quando a string tem simples e não tem
dupla), para que um par de oráculo compare caractere por caractere.

O contêiner vazio segue o Python inclusive na assimetria: `[]`, `{}` para dict e
`set()` para conjunto — que é a única grafia que volta como ela mesma.
"""

enum Color:
    RED
    GREEN
    BLUE

record Pt:
    x: int
    y: int

record Line:
    a: Pt
    b: Pt
    tint: Color

struct Named:
    label: str
    at: Pt

struct Money:
    cents: int
    def to_str(self) -> str:
        return "$" + str(self.cents // 100)

def main():
    p = Pt(1, 2)
    print(p)
    print(Line(Pt(0, 0), Pt(3, 4), BLUE))
    print(GREEN)
    n = Named("origin", p)
    print(n)
    print(Money(250))
    print("value:", p, "and", RED)
    print(f"in a string: {p} / {BLUE} / {Money(99)}")
    print(str(p) == "Pt(x=1, y=2)")

    # ---- contêineres (97) ----
    xs = [1, 2, 3]
    print(xs)
    print(["ada", "it's", "a \"b\""])
    d: Dict<str, int> = {"a": 1, "bb": 22}
    print(d)
    st: Set<int> = {3, 1}
    print(st)
    print([1.5, 2.0])

    # os três vazios, e a assimetria do Python entre eles
    empty: List<int> = []
    ed: Dict<str, int> = {}
    print(empty, ed, Set<int>())

    # aninhado: o adaptador de `List<int>` é chamado pelo de `Dict<str,
    # List<int>>`, e é por isso que a lista de adaptadores está fechada antes de
    # qualquer corpo ser escrito
    print([[1, 2], [3]])
    dl: Dict<str, List<int>> = {"a": [1, 2], "b": []}
    print(dl)
    print([{1}, {2, 3}])

    # e um struct com campo de contêiner e campo de string, que é onde as duas
    # metades desta bateria se encontram
    print(Named("origin", p))
    print([Named("a", p)])
    print(f"na f-string: {xs} / {d}")
    print(str(xs) == "[1, 2, 3]", len(str(d)))
main()
