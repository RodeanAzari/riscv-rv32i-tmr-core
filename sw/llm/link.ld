/* The tiny-LLM demo (sw/llm/): sw/app/link.ld for the LLM build's 384 KiB
 * RAM (make impl LLM=1, RAM_WORDS 98304; bootloader built with RAM_END
 * 0x60000), so 0x1000 up to 0x60000. Otherwise as sw/app/link.ld:
 *
 * Programs loaded by the bootloader (sw/boot/), at 0x1000 up to the top of
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
  APP (rwx) : ORIGIN = 0x00001000, LENGTH = 0x5F000
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

  /* libgcc's 64-bit divide (llm.c's reciprocals) brings unwind tables,
   * which sw/app/link.ld never met; nothing here unwinds. */
  /DISCARD/ : { *(.eh_frame .eh_frame_hdr) }

  /* 1 KiB of stack, as sw/app/link.ld; llm.c keeps its buffers static. */
  __stack_top = ORIGIN(APP) + LENGTH(APP);
  ASSERT(__stack_top - __bss_end >= 1024, "program: under 1 KiB left for the stack")
}
