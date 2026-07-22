include <stdio.h>

struct wchar:
    data: *char
    mem: char[1]

struct wint:
    data: *char
    mem: int[1]

def f1char() -> int:
    s: char[9] = "nonono"
    q: wchar = {"bugs"}
    return not s[0]

def f1int() -> int:
    s: char[9] = "nonono"
    q: wint = {"bugs"}
    return not s[0]

def main() -> int:
    s: char[9] = "nonono"
    if f1char() or f1int():
        printf("bla\n")
    return not s[0]
