# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Bitstream of the RV64 Linux CVA6 demonstrator (top cva6_linux64_kv260_top).
#
#   vivado -mode batch -notrace -source examples/kv260/cva6_linux64/fpga/run_cva6_linux64_bitstream.tcl
#   vivado ... -source examples/kv260/cva6_linux64/fpga/run_cva6_linux64_bitstream.tcl -tclargs 64
#
# OWN project (proj_linux64/), not the RV32 project: the RV64 configuration
# cv64a6_imac_sv39_ctrace brings a different CVA6 config_pkg than
# cv32a6_ima_sv32_fpga -- both in the same fileset would supply the same
# package declaration twice. The four PS glue IPs are (re)generated with
# gen_ip.tcl in this project (BIT-IDENTICAL configuration to the RV32 Linux
# design, incl. S_AXI_GP3 64 bit for the CVA6 memory path).
#
# The core configuration is replaced by its BOARD version (Cached 64 MiB
# instead of 192 MiB) -- rationale and derivation in
# cva6_linux64_board_cfg.tcl.
#
# ---------------------------------------------------------------------------
# ENCODER ADDRESS WIDTH
# ---------------------------------------------------------------------------
# First tclarg = ct_pkg::CT_XLEN of the encoder, 32 (default) or 64.
#
#   32  ->  this repository's own encoder tree (the default branch, see
#           below), project proj_linux64/, reports cva6_linux64_*.rpt.
#           This is BIT-FOR-BIT the original run; without a tclarg this
#           script does not change.
#   64  ->  CT_XLEN=64 mirror (default bld/w1_rv64_decode/ctte_xlen64,
#           overridable via a second tclarg), own project
#           proj_linux64_x64/, reports cva6_linux64_x64_*.rpt.
#
# WHY a mirror and not a switch: CT_XLEN is a localparam in
# rtl/pkg/ct_pkg.sv, not a `define -- the width is a synthesis parameter of
# the netlist. The mirror is produced from a separately checked-out working
# tree with CT_XLEN=64 and carries a provenance file with the source commit
# and a ct_pkg hash.
#
# NOTE (migration, 2026-08-17): in the predecessor repository this mirror was produced by a
# session-specific measurement workflow (sim/cva6_rv64/mk_ctte64.ps1) from a
# separate working checkout of the encoder, which has not been ported into
# this repository yet -- bld/ here is gitignored and currently empty for
# this path. The x64 branch is kept structurally intact (so a future port
# only needs to populate the directory, not rewrite this script), but it is
# NOT functional today.
#
# EN_ETRACE stays 0 (cva6_linux64_kv260_top.sv). That is not merely a
# profile choice at CT_XLEN=64, it is mandatory: ct_encoder aborts
# elaboration with $fatal otherwise (X2b not implemented).

set script_dir [file dirname [file normalize [info script]]]
# This script now sits 4 levels under the repo root
# (examples/kv260/cva6_linux64/fpga/), unlike the predecessor repository's vivado/kv260_app/
# (2 levels) -- same path-depth fix as the sibling migrated TCL scripts.
set repo_root  [file normalize [file join $script_dir .. .. .. ..]]
set part       xck26-sfvc784-2LV-c
set cfg        cv64a6_imac_sv39_ctrace

