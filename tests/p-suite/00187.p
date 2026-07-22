include <stdio.h>

def main() -> int:
    f: *FILE = fopen("fred.txt", "w")
    fwrite("hello\nhello\n", 1, 12, f)
    fclose(f)

    freddy: char[7]
    f = fopen("fred.txt", "r")
    if fread(freddy, 1, 6, f) != 6:
        printf("couldn't read fred.txt\n")

    freddy[6] = '\0'
    fclose(f)

    printf("%s", freddy)

    InChar: int
    ShowChar: char
    f = fopen("fred.txt", "r")
    while True:
        InChar = fgetc(f)
        if InChar == EOF:
            break
        ShowChar = InChar
        if ShowChar < ' ':
            ShowChar = '.'

        printf("ch: %d '%c'\n", InChar, ShowChar)
    fclose(f)

    f = fopen("fred.txt", "r")
    while True:
        InChar = getc(f)
        if InChar == EOF:
            break
        ShowChar = InChar
        if ShowChar < ' ':
            ShowChar = '.'

        printf("ch: %d '%c'\n", InChar, ShowChar)
    fclose(f)

    f = fopen("fred.txt", "r")
    while fgets(freddy, sizeof(freddy), f) != None:
        printf("x: %s", freddy)

    fclose(f)

    return 0
