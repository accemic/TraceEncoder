# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# D3 step 1: the FULL BUILD of the dual-CVA6 -- area and timing measured
# before a bitstream is built.
#
#   vivado -mode batch -notrace -source examples/kv260/cva6_2/fpga/synth_cva6_2_soc_ooc.tcl \
#          -tclargs <tag> [<part>] [<ctte-root>] [<place:0|1>] [<route:0|1>] \
#                   [<cva6-config>]
#
#   <tag>          name of the output branch bld/d3_cva6_2_soc/synth_<tag>
#   <route>        1 = additionally route_design (implies place)
#   <cva6-config>  default cv64a6_imac_sv39_ctrace; RV32 with
#                  cv32a6_ima_sv32_fpga (NOT cv32a60x -- without MMU/S-mode
#                  the core cannot run Linux).
#
# DIFFERENCE TO synth_cva6_2_ooc.tcl (D2): there the top was the MEASUREMENT
# CIRCUIT `cva6_2_soc_synth_wrap` -- two cores, two encoders, funnel,
# nothing else, explicitly a LOWER BOUND. Here the top is `cva6_2_soc_top`,
# i.e. the same tree PLUS the memory path (2x demux, 3x atomics, 3x guard,
# merge), peripherals (two-hart CLINT + console), URAM ring, DDR sink and
# PIB. This is the number the plan's own gate requires: "measure, don't
# assume".
#
# What is STILL missing here and gets added in the bitstream: the three PS
# glue IPs (dwc + pc measured separately, rst negligible) and the PS block
# itself (occupies no fabric logic). The bitstream run
# (run_cva6_2_bitstream.tcl) measures the whole; this OOC number is the
# fast, comparable precursor to D2's bound.
#
# ORDER RV32 FIRST: the integration is the same work, but at RV32 ~65% of
# the area is free and the timing margin is five times as large. An
# integration bug costs nothing there; at RV64 (near-full CLB occupancy,
# small post-route margin) it would be indistinguishable from a real area
# or timing problem.
#
# Checkpoints after EVERY stage (post_synth/post_place/post_route.dcp) --
# a question without a checkpoint cost D2 39 min of resynthesis.

set tag  [lindex $argv 0]
set part [lindex $argv 1]
set ctenc [lindex $argv 2]
set doplace [lindex $argv 3]
set doroute [lindex $argv 4]
set cfgarg [lindex $argv 5]
if {$tag  eq ""} { set tag  soc_rv64 }
if {$part eq ""} { set part xck26-sfvc784-2LV-c }
if {$doplace eq ""} { set doplace 1 }
if {$doroute eq ""} { set doroute 0 }
if {$doroute} { set doplace 1 }

set script_dir [file dirname [file normalize [info script]]]
# This script now sits 4 levels under the repo root
# (examples/kv260/cva6_2/fpga/), unlike the predecessor repository's vivado/kv260_app/
# (2 levels) -- same path-depth fix as the sibling migrated TCL scripts.
set repo_root  [file normalize [file join $script_dir .. .. .. ..]]
set ref        [file join $repo_root examples kv260 third_party cva6_ref]
set pulp       [file join $ref vendor pulp-platform]
set rtl        [file join $script_dir .. rtl]
set flist      [file join $ref core Flist.cva6]
set cfg        cv64a6_imac_sv39_ctrace
if {$cfgarg ne ""} { set cfg $cfgarg }

# Default: the two-hart Rocket example's slim 64-bit profile -- the same
# one D2 measured with. Requirement point 2: two numbers are only a
# comparison if they measure the same thing.
set ctte [file join $repo_root bld m4_rocket_2hart ctte_slim64]
if {$ctenc ne ""} { set ctte [file normalize $ctenc] }

set outdir [file join $repo_root bld d3_cva6_2_soc synth_$tag]
file mkdir $outdir

puts "### D3-OOC: dual-CVA6 FULL BUILD, tag=$tag, config=$cfg, part=$part, place=$doplace, route=$doroute"

set dcp_synth [file join $outdir post_synth.dcp]
set dcp_place [file join $outdir post_place.dcp]
set dcp_route [file join $outdir post_route.dcp]
set resumed_from ""
if {$doroute && [file exists $dcp_place]} {
	puts "### D3-OOC: RESUMING on $dcp_place -- synthesis and place are skipped"
	open_checkpoint $dcp_place
	set resumed_from place
}

