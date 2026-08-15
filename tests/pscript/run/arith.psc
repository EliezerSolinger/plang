"""The arithmetic that makes pscript pscript, end to end.

Every line here is a place where the answer differs from C's, which is why
these have to be right before anything is built on top of them.
"""

def show(label: str, v: int):
    print(label + " = " + str(v))


def showf(label: str, v: float):
    print(label + " = " + str(v))


# 39.1: `/` is float even between ints — whoever wants integers writes `//`
showf("7 / 2", 7 / 2)
showf("6 / 3", 6 / 3)

# `//` floors (toward minus infinity), unlike C's truncation toward zero
show("7 // 2", 7 // 2)
show("-7 // 2", -7 // 2)
show("7 // -2", 7 // -2)

# `%` takes the DIVISOR's sign, preserving a == (a//b)*b + a%b
show("-7 % 3", -7 % 3)
show("7 % -3", 7 % -3)

# `**` on integers is an integer (47.3)
show("2 ** 10", 2 ** 10)

# 54.1: the wrapping operators are the only arithmetic that does not check
show("wrap", 9223372036854775807 %+ 1)

x = 10
x += 5
x *= 2
show("x", x)

if x > 20 and x < 100:
    print("in range")
else:
    print("out of range")

i = 0
total = 0
while i < 5:
    total += i * i
    i += 1
show("sum of squares", total)

print("len " + str(len("hello")))
print("int(str) " + str(int("42") + 1))
print("float " + str(1.5 + 2.5))
print("bool " + str(True))
