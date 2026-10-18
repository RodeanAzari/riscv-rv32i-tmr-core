#!/usr/bin/env python3
"""Send a program to the board's bootloader (sw/boot/), then optionally talk to it.

Usage: scripts/load.py <program.bin> [--port /dev/ttyUSB1] [--term]
       scripts/load.py --term            # terminal only, no program

The bootloader takes "RVLD", the length and CRC-32 (little-endian u32s), then
the program; it replies OK and runs it, or ERR. Opening the port resets the
Arty (DTR reaches its reset), so whatever was running, the bootloader is
what receives the image; the previous program stays in RAM until replaced. With --term, the terminal stays open after loading: keys go to the
board as you type them, its output comes to the screen, and Ctrl-] quits.

Needs pyserial. On Windows, use the COM port (--port COM4) and leave out
--term; PuTTY is the terminal there. In WSL the Arty must be attached with
usbipd (docs/vivado-setup.md section 6).
"""
import argparse
import os
import struct
import sys
import time
import zlib

import serial

QUIT = b"\x1d"                       # Ctrl-]


def load(port, image):
    # Opening the port resets the board: the FTDI bridge's DTR reaches the
    # Arty's reset. The bootloader then prints its banner and only listens
    # once that is sent; bytes arriving meanwhile overrun its one-byte buffer.
    # So wait for the banner (or half a second) before sending.
    banner = b""
    deadline = time.monotonic() + 0.5
    while b"bootloader" not in banner or not banner.endswith(b"\r\n"):
        if time.monotonic() > deadline:
            break
        banner += port.read(port.in_waiting or 1)
    port.reset_input_buffer()
    port.write(b"RVLD" + struct.pack("<II", len(image), zlib.crc32(image)) + image)
    port.flush()
    reply = b""
    deadline = time.monotonic() + 3 + len(image) * 10 / port.baudrate
    while time.monotonic() < deadline:
        reply += port.read(port.in_waiting or 1)
        if b"OK\r\n" in reply:
            return reply.split(b"OK\r\n", 1)[1]     # the program's first output
        if b"ERR" in reply and reply.endswith(b"\r\n"):
            break
    sys.stderr.write(f"load failed: {reply.decode(errors='replace').strip() or 'no reply'}"
                     " -- press RESET on the board and try again\n")
    return None


def terminal(port):
    import termios
    import tty
    import select
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    sys.stderr.write("-- terminal: Ctrl-] quits --\r\n")
    try:
        tty.setraw(fd)
        while True:
            ready, _, _ = select.select([fd, port.fileno()], [], [])
            if port.fileno() in ready:
                os.write(sys.stdout.fileno(), port.read(port.in_waiting or 1))
            if fd in ready:
                key = os.read(fd, 64)
                if QUIT in key:
                    break
                port.write(key)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        sys.stderr.write("\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("program", nargs="?", help="flat binary from make apps")
    ap.add_argument("--port", default="/dev/ttyUSB1")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--term", action="store_true", help="stay as a terminal afterwards")
    args = ap.parse_args()
    if not args.program and not args.term:
        ap.error("give a program, --term, or both")
    with serial.Serial(args.port, args.baud, timeout=0.1) as port:
        if args.program:
            with open(args.program, "rb") as f:
                image = f.read()
            early = load(port, image)
            if early is None:
                sys.exit(1)
            sys.stderr.write(f"loaded {args.program}: {len(image)} bytes\n")
            sys.stdout.buffer.write(early)
            sys.stdout.flush()
        if args.term:
            terminal(port)


if __name__ == "__main__":
    main()
