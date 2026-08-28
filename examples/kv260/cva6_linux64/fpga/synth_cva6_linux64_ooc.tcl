# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Out-of-context synthesis of the ENTIRE cv64a6 SoC branch -- the
# measurement that answers, before the bitstream, whether "cv64a6 + periph
# + xbar + encoder" fits on the xck26 and with which encoder profile.
#
# Deliberately OOC and without the four PS glue IPs: this measures the PL
# share this design itself brings. The PS connection (dwc/pc/rst/ps) is
# identical across every KV260 design in this repository and included in
# the bitstream run.
#
#   vivado -mode batch -notrace -source examples/kv260/cva6_linux64/fpga/synth_cva6_linux64_ooc.tcl \
#          -tclargs <what> [<en_etrace>] [<part>]
#
#   <what>       soc  = cva6_linux64_soc_top  (core + encoder + xbar + periph
#                       + URAM ring + DDR sink + PIB)   -- default
#                wrap = cva6_soc64_synth_wrap (core + RVFI + ITI + shim +
#                       encoder only) -- 1:1 comparable with the RV32 value
#                       from bld/synth_cva6_cv32a6_ima_sv32_fpga/util_hier.rpt
#   <en_etrace>  1 = DUAL (N-Trace + E-Trace, as in the RV32 Linux design)
#                0 = N-Trace backend only (E-Trace constants gone)
#
# Reports IN THE TREE (gate evidence, bld/ is gitignored):
#   examples/kv260/cva6_linux64/fpga/cva6_linux64_ooc_<tag>_utilization.rpt
#   examples/kv260/cva6_linux64/fpga/cva6_linux64_ooc_<tag>_utilization_hier.rpt
#   examples/kv260/cva6_linux64/fpga/cva6_linux64_ooc_<tag>_timing.rpt
# with <tag> = <what>_{dual|nonly}.

# Fourth tclarg = encoder tree, fifth = tag suffix. Without both the run is
# unchanged (this repository's own encoder tree, reports
# cva6_linux64_ooc_<what>_{dual|nonly}_*.rpt). With an override the run
# measures a DIFFERENT encoder netlist (e.g. CT_XLEN=64 + CT_CONTEXT_WIDTH=16)
# and writes under its own tag -- the existing reports stay evidence for the
# state they came from.
set what [lindex $argv 0]
set enet [lindex $argv 1]
set part [lindex $argv 2]
set ctenc [lindex $argv 3]
set tagsfx [lindex $argv 4]
if {$what eq ""} { set what soc }
if {$enet eq ""} { set enet 1 }
if {$part eq ""} { set part xck26-sfvc784-2LV-c }

switch -- $what {
	soc     { set top cva6_linux64_soc_top }
	wrap    { set top cva6_soc64_synth_wrap }
	default { puts "### ERROR: <what> must be soc or wrap (was: $what)"; exit 2 }
}
set tag "${what}_[expr {$enet ? {dual} : {nonly}}]"
if {$tagsfx ne ""} { set tag "${tag}_${tagsfx}" }

set script_dir [file dirname [file normalize [info script]]]
# This script now sits 4 levels under the repo root
# (examples/kv260/cva6_linux64/fpga/), unlike the predecessor repository's vivado/kv260_app/
# (2 levels) -- same path-depth fix as the sibling migrated TCL scripts.
set repo_root  [file normalize [file join $script_dir .. .. .. ..]]
set ref        [file join $repo_root examples kv260 third_party cva6_ref]
set pulp       [file join $ref vendor pulp-platform]
# This repository IS the CTTE encoder by default (unlike the predecessor repository,
# which built against a third_party/CTTE/ vendor copy).
set ctte     [file normalize $repo_root]
if {$ctenc ne ""} { set ctte [file normalize $ctenc] }
set rtl        [file join $script_dir .. rtl]
set flist      [file join $ref core Flist.cva6]
set cfg        cv64a6_imac_sv39_ctrace

set outdir [file join $repo_root bld r4b_cv64a6_bit ooc_$tag]
file mkdir $outdir

puts "### R4b-OOC: top=$top  config=$cfg  EN_ETRACE=$enet  part=$part"
# Encoder netlist button state READ BACK, not assumed (an OOC number
# without the button state it belongs to proves nothing).
puts "### ENCODER: $ctte"
set _ctp [file join $ctte rtl pkg ct_pkg.sv]
if {[file exists $_ctp]} {
	set _fh [open $_ctp r]; set _t [read $_fh]; close $_fh
	foreach _k {CT_XLEN CT_CONTEXT_WIDTH CT_EN_OWNERSHIP CT_EN_FILTERS CT_EN_FILTER_SYNC} {
		if {[regexp "localparam\\s+\[a-z \]*\\s${_k}\\s*=\\s*(\[0-9\]+);" $_t -> _v]} {
			puts "###   $_k = $_v"
		} else { puts "###   $_k = <not present>" }
	}
}
set _prov [file join $ctte CTTE_XLEN_PROVENANCE.txt]
if {[file exists $_prov]} {
	set _fh [open $_prov r]
	foreach _ln [split [string trim [read $_fh]] "\n"] { puts "###   $_ln" }
	close $_fh
}

