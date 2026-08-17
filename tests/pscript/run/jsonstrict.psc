"""What the JSONTestSuite corpus taught this parser (tests/conformance).

Everything below was WRONG before the corpus ran, and every line is a way two
programs could have disagreed about what a document says:

  * `\\uXXXX` was not decoded at all — `"\\u00e9"` came back as the four letters
    `u00e9`. Anything that spoke JSON to us in escaped form was mangled.
  * the escape set was open: `\\x` read as `x`, and `\\b`/`\\f` as `b`/`f`.
  * a raw control byte inside a string was accepted.
  * the number grammar was `strtod`, which speaks C: `01`, `.5`, `2.`, `0x1F`,
    `NaN` and `Infinity` all got in, and none of them are JSON.
  * a TRUNCATED document parsed as a value: `[` alone returned an empty list.
  * there was no depth limit, so a hundred thousand `[` was a segfault — a
    crash reachable from a string somebody else wrote.
"""

import json


def taken(text: str) -> str:
    try:
        v = json.parse(text)
        return "ok"
    catch e:
        return e.message


# \u is a codepoint, not four letters after a u
print(json.parse("\"\\u00e9\"") as str)
print(json.parse("\"\\u0041\\u0042\"") as str)
# a surrogate PAIR is one codepoint above the BMP
print(json.parse("\"\\ud83d\\ude00\"") as str)
# a LONE surrogate cannot be encoded, so it becomes U+FFFD — what a browser's
# TextEncoder does with the same input, and what keeps `str` valid UTF-8 (83.2)
print(len(json.parse("\"\\ud800\"") as str))
# the escapes that were silently passing through as letters
esc = json.parse("\"a\\bb\\fc\\/d\"") as str
print(esc == "a" + chr(8) + "b" + chr(12) + "c/d")

# the closed escape set
print(taken("\"\\x\""))
print(taken("\"\\U0041\""))
# a control byte has to be escaped
print(taken("\"tab\there\""))

# the number grammar, RFC 8259 §6
print(taken("[01]"))
print(taken("[-01]"))
print(taken("[.5]"))
print(taken("[2.]"))
print(taken("[2.e3]"))
print(taken("[0x1F]"))
print(taken("[NaN]"))
print(taken("[-Infinity]"))
print(taken("[1e]"))
# and what it still takes
print(taken("[0, -0, 1e400, 1E-3, 0.5, -12.75e+2]"))

# an integer that does not fit is refused, not wrapped: there is no bignum here
# and overflow raises everywhere else (7.2)
print(taken("[123456789012345678901234567890]"))
print(json.parse("9223372036854775807") as int)
print(json.parse("-9223372036854775808") as int)

# truncation is a failure, not a shorter value
print(taken("["))
print(taken("{"))
print(taken("[1, 2"))
print(taken("{\"a\": 1"))

# the depth limit: reachable from untrusted text, so it raises instead of
# taking the stack down with it
deep = ""
for i in range(2000):
    deep += "["
print(taken(deep))
