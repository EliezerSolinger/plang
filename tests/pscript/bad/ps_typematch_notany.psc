# `match type(x)` asks what an `any` holds; a value with a static type has
# nothing to ask
n = 5
match type(n):
    case int:
        print("no")
