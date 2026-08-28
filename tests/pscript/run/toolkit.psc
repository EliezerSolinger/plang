"""O que o par de oráculo do ferramental (104) não pode medir: o que LEVANTA.

O oráculo compara com o Python linha por linha, e uma exceção no meio dele
interromperia a comparação. Então as bordas que levantam ficam aqui, com a
mensagem que o programa vê — e, no fim, o mesmo ferramental sobre uma lista de
objetos coletados, que é onde o coletor entra.
"""

struct Customer:
    name_s: str
    balance: int

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
cs = [Customer("ana", 10), Customer("bruno", 20), Customer("carla", 30)]
names = [c.name_s for c in cs]
print(names)
balances = [c.balance for c in cs]
print(sum(balances), min(balances), max(balances))
cs.append(Customer("davi", 40))
taken = cs.pop(1)
print(taken.name_s, len(cs))
other = cs.copy()
other.extend(cs)
print(len(other), other[0].name_s, other[4].name_s)
by_name = {c.name_s: c.balance for c in cs}
print(by_name)
copy_v = by_name.copy()
copy_v.update({"ana": 99})
print(by_name["ana"], copy_v["ana"])
names.sort()
print(names)
together = names + ["zebra"]
print(", ".join(together))
