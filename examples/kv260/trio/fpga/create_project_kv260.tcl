# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# create_project_kv260.tcl -- trio (MBV + TGC5B + CVA6) KV260 project. Entry point.
#
#   vivado -mode batch -source examples/kv260/trio/fpga/create_project_kv260.tcl            # project + elab check
#   TRIO_KV260_SYNTH=1 vivado -mode batch -source .../create_project_kv260.tcl               # + full synth/impl/bitstream
#
# Migrated from an internal predecessor repository,
# run_trio_bitstream.tcl}. Like
# ../../duo/fpga/create_project_kv260.tcl, this is a SELF-CONTAINED single
# entry point (the predecessor repository built trio incrementally on top of an already-open
# mbv/duo project to reuse a cached block design across local iterations --
# a development-time optimization, not a portability requirement; the
# resulting bitstream is unaffected). It performs the block-design creation
# step (create_bd.tcl, required by mbv_soc_synth_wrap.sv) plus the TGC5B and
# CVA6 branches' files.
#
# *** DISCLOSURE: the CVA6 branch cannot elaborate in this repository TODAY. ***
# trio_soc_top.sv's third core (cva6_soc_synth_wrap.sv, shared from the
# ../rtl/) instantiates the vendored CVA6-with-ITI core via
# rtl/adapters/cva6/cva6_trace_wrap.sv (already migrated to this repository's
# root -- see its own README.md), which in turn instantiates the upstream
# `cva6`/`cva6_rvfi`/`cva6_iti` modules by name. Those modules are NOT
# vendored into this repository -- per the TraceEncoder consolidation plan
# they are meant to be FETCHED (an `examples/kv260/third_party/fetch.sh`
# pattern) rather than committed, and that fetch step has not landed yet
# (same gap `rtl/adapters/cva6/README.md` already discloses for the adapter
# migration). This script therefore resolves the CVA6 file list from
# `examples/kv260/third_party/cva6_ref/core/Flist.cva6` and fails with a clear,
# named error if that checkout is missing, rather than a cryptic
# file-not-found deep in a `foreach`. Once a future step lands the fetch,
# this script needs no further change.
#
# Structure follows ../../duo/fpga/create_project_kv260.tcl: xck26 project +
# CTTE encoder (file list from the .abc graph, abc_filelist.py) + the
# mbv_ctrace_soc block design (MBV_KV260=1 mode, reused from
# ../../mbv/fpga/create_bd.tcl) + the TGC5B building blocks
# (examples/kv260/common/tgc5b/) + the CVA6-with-ITI core (vendored fetch, see above)
# + the CVA6 CTTE adapter (rtl/adapters/cva6/, already in this repository) +
# the shared sink RTL (examples/kv260/common/) + this example's own
# trio_soc_top.sv / cva6_soc_synth_wrap.sv / trio_kv260_top.sv + the 4
# standalone PS-glue IPs (gen_ip.tcl, now also provisioning S_AXI_GP3/HP1
# 64-bit for the CVA6 memory path).
#
# The default run ends with `synth_design -rtl -top trio_soc_top` as an
# elaboration gate.

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir .. .. .. ..]]
set proj_name  trio_kv260
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

