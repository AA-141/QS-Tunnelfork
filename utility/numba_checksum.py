def checksum(data: bytes | bytearray) -> int:
    length = len(data)
    s = 0
    i = 0
    n = length & ~1

    while i < n:
        s += (data[i] << 8) | data[i + 1]
        i += 2

    if length & 1:
        s += data[n] << 8

    s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)

    return (~s) & 0xFFFF
