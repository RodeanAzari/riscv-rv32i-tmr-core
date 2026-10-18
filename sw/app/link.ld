/* Programs loaded by the bootloader (sw/boot/), at 0x1000 up to the top of
 * the 32 KiB RAM (sw/lib/soc.h).
 *
 * The image the bootloader receives -- and checks by CRC before a rerun --
 * is code, read-only data, and a pristine copy of .data, in that order, and
 * the program never writes any of it: crt0 copies .data to its run address
 * just past the image and zeroes .bss after that. So a program that changes
 * its globals can be rerun (r) and starts from the same initial values, and
 * the CRC still matches. The stack grows down from the top of RAM.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  APP (rwx) : ORIGIN = 0x00001000, LENGTH = 0x7000
}

SECTIONS
{
  .text : {
    KEEP(*(.text.start))      /* crt0's _start, where the bootloader jumps */
    *(.text .text.*)
  } > APP

  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > APP

  /* Loaded at __data_load (the end of the image), run just after it. */
  __data_load = ALIGN(4);
  .data (__data_load + SIZEOF(.data)) : AT(__data_load) {
    __data_start = .;
    *(.data .data.* .sdata .sdata.*)
    . = ALIGN(4);
    __data_end = .;
  }

  .bss (ADDR(.data) + SIZEOF(.data)) (NOLOAD) : {
    . = ALIGN(4);             /* crt0 zeroes it a word at a time */
    __bss_start = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(4);
    __bss_end = .;
  }

  /* 1 KiB of stack: the demo reel's deepest call chain (Tower of Hanoi,
   * eight levels of recursion, then printf) takes about 660 bytes by
   * gcc -fstack-usage (2026-10-18). */
  __stack_top = ORIGIN(APP) + LENGTH(APP);
  ASSERT(__stack_top - __bss_end >= 1024, "program: under 1 KiB left for the stack")
}