# --- trio-local build profile: CT_EN_ETRACE=1 in a SANDBOX copy of rtl/pkg ---
# WHY THE FLIP. trio is the only example whose three encoders do not all speak
# the same protocol: trio_kv260_top instantiates ENC2 (CVA6, the core with the
# native E-Trace ingress) with EN_ETRACE=1 while MBV/TGC5B stay N-Trace-only --
# see the "Backend fit for the BOARD build" comment there. The back end is a
# per-INSTANCE synthesis parameter, but the eTIP SIDEBAND widths (priv, ecause,
# tval, ilastsize) are sized by a PACKAGE, and a package cannot be
# parameterised per instance. ct_pkg::CT_EN_ETRACE therefore stays the netlist
# master and has to be 1 as soon as ANY instance speaks E-Trace.
# rtl/ct_encoder.sv:246 enforces exactly that and names this build in its own
# comment ("The mixed/Trio case therefore needs CT_EN_ETRACE=1 in ct_pkg even
# if only one of the instances speaks E-Trace"). Without the flip the run died
# in elaboration -- measured 2026-08-18, bld/demo_builds/trio.log:841.
#
# WHY NOT IN rtl/pkg/ct_pkg.sv. That file is shared by all nine examples and by
# every gate; a committed flip would widen the sideband in mbv/duo/cva6/rocket
# too and move their resource numbers. The older in-tree "sed + git checkout --
# restore" of scripts/etrace_synth_compare.sh is worse still: it destroys a
# parallel worker's uncommitted edits in rtl/pkg (it did, 2026-08-05 -- see the
# header of scripts/cli_etrace_test.sh). So this uses that script's answer: a
# PROFILE SANDBOX under bld/ (gitignored) that the fileset points at instead of
# rtl/pkg, copied from the WORKING TREE so uncommitted RTL still gets built.
#
# ONLY ct_pkg.sv is edited, and scripts/gen_rdl_profile.py is deliberately NOT
# run: the RDL-derived CSR block does not depend on this switch. Its
# SWITCH_TO_DEFINE map has no CT_EN_ETRACE entry, and running it out of tree
# over an otherwise identical CT_EN_ETRACE=0/1 pair produces byte-identical
# ct_cs_cpuif.sv, ct_cs_cpuif_pkg.sv and ct_profile.inc.rdl (measured
# 2026-08-18: md5 7c9c0f8579945c464046562f98cee451 on both ct_cs_cpuif.sv).
# The generated files in the sandbox are thus exactly the committed ones the
# other examples build with, and this script needs no PeakRDL venv.
set prof_dir [file join $repo_root bld trio_kv260_profile pkg]
file delete -force $prof_dir
file mkdir $prof_dir
foreach f [glob -nocomplain [file join $repo_root rtl pkg *.sv]] {
	file copy -force $f $prof_dir
}
set prof_pkg [file join $prof_dir ct_pkg.sv]
# -translation binary on BOTH ends: the default would rewrite every line
# ending on Windows and turn a one-line profile delta into a whole-file
# diff -- the sandbox has to stay auditable against rtl/pkg.
set fh [open $prof_pkg r]; fconfigure $fh -translation binary; set txt [read $fh]; close $fh
# Same match as set_sw_in() in scripts/ct_profiles.sh, the canonical setter.
set repl {\1}; append repl "1;"
set hits [regsub -all {(localparam bit CT_EN_ETRACE[ \t]*=[ \t]*)[01];} $txt $repl txt]
if {$hits != 1} {
	# A silent no-op here would rebuild the same broken netlist, so it is an
	# error, not a warning: the switch was renamed or the file is not ct_pkg.
	puts "### ERROR: profile sandbox: CT_EN_ETRACE assignment matched $hits times (expected 1) in $prof_pkg"
	exit 1
}
# Judge the RESULT, not the match count: a backreference that expanded wrong
# would leave a plausible-looking file and rebuild the same broken netlist.
if {![regexp {localparam bit CT_EN_ETRACE[ \t]*=[ \t]*1;} $txt]} {
	puts "### ERROR: profile sandbox: CT_EN_ETRACE is not 1 after the flip in $prof_pkg"
	exit 1
}
set fh [open $prof_pkg w]; fconfigure $fh -translation binary; puts -nonewline $fh $txt; close $fh

# Redirect every rtl/pkg source of the .abc file list to the sandbox copy.
set pkg_src [file normalize [file join $repo_root rtl pkg]]
set ct_files_prof [list]
set n_redir 0
foreach f $ct_files {
	set fn [file normalize $f]
	if {[file dirname $fn] eq $pkg_src} {
		lappend ct_files_prof [file join $prof_dir [file tail $fn]]
		incr n_redir
	} else {
		lappend ct_files_prof $fn
	}
}
set ct_files $ct_files_prof
if {$n_redir == 0} {
	puts "### ERROR: profile sandbox: no rtl/pkg source redirected -- the flip would have no effect"
	exit 1
}
puts "### PROFILE: CT_EN_ETRACE=1 (mixed N-/E-Trace netlist), $n_redir package sources from $prof_dir"

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
# examples/kv260/common/tgc5b/ copy, not a vendored snapshot. NOTE: ct_soc_synth_wrap.sv
# itself is NOT in this list -- trio's TGC5B branch needs dual-protocol
# (EN_ETRACE/atb_te_raw) support that shared file does not carry (a real
# divergence from the predecessor repository's own vendored copy, found during this
# migration). It uses this example's own tgc5b_dual_synth_wrap.sv instead
# (../rtl/, added to board_files below) -- see that file's header for the
# finding. ---
set tgc [file join $repo_root examples kv260 common tgc5b]
set tgc_files [list \
	[file join $tgc pkg ct_soc_regs_pkg.sv] \
	[file join $tgc pkg ct_soc_regs.sv] \
	[file join $tgc cpu TGC5B_AXI4L_H2E.sv] \
	[file join $tgc rtl ct_tip_adapter.sv] \
	[file join $tgc rtl ct_soc_ram.sv] \
	[file join $tgc rtl ct_soc_periph.sv] \
	[file join $tgc rtl ct_axil_to_wb.sv] \
	[file join $tgc rtl ct_soc_axis_buf.sv] \
]

