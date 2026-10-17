# First-light startup: stack, zeroed .bss, main, then park.
#
# Placed at the reset vector (address 0) by link.ld. No .data copy: the
# bitstream loads the image into RAM where it runs. No gp: nothing here is
# built to use small-data relaxation against it.

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

    # main returned: ebreak halts this core (every exception does), which
    # freezes the pipeline with the LEDs and UART as main left them.
    ebreak
