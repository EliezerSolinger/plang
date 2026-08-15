def named() -> (str, int):
    return ("answer", 42)
print(str(named() == named()))
