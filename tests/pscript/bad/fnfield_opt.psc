struct W:
    on: def(int, int)?

    def go(self):
        self.on(1, 2)

w = W(None)
w.go()
