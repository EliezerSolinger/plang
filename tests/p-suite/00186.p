include <stdio.h>

def main() -> int:
    Buf: char[100]
    Count: int

    for Count in range(1, 21):
        sprintf(Buf, "->%02d<-\n", Count)
        printf("%s", Buf)

    return 0
