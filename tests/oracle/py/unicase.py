M = 1 << 64
h_up = h_lo = n_up = n_lo = 0
for cp in range(1114112):
    if 55296 <= cp <= 57343:
        continue
    c = chr(cp)
    u = c.upper()
    l = c.lower()
    if u != c:
        n_up += 1
        for ch in u:
            h_up = ((h_up * 1000003 + ord(ch)) % M) % 1000000007
    if l != c:
        n_lo += 1
        for ch in l:
            h_lo = ((h_lo * 1000003 + ord(ch)) % M) % 1000000007
print("upper", n_up, h_up)
print("lower", n_lo, h_lo)
