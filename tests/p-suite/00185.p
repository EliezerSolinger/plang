include <stdio.h>

def main() -> i32:
    Array: i32[10] = { 12, 34, 56, 78, 90, 123, 456, 789, 8642, 9753 }
    Count: i32 = 0
    while Count < 10:
        printf("%d: %d\n", Count, Array[Count])
        Count += 1
    Array2: i32[10] = { 12, 34, 56, 78, 90, 123, 456, 789, 8642, 9753, }
    Count = 0
    while Count < 10:
        printf("%d: %d\n", Count, Array2[Count])
        Count += 1
    return 0
