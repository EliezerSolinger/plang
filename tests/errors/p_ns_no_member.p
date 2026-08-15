# a qualified name is CHECKED: the module has to declare it
import "p_ns_mod.ph" as m

def main() -> int:
    return m.nosuch()
