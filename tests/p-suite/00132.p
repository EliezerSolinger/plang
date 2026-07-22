include <stdio.h>

def main() -> int:
    printf("Hello world\n")
    Count: int
    for Count in range(-5, 6):
        printf("Count = %d\n", Count)
    printf("String 'hello', 'there' is '%s', '%s'\n", "hello", "there")
    printf("Character 'A' is '%c'\n", 65)
    printf("Character 'a' is '%c'\n", 'a')
    return 0
