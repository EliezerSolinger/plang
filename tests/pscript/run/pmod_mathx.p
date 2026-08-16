# the code behind pmod_mathx.ph — plain P, with no idea who calls it
import "pmod_mathx.ph"

def mathx_add(a: i64, b: i64) -> i64:
    return a + b

def mathx_scaled(v: i64, s: i32) -> i64:
    return v * i64(s)

def mathx_is_even(v: i64) -> bool:
    return v % 2 == 0
