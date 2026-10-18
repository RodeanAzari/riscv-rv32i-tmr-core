/* The SoC's memory map (rtl/top/soc.sv), for the bootloader and programs.
 *
 *   0x0000_0000  RAM, 32 KiB: the bootloader below BOOT_END, programs above
 *   0x1000_0000  I/O registers
 */
#ifndef SOC_H
#define SOC_H

#include <stdint.h>

#define REG(a) (*(volatile uint32_t *)(a))

#define LED      REG(0x10000000u)    /* W: bits [3:0] drive LD4-LD7 */
#define UART_TX  REG(0x10000004u)    /* W: a byte to send */
#define UART_ST  REG(0x10000008u)    /* R: the status bits below */
#define UART_RX  REG(0x1000000Cu)    /* R: the waiting byte; W: acknowledge */
#define CYCLE    REG(0x10000010u)    /* R: core cycles since reset, mod 2^32 */

#define UART_TX_READY 1u
#define UART_RX_VALID 2u
#define UART_RX_OVERRUN 4u
#define UART_RX_FRAME_ERR 8u

/* RAM layout, shared with sw/boot/link.ld and sw/app/link.ld. The last words
 * below BOOT_END hold the last good image's length and CRC, so RESET can
 * rerun it; nothing else touches them. */
#define RAM_END     0x8000u
#define BOOT_END    0x1000u
#define APP_BASE    BOOT_END
#define APP_MAX     (RAM_END - APP_BASE)
#define SAVED_MAGIC REG(0x0FF4u)
#define SAVED_LEN   REG(0x0FF8u)
#define SAVED_CRC   REG(0x0FFCu)

#endif /* SOC_H */
