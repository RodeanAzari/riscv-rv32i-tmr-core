/* riscv-tests on this core: code from the reset vector, data after it.
 *
 * One flat image starting at 0. The core is Harvard -- separate instruction
 * and data ports -- so the testbench loads the same image behind both, the
 * way two BRAMs initialised from one file would be. Tests reach their data
 * pc-relatively (la), so data must sit at the address it was linked for.
 *
 * Upstream's env/p/link.ld starts at 0x80000000 and adds a .tohost section
 * for its trap handler; neither applies here.
 */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0x00000000;
  .text.init : { *(.text.init) }
  .text      : { *(.text) }
  . = ALIGN(0x1000);
  .data      : { *(.data) }
  .bss       : { *(.bss) }
  _end = .;
}
