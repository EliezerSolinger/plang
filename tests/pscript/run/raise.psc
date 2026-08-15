"""An exception reaching the top of the program.

The flag model of 49.2 end to end: `ps_div` raises, the statement's check sees
it, every later call becomes a no-op, and the entry point turns it into a
message and an exit status. Nothing after the failing line runs.
"""

def half(n: int) -> float:
    return n / 0


print("before")
value = half(10)
print("after — must not be printed")
