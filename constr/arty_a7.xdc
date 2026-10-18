# Board-level constraints for rtl/top/arty_a7_top.sv on the Arty A7-100T.
#
# Pins copied from Digilent's master XDC (digilent-xdc, Arty-A7-100-Master.xdc),
# only the ones in use. Port names follow this repo's conventions; the
# Digilent name is in each comment.

# ---- clock: 100 MHz oscillator ----
set_property -dict { PACKAGE_PIN E3    IOSTANDARD LVCMOS33 } [get_ports { clk100_i }];   # CLK100MHZ
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports { clk100_i }];
# The 50 MHz core clock is derived by Vivado from the MMCM's settings.

# ---- reset: the red RESET button, active low ----
set_property -dict { PACKAGE_PIN C2    IOSTANDARD LVCMOS33 } [get_ports { rst_ni }];     # ck_rst

# ---- LEDs LD4-LD7 ----
set_property -dict { PACKAGE_PIN H5    IOSTANDARD LVCMOS33 } [get_ports { led_o[0] }];   # led[0]
set_property -dict { PACKAGE_PIN J5    IOSTANDARD LVCMOS33 } [get_ports { led_o[1] }];   # led[1]
set_property -dict { PACKAGE_PIN T9    IOSTANDARD LVCMOS33 } [get_ports { led_o[2] }];   # led[2]
set_property -dict { PACKAGE_PIN T10   IOSTANDARD LVCMOS33 } [get_ports { led_o[3] }];   # led[3]

# ---- UART to and from the USB-UART bridge (Digilent names them from the bridge) ----
set_property -dict { PACKAGE_PIN D10   IOSTANDARD LVCMOS33 } [get_ports { uart_tx_o }];  # uart_rxd_out
set_property -dict { PACKAGE_PIN A9    IOSTANDARD LVCMOS33 } [get_ports { uart_rx_i }];  # uart_txd_in

# ---- asynchronous and slow I/O ----
# The button and the UART input are asynchronous and each go through a
# synchroniser (the top's; uart_rx.sv's); the LEDs are seen by eyes and the
# UART output changes every 868 clocks at 100 MHz. None of them
# has a timing relationship to the core clock worth constraining, so their
# paths are cut rather than left unconstrained (which Vivado warns about).
set_false_path -from [get_ports {rst_ni uart_rx_i}]
set_false_path -to   [get_ports {led_o[*] uart_tx_o}]

# ---- configuration ----
set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