if {$resumed_from eq ""} {

puts "### D3-OOC: top = cva6_2_soc_top (full build)"
puts "### D3-OOC: encoder tree = $ctte"

# Encoder netlist button state READ BACK, not assumed (W1 lesson).
set _ctp [file join $ctte rtl pkg ct_pkg.sv]
if {[file exists $_ctp]} {
	set _fh [open $_ctp r]; set _t [read $_fh]; close $_fh
	foreach _k {CT_XLEN CT_CONTEXT_WIDTH CT_EN_OWNERSHIP CT_EN_FILTERS CT_EN_FILTER_SYNC} {
		if {[regexp "localparam\\s+\[a-z \]*\\s${_k}\\s*=\\s*(\[0-9\]+);" $_t -> _v]} {
			puts "###   $_k = $_v"
		} else { puts "###   $_k = <not present>" }
	}
}
foreach _pf {CTTE_M4_PROVENANCE.txt CTTE_XLEN_PROVENANCE.txt} {
	set _prov [file join $ctte $_pf]
	if {[file exists $_prov]} {
		set _fh [open $_prov r]
		foreach _ln [split [string trim [read $_fh]] "\n"] { puts "###   $_ln" }
		close $_fh
	}
}

# --- CVA6 in the chosen configuration ---------------------------------------
set cva6_files [split [string trim [exec py [file join $script_dir cva6_filelist.py] \
    $flist --target $cfg --exclude counter.sv --exclude tc_sram_wrapper.sv]] "\n"]

# Replace the core configuration with its BOARD version (Cached 64 MiB
# instead of 192 MiB) -- ONLY needed for the RV64 core. The RV32
# configuration cv32a6_ima_sv32_fpga already carries CachedRegionLength as
# 0x0400_0000 (64 MiB from 0x6400_0000), i.e. exactly the board-proven
# conservative state; the derivation does not apply there and does not
# need to.
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
	puts "### D3-OOC: configuration $cfg -- board derivation not applied (check the cached region!)"
}

lappend cva6_files [file join $ref common local util tc_sram_fpga_wrapper.sv]
lappend cva6_files [file join $ref vendor pulp-platform fpga-support rtl SyncSpRamBeNx64.sv]
set cva6_incs [split [string trim [exec py [file join $script_dir cva6_filelist.py] \
    $flist --incdirs]] "\n"]
lappend cva6_incs [file join $ref corev_apu instr_tracing ITI include]

# --- CTTE encoder from the .abc graph (compile order, AD-01) ------------
if {[catch {set ct_files [exec py [file join $script_dir abc_filelist.py] \
        [file join $ctte rtl ct_encoder.abc] --root $ctte --quiet]} err]} {
	puts "### ERROR: abc_filelist.py failed: $err"; exit 1
}
set ct_files [split [string trim $ct_files] "\n"]

# FUNNEL: this repository's own repo-root rtl/ct_L1_funnel.sv (delta
# version, MDO_WIDTH parametric), NOT the upstream version with
# LOGICAL_CHUNK_W = 32 (finding F-1). It would switch channels mid-message,
# and elaboration turns nothing red.
set funnel [file join $repo_root rtl ct_L1_funnel.sv]
puts "### D3-OOC: funnel = $funnel (delta version, MDO_WIDTH=6)"

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
    $funnel \
    [file join $rtl cva6_2_soc_synth_wrap.sv] \
]

# --- Memory path, peripherals, sinks (the full build) -----------------------
# NEW in this list vs. the single-core build: axi_id_prepend, axi_serializer,
# axi_mux and axi_id_serialize. They carry the SHARED path: serialize per
# core to one ID (otherwise the reservation table would be 2^5 entries
# wide), then merge, then ONE shared atomics instance.
set rocket1_rtl [file join $repo_root examples kv260 rocket_linux rtl]
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
    [file join $repo_root examples kv260 common tgc5b rtl ct_axil_to_wb.sv] \
    [file join $repo_root examples kv260 common ct_soc_trace_ring.sv] \
    [file join $repo_root examples kv260 common ct_soc_ddr_sink.sv] \
    [file join $repo_root examples kv260 common ct_soc_pib.sv] \
    [file join $rocket1_rtl rocket_mem_window.sv] \
    [file join $rtl cva6_2_periph.sv] \
    [file join $rtl cva6_2_mem_xbar.sv] \
    [file join $rtl cva6_2_soc_top.sv]

foreach f [concat $ct_files $cva6_files $own_files] {
	if {![file exists $f]} { puts "### ERROR missing: $f"; exit 1 }
	read_verilog -sv $f
}
set_property include_dirs $cva6_incs [current_fileset]

# Single synthesis thread: with multiple threads Vivado 2026.1 occasionally
# dies on this design type in "Cross Boundary and Area Optimization". With
# two cores, more so than ever.
set_param general.maxThreads 1

puts "### D3-OOC: synth_design cva6_2_soc_top (EN_ETRACE=0) ..."
if {[catch {synth_design -top cva6_2_soc_top -part $part -mode out_of_context \
        -generic [list EN_ETRACE=0] -include_dirs $cva6_incs} err]} {
	puts "### SYNTH_FAILED ($tag): $err"
	exit 1
}

