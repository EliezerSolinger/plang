# `async` é parte da assinatura: uma dá um Task<T> e a outra dá o T, portanto
# quem escreve contra o trait escreve `await` ou não escreve. As duas têm de
# concordar, ou o sítio da chamada está errado para uma delas.
trait Src:
    async def get(self, n: int) -> int

struct Mem implements Src:
    base: int
    def get(self, n: int) -> int:
        return self.base + n

print("nunca chega aqui")
