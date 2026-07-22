# Generic free functions: def foo<T>(...). Monomorphized explicitly (C has no
# overloading) via declare/implement, like generic structs; the call infers the
# type args from the arguments (unification: T, *T, nested). Same code for many T.
include <stdio.h>

struct Pt:
    x: i32
    y: i32

def maxv<T>(a: T, b: T) -> T:
    return a if a > b else b

def first<T>(p: *T) -> T:          # infers T from a *T argument
    return *p

def pick<K, V>(k: K, v: V) -> V:   # two type parameters
    return v if k > 0 else v

def snd<T>(a: T, b: T) -> T:       # works with a struct-by-value T
    return b

declare maxv<int>
implement maxv<int>
declare maxv<double>
implement maxv<double>
declare first<int>
implement first<int>
declare pick<int, double>
implement pick<int, double>
declare snd<Pt>
implement snd<Pt>

def main() -> int:
    printf("%d\n", maxv(3, 7))          # 7
    printf("%.1f\n", maxv(2.5, 1.5))    # 2.5
    n: int = 42
    printf("%d\n", first(&n))           # 42 (infers T=int from *int)
    printf("%.1f\n", pick(1, 9.5))      # 9.5
    a: Pt = {1, 2}
    b: Pt = {3, 4}
    r: Pt = snd(a, b)                   # struct by value
    printf("%d %d\n", r.x, r.y)         # 3 4
    return 0
