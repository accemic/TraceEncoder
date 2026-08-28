# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# D2 step 1: capacity measurement of the TWO-CORE cv64a6 branch, BEFORE any
# bitstream or SoC is built. The question "does a dual-CVA6 with two
# encoders fit on the xck26?" is MEASURED here, not estimated.
#
#   vivado -mode batch -notrace -source examples/kv260/cva6_2/fpga/synth_cva6_2_ooc.tcl \
#          -tclargs <tag> [<part>] [<ctte-root>] [<place:0|1>] [<route:0|1>] \
#                   [<cva6-config>]
#
#   <tag>          name of the output branch bld/d2_cva6_2hart/synth_<tag>
#   <route>        1 = additionally route_design (implies place). Answers
#                  the question PLACE_WNS leaves open.
#   <cva6-config>  default cv64a6_imac_sv39_ctrace; RV32 comparison with
#                  cv32a6_ima_sv32_fpga (NOT cv32a60x -- without MMU/S-mode).
#
# A checkpoint is written after every stage (post_synth/post_place/
# post_route.dcp); a route run with an existing post_place.dcp resumes
# there and skips synthesis and place.
#
# Templates: synth_cva6_linux64_ooc.tcl (CVA6 file list, board
# configuration) and synth_rocket2_ooc.tcl (the PLACE step). FOUR points,
# each with a reason:
#
#  1. TOP = cva6_2_soc_synth_wrap (2x core + 2x shim + 2x ct_encoder +
#     ct_L1_funnel). Deliberately WITHOUT xbar/console/ring/periph -- see
#     point 2.
#
#  2. LOWER BOUND, and that is the whole proof. The real SoC additionally
#     needs a crossbar + atomics + demux (2,558 LUT in the single-core
#     build), console (610), URAM ring, DDR sink, PIB, periph and the PS
#     glue IPs. All of that makes the picture WORSE. If already this bound
#     exceeds capacity, the question is conclusively answered with NO; if
#     it stays under it, nothing is proven and the full build must be
#     measured.
#
#  3. PLACE STEP (default on). The BINDING size is CLB occupancy, not the
#     LUT count (a trio measured 85.9% LUT at 99.8% CLB). A plain synthesis
#     evaluation CANNOT answer the question -- `report_utilization` after
#     synth_design has no CLB row at all, that only appears once placed. A
#     place_design abort IS the result: it means "does not fit".
#
#  4. ENCODER TREE defaults to bld/m4_rocket_2hart/ctte_slim64, i.e. the
#     profile the two-hart Rocket example reaches its 4,653 LUT per encoder
#     with (slimfull_gold, xlen=64, ctxwidth=22). A single-core CVA6 build
#     carries a FULL profile with 25,743 LUT per encoder -- that would be
#     hopeless for two instances from the outset and would obscure the
#     core question.

set tag  [lindex $argv 0]
set part [lindex $argv 1]
set ctenc [lindex $argv 2]
set doplace [lindex $argv 3]
set doroute [lindex $argv 4]
# Sixth tclarg: CVA6 core configuration. Default is the RV64 core; for the
# RV32 comparison, cv32a6_ima_sv32_fpga is passed.
#
# NOT cv32a60x, even though that is the RV32 core used in the trio example:
# it carries MmuPresent = 0 and RVS = 0 (cv32a60x_config_pkg.sv) and
# consequently CANNOT run Linux. An area comparison against it would
# measure a core that does not perform the task at all.
set cfgarg [lindex $argv 5]
if {$tag  eq ""} { set tag  slim2 }
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

# Default: the two-hart Rocket example's slim 64-bit profile.
set ctte [file join $repo_root bld m4_rocket_2hart ctte_slim64]
if {$ctenc ne ""} { set ctte [file normalize $ctenc] }

set outdir [file join $repo_root bld d2_cva6_2hart synth_$tag]
file mkdir $outdir

puts "### D2-OOC: two-core CVA6, tag=$tag, config=$cfg, part=$part, place=$doplace, route=$doroute"

# --- RESUME instead of rebuilding -------------------------------------------
# The first D2 run wrote NO checkpoint. When the routing question came up
# afterward, the placed database was gone and 39 min of synth+place had to
# run again -- for a step that would have finished in minutes on the
# existing placement. Hence this run writes a checkpoint after EVERY stage
# and resumes on the latest usable one.
set dcp_synth [file join $outdir post_synth.dcp]
set dcp_place [file join $outdir post_place.dcp]
set dcp_route [file join $outdir post_route.dcp]
set resumed_from ""
if {$doroute && [file exists $dcp_place]} {
	puts "### D2-OOC: RESUMING on $dcp_place -- synthesis and place are skipped"
	open_checkpoint $dcp_place
	set resumed_from place
}
puts "### D2-OOC: top = cva6_2_soc_synth_wrap (LOWER BOUND, without xbar/console/ring)"
puts "### D2-OOC: encoder tree = $ctte"

