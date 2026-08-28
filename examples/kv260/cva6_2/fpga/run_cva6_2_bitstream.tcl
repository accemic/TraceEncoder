# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Bitstream of the dual-CVA6 demonstrator (top cva6_2_kv260_top).
#
#   vivado -mode batch -notrace -source examples/kv260/cva6_2/fpga/run_cva6_2_bitstream.tcl \
#          [-tclargs <cva6-config> [<ctte-root>]]
#
#   <cva6-config>  cv64a6_imac_sv39_ctrace (default) or cv32a6_ima_sv32_fpga
#
# ONE file for BOTH deliveries (requirement: a congruent view): RV32 and
# RV64 differ EXCLUSIVELY in the core configuration. Register map,
# segments, memory layout, block sequence and labeling are identical --
# the same demonstrator must not tell two different stories depending on
# the visitor.
#
# FOUR points, each with a reason:
#
#  1. PS IP is ct_soc_kv260_ps4 (FOUR slave ports), not the shared
#     ct_soc_kv260_ps. Extending the shared one would have forced every
#     other app to resynthesize and left its two new slave ports undriven
#     -- and a demonstrator is running from one of these bitstreams on the
#     board right now (gen_ip_ps4.tcl, header).
#
#  2. ENCODER from a MIRROR, one per variant (rv64:
#     bld/m4_rocket_2hart/ctte_slim64, rv32: bld/d3_cva6_2_soc/ctte_slim32).
#     The repository's own rtl/ is the RV32 FULL profile and is shared with
#     six other examples; only a mirror carries this design's slim profile,
#     and only the rv64 one carries CT_XLEN=64. Build them with
#     examples/kv260/common/tools/mk_encoder_mirror.sh. The width switch is
#     READ BACK FROM the tree, not assumed -- a bitstream with the wrong
#     encoder otherwise only shows up at the board (and there as "decoder
#     broken" instead of "wrong build").
#
#  3. FUNNEL: this repository's own repo-root rtl/ct_L1_funnel.sv (delta
#     version, MDO_WIDTH=6), NOT a copy inside the encoder tree -- finding
#     F-1: an upstream funnel version parses ONE 32-bit chunk per beat,
#     while the encoder of this design emits four byte chunks. It would
#     switch channels mid-message, and elaboration turns nothing red.
#     (This was a deviation from ../../rocket2/fpga/run_rocket2_bitstream.tcl,
#     whose migrated funnel path pointed at a non-existent
#     third_party/CTTE/rtl/ct_L1_funnel.sv left over from the source
#     repository's layout. That path was corrected to the same repo-root file
#     on 2026-08-18, so the two flows now agree -- verified before writing
#     this script that repo-root rtl/ct_L1_funnel.sv is the correct, already
#     MDO_WIDTH-parametrized file in THIS repository, see
#     ../rtl/cva6_2_soc_synth_wrap.sv's own header.)
#
#  4. TIMING IS A GATE. A negative WNS leads to exit 5. A bitstream that
#     does not hold the target frequency is not a result, it is a file.
#     At RV64, timing is the FIRST number to re-measure.
#
# EN_ETRACE is FIXED at 0 and not a tclarg: the funnel parses MSEO, an
# E-Trace backend delivers raw bytes (the shell aborts elaboration at 1),
# and CT_XLEN=64 forbids it anyway.

set script_dir [file dirname [file normalize [info script]]]
# This script now sits 4 levels under the repo root
# (examples/kv260/cva6_2/fpga/), unlike the predecessor repository's vivado/kv260_app/
# (2 levels) -- same path-depth fix as the sibling migrated TCL scripts.
set repo_root  [file normalize [file join $script_dir .. .. .. ..]]
set part       xck26-sfvc784-2LV-c

set cfg [lindex $argv 0]
if {$cfg eq ""} { set cfg cv64a6_imac_sv39_ctrace }
set ctte [lindex $argv 1]

switch -- $cfg {
	cv64a6_imac_sv39_ctrace { set variant rv64 }
	cv32a6_ima_sv32_fpga    { set variant rv32 }
	default {
		puts "### ERROR: unknown CVA6 configuration '$cfg'"
		puts "###        allowed: cv64a6_imac_sv39_ctrace | cv32a6_ima_sv32_fpga"
		puts "###        NOT cv32a60x -- it carries MmuPresent=0 and RVS=0 and"
		puts "###        cannot run Linux."
		exit 1
	}
}

