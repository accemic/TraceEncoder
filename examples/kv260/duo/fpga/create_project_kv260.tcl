# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# create_project_kv260.tcl -- duo (MBV + TGC5B) KV260 project. Entry point.
#
#   vivado -mode batch -source examples/kv260/duo/fpga/create_project_kv260.tcl            # project + elab check
#   DUO_KV260_SYNTH=1 vivado -mode batch -source .../create_project_kv260.tcl               # + full synth/impl/bitstream
#
# Migrated from an internal predecessor repository,
# run_duo_bitstream.tcl}.
# the predecessor repository built this bitstream INCREMENTALLY, by first running the mbv
# entry point (create_project_kv260.tcl there) to get a cached mbv_kv260
# project + its already-generated MicroBlaze-V block design, and only then
# running run_duo_bitstream.tcl to add the TGC5B/funnel/sink files on top and
# switch the fileset top to duo_kv260_top -- a local development-time reuse
# optimization (project-cache reuse across iterations, not a portability
# requirement of the design itself: the resulting bitstream is identical
# either way). This example is migrated as a SELF-CONTAINED single entry
# point instead (matching examples/kv260/mbv/fpga/create_project_kv260.tcl's
# convention), so a fresh checkout of this repository can build `duo`
# without first building `mbv`. It therefore performs the block-design
# creation step mbv's script performs (`create_bd.tcl`, required because
# `mbv_soc_synth_wrap.sv` -- which duo_soc_top instantiates for its MBV
# branch -- instantiates the Vivado-generated `mbv_ctrace_soc_wrapper`) in
# addition to the duo-specific board/top files.
#
# Aufbau: xck26 project + CTTE encoder (file list from the .abc graph,
# abc_filelist.py) + MBV adapter RTL + the mbv_ctrace_soc block design
# (MBV_KV260=1 mode -- BRAM ports at the edge, 75 MHz) + the TGC5B building
# blocks (from examples/kv260/common/tgc5b/, this repository's own copy) + the shared
# sink RTL (examples/kv260/common/) + this example's own duo_soc_top.sv /
# duo_kv260_top.sv + the 4 standalone PS-glue IPs (gen_ip.tcl).
#
# The default run ends with `synth_design -rtl -top duo_soc_top` as an
# elaboration gate: this checks every new RTL building block + the BD
# wrapper's port names, without waiting for the PS IP generation.

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir .. .. .. ..]]
set proj_name  duo_kv260
set proj_dir   [file join $script_dir proj]
set part       xck26-sfvc784-2LV-c

file delete -force $proj_dir
create_project $proj_name $proj_dir -part $part
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property xpm_libraries {XPM_MEMORY XPM_CDC XPM_FIFO} [current_project]

# --- CTTE encoder sources (pinned, UNCHANGED -- AD-01) in compile order --
# This repository IS the encoder (rtl/ct_encoder.abc sits at $repo_root).
set filelist_tool [file join $script_dir abc_filelist.py]
if {[catch {set ct_files [exec py $filelist_tool [file join $repo_root rtl ct_encoder.abc] --quiet]} err]} {
	puts "### ERROR: abc_filelist.py failed: $err"
	exit 1
}
set ct_files [split [string trim $ct_files] "\n"]
puts "### CTTE sources resolved from .abc: [llength $ct_files]"

# --- MBV adapter RTL (order: pkg -> if -> module) ---
set adapter_dir [file join $repo_root rtl adapters amd_microblaze_v]
set our_files [list \
	[file join $adapter_dir mbv_trace_pkg.sv] \
	[file join $adapter_dir mbv_trace_if.sv] \
	[file join $adapter_dir mbv_riscv_itype_decoder.sv] \
	[file join $adapter_dir mbv_trap_mapper.sv] \
	[file join $adapter_dir mbv_to_ctte_tip.sv] \
]

# --- TGC5B building blocks (order: pkg -> cpu -> rtl); this repository's own
# examples/kv260/common/tgc5b/ copy, not a vendored snapshot ---
set tgc [file join $repo_root examples kv260 common tgc5b]
set tgc_files [list \
	[file join $tgc pkg ct_soc_regs_pkg.sv] \
	[file join $tgc pkg ct_soc_regs.sv] \
	[file join $tgc cpu TGC5B_AXI4L_H2E.sv] \
	[file join $tgc rtl ct_tip_adapter.sv] \
	[file join $tgc rtl ct_soc_ram.sv] \
	[file join $tgc rtl ct_soc_periph.sv] \
	[file join $tgc rtl ct_soc_synth_wrap.sv] \
	[file join $tgc rtl ct_axil_to_wb.sv] \
	[file join $tgc rtl ct_soc_axis_buf.sv] \
]

