# a record is pure bytes: a pointer field is the one thing it cannot hold
record Bad:
    id: i32
    name: const *char