# ENCODER MIRROR, per variant. Produced by
# examples/kv260/common/tools/mk_encoder_mirror.sh (the Bash port of
# the predecessor repository's mk_ctte_m4.ps1, migrated 2026-08-18):
#
#   rv64: mk_encoder_mirror.sh --dest bld/m4_rocket_2hart/ctte_slim64 \
#             --profile slimfull_gold --xlen 64 --ctx-width 22
#   rv32: mk_encoder_mirror.sh --dest bld/d3_cva6_2_soc/ctte_slim32 \
#             --profile slimfull_gold --xlen 32 --ctx-width 22
#
# TWO mirrors, not one, and the earlier "both widths are correct here"
# comment below this block was WRONG since 2026-08-12: P0-07 (1415a02524)
# added an elaboration guard that refuses CORE_XLEN != ct_pkg::CT_XLEN, and
# ../rtl/cva6_2_soc_synth_wrap.sv passes .CORE_XLEN(Cfg.XLEN). An RV32 build
# against the 64-bit mirror therefore no longer synthesizes -- it aborts with
# "CORE_XLEN=32 does not match this netlist's trace ingress width of 64 bit".
# The variant now picks its own tree, and the check below is symmetric.
#
# Why a slim profile at all: TWO encoders. The full profile costs 25,743 LUT
# per encoder (synth_cva6_2_ooc.tcl header point 4), slimfull_gold 4,653 --
# two full ones plus two cores are hopeless on the xck26 from the outset.
if {$ctte eq ""} {
	if {$variant eq "rv64"} {
		set ctte [file join $repo_root bld m4_rocket_2hart ctte_slim64]
	} else {
		set ctte [file join $repo_root bld d3_cva6_2_soc ctte_slim32]
	}
}
set ctte [file normalize $ctte]

set enet      0
set proj_name cva6_2_${variant}_kv260
set proj_dir  [file join $script_dir proj_cva6_2_$variant]
set rpt_pfx   cva6_2_$variant
set outdir    [file join $repo_root bld d3_cva6_2_soc bit_$variant]
set ref       [file join $repo_root examples kv260 third_party cva6_ref]
set pulp      [file join $ref vendor pulp-platform]
set rtl       [file join $script_dir .. rtl]
file mkdir $outdir

puts "### D3-BIT: variant $variant ($cfg), encoder $ctte"

# --- 0. Encoder tree button state read back (W1 lesson) --------------------
set ct_pkg_file [file join $ctte rtl pkg ct_pkg.sv]
if {![file exists $ct_pkg_file]} { puts "### ERROR: $ct_pkg_file missing"; exit 1 }
set fh [open $ct_pkg_file r]; set ct_pkg_txt [read $fh]; close $fh
set have_xlen 0
regexp {localparam int unsigned CT_XLEN = (\d+);} $ct_pkg_txt -> have_xlen
puts "### ENCODER: $ctte  (CT_XLEN=$have_xlen, EN_ETRACE=$enet)"
# HARD comparison, both ways (changed 2026-08-18). Until P0-07 the RV32
# build was allowed to carry the 64-bit encoder and this check only guarded
# the RV64 side; ct_encoder now refuses the mismatch in elaboration
# (rtl/ct_encoder.sv:298), because a 32-bit ingress silently truncates a
# 64-bit hart's upper address bits and the stream stays well-formed. Failing
# here costs a second, failing in synthesis costs the whole run.
set want_xlen [expr {$variant eq "rv64" ? 64 : 32}]
if {$have_xlen ne "$want_xlen"} {
	puts "### ERROR: $variant build requires CT_XLEN=$want_xlen, tree carries $have_xlen"
	puts "###        tree: $ctte"
	puts "###        build it with examples/kv260/common/tools/mk_encoder_mirror.sh"
	exit 1
}
foreach provname {CTTE_M4_PROVENANCE.txt CTTE_XLEN_PROVENANCE.txt} {
	set prov [file join $ctte $provname]
	if {[file exists $prov]} {
		set fh [open $prov r]
		foreach ln [split [string trim [read $fh]] "\n"] { puts "###   $ln" }
		close $fh
	}
}

file delete -force $proj_dir
create_project $proj_name $proj_dir -part $part
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property xpm_libraries {XPM_MEMORY XPM_CDC XPM_FIFO} [current_project]

# --- 1. CTTE encoder (from the .abc graph, unchanged -- AD-01) -----------
if {[catch {set ct_files [exec py [file join $script_dir abc_filelist.py] \
        [file join $ctte rtl ct_encoder.abc] --root $ctte --quiet]} err]} {
	puts "### ERROR: abc_filelist.py failed: $err"; exit 1
}
set ct_files [split [string trim $ct_files] "\n"]

# --- 2. CVA6 in the chosen configuration ------------------------------------
set flist [file join $ref core Flist.cva6]
set cva6_files [split [string trim [exec py [file join $script_dir cva6_filelist.py] \
    $flist --target $cfg --exclude counter.sv --exclude tc_sram_wrapper.sv]] "\n"]

# Board version of the core configuration: Cached 64 MiB instead of
# 192 MiB. ONLY needed for RV64 -- cv32a6_ima_sv32_fpga already carries
# CachedRegionLength as 0x0400_0000 ab 0x6400_0000, i.e. exactly the
# board-proven conservative state (read back, not assumed).
if {$cfg eq "cv64a6_imac_sv39_ctrace"} {
	source [file join $script_dir cva6_linux64_board_cfg.tcl]
	set cfg_sv [r4b_board_config_pkg $repo_root $outdir]
	set idx -1
	for {set i 0} {$i < [llength $cva6_files]} {incr i} {
		if {[file tail [lindex $cva6_files $i]] eq "${cfg}_config_pkg.sv"} { set idx $i; break }
	}
	if {$idx < 0} { puts "### ERROR: ${cfg}_config_pkg.sv not in the file list"; exit 1 }
	set cva6_files [lreplace $cva6_files $idx $idx $cfg_sv]
} else {
	puts "### D3-BIT: $cfg -- board derivation not needed (Cached already 64 MiB)"
}

