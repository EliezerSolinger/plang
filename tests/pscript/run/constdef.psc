"""`const def` (65.10): uma função avaliada em COMPILAÇÃO.

> *"Zero runtime, e o pscript já vai precisar dela para f-string e para `T[N]`."*

A promessa é **"isto não existe em tempo de execução"**, e é por isso que o
avaliador tem de ser total sobre o que aceita: ou devolve um literal, ou dá um
erro com uma posição. **Nunca cai para uma chamada.** Uma que caísse tornaria a
promessa num acaso — a função passaria a existir ou não conforme os argumentos, e
ninguém saberia qual dos dois sem ler o C gerado.

O `const` já estava na linguagem e já queria dizer *conhecido em compilação*;
pô-lo à frente do `def` diz a mesma coisa da função e não custa palavra nova.

**O que ele computa são números e booleanos**, com `if`, `while`,
`for i in range(...)`, locais, e chamadas a outros `const def`. O texto ainda
não, e é uma recusa e não um esquecimento: o `text` de um literal é a GRAFIA da
fonte — aspas e escapes — e devolver um literal novo exigiria reconstruí-la ao
contrário, que é onde um escape mal posto vira um valor diferente sem ninguém dar
por isso.

**A divisão é a do Python** (39.1) e não a do C, e isto tem de ser dito porque é
a diferença entre uma constante certa e uma constante errada: em C o `-7 / 2`
trunca para -3 e o resto fica negativo; aqui o piso é -4 e o resto tem o sinal do
divisor, exactamente como em tempo de execução. Uma constante que mudasse de
valor por ser dobrada seria pior do que não haver dobra nenhuma.
"""


const def double_v(x: int) -> int:
    return x * 2


const def fact(n: int) -> int:
    r = 1
    for i in range(2, n + 1):
        r *= i
    return r


const def fib(n: int) -> int:
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)


const def kib(n: int) -> int:
    return n * 1024


const N: int = 8


# ... e um `const` do módulo é conhecido em compilação por definição, portanto
# vê-se de dentro sem ser passado
const def double_of_N() -> int:
    return double_v(N)


print(double_v(21), fact(10), fib(20), kib(4), double_of_N())

# o caso que a 65.10 nomeou ao ser decidida: o tamanho de um `T[N]`
buf: int[double_v(4)] = [1, 2, 3, 4, 5, 6, 7, 8]
print("o array tem", len(buf), "e o ultimo e", buf[7])

# a aritmética, e o piso e o resto do PYTHON
print(2 ** 10, 7 // 2, -7 // 2, 7 % 3, -7 % 3, 7 / 2)
print(double_v(3) < fact(3), min(fib(10), 50), abs(double_v(-4)))
