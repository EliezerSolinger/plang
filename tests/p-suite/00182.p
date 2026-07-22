include <stdlib.h>
include <stdio.h>

# Print the top line of the digit d into buffer.
def topline(d: int, p: *char) -> void:
    *p = ' '
    p += 1
    match d:
        case 0, 2, 3, 5, 7, 8, 9:
            *p = '_'
            p += 1
        case _:
            *p = ' '
            p += 1
    *p = ' '
    p += 1

# Print the middle line of the digit d into the buffer.
def midline(d: int, p: *char) -> void:
    match d:
        case 0, 4, 5, 6, 8, 9:
            *p = '|'
            p += 1
        case _:
            *p = ' '
            p += 1
    match d:
        case 2, 3, 4, 5, 6, 8, 9:
            *p = '_'
            p += 1
        case _:
            *p = ' '
            p += 1
    match d:
        case 0, 1, 2, 3, 4, 7, 8, 9:
            *p = '|'
            p += 1
        case _:
            *p = ' '
            p += 1

# Print the bottom line of the digit d. Does not null terminate.
def botline(d: int, p: *char) -> void:
    match d:
        case 0, 2, 6, 8:
            *p = '|'
            p += 1
        case _:
            *p = ' '
            p += 1
    match d:
        case 0, 2, 3, 5, 6, 8:
            *p = '_'
            p += 1
        case _:
            *p = ' '
            p += 1
    match d:
        case 0, 1, 3, 4, 5, 6, 7, 8, 9:
            *p = '|'
            p += 1
        case _:
            *p = ' '
            p += 1

# Write the led representation of integer to string buffer.
def print_led(x: unsigned long, buf: *char) -> void:
    i: int = 0
    n: int
    d: int[32]

    # 0 is a digit, hence a special case
    n = 1 if x == 0 else 0

    while x:
        d[n] = int(x % 10)
        n += 1
        if n >= 32:
            break
        x = x / 10

    # print top lines of all digits
    for i in range(n - 1, -1, -1):
        topline(d[i], buf)
        buf += 3
        *buf = ' '
        buf += 1
    *buf = '\n'
    buf += 1

    # print middle lines of all digits
    for i in range(n - 1, -1, -1):
        midline(d[i], buf)
        buf += 3
        *buf = ' '
        buf += 1
    *buf = '\n'
    buf += 1

    # print bottom lines of all digits
    for i in range(n - 1, -1, -1):
        botline(d[i], buf)
        buf += 3
        *buf = ' '
        buf += 1
    *buf = '\n'
    buf += 1
    *buf = '\0'

def main() -> int:
    buf: char[160]
    print_led(1234567, buf)
    printf("%s\n", buf)

    return 0
