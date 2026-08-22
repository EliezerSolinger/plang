# 118: `static` no longer spells privacy — `private` does. The word stays a
# keyword (C's `T x[static N]` declarator needs it), so old code gets a message
# instead of silently turning `static` into an identifier.
static def helper(n: i32) -> i32:
    return n * 2
