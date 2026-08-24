"""`match type(x)` (68.5): the question `as` enforces, asked instead.

The subject is an `any`, the cases are the kinds it can hold, and inside each
case the subject IS that type — no `as`, no second check written by hand. The
device is P's own (`match type(x)` exists there for compile-time dispatch);
here the tag lives in the object's header, which is the same tag `as` checks.
"""

import json


def describe(v: any) -> str:
    match type(v):
        case int:
            return f"int {v * 2}"
        case float:
            return f"float {v + 0.5}"
        case str:
            return f"str {len(v)} chars"
        case bool:
            return "yes" if v else "no"
        case List:
            return f"list of {len(v)}"
        case None:
            return "nothing"
        case _:
            return "something else"


values: List<any> = [21, 2.0, "hello", True, [1, 2, 3], None]
i = 0
while i < len(values):
    print(describe(values[i]))
    i += 1

# straight from a parsed document, which is where the question comes up (41.1)
doc = json.parse("{\"n\": 7, \"name\": \"x\"}") as Dict<str, any>
match type(doc["n"]):
    case int:
        print("n is an int")
    case _:
        print("n is not an int")