# --- shared sink RTL (examples/kv260/common/) + own MBV RTL (mbv/rtl/) +
# funnel (repo root) + this example's own board RTL + bitstream top ---
set common_dir [file join $repo_root examples kv260 common]
set mbv_rtl    [file join $repo_root examples kv260 mbv rtl]
set board_files [list \
	[file join $common_dir ct_soc_trace_ring.sv] \
	[file join $common_dir ct_soc_ddr_sink.sv] \
	[file join $common_dir ct_soc_pib.sv] \
	[file join $common_dir ct_trace_sinks.sv] \
	[file join $repo_root rtl ct_L1_funnel.sv] \
	[file join $mbv_rtl mbv_soc_synth_wrap.sv] \
	[file join $script_dir .. rtl duo_soc_top.sv] \
	[file join $script_dir duo_kv260_top.sv] \
]

foreach f [concat $ct_files $our_files $tgc_files $board_files] {
	set f [file normalize $f]
	if {![file exists $f]} { puts "### WARN missing: $f"; continue }
	add_files -fileset sources_1 -norecurse $f
	set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1] $f]
}

# --- Constraints (PIB pinout) ---
set xdc [file normalize [file join $script_dir duo_pib_pmod.xdc]]
add_files -fileset constrs_1 -norecurse $xdc

# --- Block design in KV260 mode (BRAM external, 75 MHz) -- required by
# mbv_soc_synth_wrap.sv's mbv_ctrace_soc_wrapper instantiation. Reused from
# the mbv example (already migrated, ../../mbv/fpga/create_bd.tcl) rather
# than vendoring a second copy -- read-only source, not modified here. ---
set ::env(MBV_KV260) 1
source [file join $repo_root examples kv260 mbv fpga create_bd.tcl]

set bd_file [get_files *mbv_ctrace_soc.bd]
make_wrapper -files $bd_file -top
set wrapper [file join $proj_dir ${proj_name}.gen sources_1 bd mbv_ctrace_soc hdl mbv_ctrace_soc_wrapper.v]
if {![file exists $wrapper]} {
	set wrapper [lindex [glob -nocomplain [file join $proj_dir *.gen sources_1 bd mbv_ctrace_soc hdl *wrapper.v]] 0]
}
add_files -norecurse $wrapper
puts "### WRAPPER: $wrapper"

# --- PS-glue IPs (verbatim gen_ip.tcl; abc namespace shim) ---
namespace eval abc { variable proj_dir }
set abc::proj_dir $proj_dir
source [file join $script_dir gen_ip.tcl]

set_property top duo_kv260_top [current_fileset]
update_compile_order -fileset sources_1

# Synthesize the BD globally (no OOC-per-IP checkpoint) -- otherwise
# elaboration is missing the generated IP submodules (mbv_ctrace_soc_dlmb_0 ...).
set_property synth_checkpoint_mode None $bd_file
generate_target all $bd_file

# --- Elaboration gate: duo_soc_top (without the PS IPs) ---
puts "### ELAB-CHECK: synth_design -rtl -top duo_soc_top"
if {[catch {synth_design -rtl -top duo_soc_top -mode out_of_context} elab_err]} {
	puts "### ELAB_FAIL: $elab_err"
	exit 2
}
puts "### ELAB_OK (duo_soc_top elaborates)"
close_design
# synth_design -rtl -top switches the fileset top -- switch back to the
# bitstream top for the runs (otherwise synth_1 implements duo_soc_top with
# bare I/O ports -> DRC NSTD-1/UCIO-1).
set_property top duo_kv260_top [current_fileset]
update_compile_order -fileset sources_1

if {[info exists ::env(DUO_KV260_SYNTH)] && $::env(DUO_KV260_SYNTH) eq "1"} {
	puts "### SYNTH: full flow (synth_1 -> impl_1 -> bitstream)"
	# Only the 4 standalone PS-glue IPs -- BD-internal IPs (mbv_ctrace_soc_*)
	# are generated exclusively by the BD itself (Vivado 12-3563).
	generate_target all [get_ips ct_soc_kv260_*]
	launch_runs synth_1 -jobs 8
	wait_on_run synth_1
	if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { puts "### SYNTH_FAIL"; exit 3 }
	launch_runs impl_1 -to_step write_bitstream -jobs 8
	wait_on_run impl_1
	if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { puts "### IMPL_FAIL"; exit 4 }
	open_run impl_1
	set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
	puts "### WNS: $wns"
	report_utilization -hierarchical -hierarchical_depth 2 \
		-file [file join $script_dir duo_utilization.rpt]
	puts "### BITSTREAM_OK: [glob -nocomplain [file join $proj_dir ${proj_name}.runs impl_1 *.bit]]"
}

puts "### PROJECT READY: $proj_dir  TOP: [get_property top [current_fileset]]"