if {$resumed_from eq ""} {

# Encoder netlist button state READ BACK, not assumed (W1 lesson): an OOC
# number without the button state it belongs to proves nothing.
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

# --- CVA6 in the RV64 configuration (delta D6) ------------------------------
# --exclude counter.sv: common_cells' `counter` collides with CTTE's counter.
# --exclude tc_sram_wrapper.sv: the sim model -> the FPGA variant is used
#   here instead, otherwise DRC INBB-3 (black box) in implementation.
set cva6_files [split [string trim [exec py [file join $script_dir cva6_filelist.py] \
    $flist --target $cfg --exclude counter.sv --exclude tc_sram_wrapper.sv]] "\n"]

# Replace the core configuration with its BOARD version (Cached 64 MiB
# instead of 192 MiB), AT THE SAME POSITION in the list -- the order of
# package declarations is a contract. This belongs to the RV64 core and
# patches its config_pkg; for another configuration it does not apply and
# is skipped instead of silently touching the wrong file.
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
	puts "### D2-OOC: configuration $cfg -- board derivation (Cached 64 MiB) NOT applied"
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

# --- ITI + shim + funnel + two-core shell -----------------------------------
# FUNNEL: this repository's own repo-root rtl/ct_L1_funnel.sv (delta
# version, MDO_WIDTH parametric), NOT the upstream version with
# LOGICAL_CHUNK_W = 32 (finding F-1). Carried as its own source so its
# origin stays visible in the file-list log.
set funnel [file join $repo_root rtl ct_L1_funnel.sv]
puts "### D2-OOC: funnel = $funnel (delta version, MDO_WIDTH=6)"

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

foreach f [concat $ct_files $cva6_files $own_files] {
	if {![file exists $f]} { puts "### ERROR missing: $f"; exit 1 }
	read_verilog -sv $f
}
set_property include_dirs $cva6_incs [current_fileset]

# Single synthesis thread: with multiple threads Vivado 2026.1 occasionally
# dies on this design type in "Cross Boundary and Area Optimization". With
# two cores the design is even bigger -- more so than ever.
set_param general.maxThreads 1

# EN_ETRACE=0 is mandatory: the funnel parses MSEO, E-Trace delivers raw
# bytes. The shell aborts elaboration at EN_ETRACE=1 with $fatal
# (g_etrace_guard).
puts "### D2-OOC: synth_design cva6_2_soc_synth_wrap (EN_ETRACE=0) ..."
if {[catch {synth_design -top cva6_2_soc_synth_wrap -part $part -mode out_of_context \
        -generic [list EN_ETRACE=0] -include_dirs $cva6_incs} err]} {
	puts "### SYNTH_FAILED ($tag): $err"
	exit 1
}

report_utilization               -file [file join $outdir util_synth_flat.rpt]
report_utilization -hierarchical -hierarchical_depth 3 -file [file join $outdir util_synth_hier.rpt]

# 75 MHz board clock (pl_clk0 of the sibling branches).
create_clock -period 13.333 -name clk [get_ports clk]
report_timing_summary -file [file join $outdir timing_synth.rpt]

set rpt [report_utilization -return_string]
foreach line [split $rpt "\n"] {
	if {[regexp {CLB LUTs|CLB Registers|Block RAM Tile|URAM |DSPs} $line]} { puts "### SYNTH $line" }
}
set wns_s [get_property SLACK [get_timing_paths -delay_type max]]
puts "### D2_OOC_SYNTH tag=$tag WNS=$wns_s"
write_checkpoint -force $dcp_synth

} else {
	# Resumed: the synthesis numbers are in the report of the run the
	# checkpoint came from. NOT re-claimed here (attestation honesty).
	set wns_s "n/a(resume-from-$resumed_from)"
	create_clock -period 13.333 -name clk [get_ports clk]
}

