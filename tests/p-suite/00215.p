include <stdio.h>

def kb_wait_1() -> void:
    timeout: unsigned long = 2
    do:
        if 1:
            printf("timeout=%ld\n", timeout)
        else:
            while 1:
                printf("error\n")
        timeout -= 1
    while timeout

def kb_wait_2() -> void:
    timeout: unsigned long = 2
    do:
        if 1:
            printf("timeout=%ld\n", timeout)
        else:
            while 1:
                printf("error\n")
        timeout -= 1
    while timeout

def kb_wait_2_1() -> void:
    timeout: unsigned long = 2
    do:
        if 1:
            printf("timeout=%ld\n", timeout)
        else:
            do:
                printf("error\n")
            while 1
        timeout -= 1
    while timeout

def kb_wait_2_2() -> void:
    timeout: unsigned long = 2
    do:
        if 1:
            printf("timeout=%ld\n", timeout)
        else:
            label:
            printf("error\n")
            goto label
        timeout -= 1
    while timeout

def kb_wait_3() -> void:
    timeout: unsigned long = 2
    do:
        if 1:
            printf("timeout=%ld\n", timeout)
        else:
            i: int = 1
            goto label
            i = i + 2
            label:
            i = i + 3
        timeout -= 1
    while timeout

def kb_wait_4() -> void:
    timeout: unsigned long = 2
    do:
        if 1:
            printf("timeout=%ld\n", timeout)
        else:
            match timeout:
                case 2:
                    printf("timeout is 2")
                case 1:
                    printf("timeout is 1")
                case _:
                    printf("timeout is 0?")
        timeout -= 1
    while timeout

def main() -> int:
    printf("begin\n")
    kb_wait_1()
    kb_wait_2()
    kb_wait_2_1()
    kb_wait_2_2()
    kb_wait_3()
    kb_wait_4()
    printf("end\n")
    return 0
