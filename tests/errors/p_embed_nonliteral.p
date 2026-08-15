# the path must be a literal: embed runs before there is any notion of scope
P: const *char = "x.txt"
X: const *char = embed(P)