# --- CVA6-with-ITI core (vendored fetch -- see the DISCLOSURE above) --------
# The vendored reference cores live under examples/kv260/third_party/ in THIS
# repository -- the bare $repo_root/third_party path is a leftover of the
# the predecessor repository layout and made this example unbuildable (measured 2026-08-18:
# the run stopped with "CVA6-with-ITI checkout missing" although cva6_ref was
# fetched). Every other cva6 flow here already resolves it the migrated way.
set cva6_ref [file join $repo_root examples kv260 third_party cva6_ref]
set cva6_flist [file join $cva6_ref core Flist.cva6]
if {![file exists $cva6_flist]} {
	puts "### ERROR: CVA6-with-ITI checkout missing: $cva6_flist"
	puts "### The trio example's CVA6 branch needs a fetched"
	puts "### third_party/cva6_ref/ (the CVA6-with-ITI fork; see"
	puts "### rtl/adapters/cva6/README.md for the disclosure)."
	puts "### create_project_kv260.tcl for the mbv-only or duo (2-core)"
	puts "### example does not need this -- only trio's third core does."
	exit 1
}
set cva6_filelist_tool [file join $script_dir .. tools cva6_filelist.py]

# Collision hygiene (see run_trio_sim.tcl in the predecessor repository): common_cells'
# counter.sv would collide with this repository's own counter-named module
# if ever added to the fileset unfiltered -- excluded here defensively,
# matching the source flow (no such collision exists today in this
# repository, but the exclusion is cheap and future-proof).
set cva6_files [split [string trim [exec py $cva6_filelist_tool $cva6_flist --target cv32a60x --exclude counter.sv --exclude tc_sram_wrapper.sv]] "\n"]
lappend cva6_files [file join $cva6_ref common local util tc_sram_fpga_wrapper.sv]
lappend cva6_files [file join $cva6_ref vendor pulp-platform fpga-support rtl SyncSpRamBeNx64.sv]
lappend cva6_files [file join $cva6_ref common local util tc_sram_wrapper.sv]
set cva6_incs  [split [string trim [exec py $cva6_filelist_tool $cva6_flist --incdirs]] "\n"]
lappend cva6_incs [file join $cva6_ref corev_apu instr_tracing ITI include]

# --- CVA6 ITI + CTTE adapter (this repository's own rtl/adapters/cva6/, no
# vendoring needed -- already migrated there) ---
set cva6_adapter_dir [file join $repo_root rtl adapters cva6]
set cva6_iti_files [list \
	[file join $cva6_ref core cva6_rvfi.sv] \
	[file join $cva6_ref corev_apu instr_tracing ITI include iti_pkg.sv] \
	[file join $cva6_ref corev_apu instr_tracing ITI cva6_iti itype_detector.sv] \
	[file join $cva6_ref corev_apu instr_tracing ITI cva6_iti single_retirement.sv] \
	[file join $cva6_ref corev_apu instr_tracing ITI cva6_iti block_retirement.sv] \
	[file join $cva6_ref corev_apu instr_tracing ITI cva6_iti iti.sv] \
	[file join $cva6_adapter_dir cva6_trace_wrap.sv] \
	[file join $cva6_adapter_dir cva6_riscv_itype_refine.sv] \
	[file join $cva6_adapter_dir cva6_iti_to_ctte_tip.sv] \
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
	[file join $script_dir .. rtl tgc5b_dual_synth_wrap.sv] \
	[file join $script_dir .. .. cva6_linux rtl cva6_soc_synth_wrap.sv] \
	[file join $script_dir .. rtl trio_soc_top.sv] \
	[file join $script_dir trio_kv260_top.sv] \
]

