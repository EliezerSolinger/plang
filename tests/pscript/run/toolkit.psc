"""O que o par de oráculo do ferramental (104) não pode medir: o que LEVANTA.

O oráculo compara com o Python linha por linha, e uma exceção no meio dele
interromperia a comparação. Então as bordas que levantam ficam aqui, com a
mensagem que o programa vê — e, no fim, o mesmo ferramental sobre uma lista de
objetos coletados, que é onde o coletor entra.
"""

struct Cliente:
    nome: str
    saldo: int

mt: List<int> = []

try:
    print(str(min(mt)))
catch e:
    print(f"min: {e.message}")
try:
    print(str(max(mt)))
catch e:
    print(f"max: {e.message}")
try:
    print(str(mt.pop()))
catch e:
    print(f"pop: {e.message}")
try:
    print(str([1, 2].index(9)))
catch e:
    print(f"index: {e.message}")
try:
    xs = [1, 2]
    xs.remove(9)
catch e:
    print(f"remove: {e.message}")
try:
    print(str([1, 2].pop(7)))
catch e:
    print(f"pop 7: {e.message}")
try:
    d: Dict<str, int> = {}
    print(str(d.pop("nada")))
catch e:
    print(f"dict pop: {e.message}")
try:
    print("hi".index("zz"))
catch e:
    print(f"str index: {e.message}")
try:
    print("hi".center(9, "ab"))
catch e:
    print(f"center: {e.message}")
try:
    print(str(divmod(7, 0)))
catch e:
    print(f"divmod: {e.message}")
try:
    big = [9223372036854775807, 1]
    print(str(sum(big)))
catch e:
    print(f"sum: {e.message}")

# ---- e sobre objetos coletados, com o coletor no meio ----
cs = [Cliente("ana", 10), Cliente("bruno", 20), Cliente("carla", 30)]
nomes = [c.nome for c in cs]
print(nomes)
saldos = [c.saldo for c in cs]
print(sum(saldos), min(saldos), max(saldos))
cs.append(Cliente("davi", 40))
tirado = cs.pop(1)
print(tirado.nome, len(cs))
outra = cs.copy()
outra.extend(cs)
print(len(outra), outra[0].nome, outra[4].nome)
por_nome = {c.nome: c.saldo for c in cs}
print(por_nome)
copia = por_nome.copy()
copia.update({"ana": 99})
print(por_nome["ana"], copia["ana"])
nomes.sort()
print(nomes)
juntos = nomes + ["zebra"]
print(", ".join(juntos))
