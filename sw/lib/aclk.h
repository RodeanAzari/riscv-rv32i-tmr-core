/* The array clock (Phase H box 4): software reprograms the array MMCM's
 * CLKOUT0 divider at run time through the SoC's ACLK register
 * (rtl/periph/array_clk_ctl.sv), following AMD's flow (XAPP888): MMCM in
 * reset, read-modify-write of each register over the DRP, release, wait
 * for LOCKED. The words and masks are sw/model/mmcm_drp.py's, the golden
 * model, checked against AMD's own Verilog (make aclk-check).
 *
 * On the board the MMCM's VCO is 800 MHz: divide 8 is 100 MHz (as
 * configured), 10 is 80 MHz. The accelerator is held in reset by hardware
 * from the start of the change until the new clock is locked, so call this
 * only with the accelerator idle; afterwards its registers are at their
 * reset values (the buffers keep their contents).
 */
#ifndef ACLK_H
#define ACLK_H

#include <stdint.h>
#include "soc.h"

#define ACLK         REG(0x1000001Cu)
#define ACLK_GO      (1u << 24)
#define ACLK_WE      (1u << 23)
#define ACLK_RST     (1u << 31)
#define ACLK_BUSY    (1u << 16)
#define ACLK_LOCKED  (1u << 17)
#define ACLK_ADDR(a) ((uint32_t)(a) << 16)

#define ACLK_DIV_MAX 128u

/* nonzero when the SoC has an array clock to control (ARRAY_CDC) and it is
 * locked; without ARRAY_CDC the register reads 0 */
int aclk_present(void);

/* CLKOUT0 divide d (1 to ACLK_DIV_MAX); 0 when locked again, -1 for a
 * divide out of range or no array clock, -2 if it did not lock */
int aclk_set_divide(uint32_t d);

#endif /* ACLK_H */
