/* Programs loaded by the bootloader (sw/boot/), at 0x1000 up to the top of
 * the 32 KiB RAM (sw/lib/soc.h). The bootloader copies the whole flat image,
 * .data included, where it runs; crt0 zeroes .bss. The stack grows down from
 * the top of RAM.
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
  .data   : { *(.data .data.* .sdata .sdata.*) } > APP

  .bss (NOLOAD) : {
    . = ALIGN(4);             /* crt0 zeroes it a word at a time */
    __bss_start = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > APP

  __stack_top = ORIGIN(APP) + LENGTH(APP);
  ASSERT(__stack_top - __bss_end >= 2048, "program: under 2 KiB left for the stack")
}
