# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Standalone Xilinx IP generation for the KV260 app (no block design).
# Sourced by ct_soc_kv260.abc inside the abc/Vivado project context; each IP
# is created as a plain XCI with an explicit configuration and instantiated
# from ct_soc_kv260_top.sv.
#
# The chain replicates what the former block design (SmartConnect) resolved
# to: PS M_AXI_HPM0_FPD (AXI4, 128-bit — its native FPD width; narrower
# widths mis-steer write byte lanes, see ct_soc_kv260_top.sv) -> AXI data
# width converter 128->32 -> AXI4 -> AXI4-Lite protocol converter ->
# ct_soc_top @ 0xA000_0000.
#
# IPs land in <project>/../ip. Re-sourcing into an existing project reads
# the XCIs back and re-applies the configuration, so edits here take effect
# without a fresh project (`abc -new`).

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
# is a single clock domain; 100 MHz misses timing, see the README), one
# fabric reset. 75 MHz also sets the pl_clk0 timing constraint the IP emits.
ct_soc_ip::ensure ct_soc_kv260_ps zynq_ultra_ps_e {
	CONFIG.PSU__USE__M_AXI_GP0 {1}
	CONFIG.PSU__USE__M_AXI_GP1 {0}
	CONFIG.PSU__USE__M_AXI_GP2 {0}
	CONFIG.PSU__MAXIGP0__DATA_WIDTH {128}
	CONFIG.PSU__FPGA_PL0_ENABLE {1}
	CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {75}
	CONFIG.PSU__NUM_FABRIC_RESETS {1}
}

# Fabric reset synchronizer: pl_resetn0 -> peripheral_aresetn. Both reset
# inputs are configured active-low (the IP DEFAULTS aux to active-HIGH — left
# at that, the constant-high tie in ct_soc_kv260_top holds everything in
# permanent reset and every PS access hangs).
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
