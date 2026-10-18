#!/usr/bin/env python3
"""A RAM image with a program already loaded, as if scripts/load.py had sent it.

Usage: scripts/mkimage.py <boot.bin> <program.bin> <out.hex>

The bootloader at 0, the program at APP_BASE, and the saved length and CRC
the bootloader keeps for r (rerun) -- so a simulation reaches the program by
sending one key instead of the whole image at 115200 baud. Layout:
sw/lib/soc.h.
"""
import struct
import sys
import zlib

APP_BASE = 0x1000
SAVED = 0x0FF4                 # magic, length, CRC
MAGIC = 0x444C5652             # "RVLD"

boot = open(sys.argv[1], "rb").read()
app = open(sys.argv[2], "rb").read()
assert len(boot) <= SAVED, "bootloader overlaps the saved header"
img = bytearray(APP_BASE + len(app))
img[:len(boot)] = boot
img[SAVED:APP_BASE] = struct.pack("<III", MAGIC, len(app), zlib.crc32(app))
img[APP_BASE:] = app
img += bytes(-len(img) % 4)
with open(sys.argv[3], "w") as out:
    for i in range(0, len(img), 4):
        out.write(f"{int.from_bytes(img[i:i + 4], 'little'):08x}\n")
