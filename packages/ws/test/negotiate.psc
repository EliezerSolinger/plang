"""A gramatica de cabecalhos, a negociacao do permessage-deflate e a
fragmentacao de envio -- as tres sem rede nenhuma.

Sao a parte do protocolo que e uma FUNCAO PURA, e por isso o portao delas nao
precisa de portos nem de esperas: um cabecalho entra, uma decisao sai, e o que se
compara e a decisao. As mesmas pecas ligadas ao fio tem o seu portao em
`tests/ws-features.sh`.

O caso que da nome a este ficheiro e o penultimo da lista da gramatica:

    x; a="permessage-deflate"

Uma busca de subcadeia -- que era o que aqui estava -- acerta nele e conclui que o
cliente ofereceu a extensao. Nao ofereceu: ofereceu uma extensao `x` com um
parametro cujo VALOR e aquele texto. Ler a gramatica e a diferenca entre as duas
leituras, e e por isso que ela existe.
"""
import <ws/ws.psc> as ws

def show(h: str):
    print("  <" + h + ">")
    for o in ws.parse_list(h):
        s = "    item=" + o.name
        for pm in o.params:
            s += " | " + pm.name + "=" + ("<sem valor>" if len(pm.value) == 0 else pm.value)
        print(s)

print("== a gramatica ==")
show("permessage-deflate")
show("permessage-deflate; client_max_window_bits")
show("permessage-deflate; server_max_window_bits=10; client_max_window_bits=12")
show('foo; a="um, dois; tres", permessage-deflate')
show("  x ; y = 1 ,  z ")
show(",,;;")

print("== a negociacao ==")
for h in ["permessage-deflate",
          "permessage-deflate; client_max_window_bits",
          "permessage-deflate; client_max_window_bits=10",
          "permessage-deflate; server_max_window_bits=9",
          "permessage-deflate; server_max_window_bits",
          "permessage-deflate; server_max_window_bits=7",
          "permessage-deflate; algo_novo",
          "permessage-deflate; algo_novo, permessage-deflate",
          'x; a="permessage-deflate"',
          ""]:
    n = ws.negotiate(h)
    print("  <" + h + "> -> <" + n.accepted + "> ligada=" + str(n.pmd.enabled) + " sb=" + str(n.pmd.out_bits))

print("== o subprotocolo ==")
print("  ", ws.pick_token("chat, superchat", ["superchat", "chat"]))
print("  ", ws.pick_token("chat, superchat", ["chat", "superchat"]))
print("  ", "<" + ws.pick_token("nada", ["chat"]) + ">")

print("== a fragmentacao ==")
for sz in [0, 4, 100]:
    fs = ws.fragments(ws.OP_TEXT, b"abcdefghij", sz, True)
    s = "  size=" + str(sz) + ":"
    for f in fs:
        s += " [op=" + str(f.op) + " fin=" + str(f.fin) + " rsv1=" + str(f.rsv1) + " n=" + str(len(f.payload)) + "]"
    print(s)
fs2 = ws.fragments(ws.OP_BIN, b"", 4, False)
print("  vazia ->", len(fs2), "quadro(s), fin =", fs2[0].fin)

print("== ida e volta com janela apertada ==")
orig = b"abcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabc"
for bits in [8, 10, 15]:
    z = ws.compress_payload(orig, bits)
    back = ws.decompress_payload(z, 1 << 20)
    print("  bits=" + str(bits) + " comprimido=" + str(len(z)) + " igual=" + str(back == orig))
print("== a oferta do cliente, e a resposta lida de volta ==")
print("  oferta:", ws.client_offer())
for resp in ["permessage-deflate; server_no_context_takeover; client_no_context_takeover",
             "permessage-deflate; server_no_context_takeover; client_no_context_takeover; client_max_window_bits=10",
             "permessage-deflate; server_no_context_takeover",
             "permessage-deflate; client_no_context_takeover",
             "permessage-deflate",
             "permessage-deflate; server_no_context_takeover; client_no_context_takeover; algo_novo",
             ""]:
    d = ws.read_accepted(resp)
    print("  <" + resp + "> -> ligada=" + str(d.enabled) + " saida=" + str(d.out_bits)
          + " entrada=" + str(d.in_bits))
print("negotiate-ok")
