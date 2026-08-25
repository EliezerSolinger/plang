"""`log` (S8): registo estruturado sem cadeado, e o punho que teve de ser explícito.

A §4.1 do `STDLIB.md` decidiu que isto seria GLOBAL — `log.info("...")` sem passar
nada — apoiada na 42.2: uma global mutável é privada do worker, portanto cada
worker teria o seu logger sem contenção. **Não dá**, e a razão é do sistema de
módulos: um módulo IMPORTADO não pode ter estado no topo, porque um pacote é um
conjunto de definições e não um programa com ordem de execução.

Pôr o `log` no runtime para ganhar a global seria meter uma escolha de POLÍTICA
— para onde vão os registos, a partir de que nível — dentro da linguagem. O punho
custa uma palavra por chamada e torna a história dos workers visível em vez de
mágica.

**A metade boa da decisão mantém-se: não há cadeado nenhum.** Uma linha sai
inteira porque o `print` já garante isso (107.2), e um logger que escreva por
linhas herda a garantia em vez de a reconstruir.

O carimbo de tempo está desligado neste portão porque ele muda a cada corrida —
o que se prova aqui é o FORMATO.
"""
import <log/log.psc> as log


def main():
    lg = log.logger()
    lg.with_time = False

    # logfmt: aspas SÓ quando fazem falta, que é o que o torna legível a olho
    log.info(lg, "server started", "port", 8080, "tls", False)
    log.warn(lg, "slow", "ms", 1234, "ratio", 0.5)
    log.info(lg, "com espacos", "path", "/tmp/a b", "vazio", "", "igual", "a=b")
    log.info(lg, "aspas", "q", "diz \"ola\"")

    # o nível corta, e corta ANTES de formatar
    lg.level = log.WARN
    log.debug(lg, "isto nao sai")
    log.info(lg, "isto tambem nao")
    log.error_(lg, "isto sai", "why", "no disk")
    print("enabled:", log.enabled(lg, log.WARN), log.enabled(lg, log.INFO))

    # JSON por linha, para quando é uma máquina a ler
    j = log.json_logger()
    j.with_time = False
    log.info(j, "em json", "k", "v\"x", "n", 42, "b", True)

    # um par sem valor é um erro de PROGRAMA, e levanta
    try:
        log.info(lg, "impar", "so a chave")
        print("ISTO NAO DEVIA APARECER")
    catch e:
        print("impar:", e.message)

    # e dois loggers não se vêem um ao outro — que é o que o punho compra
    a = log.logger(log.DEBUG)
    a.with_time = False
    b = log.logger(log.ERROR)
    b.with_time = False
    log.debug(a, "o A fala")
    log.debug(b, "o B cala-se")

    print("log-ok")


main()
