# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Standalone Xilinx IP generation for the KV260 app (no block design).
# Sourced by run_cva6_linux64_bitstream.tcl inside the open Vivado project
# context; each IP is created as a plain XCI with an explicit configuration
# and instantiated from cva6_linux64_kv260_top.sv.
#
# The chain replicates what the former block design (SmartConnect) resolved
# to: PS M_AXI_HPM0_FPD (AXI4, 128-bit -- its native FPD width; narrower
# widths mis-steer write byte lanes) -> AXI data width converter 128->32 ->
# AXI4 -> AXI4-Lite protocol converter -> cva6_linux64_soc_top @ 0xA000_0000.
#
# IPs land in <project>/../ip. Re-sourcing into an existing project reads
# the XCIs back and re-applies the configuration, so edits here take effect
# without a fresh project.
#
# Migrated 2026-08-17 from an internal predecessor repository.
# Vendored per-example (own copy
# here, and in ../../cva6_linux/fpga/ and ../../cva6_2/fpga/), same
# reasoning as mbv's own copy: no cross-example TCL dependency for a small,
# self-contained generation script -- this is now the FIFTH vendored copy
# in the tree (after mbv, rocket_linux, rocket2, cva6_linux). Content is
# byte-identical to ../../cva6_linux/fpga/gen_ip.tcl.

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
# S_AXI_GP2 = S_AXI_HP0_FPD: 32-bit slave port for the trace DDR sink
# (ct_soc_ddr_sink AXI master) -- write-only, see cva6_linux64_kv260_top.sv.
# S_AXI_GP3 = S_AXI_HP1_FPD: 64-bit slave port for the CVA6 memory path
# (cva6_linux_mem_xbar -> mem_axi_*) -> PS DDR window 0x6400_0000 (board
# memory map).

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