report_utilization               -file [file join $outdir util_synth_flat.rpt]
report_utilization -hierarchical -hierarchical_depth 3 -file [file join $outdir util_synth_hier.rpt]

create_clock -period 13.333 -name clk [get_ports clk]
report_timing_summary -file [file join $outdir timing_synth.rpt]

foreach line [split [report_utilization -return_string] "\n"] {
	if {[regexp {CLB LUTs|CLB Registers|Block RAM Tile|URAM |DSPs} $line]} { puts "### SYNTH $line" }
}
set wns_s [get_property SLACK [get_timing_paths -delay_type max]]
puts "### D3_OOC_SYNTH tag=$tag WNS=$wns_s"
write_checkpoint -force $dcp_synth

} else {
	set wns_s "n/a(resume-from-$resumed_from)"
	create_clock -period 13.333 -name clk [get_ports clk]
}

if {$doplace && $resumed_from eq ""} {
	puts "### D3-OOC: opt_design + place_design (for the CLB row) ..."
	if {[catch {opt_design} err]} { puts "### OPT_FAILED ($tag): $err"; exit 1 }
	if {[catch {place_design} err]} {
		puts "### PLACE_FAILED ($tag): $err"
		report_utilization -file [file join $outdir util_place_failed.rpt]
		puts "### D3_OOC_RESULT tag=$tag PLACE=FAILED"
		exit 1
	}
	report_utilization               -file [file join $outdir util_place_flat.rpt]
	report_utilization -hierarchical -hierarchical_depth 3 -file [file join $outdir util_place_hier.rpt]
	report_timing_summary -file [file join $outdir timing_place.rpt]
	foreach line [split [report_utilization -return_string] "\n"] {
		if {[regexp {^\| CLB +\||CLB LUTs|CLB Registers|Block RAM Tile|URAM |DSPs} $line]} { puts "### PLACE $line" }
	}
	set wns_p [get_property SLACK [get_timing_paths -delay_type max]]
	puts "### D3_OOC_PLACE tag=$tag SYNTH_WNS=$wns_s PLACE_WNS=$wns_p"
	write_checkpoint -force $dcp_place
} elseif {$resumed_from ne ""} {
	set wns_p [get_property SLACK [get_timing_paths -delay_type max]]
	puts "### D3_OOC_PLACE tag=$tag (from checkpoint) PLACE_WNS=$wns_p"
} else {
	set wns_p "skipped"
	puts "### D3_OOC_PLACE tag=$tag SYNTH_WNS=$wns_s PLACE=skipped"
}

if {$doroute} {
	puts "### D3-OOC: route_design ..."
	if {[catch {route_design} err]} {
		puts "### ROUTE_FAILED ($tag): $err"
		report_route_status -file [file join $outdir route_status_failed.rpt]
		puts "### D3_OOC_RESULT tag=$tag ROUTE=FAILED"
		exit 1
	}
	report_utilization               -file [file join $outdir util_route_flat.rpt]
	report_utilization -hierarchical -hierarchical_depth 3 -file [file join $outdir util_route_hier.rpt]
	report_timing_summary -file [file join $outdir timing_route.rpt]
	report_route_status   -file [file join $outdir route_status.rpt]
	foreach line [split [report_utilization -return_string] "\n"] {
		if {[regexp {^\| CLB +\||CLB LUTs|CLB Registers|Block RAM Tile|URAM |DSPs} $line]} { puts "### ROUTE $line" }
	}
	set wns_r [get_property SLACK [get_timing_paths -delay_type max]]
	set whs_r [get_property SLACK [get_timing_paths -delay_type min]]
	# AUTHORITATIVE is "nets with routing errors" from report_route_status,
	# NOT a hand-rolled get_nets filter: that would count the top-level
	# port nets in OOC operation too ("implicitly routed ports") and raise
	# a false alarm -- a guard that does this gets ignored the next time
	# (D2 finding).
	set _rs [report_route_status -return_string]
	set nerr "?"
	if {[regexp {nets with routing errors[\. ]*:\s*([0-9]+)} $_rs -> _m]} { set nerr $_m }
	puts "### D3_OOC_ROUTE tag=$tag ROUTE_WNS=$wns_r ROUTE_WHS=$whs_r ROUTE_ERRORS=$nerr"
	write_checkpoint -force $dcp_route
	puts "### D3_OOC_RESULT tag=$tag SYNTH_WNS=$wns_s PLACE_WNS=$wns_p ROUTE_WNS=$wns_r ROUTE_WHS=$whs_r ROUTE_ERRORS=$nerr"
} else {
	puts "### D3_OOC_RESULT tag=$tag SYNTH_WNS=$wns_s PLACE_WNS=$wns_p ROUTE=skipped"
}
puts "### D3_OOC_DONE tag=$tag -> $outdir"
