# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# create_project.tcl -- AXIS watchpoint testbed. Entry point.
#
#   vivado -mode batch -notrace -source examples/kv260/tgc5b2_axis_wp/fpga/create_project.tcl
#
# Migrated from an internal predecessor repository
#. the predecessor repository's original script
# selected between four RTL legs (D1/C0B/C0B_DDR/C0B_SINK3, an iteration
# history of this testbed's encoder feature set) via the AXIS_WP_LEG env
# var; by the T2 state migrated here all legs build the SAME RTL (the leg
# split only ever differed in which encoder checkout was bound), so that
# selection machinery -- including the C0B leg's dependency on a read-only
# external worktree path that does not exist outside the predecessor repository -- is not
# carried over. This script always builds the T2 configuration, matching
# what the predecessor repository called the C0B_SINK3 leg.
#
# Structure follows the kv260_app pattern (examples/kv260/mbv/fpga/
# create_project_kv260.tcl): xck26 project + CTTE encoder (file list from
# the .abc graph, tools/abc_filelist.py, vendored per-example as
# abc_filelist.py) + rtl/ct_L1_funnel.sv (this repository's only copy, the
# delta version with chan_te_raw/te_tag_*/EN_TE_RAW -- no duplicate-version
# pinning needed here, unlike the predecessor repository, since only one copy exists in this
# tree) + the shared TGC5B building blocks (from examples/kv260/common/tgc5b/, this
# repository's own copy -- NOT a vendored third_party/ snapshot, since this
# repository hosts them as a library) + this example's own RTL +
# bitstream top tgc5b2_kv260_top + the 5 standalone IPs (gen_ip.tcl).
#
# The run ends with an elaboration gate: `synth_design -rtl -top
# tgc5b2_axis_soc_top` checks every RTL building block without waiting for
# the PS IP generation; it also prints the FIFO IP's instantiation template
# (port-contract verification for tgc5b2_kv260_top). Full bitstream build:
# run_bitstream.tcl.

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir .. .. .. ..]]
set proj_name  tgc5b2_axis_wp
set proj_dir   [file join $script_dir proj]
set part       xck26-sfvc784-2LV-c

file delete -force $proj_dir
create_project $proj_name $proj_dir -part $part
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property xpm_libraries {XPM_MEMORY XPM_CDC XPM_FIFO} [current_project]

# --- CTTE encoder sources in compile order -------------------------------
# This repository IS the encoder (rtl/ct_encoder.abc sits at $repo_root),
# unlike the predecessor repository which vendored a third_party/CTTE copy.
set filelist_tool [file join $script_dir abc_filelist.py]
if {[catch {set ct_files [exec py $filelist_tool [file join $repo_root rtl ct_encoder.abc] --root $repo_root --quiet]} err]} {
	puts "### ERROR: abc_filelist.py failed: $err"
	exit 1
}
set ct_files [split [string trim $ct_files] "\n"]
puts "### CTTE sources resolved from .abc: [llength $ct_files]"

# Funnel: this repository's rtl/ct_L1_funnel.sv is the delta version
# (chan_te_raw/te_tag_*/EN_TE_RAW) the SoC top instantiates. It is not part
# of the ct_encoder.abc closure (the funnel is system-integration RTL, not
# part of the encoder core), so it is appended explicitly. Unlike
# the predecessor repository's create_project.tcl, no de-duplication pass is needed here --
# this tree carries exactly one ct_L1_funnel.sv.
set funnel [file join $repo_root rtl ct_L1_funnel.sv]
if {[lsearch -exact $ct_files $funnel] < 0} { lappend ct_files $funnel }

# --- shared TGC5B building blocks (order: pkg -> cpu -> rtl) ---
# This repository's own examples/kv260/common/tgc5b/ copy (not a vendored snapshot).
set tgc [file join $repo_root examples kv260 common tgc5b]
set tgc_files [list \
	[file join $tgc pkg ct_soc_regs_pkg.sv] \
	[file join $tgc pkg ct_soc_regs.sv] \
	[file join $tgc cpu TGC5B_AXI4L_H2E.sv] \
	[file join $tgc rtl ct_tip_adapter.sv] \
	[file join $tgc rtl ct_soc_ram.sv] \
	[file join $tgc rtl ct_soc_periph.sv] \
	[file join $tgc rtl ct_axil_to_wb.sv] \
]

# --- shared sink/shim RTL (examples/kv260/common/) + this example's own RTL --
set common_dir [file join $repo_root examples kv260 common]
set board_files [list \
	[file join $common_dir ct_soc_trace_ring.sv] \
	[file join $common_dir ct_soc_ddr_sink.sv] \
	[file join $common_dir ct_soc_pib.sv] \
	[file join $common_dir ct_trace_sinks.sv] \
	[file join $common_dir ct_axis_wp_shim.sv] \
	[file join $script_dir .. rtl tgc5b_wp_synth_wrap.sv] \
	[file join $script_dir .. rtl tgc5b2_axis_soc_top.sv] \
	[file join $script_dir tgc5b2_kv260_top.sv] \
]

foreach f [concat $ct_files $tgc_files $board_files] {
	set f [file normalize $f]
	if {![file exists $f]} { puts "### ERROR missing: $f"; exit 1 }
	add_files -fileset sources_1 -norecurse $f
	set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1] $f]
}

# --- Constraints -------------------------------------------------------------
set xdc [file join $script_dir tgc5b2_axis_wp.xdc]
add_files -fileset constrs_1 -norecurse $xdc

# --- Standalone IPs (gen_ip.tcl; own ip tree, kv260_app is untouched) --------
source [file join $script_dir gen_ip.tcl]

set_property top tgc5b2_kv260_top [current_fileset]
update_compile_order -fileset sources_1

# --- FIFO port contract: print the instantiation template -------------------
generate_target instantiation_template [get_ips wp_axi_fifo]
set veo [glob -nocomplain [file join $script_dir ip wp_axi_fifo wp_axi_fifo.veo]]
if {$veo ne ""} {
	set fh [open [lindex $veo 0] r]; set vtxt [read $fh]; close $fh
	puts "### WP_AXI_FIFO VEO:"
	foreach line [split $vtxt "\n"] {
		if {[regexp {^\s*\.} $line]} { puts "### VEO: [string trim $line]" }
	}
} else {
	puts "### WARN: wp_axi_fifo.veo not found"
}

# --- Elaboration gate: SoC top without the PS IPs ---------------------------
puts "### ELAB-CHECK: synth_design -rtl -top tgc5b2_axis_soc_top"
if {[catch {synth_design -rtl -top tgc5b2_axis_soc_top -mode out_of_context} elab_err]} {
	puts "### ELAB_FAIL: $elab_err"
	exit 2
}
puts "### ELAB_OK (tgc5b2_axis_soc_top elaborates)"
close_design
# synth_design -rtl -top switches the fileset top -- switch back to the
# bitstream top.
set_property top tgc5b2_kv260_top [current_fileset]
update_compile_order -fileset sources_1

puts "### PROJECT READY: $proj_dir  TOP: [get_property top [current_fileset]]"
