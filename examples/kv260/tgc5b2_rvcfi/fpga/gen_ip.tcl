# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Standalone IP generation for the AXIS watchpoint testbed (package D1, no
# block design). Clone of the vivado/kv260_app/gen_ip.tcl pattern with its
# OWN ip_dir (this example's fpga/ip) -- the kv260_app XCIs are deliberately
# NOT reused: re-sourcing with `set_property` would rewrite their
# configuration (kv260_app is read-only as far as this example is concerned).
#
# Same chain as that pattern: PS M_AXI_HPM0_FPD (AXI4, 128 bit -- the native
# FPD width; narrower mis-steers write byte lanes) -> AXI data width
# converter 128->32 -> AXI4->AXI4-Lite -> router in tgc5b2_rvcfi_kv260_top
# @ 0xA000_0000. NEW vs. that pattern: wp_axi_fifo (axi_fifo_mm_s, RX-only)
# for the WP record streams of both shims. The PS XCI also carries
# S_AXI_GP2 (= S_AXI_HP0_FPD, 32 bit) for the DDR4 trace sink
# (ct_soc_ddr_sink in the SoC top, duo pattern); S_AXI_GP3 stays off (no
# guest memory path in this testbed).
#
# IPs land in <script_dir>/ip. Re-sourcing into an existing project reads
# the XCIs back and re-applies the configuration.

namespace eval wp_ip {
	variable ip_dir [file normalize [file join [file dirname [info script]] ip]]

	proc ensure {mod name cfg} {
		variable ip_dir
		set xci [file join $ip_dir $mod "$mod.xci"]
		if {[file exists $xci]} {
			if {[llength [get_ips -quiet $mod]] == 0} { read_ip $xci }
		} else {
			file mkdir $ip_dir
			# No -version: use the newest revision the Vivado release ships.
			create_ip -name $name -vendor xilinx.com -library ip \
				-module_name $mod -dir $ip_dir
		}
		if {[llength $cfg]} {
			set_property -dict $cfg [get_ips $mod]
		}
	}
}

# Zynq UltraScale+ PS: one 128-bit FPD master, pl_clk0 = 75 MHz (the choice
# of every kv260_app build; the IP emits the clock constraint from it.
# BOARD REALITY: the boot firmware provides 100 MHz -- a board runner must
# drive pl_clk0 down to 75 MHz before use, like every kv260_app build), one
# fabric reset. S_AXI_GP2 = S_AXI_HP0_FPD: 32-bit slave port for the DDR4
# trace sink (ct_soc_ddr_sink AXI master, D2; kv260_app pattern -- there the
# saxigp2 inputs are tied off in tops without a sink).
wp_ip::ensure ct_soc_kv260_ps zynq_ultra_ps_e {
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
	CONFIG.PSU__SAXIGP3__DATA_WIDTH {32}
}
# S_AXI_GP3 (= S_AXI_HP1_FPD, 32 bit, N3): second HP port for the core-1
# record ring -- one ct_soc_ddr_sink per core, no arbiter in the fabric.
# (The comment sits OUTSIDE the config block on purpose: the block is a Tcl
# dict literal, and a `#` line inside it is data, not a comment -- it shifts
# the name/value pairing and create_project dies on "Missing name/value
# pair". Found by the first build after N3.)

# Fabric reset synchronizer: pl_resetn0 -> peripheral_aresetn. Both reset
# inputs are configured active-low (the IP DEFAULTS aux to active-HIGH -- left
# at that, the constant-high tie in the top holds everything in permanent
# reset and every PS access hangs).
wp_ip::ensure ct_soc_kv260_rst proc_sys_reset {
	CONFIG.C_EXT_RESET_HIGH {0}
	CONFIG.C_AUX_RESET_HIGH {0}
}

# AXI data width converter 128 -> 32 (the byte-lane-correct downsize).
wp_ip::ensure ct_soc_kv260_dwc axi_dwidth_converter {
	CONFIG.ADDR_WIDTH {40}
	CONFIG.SI_DATA_WIDTH {128}
	CONFIG.SI_ID_WIDTH {16}
	CONFIG.MI_DATA_WIDTH {32}
}

# AXI4 -> AXI4-Lite protocol converter (bursts/IDs terminated here).
wp_ip::ensure ct_soc_kv260_pc axi_protocol_converter {
	CONFIG.ADDR_WIDTH {40}
	CONFIG.DATA_WIDTH {32}
	CONFIG.ID_WIDTH {0}
	CONFIG.SI_PROTOCOL {AXI4}
	CONFIG.MI_PROTOCOL {AXI4LITE}
}

# AXI4-Stream FIFO (PG080), instantiated once each for shim 0/1 (ONE XCI,
# two instances). Config rationale (SPEC_axis_wp_memory_map.md §4):
#   - RX-only: the data path is exclusively PL->PS (WP records); the TX
#     data and TX control paths are disabled.
#   - C_RX_FIFO_DEPTH 4096 words = 1024 records (4 words/record) >= the
#     requirement (>=1024 records) -- one complete 1023-WP set fits buffered.
#   - C_DATA_INTERFACE_TYPE 0 (AXI4-Lite only): the F0 host reader polls
#     RDFO/RDFD word-wise via a /dev/mem mmap; a full AXI4 port would go
#     unused and cost a second fabric path.
#   - tkeep/tstrb/tid/tdest/tuser off: records are full 32-bit words, the
#     core ID lives in W3 of the record.
#   - Store-and-forward (no RX cut-through): a record only becomes visible
#     after tlast -> RDFO/RLR stay record-consistent.
#   - BASE/HIGHADDR 0x0000_0000/0x0000_FFFF: the router passes the lower
#     16 offset bits through zero-extended (the window bases are the
#     router's job).
wp_ip::ensure wp_axi_fifo axi_fifo_mm_s {
	CONFIG.C_USE_RX_DATA {1}
	CONFIG.C_USE_TX_DATA {0}
	CONFIG.C_USE_TX_CTRL {0}
	CONFIG.C_RX_FIFO_DEPTH {4096}
	CONFIG.C_DATA_INTERFACE_TYPE {0}
	CONFIG.C_BASEADDR {0x00000000}
	CONFIG.C_HIGHADDR {0x0000FFFF}
}
