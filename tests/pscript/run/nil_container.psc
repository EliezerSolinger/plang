"""Um contentor AUSENTE levanta, e não corrompe (148).

Uma global é do WORKER (42.2), e o worker não corre o topo do programa — portanto
uma global `List<int> = []` é `None` lá dentro, e não uma lista vazia. Indexá-la
era um `l->len` no endereço zero: SIGSEGV numa thread sem pilha para ler, que é o
pior sítio possível para um defeito de programa.

Agora levanta, e a mensagem diz a coisa que a pessoa precisa de saber — não
"ponteiro nulo", mas *porque* é que ele está nulo, e o que fazer.

Note-se onde a verificação NÃO pôde ficar: o `ps_list_base`. Um `xs[i] = v` sai
como `base(xs)[at(ctx, xs, i)] = v`, e o C não define qual dos dois corre primeiro
— se o `base` corresse antes, o acesso ao endereço zero acontecia antes de o `at`
ter a chance de levantar. Portanto quem levanta é o `at` (que tem contexto e
posição), e o `base` devolve um sítio seguro para a escrita ir morrer. É o mesmo
padrão que o índice fora de limites já usava.

Isto é diferente do `const` do ficheiro ao lado: um `const` PASSA a existir no
worker, porque o inicializador dele corre em cada contexto. Uma global MUTÁVEL
não — ela nasce no seu valor por omissão, que é o que a 42.2 promete, e é por isso
que a mensagem aponta para lá.
"""

xs: List<int> = [1, 2, 3]
ds: Dict<str, int> = {"a": 1}


async def inside(k: int) -> int:
    try:
        xs[0] = 5
        print("ERRO: devia ter levantado")
    catch e:
        print("indexar:", e.message[:46])
    try:
        ds["b"] = 2
        print("ERRO: devia ter levantado")
    catch e:
        print("dicionario:", e.message[:46])
    try:
        xs.append(9)
        print("ERRO: devia ter levantado")
    catch e:
        print("append:", e.message[:46])
    # o `len` de um ausente é zero, e essa é a única saída: a função não tem
    # contexto para levantar e é chamada de dentro de laços. Quem o USA levanta.
    print("len:", len(xs), len(ds))
    parent.send(1)
    return 0


# no topo elas EXISTEM, que é o outro lado da mesma regra
print("no topo:", xs[0], ds["a"], len(xs))
w = spawn(inside, (1,))
print("o worker acabou:", await w.recv())