set ct_xlen 32
if {[llength $argv] >= 1} { set ct_xlen [lindex $argv 0] }
if {$ct_xlen ne "32" && $ct_xlen ne "64"} {
	puts "### ERROR: first tclarg must be 32 or 64 (was '$ct_xlen')"; exit 1
}
if {$ct_xlen eq "64"} {
	set ctte_root [file join $repo_root bld w1_rv64_decode ctte_xlen64]
	if {[llength $argv] >= 2} { set ctte_root [file normalize [lindex $argv 1]] }
	set proj_name  cva6_linux64_x64_kv260
	set proj_dir   [file join $script_dir proj_linux64_x64]
	set rpt_pfx    cva6_linux64_x64
	set outdir     [file join $repo_root bld w1_rv64_decode]
	# Third tclarg = tag. Without it the run is unchanged. With it the run
	# gets its OWN project and own reports -- a measurement build must not
	# overwrite the tree an existing reference bitstream came from
	# (otherwise it is no longer provable afterwards which button state a
	# measurement was taken with).
	if {[llength $argv] >= 3 && [lindex $argv 2] ne ""} {
		set sfx        [lindex $argv 2]
		set proj_name  cva6_linux64_x64_${sfx}_kv260
		set proj_dir   [file join $script_dir proj_linux64_x64_$sfx]
		set rpt_pfx    cva6_linux64_x64_$sfx
		set outdir     [file join $repo_root bld w5_ownership_board]
	}
} else {
	# This repository IS the CTTE encoder (unlike the predecessor repository, which
	# built against a third_party/CTTE/ vendor copy) -- default source
	# is the repo root itself, same adaptation as the sibling migrated TCL
	# scripts.
	set ctte_root [file normalize $repo_root]
	set proj_name  cva6_linux64_kv260
	set proj_dir   [file join $script_dir proj_linux64]
	set rpt_pfx    cva6_linux64
	set outdir     [file join $repo_root bld r4b_cv64a6_bit]
}
file mkdir $outdir

file delete -force $proj_dir
create_project $proj_name $proj_dir -part $part
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property xpm_libraries {XPM_MEMORY XPM_CDC XPM_FIFO} [current_project]

set ref    [file join $repo_root examples kv260 third_party cva6_ref]
set pulp   [file join $ref vendor pulp-platform]
set ctte $ctte_root
set rtl    [file join $script_dir .. rtl]
set common_dir [file join $repo_root examples kv260 common]
set tgc5b_dir  [file join $repo_root examples kv260 common tgc5b rtl]

# --- 1. CTTE encoder (from the .abc graph, unchanged -- AD-01) -----------
# xlen 32: this repository's own encoder tree.
# xlen 64: a separately checked-out mirror with CT_XLEN=64 (see header).
#
# The width switch is READ BACK FROM the tree, not assumed -- a bitstream
# carrying the wrong encoder otherwise only shows up at the board (and
# there as "decoder broken", not as "wrong build").
set ct_pkg_file [file join $ctte rtl pkg ct_pkg.sv]
if {![file exists $ct_pkg_file]} { puts "### ERROR: $ct_pkg_file missing"; exit 1 }
set fh [open $ct_pkg_file r]; set ct_pkg_txt [read $fh]; close $fh
set have_xlen 32
if {[regexp {localparam int unsigned CT_XLEN = (\d+);} $ct_pkg_txt -> m]} {
	set have_xlen $m
} elseif {$ct_xlen eq "64"} {
	puts "### ERROR: $ct_pkg_file does not know CT_XLEN (encoder stand predates X2a)"; exit 1
}
if {$have_xlen ne $ct_xlen} {
	puts "### ERROR: encoder tree carries CT_XLEN=$have_xlen, requested is $ct_xlen"
	puts "###        tree: $ctte"
	exit 1
}
set prov [file join $ctte CTTE_XLEN_PROVENANCE.txt]
puts "### ENCODER: $ctte  (CT_XLEN=$have_xlen)"
if {[file exists $prov]} {
	set fh [open $prov r]
	foreach ln [split [string trim [read $fh]] "\n"] { puts "###   $ln" }
	close $fh
}
if {[catch {set ct_files [exec py [file join $script_dir abc_filelist.py] \
        [file join $ctte rtl ct_encoder.abc] --root $ctte --quiet]} err]} {
	puts "### ERROR: abc_filelist.py failed: $err"; exit 1
}
set ct_files [split [string trim $ct_files] "\n"]
# E-Trace backend: NOT in the .abc graph (that describes the N-Trace path
# only), but mandatory for the DUAL build -- the same addition as in the
# RV32 run.
lappend ct_files [file join $ctte rtl ct_L2_te_inst_gen.sv]
lappend ct_files [file join $ctte rtl ct_L2_te_packetizer.sv]

