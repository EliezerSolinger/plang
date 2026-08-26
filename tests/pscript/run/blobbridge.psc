"""O blob PARTILHADO: um array plano que os dois lados escrevem (161).

> *"como um código P e um código PScript podem gerir um mesmo blob de bytes?
> digo um manipular dos dois lados"*

A peça já existia e chama-se `Buffer`. O que faltava era a porta.

**Porque é que é o `Buffer` e não outra coisa.** Ele é `calloc`'d — header e
bytes — e vive fora do monte coletado, porque a 19.4/52.3 o construiu assim para
outra thread poder segurar o ponteiro. **Não se mexe.** Uma colheita a meio da
chamada não lhe toca, o que faz dele a travessia mais segura das quatro: mais do
que um `List<u8>`, cujo armazenamento o coletor possui E move.

**E o que o `CBuf` recusa é o que o torna melhor do que a conversão que
substitui.** Um `bytes` é imutável por contrato; um `List<u8>` move-se. Antes da
161 escrevia-se nos dois com um `(*u8)(b.ptr)` de duas linhas, sem ninguém se
queixar. Agora a assinatura diz o que se quer, e o compilador recusa dá-lo sobre
o que não devia ser escrito.

Zero cópias nos dois sentidos: é o mesmo bloco.
"""
import "pmod_blob.ph"


with Buffer(4) as buf:
    v = buf.view_u8()
    v[0] = u8(1)
    v[1] = u8(2)
    v[2] = u8(3)
    v[3] = u8(4)

    # ---- 1. o P LÊ o buffer do pscript ----
    print("o P le:", blob_soma(buf))

    # ---- 2. ... e ESCREVE nele, que é o que a 161 abriu ----
    blob_dobra(buf)
    print("o P escreveu:", int(v[0]), int(v[1]), int(v[2]), int(v[3]))

    # ---- 3. uma VISTA também atravessa: é uma janela do mesmo bloco ----
    blob_enche(v, 7)
    print("por uma vista:", int(v[0]), int(v[3]))

    # ---- 4. e o pscript continua a ver o mesmo, porque É o mesmo ----
    v[0] = u8(100)
    print("e o pscript escreve de volta:", blob_soma(buf))
