/* Bootloader: the first 4 KiB of the 32 KiB RAM (sw/lib/soc.h).
 *
 * Code, data and stack all stay below 0x0FF4, where the last good program's
 * length and CRC are kept; programs load from 0x1000 up and must not touch
 * any of it. Loaded by the bitstream, so there is no .data to copy.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  BOOT (rwx) : ORIGIN = 0x00000000, LENGTH = 0x0FF0
}

SECTIONS
{
  .text : {
    KEEP(*(.text.start))      /* crt0's _start, at the reset vector */
    *(.text .text.*)
  } > BOOT

  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > BOOT
  .data   : { *(.data .data.* .sdata .sdata.*) } > BOOT

  .bss (NOLOAD) : {
    . = ALIGN(4);             /* crt0 zeroes it a word at a time */
    __bss_start = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > BOOT

  __stack_top = ORIGIN(BOOT) + LENGTH(BOOT);
  ASSERT(__stack_top - __bss_end >= 512, "bootloader: under 512 bytes left for its stack")
}