# --- 2. CVA6 in the RV64 configuration (delta D6, board version) -----------
# --exclude counter.sv: common_cells' `counter` collides with CTTE's
#   module of the same name (different port list); PULP consumers instead
#   pull the renamed copy pulp_counter.sv (vendoring delta, CVA6_PIN.md).
# --exclude tc_sram_wrapper.sv: behavioral == simulation only; synthesis
#   uses tc_sram_fpga_wrapper + SyncSpRamBeNx64 instead (otherwise DRC INBB-3).
set flist [file join $ref core Flist.cva6]
set cva6_files [split [string trim [exec py [file join $script_dir cva6_filelist.py] \
    $flist --target $cfg --exclude counter.sv --exclude tc_sram_wrapper.sv]] "\n"]

source [file join $script_dir cva6_linux64_board_cfg.tcl]
set cfg_sv [r4b_board_config_pkg $repo_root $outdir]
set idx -1
for {set i 0} {$i < [llength $cva6_files]} {incr i} {
	if {[file tail [lindex $cva6_files $i]] eq "${cfg}_config_pkg.sv"} { set idx $i; break }
}
if {$idx < 0} { puts "### ERROR: ${cfg}_config_pkg.sv not in the file list"; exit 1 }
set cva6_files [lreplace $cva6_files $idx $idx $cfg_sv]

lappend cva6_files [file join $ref common local util tc_sram_fpga_wrapper.sv]
lappend cva6_files [file join $ref vendor pulp-platform fpga-support rtl SyncSpRamBeNx64.sv]
set cva6_incs [split [string trim [exec py [file join $script_dir cva6_filelist.py] $flist --incdirs]] "\n"]
lappend cva6_incs [file join $ref corev_apu instr_tracing ITI include]

# --- 3. ITI + PULP AXI infrastructure + our own SoC building blocks --------
# Against the RV32 version, exactly three swapped lines:
# cva6_soc64_synth_wrap / cva6_linux64_periph / cva6_linux64_soc_top.
# cva6_linux_mem_xbar is SHARED (width-parametric; the RV64 instance sets
# RISCV_WORD_WIDTH=64, default 32 = RV32 state) -- cross-referenced from
# ../../cva6_linux/rtl/, not duplicated.
set soc_files [list \
    [file join $ref core cva6_rvfi.sv] \
    [file join $ref corev_apu instr_tracing ITI include iti_pkg.sv] \
    [file join $ref corev_apu instr_tracing ITI cva6_iti itype_detector.sv] \
    [file join $ref corev_apu instr_tracing ITI cva6_iti single_retirement.sv] \
    [file join $ref corev_apu instr_tracing ITI cva6_iti block_retirement.sv] \
    [file join $ref corev_apu instr_tracing ITI cva6_iti iti.sv] \
    [file join $repo_root rtl adapters cva6 cva6_trace_wrap.sv] \
    [file join $repo_root rtl adapters cva6 cva6_riscv_itype_refine.sv] \
    [file join $repo_root rtl adapters cva6 cva6_iti_to_ctte_tip.sv] \
    [file join $pulp common_cells src pulp_counter.sv] \
    [file join $pulp common_cells src delta_counter.sv] \
    [file join $pulp common_cells src onehot_to_bin.sv] \
    [file join $pulp common_cells src id_queue.sv] \
    [file join $pulp common_cells src deprecated fifo_v2.sv] \
    [file join $pulp common_cells src spill_register_flushable.sv] \
    [file join $pulp common_cells src spill_register.sv] \
    [file join $pulp common_cells src stream_register.sv] \
    [file join $pulp axi src axi_intf.sv] \
    [file join $pulp axi src axi_atop_filter.sv] \
    [file join $pulp axi src axi_burst_splitter.sv] \
    [file join $pulp axi src axi_demux.sv] \
    [file join $pulp axi src axi_err_slv.sv] \
    [file join $pulp axi src axi_to_axi_lite.sv] \
    [file join $pulp axi_riscv_atomics src axi_res_tbl.sv] \
    [file join $pulp axi_riscv_atomics src axi_riscv_amos_alu.sv] \
    [file join $pulp axi_riscv_atomics src axi_riscv_amos.sv] \
    [file join $pulp axi_riscv_atomics src axi_riscv_lrsc.sv] \
    [file join $pulp axi_riscv_atomics src axi_riscv_atomics.sv] \
    [file join $pulp axi_riscv_atomics src axi_riscv_lrsc_wrap.sv] \
    [file join $pulp axi_riscv_atomics src axi_riscv_atomics_wrap.sv] \
    [file join $rtl cva6_soc64_synth_wrap.sv] \
    [file join $tgc5b_dir ct_axil_to_wb.sv] \
    [file join $common_dir ct_soc_trace_ring.sv] \
    [file join $common_dir ct_soc_ddr_sink.sv] \
    [file join $common_dir ct_soc_pib.sv] \
    [file join $rtl cva6_linux64_periph.sv] \
    [file join $repo_root examples kv260 cva6_linux rtl cva6_linux_mem_xbar.sv] \
    [file join $rtl cva6_linux64_soc_top.sv] \
    [file join $script_dir cva6_linux64_kv260_top.sv] \
]

