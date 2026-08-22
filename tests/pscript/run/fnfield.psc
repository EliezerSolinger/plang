"""Função em CAMPO, e as três coisas que o porte do pui cobrou (112).

A 28.1 diz que função é valor e que valor vive em contêiner. Um campo é
contêiner, então `x.f(a)` é uma chamada quando `f` é campo de tipo função — só é
método quando o método existe. Foi o toolkit de widgets que pediu: o
comportamento do widget do app mora em campos do nó.

E duas que apareceram no mesmo dia:
  * uma lambda passada a um MÉTODO não tinha contexto (o tipo do parâmetro), só
    a passada a uma função livre tinha;
  * um `def(...)?` também é contexto — um sinal que ninguém ligou é AUSENTE, e
    por isso o campo é opcional.
"""

log: list<str> = []


struct Widget:
    name: str
    draw: def(str, int)              # campo NÃO opcional: sempre chamável
    on_click: def(int, int)?         # o sinal: ausente até alguém ligar

    def click(self, arg: int):
        # a prova de não-nulo é sobre LOCAL (43.1), então o campo sai para uma
        # variável — e a mensagem do compilador diz isso quando se esquece
        f = self.on_click
        if f != None:
            f(len(self.name), arg)

    def paint(self, n: int):
        self.draw(self.name, n)      # CAMPO chamado direto: 112

    def connect(self, fn: def(int, int)?):
        self.on_click = fn


def note(s: str):
    log.append(s)


w = Widget("botao", lambda nm, n: note("draw " + nm + " " + str(n)), None)
w.paint(3)
w.click(7)                            # sem sinal ligado: nada acontece
w.connect(lambda id, arg: note("click " + str(id) + " " + str(arg)))
w.click(7)
w.connect(None)
w.click(9)                            # desligado outra vez

# a lambda entra por um MÉTODO (o contexto é o tipo do parâmetro), e o corpo
# dela não devolve nada — um `return` de void sob a guarda de exceção era o
# defeito que isto pega
w.connect(lambda id, arg: note("again " + str(id + arg)))
w.click(1)

for line in log:
    print(line)

# uma tabela de despacho em campo: o mesmo mecanismo, dentro de um dict
handlers: dict<str, def(int, int)?> = {"a": lambda i, j: note("a"), "b": None}
ha = handlers["a"]
if ha != None:
    ha(0, 0)
hb = handlers["b"]
print("b ligado: " + str(hb != None))
print(log[len(log) - 1])
