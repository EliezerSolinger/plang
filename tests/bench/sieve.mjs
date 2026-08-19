const N = 2000000;
function countPrimes(n) {
  const sieve = new Array(n + 1).fill(true);
  sieve[0] = false; sieve[1] = false;
  for (let i = 2; i * i <= n; i++) {
    if (sieve[i]) for (let j = i * i; j <= n; j += i) sieve[j] = false;
  }
  let c = 0;
  for (let i = 0; i <= n; i++) if (sieve[i]) c++;
  return c;
}
console.log(countPrimes(N));
