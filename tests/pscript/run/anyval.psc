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
