include <stdio.h>
include <wchar.h>

def main() -> i32:
    s: *wchar_t = L"wide"
    c: wchar_t = L'Z'
    arr: wchar_t[8] = L"café"
    printf("len=%zu c=%d arr0=%d arr3=%d\n", wcslen(s), c, arr[0], arr[3])
    return 0
