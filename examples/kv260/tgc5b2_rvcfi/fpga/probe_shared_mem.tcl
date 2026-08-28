# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Out-of-context synthesis of ct_soc_shared_mem alone, purely to answer ONE
# question in a minute instead of an hour: did it become UltraRAM?
#
# `ram_style = "ultra"` is a request, not a contract (see the module header).
# A full bitstream run is a very slow way to find out that it was declined.
set script_dir [file dirname [file normalize [info script]]]
set part xck26-sfvc784-2LV-c
create_project -in_memory -part $part
add_files -norecurse [file join $script_dir .. rtl ct_soc_shared_mem.sv]
set_property file_type SystemVerilog [get_files *ct_soc_shared_mem.sv]
synth_design -top ct_soc_shared_mem -mode out_of_context -part $part
set rpt [file join $script_dir logs probe_shared_mem_util.rpt]
report_utilization -file $rpt
puts "### PROBE_REPORT: $rpt"
set uram [llength [get_cells -hier -filter {PRIMITIVE_TYPE =~ BLOCKRAM.URAM.*}]]
set bram [llength [get_cells -hier -filter {PRIMITIVE_TYPE =~ BLOCKRAM.BRAM.*}]]
puts "### PROBE_URAM: $uram"
puts "### PROBE_BRAM: $bram"
if {$uram > 0 && $bram == 0} { puts "### PROBE_OK: UltraRAM" } else { puts "### PROBE_FAIL: not UltraRAM" }
