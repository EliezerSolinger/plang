"""A sieve: list indexing and a tight loop over a big collection.

Each loop uses its own name on purpose. 64.1 says a name born in a block dies
with it and `for` does not leak its variable — but the CHECKER still counts the
loop variable as belonging to the function, so `for i in ...` followed by `i = 2`
is refused as a redefinition. The rule and the check disagree; noted in
pscript/PLAN.md rather than worked around silently."""

N: int = 2000000


def count_primes(n: int) -> int:
    sieve: List<bool> = []
    for f in range(n + 1):
        sieve.append(True)
    sieve[0] = False
    sieve[1] = False
    i = 2
    while i * i <= n:
        if sieve[i]:
            j = i * i
            while j <= n:
                sieve[j] = False
                j += i
        i += 1
    c = 0
    for k in range(n + 1):
        if sieve[k]:
            c += 1
    return c


print(count_primes(N))
