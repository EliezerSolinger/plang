# a `match type` case is one of the kinds an `any` holds
v: any = 1
match type(v):
    case buffer:
        print("no")
