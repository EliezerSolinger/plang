# A call to a function defined further DOWN is an ordering problem, not a
# missing name. The diagnostic has to point at the definition and say what to do
# about it; `p_implicit_call` covers the genuinely-unknown case, which must keep
# reporting C's implicit-declaration wording.
def uses() -> i32:
    return after(3)

def after(x: i32) -> i32:
    return x * 2

def main() -> int:
    return uses()
