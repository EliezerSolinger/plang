"""`any` (39.2) and `as` (55.2).

`any` is one pointer to an object whose HEADER says what it is — narrow on
purpose, because that is what lets it be the same size as every other reference.
A `str`, a `list` or a `dict` already is such an object, so it goes in as
itself: nothing is wrapped and nothing is copied. A number, a bool or None gets
a box, which is what the header buys.

Reading it back is `as`, and `as` is CHECKED: the tag has to agree or it raises,
with a message that says what the value really was. Converting between numbers
is a different operation with a different name (`int(x)`).
"""

values: List<any> = [1, 2.5, True, "text", None]

print("count", len(values))
print("int", values[0] as int)
print("float", values[1] as float)
print("bool", values[2] as bool)
print("str", values[3] as str)

# `is` is IDENTITY (22.2): the same object, not an equal one
same = values
print("identity", same is values, values[3] is values[3])

try:
    n = values[3] as int
    print("unreachable", n)
catch e:
    print("caught:", e.message)

# a dict of `any` is what a parsed document looks like (41.1)
doc: Dict<str, any> = {"name": "smallpt", "samples": 16, "gamma": 2.2}
print("doc", doc["name"] as str, doc["samples"] as int, doc["gamma"] as float)

nested: List<any> = [[1, 2], "x"]
inner = nested[0] as List<any>
print("nested", len(inner), inner[1] as int)

# bytes num any (o BLOB de um banco, o binário de um protocolo). É objeto com
# header, como str, então entra como si mesmo e sai por `as bytes`, checado.
blob: any = b"\x00\x01\xff data"
gotb = blob as bytes
print("bytes", gotb.hex(), gotb == b"\x00\x01\xff data")
mixed: List<any?> = []
bv: any = b"row-blob"
mixed.append(bv)
iv: any = 7
mixed.append(iv)
mixed.append(None)
m0 = mixed[0]
if m0 != None:
    print("frombytes", str(m0 as bytes))
# a tag errada levanta, como para os outros
try:
    bad = blob as str
    print("unreachable-bytes")
catch e:
    print("bytes-tag-caught")

# `match type(x)` reconhece bytes, como reconhece str
def kindof(v: any) -> str:
    match type(v):
        case bytes:
            return "bytes"
        case str:
            return "str"
        case int:
            return "int"
        case _:
            return "other"

kb: any = b"xy"
ks: any = "xy"
ki: any = 9
print("kindof", kindof(kb), kindof(ks), kindof(ki))
