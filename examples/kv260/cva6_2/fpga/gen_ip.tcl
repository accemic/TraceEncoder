# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Standalone Xilinx IP generation for the KV260 app (no block design).
# Sourced by run_cva6_2_bitstream.tcl inside the open Vivado project
# context, ALONGSIDE gen_ip_ps4.tcl (in this same directory), which
# additively defines the four-port ct_soc_kv260_ps4 this example's top
# actually instantiates. This file's own ct_soc_kv260_ps (two ports) is
# thereby created but left UNUSED by cva6_2_kv260_top.sv -- kept as-is
# rather than trimmed, matching the source repository's own behavior
# (verified: the source's run_cva6_2_bitstream.tcl sources both files the
# same way, and `generate_target all [get_ips ct_soc_kv260_*]`'s wildcard
# generates both regardless of use). Only ct_soc_kv260_rst/dwc/pc from this
# file are actually wired into the design.
#
# The rst/dwc/pc chain replicates what the former block design
# (SmartConnect) resolved to: AXI data width converter 128->32 -> AXI4 ->
# AXI4-Lite protocol converter -> cva6_2_soc_top @ 0xA000_0000, downstream
# of ct_soc_kv260_ps4's M_AXI_HPM0_FPD.
#
# IPs land in <project>/../ip. Re-sourcing into an existing project reads
# the XCIs back and re-applies the configuration, so edits here take effect
# without a fresh project.
#
# Migrated 2026-08-17 from an internal predecessor repository.
# Vendored per-example (own copy
# here, and in ../../cva6_linux/fpga/ and ../../cva6_linux64/fpga/), same
# reasoning as mbv's own copy: no cross-example TCL dependency for a small,
# self-contained generation
# script -- this is now the SIXTH vendored copy in the tree (after mbv,
# rocket_linux, rocket2, cva6_linux, cva6_linux64), promotion to tools/ is
# increasingly overdue but out of this migration's write scope.

namespace eval ct_soc_ip {
	variable ip_dir [file normalize [file join $abc::proj_dir .. ip]]

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

# Zynq UltraScale+ PS. Only the PL-facing configuration matters for a
# runtime-loaded app (the PS itself is configured by the Kria base firmware
# at boot): one 128-bit FPD master, one 75 MHz PL clock (the whole example
# is a single clock domain), one fabric reset. 75 MHz also sets the pl_clk0
# timing constraint the IP emits.
ct_soc_ip::ensure ct_soc_kv260_ps zynq_ultra_ps_e {
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
}
# S_AXI_GP2/GP3 above describe this (unused-in-this-example, see the file
# header) IP's own two-port configuration, kept byte-identical to the
# other examples' gen_ip.tcl for diff-ability. cva6_2_kv260_top.sv's real
# PS is ct_soc_kv260_ps4 (gen_ip_ps4.tcl, four ports: HP0 trace sink, HP1
# core 0, HP2 core 1, HP3 mailbox).

# Fabric reset synchronizer: pl_resetn0 -> peripheral_aresetn. Both reset
# inputs are configured active-low (the IP DEFAULTS aux to active-HIGH -- left
# at that, a constant-high tie in the board top would hold everything in
# permanent reset and every PS access would hang).
ct_soc_ip::ensure ct_soc_kv260_rst proc_sys_reset {
	CONFIG.C_EXT_RESET_HIGH {0}
	CONFIG.C_AUX_RESET_HIGH {0}
}

# AXI data width converter 128 -> 32 (the byte-lane-correct downsize).
ct_soc_ip::ensure ct_soc_kv260_dwc axi_dwidth_converter {
	CONFIG.ADDR_WIDTH {40}
	CONFIG.SI_DATA_WIDTH {128}
	CONFIG.SI_ID_WIDTH {16}
	CONFIG.MI_DATA_WIDTH {32}
}

# AXI4 -> AXI4-Lite protocol converter (bursts/IDs terminated here).
ct_soc_ip::ensure ct_soc_kv260_pc axi_protocol_converter {
	CONFIG.ADDR_WIDTH {40}
	CONFIG.DATA_WIDTH {32}
	CONFIG.ID_WIDTH {0}
	CONFIG.SI_PROTOCOL {AXI4}
	CONFIG.MI_PROTOCOL {AXI4LITE}
}
