include <stdio.h>

array: int[16]

# Swap integer values by array indexes
def swap(a: int, b: int) -> void:
    tmp: int = array[a]
    array[a] = array[b]
    array[b] = tmp

# Partition the array into two halves and return the
# index about which the array is partitioned
def partition(left: int, right: int) -> int:
    pivotIndex: int = left
    pivotValue: int = array[pivotIndex]
    index: int = left
    i: int

    swap(pivotIndex, right)
    for i in range(left, right):
        if array[i] < pivotValue:
            swap(i, index)
            index += 1
    swap(right, index)

    return index

# Quicksort the array
def quicksort(left: int, right: int) -> void:
    if left >= right:
        return

    index: int = partition(left, right)
    quicksort(left, index - 1)
    quicksort(index + 1, right)

def main() -> int:
    i: int

    array[0] = 62
    array[1] = 83
    array[2] = 4
    array[3] = 89
    array[4] = 36
    array[5] = 21
    array[6] = 74
    array[7] = 37
    array[8] = 65
    array[9] = 33
    array[10] = 96
    array[11] = 38
    array[12] = 53
    array[13] = 16
    array[14] = 74
    array[15] = 55

    for i in range(0, 16):
        printf("%d ", array[i])

    printf("\n")

    quicksort(0, 15)

    for i in range(0, 16):
        printf("%d ", array[i])

    printf("\n")

    return 0
