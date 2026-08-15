# a qualified TYPE is checked the same way a qualified value is
import "p_ns_mod.ph" as m

def main() -> int:
    v: m.NoType
    return 0