foreach f [concat $ct_files $our_files $tgc_files $cva6_files $cva6_iti_files $board_files] {
	set f [file normalize $f]
	if {![file exists $f]} { puts "### WARN missing: $f"; continue }
	add_files -fileset sources_1 -norecurse $f
	set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1] $f]
}
set_property include_dirs $cva6_incs [get_filesets sources_1]

# USED_IN split of the two tc_sram_wrapper definitions (see run_trio_sim.tcl
# in the predecessor repository): behavioral (translate_off content) ONLY for simulation
# (XSIM ~30x faster), tc_sram_fpga_wrapper (+SyncSpRamBeNx64) ONLY for
# synthesis (otherwise DRC INBB-3).
set f_beh  [file normalize [file join $cva6_ref common local util tc_sram_wrapper.sv]]
set f_fpga [file normalize [file join $cva6_ref common local util tc_sram_fpga_wrapper.sv]]
set f_sp   [file normalize [file join $cva6_ref vendor pulp-platform fpga-support rtl SyncSpRamBeNx64.sv]]
if {[llength [get_files -quiet $f_beh]]}  { set_property USED_IN {simulation} [get_files $f_beh] }
if {[llength [get_files -quiet $f_fpga]]} { set_property USED_IN {synthesis implementation} [get_files $f_fpga] }
if {[llength [get_files -quiet $f_sp]]}   { set_property USED_IN {synthesis implementation simulation} [get_files $f_sp] }

# --- Constraints (PIB pinout, same as duo) ---
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

# --- PS-glue IPs (verbatim gen_ip.tcl; abc namespace shim). NEW vs. mbv/duo:
# S_AXI_GP3/HP1 64-bit for the CVA6 memory path -> DDR4 window 0x7C00_0000
# (SPEC_board_memory_map). ---
namespace eval abc { variable proj_dir }
set abc::proj_dir $proj_dir
source [file join $script_dir gen_ip.tcl]

set_property top trio_kv260_top [current_fileset]
update_compile_order -fileset sources_1

# Synthesize the BD globally (no OOC-per-IP checkpoint) -- otherwise
# elaboration is missing the generated IP submodules (mbv_ctrace_soc_dlmb_0 ...).
set_property synth_checkpoint_mode None $bd_file
generate_target all $bd_file

# --- Elaboration gate: trio_soc_top (without the PS IPs) --------------------
puts "### ELAB-CHECK: synth_design -rtl -top trio_soc_top"
if {[catch {synth_design -rtl -top trio_soc_top -mode out_of_context} elab_err]} {
	puts "### ELAB_FAIL: $elab_err"
	exit 2
}
puts "### ELAB_OK (trio_soc_top elaborates)"
close_design
# synth_design -rtl -top switches the fileset top -- switch back to the
# bitstream top for the runs (otherwise synth_1 implements trio_soc_top with
# bare I/O ports -> DRC NSTD-1/UCIO-1).
set_property top trio_kv260_top [current_fileset]
update_compile_order -fileset sources_1

if {[info exists ::env(TRIO_KV260_SYNTH)] && $::env(TRIO_KV260_SYNTH) eq "1"} {
	puts "### SYNTH: full flow (synth_1 -> impl_1 -> bitstream)"
	# Only the 4 standalone PS-glue IPs -- BD-internal IPs (mbv_ctrace_soc_*)
	# are generated exclusively by the BD itself (Vivado 12-3563).
	generate_target all [get_ips ct_soc_kv260_*]
	launch_runs synth_1 -jobs 4
	wait_on_run synth_1
	if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { puts "### SYNTH_FAIL"; exit 3 }
	launch_runs impl_1 -to_step write_bitstream -jobs 4
	wait_on_run impl_1
	if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { puts "### IMPL_FAIL"; exit 4 }
	open_run impl_1
	report_timing_summary -file [file join $script_dir trio_timing_summary.rpt]
	report_utilization -file [file join $script_dir trio_utilization.rpt]
	set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
	puts "### WNS: $wns"
	puts "### BITSTREAM_OK: [glob -nocomplain [file join $proj_dir ${proj_name}.runs impl_1 *.bit]]"
}

puts "### PROJECT READY: $proj_dir  TOP: [get_property top [current_fileset]]"