lappend cva6_files [file join $ref common local util tc_sram_fpga_wrapper.sv]
lappend cva6_files [file join $ref vendor pulp-platform fpga-support rtl SyncSpRamBeNx64.sv]
set cva6_incs [split [string trim [exec py [file join $script_dir cva6_filelist.py] \
    $flist --incdirs]] "\n"]
lappend cva6_incs [file join $ref corev_apu instr_tracing ITI include]

# --- 3. ITI + PULP AXI + our own SoC building blocks -------------------------
# repo-root rtl/ct_L1_funnel.sv, not a copy in the encoder tree -- see the
# file header's point 3.
set funnel [file join $repo_root rtl ct_L1_funnel.sv]
puts "### D3-BIT: funnel = $funnel (delta version, MDO_WIDTH=6)"

set rocket1_rtl [file join $repo_root examples kv260 rocket_linux rtl]

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
    $funnel \
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
    [file join $pulp axi src axi_id_prepend.sv] \
    [file join $pulp axi src axi_serializer.sv] \
    [file join $pulp axi src axi_mux.sv] \
    [file join $pulp axi src axi_id_serialize.sv] \
    [file join $pulp axi src axi_to_axi_lite.sv] \
    [file join $pulp axi_riscv_atomics src axi_res_tbl.sv] \
    [file join $pulp axi_riscv_atomics src axi_riscv_amos_alu.sv] \
    [file join $pulp axi_riscv_atomics src axi_riscv_amos.sv] \
    [file join $pulp axi_riscv_atomics src axi_riscv_lrsc.sv] \
    [file join $pulp axi_riscv_atomics src axi_riscv_atomics.sv] \
    [file join $pulp axi_riscv_atomics src axi_riscv_lrsc_wrap.sv] \
    [file join $pulp axi_riscv_atomics src axi_riscv_atomics_wrap.sv] \
    [file join $rtl cva6_2_soc_synth_wrap.sv] \
    [file join $repo_root examples kv260 common tgc5b rtl ct_axil_to_wb.sv] \
    [file join $repo_root examples kv260 common ct_soc_trace_ring.sv] \
    [file join $repo_root examples kv260 common ct_soc_ddr_sink.sv] \
    [file join $repo_root examples kv260 common ct_soc_pib.sv] \
    [file join $rocket1_rtl rocket_mem_window.sv] \
    [file join $rtl cva6_2_periph.sv] \
    [file join $rtl cva6_2_mem_xbar.sv] \
    [file join $rtl cva6_2_soc_top.sv] \
    [file join $script_dir cva6_2_kv260_top.sv] \
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

# --- 4. PS glue IPs: the three shared ones PLUS the four-port PS -----------
namespace eval abc { variable proj_dir }
set abc::proj_dir $proj_dir
source [file join $script_dir gen_ip.tcl]
source [file join $script_dir gen_ip_ps4.tcl]
catch { config_ip_cache -clear_output_repo }
catch { config_ip_cache -disable_cache }
foreach ipname {ct_soc_kv260_ps4 ct_soc_kv260_rst ct_soc_kv260_dwc ct_soc_kv260_pc} {
	set xci [get_files -quiet -all */${ipname}.xci]
	if {[llength $xci]} { set_property generate_synth_checkpoint false $xci }
}
generate_target all [get_ips ct_soc_kv260_*]

set_property verilog_define {SYNTHESIS} [get_filesets sources_1]
puts "### VERILOG_DEFINE: [get_property verilog_define [get_filesets sources_1]]"

set_property top cva6_2_kv260_top [current_fileset]
set_property generic "EN_ETRACE=1'b$enet" [get_filesets sources_1]
puts "### GENERIC: [get_property generic [get_filesets sources_1]]"
update_compile_order -fileset sources_1

# --- 5. Synthesis -> implementation -> bitstream -----------------------------
# TCL.PRE hook: a project run executes in its OWN Vivado process, a
# `set_param` here does NOT apply there.
set pre [file normalize [file join $script_dir rocket_synth_pre.tcl]]
set_property STEPS.SYNTH_DESIGN.TCL.PRE $pre [get_runs synth_1]
set_property STEPS.OPT_DESIGN.TCL.PRE   $pre [get_runs impl_1]

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
puts "### WNS: $wns ns"
puts "### WHS: $whs ns"
foreach line [split [report_utilization -return_string] "\n"] {
	if {[regexp {^\| CLB +\||CLB LUTs|CLB Registers|Block RAM Tile|URAM |DSPs} $line]} {
		puts "### UTIL $line"
	}
}

if {$wns < 0 || $whs < 0} {
	puts "### D3_BIT_FAIL timing violated (WNS $wns / WHS $whs)"
	exit 5
}
puts "### D3_BIT_OK  variant=$variant  WNS=$wns  WHS=$whs  -> $bit"
exit 0
