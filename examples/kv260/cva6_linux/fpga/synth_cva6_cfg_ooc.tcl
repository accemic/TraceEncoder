# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Out-of-context synthesis of ONE CVA6 branch (cva6_soc_synth_wrap = core +
# RVFI + ITI + shim + ct_encoder) for a selectable CVA6 configuration --
# measurement basis for "does the Linux-capable Sv32 config still fit next
# to the rest on the xck26?". Standalone tool, NOT sourced by
# run_cva6_linux_bitstream.tcl -- a separate capacity-measurement entry
# point invoked on its own.
#
#   vivado -mode batch -notrace -source examples/kv260/cva6_linux/fpga/synth_cva6_cfg_ooc.tcl \
#          -tclargs <target-cfg> [<part>] [<en_etrace>]
#
# Examples:
#   ... -tclargs cv32a60x                 (reference, as used in the trio example)
#   ... -tclargs cv32a6_ima_sv32_fpga     (Linux candidate)
#
# Reports: bld/synth_cva6_<cfg>/util_{flat,hier}.rpt (+ timing at 75 MHz).
# Deliberately OOC and without the PS IPs: this measures the PL share of the
# CVA6 branch, comparable across configurations, not the complete board top.

set cfg  [lindex $argv 0]
set part [lindex $argv 1]
set enet [lindex $argv 2]
if {$cfg  eq ""} { set cfg  cv32a60x }
if {$part eq ""} { set part xck26-sfvc784-2LV-c }
if {$enet eq ""} { set enet 1 }

set script_dir [file dirname [file normalize [info script]]]
# This script now sits 4 levels under the repo root
# (examples/kv260/cva6_linux/fpga/), unlike the predecessor repository's vivado/kv260_app/
# (2 levels) -- same path-depth fix as the sibling migrated TCL scripts.
set repo_root  [file normalize [file join $script_dir .. .. .. ..]]
set ref        [file join $repo_root examples kv260 third_party cva6_ref]
set flist      [file join $ref core Flist.cva6]

set outdir [file join $repo_root bld synth_cva6_$cfg]
file mkdir $outdir

puts "### L0: CVA6 branch OOC, config=$cfg, EN_ETRACE=$enet, part=$part"

# --- File list, same exclusions as the bitstream flow -----------------------
# --exclude counter.sv: common_cells' `counter` collides with CTTE's
# counter. tc_sram_wrapper.sv is the sim model -> the FPGA variant is used
# here instead.
set cva6_files [split [string trim [exec py [file join $script_dir cva6_filelist.py] \
    $flist --target $cfg --exclude counter.sv --exclude tc_sram_wrapper.sv]] "\n"]
lappend cva6_files [file join $ref common local util tc_sram_fpga_wrapper.sv]
lappend cva6_files [file join $ref vendor pulp-platform fpga-support rtl SyncSpRamBeNx64.sv]
set cva6_incs [split [string trim [exec py [file join $script_dir cva6_filelist.py] \
    $flist --incdirs]] "\n"]
lappend cva6_incs [file join $ref corev_apu instr_tracing ITI include]

# CTTE encoder sources from the .abc graph (compile order). This
# repository IS the encoder (unlike the predecessor repository's third_party/CTTE/ vendor
# copy) -- same adaptation as run_cva6_linux_bitstream.tcl.
set ctte [file normalize $repo_root]
set ct_files [split [string trim [exec py [file join $script_dir abc_filelist.py] \
    [file join $ctte rtl ct_encoder.abc] --root $ctte --quiet]] "\n"]
lappend ct_files [file join $ctte rtl ct_L2_te_inst_gen.sv]
lappend ct_files [file join $ctte rtl ct_L2_te_packetizer.sv]

set own_files [list \
    [file join $ref core cva6_rvfi.sv] \
    [file join $ref corev_apu instr_tracing ITI include iti_pkg.sv] \
    [file join $ref corev_apu instr_tracing ITI cva6_iti itype_detector.sv] \
    [file join $ref corev_apu instr_tracing ITI cva6_iti single_retirement.sv] \
    [file join $ref corev_apu instr_tracing ITI cva6_iti block_retirement.sv] \
    [file join $ref corev_apu instr_tracing ITI cva6_iti iti.sv] \
    [file join $repo_root rtl adapters cva6 cva6_trace_wrap.sv] \
    [file join $repo_root rtl adapters cva6 cva6_iti_to_ctte_tip.sv] \
    [file join $script_dir .. rtl cva6_soc_synth_wrap.sv] \
]

foreach f [concat $ct_files $cva6_files $own_files] {
	if {![file exists $f]} { puts "### WARN: missing: $f"; continue }
	read_verilog -sv $f
}
set_property include_dirs $cva6_incs [current_fileset]

set_param general.maxThreads 1
puts "### synth_design cva6_soc_synth_wrap ($cfg) ..."
if {[catch {synth_design -top cva6_soc_synth_wrap -part $part -mode out_of_context \
        -generic [list EN_ETRACE=$enet] -include_dirs $cva6_incs} err]} {
	puts "### SYNTH_FAILED ($cfg): $err"
	exit 1
}

report_utilization               -file [file join $outdir util_flat.rpt]
report_utilization -hierarchical -hierarchical_depth 3 -file [file join $outdir util_hier.rpt]

# 75 MHz board clock as a timing hint (OOC approximation, all clocks async).
create_clock -period 13.333 -name clk [get_ports clk]
report_timing_summary -file [file join $outdir timing.rpt]

set rpt [report_utilization -return_string]
foreach line [split $rpt "\n"] {
	if {[regexp {CLB LUTs|CLB Registers|Block RAM Tile|URAM |DSPs} $line]} { puts "### $line" }
}
set wns [get_property SLACK [get_timing_paths -delay_type max]]
puts "### L0_RESULT cfg=$cfg WNS=$wns"
puts "### L0_DONE cfg=$cfg -> $outdir"
