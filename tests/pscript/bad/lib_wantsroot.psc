# an import fixture: it reaches for a name that only the program declares, which
# is exactly what a namespace has to refuse
def peek() -> int:
    return root_helper()
