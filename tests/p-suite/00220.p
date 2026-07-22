include <stdio.h>
include <wchar.h>

def main() -> i32:
    s: wchar_t[] = L"hello$$你好¢¢世界€€world"
    p: *wchar_t = s
    while *p != 0:
        printf("%04X ", u32(*p))
        p += 1
    printf("\n")
    return 0
