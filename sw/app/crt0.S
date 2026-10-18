# Startup for programs the bootloader loads: stack, .data copied from its
# pristine copy in the image (sw/app/link.ld), zeroed .bss, main, then back
# to the bootloader at address 0 -- not ebreak, so a program that finishes
# leaves the board ready for the next one without a RESET.

    .section .text.start
    .globl _start
_start:
    la    sp, __stack_top

    la    t0, __data_load
    la    t1, __data_start
    la    t2, __data_end
1:  bgeu  t1, t2, 2f
    lw    t3, 0(t0)
    sw    t3, 0(t1)
    addi  t0, t0, 4
    addi  t1, t1, 4
    j     1b

2:  la    t0, __bss_start
    la    t1, __bss_end
3:  bgeu  t0, t1, 4f
    sw    zero, 0(t0)
    addi  t0, t0, 4
    j     3b

4:  call  main
    jr    zero                # address 0: the bootloader