if {$doplace && $resumed_from eq ""} {
	puts "### D2-OOC: opt_design + place_design (for the CLB row) ..."
	if {[catch {opt_design} err]} { puts "### OPT_FAILED ($tag): $err"; exit 1 }
	if {[catch {place_design} err]} {
		# A placement abort IS the result: it means "does not fit".
		puts "### PLACE_FAILED ($tag): $err"
		report_utilization -file [file join $outdir util_place_failed.rpt]
		puts "### D2_OOC_RESULT tag=$tag PLACE=FAILED"
		exit 1
	}
	report_utilization               -file [file join $outdir util_place_flat.rpt]
	report_utilization -hierarchical -hierarchical_depth 3 -file [file join $outdir util_place_hier.rpt]
	report_timing_summary -file [file join $outdir timing_place.rpt]
	set rpt2 [report_utilization -return_string]
	foreach line [split $rpt2 "\n"] {
		if {[regexp {^\| CLB +\||CLB LUTs|CLB Registers|Block RAM Tile|URAM |DSPs} $line]} { puts "### PLACE $line" }
	}
	set wns_p [get_property SLACK [get_timing_paths -delay_type max]]
	puts "### D2_OOC_PLACE tag=$tag SYNTH_WNS=$wns_s PLACE_WNS=$wns_p"
	write_checkpoint -force $dcp_place
} elseif {$resumed_from ne ""} {
	set wns_p [get_property SLACK [get_timing_paths -delay_type max]]
	puts "### D2_OOC_PLACE tag=$tag (from checkpoint) PLACE_WNS=$wns_p"
} else {
	set wns_p "skipped"
	puts "### D2_OOC_PLACE tag=$tag SYNTH_WNS=$wns_s PLACE=skipped"
}

# --- Routing: the question PLACE's WNS leaves open --------------------------
# +0.5 ns after place does NOT say the clock rate holds -- routing eats
# into the margin. Only this number decides on 75 MHz.
if {$doroute} {
	puts "### D2-OOC: route_design ..."
	if {[catch {route_design} err]} {
		puts "### ROUTE_FAILED ($tag): $err"
		report_route_status -file [file join $outdir route_status_failed.rpt]
		puts "### D2_OOC_RESULT tag=$tag ROUTE=FAILED"
		exit 1
	}
	report_utilization               -file [file join $outdir util_route_flat.rpt]
	report_utilization -hierarchical -hierarchical_depth 3 -file [file join $outdir util_route_hier.rpt]
	report_timing_summary -file [file join $outdir timing_route.rpt]
	report_route_status   -file [file join $outdir route_status.rpt]
	set rpt3 [report_utilization -return_string]
	foreach line [split $rpt3 "\n"] {
		if {[regexp {^\| CLB +\||CLB LUTs|CLB Registers|Block RAM Tile|URAM |DSPs} $line]} { puts "### ROUTE $line" }
	}
	set wns_r [get_property SLACK [get_timing_paths -delay_type max]]
	set whs_r [get_property SLACK [get_timing_paths -delay_type min]]
	# A positive WNS alone is not enough: unrouted nets would flatter the
	# timing. Both together are the proof.
	#
	# The AUTHORITATIVE number is "nets with routing errors" from
	# report_route_status -- NOT a hand-rolled get_nets filter. An earlier
	# attempt filtered on ROUTE_STATUS != INTRASITE/ROUTED and thereby
	# counted the top-level port nets in OOC operation too ("implicitly
	# routed ports"), which by definition have no route there. That
	# reported UNROUTED=674 on a design that was in fact routed
	# error-free -- a guard that raises false alarms gets ignored the next
	# time and is then worse than none.
	set _rs [report_route_status -return_string]
	set nerr "?"
	if {[regexp {nets with routing errors[\. ]*:\s*([0-9]+)} $_rs -> _m]} { set nerr $_m }
	set nunrouted "?"
	if {[regexp {# of routable nets[\. ]*:\s*([0-9]+)} $_rs -> _rt] &&
	    [regexp {# of fully routed nets[\. ]*:\s*([0-9]+)} $_rs -> _fr]} {
		set nunrouted [expr {$_rt - $_fr}]
	}
	puts "### D2_OOC_ROUTE tag=$tag ROUTE_WNS=$wns_r ROUTE_WHS=$whs_r ROUTE_ERRORS=$nerr UNROUTED_ROUTABLE=$nunrouted"
	write_checkpoint -force $dcp_route
	puts "### D2_OOC_RESULT tag=$tag SYNTH_WNS=$wns_s PLACE_WNS=$wns_p ROUTE_WNS=$wns_r ROUTE_WHS=$whs_r ROUTE_ERRORS=$nerr UNROUTED_ROUTABLE=$nunrouted"
} else {
	puts "### D2_OOC_RESULT tag=$tag SYNTH_WNS=$wns_s PLACE_WNS=$wns_p ROUTE=skipped"
}
puts "### D2_OOC_DONE tag=$tag -> $outdir"
