# a record is pure bytes (58.2), and a struct is a collected reference (20.1)
struct Node:
    value: int


record Holder:
    n: Node
