include <stdio.h>

const ACPI_TYPE_INVALID: int = 0x1E
const NUM_NS_TYPES: int = ACPI_TYPE_INVALID + 1
const n: int = 0xe

def main() -> int:
    printf("n+1 = %d\n", n + 1)
    return 0
