N = 2000000
def count_primes(n):
    sieve = [True] * (n + 1)
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
    return sum(1 for i in range(n + 1) if sieve[i])
print(count_primes(N))
