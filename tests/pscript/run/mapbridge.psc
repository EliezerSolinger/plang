"""A ponte da 138: um `Mapping` atravessa para P sem cópia e sem fixação.

> *"o P também poderia ter um mapa de memória, que funcione lá, e não sei como
> casaria com o mapa do PScript"*

A resposta é que **já estavam casadas**. Em P um mapa não precisa de tipo novo
nenhum — é um ponteiro e um tamanho — e o `CBytes` (84.1) é literalmente *"um
struct de exactamente um ponteiro e um tamanho"*.

O que torna um `Mapping` o MELHOR valor possível para atravessar essa fronteira
é a propriedade que ele já tem por construção: **está fora do monte e nunca se
move**. Um `List<u8>` coletado, para ir para P, ou copia ou precisa de ser
fixado; um `Mapping` não precisa de nada.

E o `in` diz o resto: os bytes são EMPRESTADOS e valem durante a chamada (141.5).
A costura é assimétrica de propósito — o pscript pode segurar coisas do P, e o P
não pode segurar coisas do pscript.

**E uma correcção à palavra "só de leitura", que este ficheiro deixava passar
como garantia** (161.1): o `const` no `ptr` de um `CBytes` é conferido deste lado
e não imposto do outro. O P é a camada sem rede — tem ponteiros crus e tem
conversões — e `(*u8)(b.ptr)` são duas linhas que escrevem. Medido, e num
`bytes`, que é imutável DENTRO do pscript.

Isso não é um furo que alguém deixou aberto: é o que "o P fala com o C sem
runtime" quer dizer, levado até ao fim. Uma linguagem que chama `memcpy` não
consegue prometer a ninguém que uns bytes não mudam. O que a 161 acrescenta não é
uma capacidade nova — é um NOME para a que já existia, mais a única coisa que a
conversão nunca deu: o compilador recusa construí-lo sobre o que é imutável.
"""
import os
import path
import "pmod_bridge.ph"


D: str = "brdemo"


async def go() -> int:
    if not path.isdir(D):
        os.makedirs(D)
    target_s = path.join(D, "dados.bin")
    f = await open(target_s, "w")
    await f.write("abcdefghij")
    await f.close()

    with os.mmap(target_s) as m:
        # o ficheiro inteiro, visto de P — e nenhum byte foi copiado para lá
        print("do P:", bridge_len(m[:]), bridge_sum(m[:]))
        # ... e uma REGIÃO dele, que também é só um par
        print("uma janela:", bridge_len(m[2:5]), bridge_sum(m[2:5]))
        # duas janelas iguais comparam iguais do lado de lá
        print("compara:", bridge_eq(m[0:3], m[0:3]), bridge_eq(m[0:3], m[1:4]))

    # e o mesmo caminho serve um `bytes` que NÃO veio de um mapa: o P não vê
    # diferença nenhuma, porque não há nenhuma para ver
    b = "abcdefghij".encode()
    print("de um bytes:", bridge_len(b), bridge_sum(b))
    return 0


await go()
print("mapbridge-ok")
