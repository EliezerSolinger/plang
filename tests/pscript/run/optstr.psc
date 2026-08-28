"""`T?` escrito (9.4/97): o valor que lá está, ou a palavra `None`.

Isto era um buraco com uma forma estranha: um `T?` DENTRO de uma lista já saía
escrito — a lista é percorrida pelo runtime, guiado pela tabela de tipos —, mas
`str(x)` e `f"{x}"` sobre o mesmo valor **não compilavam**. O mesmo valor tinha
forma escrita num sítio e não tinha no outro, e a única razão era que ninguém
tinha ligado os dois caminhos.

O que fecha o buraco são duas peças:

* **no compilador**, o `T?` rende-se pela pergunta que a linguagem já faz — o
  `!= None` da 43.1 — e as duas metades do ternário são o valor e a palavra;
* **no runtime**, uma espécie nova no descritor (`PS_T_OPT`), porque é o runtime
  quem percorre um contentor e ele precisava de saber ler as DUAS representações
  da 9.4: a referência nua e o registo `{has, v}`.

E há um terceiro pedaço, que este ficheiro é o único a cobrar: a CHAVE com que um
tipo pede o seu descritor. Ela vinha do `sh_mangle`, que respondia `"v"` a
qualquer opcional — de modo que `List<str?>` e `List<int?>` pediam o mesmo
descritor e o primeiro a ser emitido servia os dois. Enquanto o opcional era
opaco isso não se via; com uma espécie que carrega `inner` e `width`, passa a
ser a diferença entre ler um ponteiro e ler um inteiro. As duas listas ao lado
uma da outra são o teste.

O texto é o de Python, em toda a linha — é a mesma escolha da 97.
"""

def main():
    # ---- 1. o topo: `str()` e a f-string, que era o que não compilava ----
    a: str? = None
    b: str? = "oi"
    i: int? = None
    j: int? = 42
    f: float? = 3.5
    t: bool? = True
    print(str(a), str(b), str(i), str(j))
    print(f"{a} {b} {i} {j} {f} {t}")

    # a largura aplica-se ao TEXTO, que é a única regra que serve aos dois lados
    # do `?`: vazio e cheio alinham na mesma coluna
    print(f"[{a:>6}][{j:>6}]")

    # ---- 2. as DUAS listas, que é o caso da chave ----
    ss: List<str?> = [None, "z", None]
    ns: List<int?> = [1, None, 3]
    print(ss)
    print(ns)
    print(f"{ss} {ns}")

    # ---- 3. dentro de um dicionário, nas duas posições que ele tem ----
    d: Dict<str, int?> = {"k": None, "m": 7}
    print(d)

    # ---- 4. num campo, que é o caminho do descritor do tipo ----
    p: Pessoa = Pessoa("Ana", None, 3)
    q: Pessoa = Pessoa("Rui", "rui@exemplo.pt", None)
    print(p)
    print(q)
    print(f"{p}")

    # ---- 5. aninhado: um opcional de contentor NÃO é o contentor vazio ----
    lv: List<int>? = None
    lc: List<int>? = [1, 2]
    print(f"{lv} {lc}")
    nn: List<List<int>?> = [None, [7]]
    print(nn)

struct Pessoa:
    nome: str
    email: str?
    idade: int?

main()
