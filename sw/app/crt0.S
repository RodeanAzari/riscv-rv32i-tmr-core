# Startup for programs the bootloader loads: stack, zeroed .bss, main, then
# back to the bootloader at address 0 -- not ebreak, so a program that
# finishes leaves the board ready for the next one without a RESET.

    .section .text.start
    .globl _start
_start:
    la    sp, __stack_top

    la    t0, __bss_start
    la    t1, __bss_end
1:  bgeu  t0, t1, 2f
    sw    zero, 0(t0)
    addi  t0, t0, 4
    j     1b

2:  call  main
    jr    zero                # address 0: the bootloader