# EVERYTHING in xil_defaultlib (NO separate library) -- CTTE's counter.sv
# carries MODE_SATURATION as a $unit-scope declaration; a library split
# would cut the compilation-unit groups apart (C4 finding 2026-07-24).
foreach f [concat $ct_files $cva6_files $soc_files] {
	set f [file normalize $f]
	if {![file exists $f]} { puts "### ERROR missing: $f"; exit 1 }
	add_files -fileset sources_1 -norecurse $f
	set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1] $f]
}
set_property include_dirs $cva6_incs [get_filesets sources_1]

set xdc [file normalize [file join $script_dir cva6_pib_pmod.xdc]]
add_files -fileset constrs_1 -norecurse $xdc

# --- 4. PS glue IPs (verbatim as for the RV32 Linux run, incl. S_AXI_GP3) ---
namespace eval abc { variable proj_dir }
set abc::proj_dir $proj_dir
source [file join $script_dir gen_ip.tcl]
catch { config_ip_cache -clear_output_repo }
catch { config_ip_cache -disable_cache }
# GLOBAL instead of OOC: the realtime stub generator stubbornly emitted a
# stale port list during the trio bring-up (6th attempt). Without a synth
# checkpoint there is no stub path -- the four small IPs are inline
# co-synthesized instead.
foreach ipname {ct_soc_kv260_ps ct_soc_kv260_rst ct_soc_kv260_dwc ct_soc_kv260_pc} {
	set xci [get_files -quiet -all */${ipname}.xci]
	if {[llength $xci]} { set_property generate_synth_checkpoint false $xci }
}
generate_target all [get_ips ct_soc_kv260_*]

set_property top cva6_linux64_kv260_top [current_fileset]
update_compile_order -fileset sources_1

# --- 5. Synthesis -> implementation -> bitstream -----------------------------
# An aborted run WITHOUT an ERROR line is treated first as a tool crash for
# this design type: Vivado 2026.1 died twice on a comparable design without
# a message, the unchanged rerun then went through -- try an unchanged
# repeat once before searching the RTL.
# Note (2026-08-08 22:53): the synthesis worker of this design has died on
# a machine under parallel foreign load with `out of memory allocating
# 8388640 bytes` -- MID "Cross Boundary and Area Optimization", without an
# ERROR line in the parent process. The parent Vivado then hangs forever in
# wait_on_run; visible only by the processes' CPU time no longer advancing
# and `__synthesis_is_running__` staying behind. MBV_MAXTHREADS=<n> caps the
# synthesis thread count and thereby the memory peak; without the variable
# the run is unchanged (a reference run stays reproducible).
if {[info exists ::env(MBV_MAXTHREADS)] && $::env(MBV_MAXTHREADS) ne ""} {
	set_param general.maxThreads $::env(MBV_MAXTHREADS)
	puts "### MAXTHREADS: $::env(MBV_MAXTHREADS)"
}
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { puts "### SYNTH_FAIL"; exit 3 }
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { puts "### IMPL_FAIL"; exit 4 }

set bit [glob -nocomplain [file join $proj_dir ${proj_name}.runs impl_1 *.bit]]
puts "### BITSTREAM_OK: $bit"

open_run impl_1
report_timing_summary -file [file join $script_dir ${rpt_pfx}_timing_summary.rpt]
report_utilization    -file [file join $script_dir ${rpt_pfx}_utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 3 \
                   -file [file join $script_dir ${rpt_pfx}_utilization_hier.rpt]
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "### WNS: $wns ns   WHS: $whs ns"
exit 0
