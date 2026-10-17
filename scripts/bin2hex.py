#!/usr/bin/env python3
"""Flat binary -> $readmemh image: one 32-bit little-endian word per line.

    bin2hex.py <in.bin> <out.hex>

The format rtl/top/ram_dp.sv loads. Written here rather than relying on the
toolchain's elf2hex, which Ubuntu's packaged toolchain (CI) does not ship.
"""
import sys

data = open(sys.argv[1], "rb").read()
data += bytes(-len(data) % 4)
with open(sys.argv[2], "w") as out:
    for i in range(0, len(data), 4):
        out.write(f"{int.from_bytes(data[i:i + 4], 'little'):08x}\n")
