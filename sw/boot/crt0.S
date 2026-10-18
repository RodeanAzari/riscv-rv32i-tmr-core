# Bootloader startup: stack, zeroed .bss, main. Runs after every RESET and
# every time a program returns (sw/app/crt0.S jumps back to address 0), so
# it sets everything up from scratch each time.

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
    ebreak                    # main never returns; halt if it somehow does
