struct W:
    draw: def(str, int)

w = W(lambda s, n: print(s))
w.draw("a")