# --- CVA6 in the RV64 configuration (delta D6) ------------------------------
# --exclude counter.sv: common_cells' `counter` collides with CTTE's counter.
# --exclude tc_sram_wrapper.sv: the sim model -> the FPGA variant is used
#   here instead, otherwise DRC INBB-3 (black box) in implementation.
set cva6_files [split [string trim [exec py [file join $script_dir cva6_filelist.py] \
    $flist --target $cfg --exclude counter.sv --exclude tc_sram_wrapper.sv]] "\n"]

# The core configuration is replaced by its BOARD version (Cached 64 MiB
# instead of 192 MiB, rationale in cva6_linux64_board_cfg.tcl). AT THE SAME
# POSITION in the list -- the order of package declarations is a contract.
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
set cva6_incs [split [string trim [exec py [file join $script_dir cva6_filelist.py] \
    $flist --incdirs]] "\n"]
lappend cva6_incs [file join $ref corev_apu instr_tracing ITI include]

# --- CTTE encoder from the .abc graph (compile order, AD-01) ------------
set ct_files [split [string trim [exec py [file join $script_dir abc_filelist.py] \
    [file join $ctte rtl ct_encoder.abc] --root $ctte --quiet]] "\n"]
# E-Trace backend: not in the .abc graph (describes the N-Trace path only),
# but mandatory for the DUAL build -- the same addition as in the trio
# example's sim flow.
lappend ct_files [file join $ctte rtl ct_L2_te_inst_gen.sv]
lappend ct_files [file join $ctte rtl ct_L2_te_packetizer.sv]

# --- ITI + shim + RV64 wrapper ----------------------------------------------
set own_files [list \
    [file join $ref core cva6_rvfi.sv] \
    [file join $ref corev_apu instr_tracing ITI include iti_pkg.sv] \
    [file join $ref corev_apu instr_tracing ITI cva6_iti itype_detector.sv] \
    [file join $ref corev_apu instr_tracing ITI cva6_iti single_retirement.sv] \
    [file join $ref corev_apu instr_tracing ITI cva6_iti block_retirement.sv] \
    [file join $ref corev_apu instr_tracing ITI cva6_iti iti.sv] \
    [file join $repo_root rtl adapters cva6 cva6_trace_wrap.sv] \
    [file join $repo_root rtl adapters cva6 cva6_riscv_itype_refine.sv] \
    [file join $repo_root rtl adapters cva6 cva6_iti_to_ctte_tip.sv] \
    [file join $rtl cva6_soc64_synth_wrap.sv] \
]

# --- Rest of the SoC (only for <what> = soc) --------------------------------
if {$what eq "soc"} {
	set common_dir [file join $repo_root examples kv260 common]
	set tgc5b_dir  [file join $repo_root examples kv260 common tgc5b rtl]
	lappend own_files \
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
	    [file join $tgc5b_dir ct_axil_to_wb.sv] \
	    [file join $common_dir ct_soc_trace_ring.sv] \
	    [file join $common_dir ct_soc_ddr_sink.sv] \
	    [file join $common_dir ct_soc_pib.sv] \
	    [file join $rtl cva6_linux64_periph.sv] \
	    [file join $repo_root examples kv260 cva6_linux rtl cva6_linux_mem_xbar.sv] \
	    [file join $rtl cva6_linux64_soc_top.sv]
}

foreach f [concat $ct_files $cva6_files $own_files] {
	if {![file exists $f]} { puts "### ERROR missing: $f"; exit 1 }
	read_verilog -sv $f
}
set_property include_dirs $cva6_incs [current_fileset]

# Single synthesis thread: with multiple threads Vivado 2026.1 occasionally
# dies on this design type in "Cross Boundary and Area Optimization" (same
# measure as in synth_cva6_cfg_ooc.tcl).
set_param general.maxThreads 1

puts "### synth_design $top ($cfg, EN_ETRACE=$enet) ..."
if {[catch {synth_design -top $top -part $part -mode out_of_context \
        -generic [list EN_ETRACE=$enet] -include_dirs $cva6_incs} err]} {
	puts "### SYNTH_FAILED ($tag): $err"
	exit 1
}

report_utilization               -file [file join $script_dir cva6_linux64_ooc_${tag}_utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 3 \
                                 -file [file join $script_dir cva6_linux64_ooc_${tag}_utilization_hier.rpt]

# 75 MHz board clock as a timing hint (OOC approximation, no placement).
create_clock -period 13.333 -name clk [get_ports clk]
report_timing_summary -file [file join $script_dir cva6_linux64_ooc_${tag}_timing.rpt]

set rpt [report_utilization -return_string]
foreach line [split $rpt "\n"] {
	if {[regexp {CLB LUTs|CLB Registers|Block RAM Tile|URAM |DSPs} $line]} { puts "### $line" }
}
set wns [get_property SLACK [get_timing_paths -delay_type max]]
puts "### R4B_OOC_RESULT tag=$tag top=$top WNS=$wns"
puts "### R4B_OOC_DONE tag=$tag -> $outdir + examples/kv260/cva6_linux64/fpga/cva6_linux64_ooc_${tag}_*.rpt"
