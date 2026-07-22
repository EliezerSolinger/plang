include <stdio.h>

def fred() -> int:
    printf("fred\n")
    return 0

def joe() -> int:
    printf("joe\n")
    return 1

def main() -> int:
    printf("%d\n", fred() and joe())
    printf("%d\n", fred() or joe())
    printf("%d\n", joe() and fred())
    printf("%d\n", joe() or fred())
    printf("%d\n", fred() and (1 + joe()))
    printf("%d\n", fred() or (0 + joe()))
    printf("%d\n", joe() and (0 + fred()))
    printf("%d\n", joe() or (1 + fred()))
    return 0
