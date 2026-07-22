include <stdio.h>
include <stdlib.h>

const N: int = 4

# These are the three towers.
A: int[4]
B: int[4]
C: int[4]

# Print the current configuration of A, B, and C to the screen
def PrintAll() -> void:
    i: int

    printf("A: ")
    for i in range(0, N):
        printf(" %d ", A[i])
    printf("\n")

    printf("B: ")
    for i in range(0, N):
        printf(" %d ", B[i])
    printf("\n")

    printf("C: ")
    for i in range(0, N):
        printf(" %d ", C[i])
    printf("\n")
    printf("------------------------------------------\n")
    return

# Move the leftmost nonzero element of source to dest, leave behind 0.
def Move(source: *int, dest: *int) -> int:
    i: int = 0
    j: int = 0

    while i < N and source[i] == 0:
        i += 1
    while j < N and dest[j] == 0:
        j += 1

    dest[j - 1] = source[i]
    source[i] = 0
    PrintAll()
    return dest[j - 1]

# Moves first n nonzero numbers from source to dest using the rules of Hanoi.
def Hanoi(n: int, source: *int, dest: *int, spare: *int) -> void:
    if n == 1:
        Move(source, dest)
        return

    Hanoi(n - 1, source, spare, dest)
    Move(source, dest)
    Hanoi(n - 1, spare, dest, source)
    return

def main() -> int:
    i: int

    # initialize the towers
    for i in range(0, N):
        A[i] = i + 1
    for i in range(0, N):
        B[i] = 0
    for i in range(0, N):
        C[i] = 0

    printf("Solution of Tower of Hanoi Problem with %d Disks\n\n", N)

    # Print the starting state
    printf("Starting state:\n")
    PrintAll()
    printf("\n\nSubsequent states:\n\n")

    # Do it! Use A = Source, B = Destination, C = Spare
    Hanoi(N, A, B, C)

    return 0
