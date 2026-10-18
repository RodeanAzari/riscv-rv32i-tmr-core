/* Console I/O for programs the bootloader loads: the UART, both ways.
 *
 * Programs link libgcc, so this uses / and % freely; RV32I has no multiply or
 * divide, so each is a library call.
 */
#ifndef IO_H
#define IO_H

#include <stdint.h>
#include "soc.h"

void putc_(char c);
void puts_(const char *s);
int  getc_(void);                    /* waits for a byte */
int  try_getc(void);                 /* a byte if one is waiting, else -1 */

/* %c %s %d %u %x, with an optional width and 0 flag (%08x, %5d). */
void printf_(const char *fmt, ...);

#endif /* IO_H */
