# 118: at the top `private` is the spelling; `static` is left to the static
# method inside a struct, which is why the message says where it still means
# something.
static def hidden() -> int:
    return 1

print(hidden())
