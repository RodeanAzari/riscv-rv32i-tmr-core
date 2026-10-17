/* First-light firmware: everything in the one 32 KiB RAM of rtl/top/soc.sv.
 *
 * The whole image -- code, read-only data and initialised data -- is loaded
 * into the RAM by the bitstream, at the addresses it runs at, so crt0 has no
 * .data to copy; it only zeroes .bss. The stack grows down from the top.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 32K
}

SECTIONS
{
  .text : {
    KEEP(*(.text.start))      /* crt0's _start, at the reset vector */
    *(.text .text.*)
  } > RAM

  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > RAM
  .data   : { *(.data .data.* .sdata .sdata.*) } > RAM

  .bss (NOLOAD) : {
    __bss_start = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > RAM

  __stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
