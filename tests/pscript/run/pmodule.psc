"""A P module pulled into a pscript build (75.3/2.4).

`import "pmod_mathx.ph"` does two things at once: it makes the module's
pointer-free signatures, enum members and scalar constants visible here (the
45.5 boundary, unchanged), and it tells the COMPILER to build `pmod_mathx.p`
alongside this program. What the pstudio port had to do by hand — compile the
P side, include the generated header, link both — is one command now.
"""

import "pmod_mathx.ph"

print("add", mathx_add(20, 22))
print("scaled", mathx_scaled(6, SCALE_TEN))
print("base", MATHX_BASE, "even", mathx_is_even(MATHX_BASE))

total = 0
for i in range(5):
    total = mathx_add(total, mathx_scaled(i, SCALE_ONE))
print("total", total)
