# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# A SECOND PS instance with FOUR slave ports, additive alongside
# ct_soc_kv260_ps. To be sourced AFTER gen_ip.tcl (from there comes the
# ct_soc_ip::ensure procedure and the other three glue IPs).
#
# Why a second IP and not extending the existing one
# ----------------------------------------------------
# The dual CVA6 needs four PS slave ports (HP0 trace sink, HP1 core 0, HP2
# core 1, HP3 mailbox). `ct_soc_kv260_ps` carries two and is used by EVERY
# other top in this repository -- among them the bitstream that is
# currently running the demonstrator on the board. Extending it would have
#   (a) forced every other app to resynthesize and
#   (b) left two slave ports undriven in every other top.
# An additive second IP costs a minute of generation and touches nothing.
#
# Everything except the two additional slave ports is word for word the
# configuration of ct_soc_kv260_ps: a 128-bit FPD master, 75 MHz PL clock
# (100 MHz breaks timing, see the README), one fabric reset.
#
#   S_AXI_GP2 = S_AXI_HP0_FPD, 32 bit -> DDR trace sink
#   S_AXI_GP3 = S_AXI_HP1_FPD, 64 bit -> private memory path core 0
#   S_AXI_GP4 = S_AXI_HP2_FPD, 64 bit -> private memory path core 1   NEW
#   S_AXI_GP5 = S_AXI_HP3_FPD, 64 bit -> shared mailbox                NEW
#
# Migrated from an internal predecessor repository
# (2026-08-17).

ct_soc_ip::ensure ct_soc_kv260_ps4 zynq_ultra_ps_e {
	CONFIG.PSU__USE__M_AXI_GP0 {1}
	CONFIG.PSU__USE__M_AXI_GP1 {0}
	CONFIG.PSU__USE__M_AXI_GP2 {0}
	CONFIG.PSU__MAXIGP0__DATA_WIDTH {128}
	CONFIG.PSU__FPGA_PL0_ENABLE {1}
	CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {75}
	CONFIG.PSU__NUM_FABRIC_RESETS {1}
	CONFIG.PSU__USE__S_AXI_GP2 {1}
	CONFIG.PSU__SAXIGP2__DATA_WIDTH {32}
	CONFIG.PSU__USE__S_AXI_GP3 {1}
	CONFIG.PSU__SAXIGP3__DATA_WIDTH {64}
	CONFIG.PSU__USE__S_AXI_GP4 {1}
	CONFIG.PSU__SAXIGP4__DATA_WIDTH {64}
	CONFIG.PSU__USE__S_AXI_GP5 {1}
	CONFIG.PSU__SAXIGP5__DATA_WIDTH {64}
}
