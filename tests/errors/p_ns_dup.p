# two imports cannot claim the same alias
import "p_ns_mod.ph" as m
import "p_ns_mod2.ph" as m

def main() -> int:
    return 0
