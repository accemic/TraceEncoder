# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# PIB parallel trace port -> KV260 carrier PMOD J2, pinned so the existing
# KR260 PMOD adapter of the CTTE reference implementation plugs in 1:1.
#
# Byte-identical to ../../duo/fpga/duo_pib_pmod.xdc except this note (D2,
# 2026-08-18): the mbv example gained the same three-sink subsystem
# (ct_trace_sinks) the other board examples already carry, so it needs the
# same PMOD pinout. Keep the two files in step -- the pin contract belongs to
# the KR260 adapter, not to a single example.
#
# Reference contract (CTTE RM ct_pib.adoc, "KR260 PMOD #3 Pinout",
# trPibMode = PIB_PAR_4 4-bit DDR): functions sit on DIGILENT PMOD positions
#   1 = TRC_CLK, 2 = TRC_DATA[0], 3 = SCL (RESERVED, I2C), 4 = SDA (RESERVED,
#   I2C), 7 = TRC_DATA[1], 8 = TRC_DATA[2], 9 = TRC_DATA[3], 10 = unused.
#
# KV260 J2 numbers its pins header-style (odd = top row, even = bottom row):
#   J2 1/3/5/7 = HDA11/12/13/14 (top row), J2 2/4/6/8 = HDA15/16/17/18
#   (bottom row), 9/10 = GND, 11/12 = 3V3 -- verified against the community
#   pin lists (gist tonosaman / tomverbeure kv260_pinout.py); GND/3V3 land
#   exactly on Digilent positions 5/6/11/12, so the socket is
#   position-compatible with the KR260 PMODs.
#
# Digilent position -> function -> HDA net -> package pin:
#   1  TRC_CLK       HDA11     H12
#   2  TRC_DATA[0]   HDA12     E10
#   3  SCL RESERVED  HDA13     D10   (not driven -- adapter I2C convention)
#   4  SDA RESERVED  HDA14     C11   (not driven -- adapter I2C convention)
#   7  TRC_DATA[1]   HDA15     B10
#   8  TRC_DATA[2]   HDA16_CC  E12
#   9  TRC_DATA[3]   HDA17     D11
#   10 (unused)      HDA18     B11
#
# Receiver contract (= reference PIB_PAR_4): LSB first (TRC_DATA[0] = LSB),
# rising TRC_CLK edge samples the LOW nibble of each byte, falling edge the
# HIGH nibble; all-ones idle between messages; no frame lane.

set_property PACKAGE_PIN H12 [get_ports pib_clk]
set_property PACKAGE_PIN E10 [get_ports {pib_data[0]}]
set_property PACKAGE_PIN B10 [get_ports {pib_data[1]}]
set_property PACKAGE_PIN E12 [get_ports {pib_data[2]}]
set_property PACKAGE_PIN D11 [get_ports {pib_data[3]}]

set_property IOSTANDARD LVCMOS33 [get_ports {pib_clk pib_data[*]}]
set_property SLEW FAST [get_ports {pib_clk pib_data[*]}]
set_property DRIVE 8 [get_ports {pib_clk pib_data[*]}]

# pib_clk is a divided register output (max clk/4 = 18.75 MHz), data toggles
# on the opposite half period -> no dedicated forwarded-clock constraint
# needed at this rate; keep the ports out of default timing analysis.
set_false_path -to [get_ports {pib_clk pib_data[*]}]
