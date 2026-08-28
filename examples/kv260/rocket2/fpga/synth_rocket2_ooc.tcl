# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# M4 step 1: capacity measurement of the TWO-HART Rocket branch
# (rocket2_soc_synth_wrap = Rocket64t2 generat + 2x shim + 2x ct_encoder +
# ct_L1_funnel + 8250 console + window guard), BEFORE a bitstream run.
#
#   vivado -mode batch -notrace -source examples/kv260/rocket2/fpga/synth_rocket2_ooc.tcl \
#          -tclargs <tag> [<part>] [<ctte-root>] [<place:0|1>]
#
# Template: synth_rocket_ooc.tcl (one-hart branch). THREE differences, each
# with a reason:
#
#  1. GENERAT rocket64t2 (two harts + context port, M2). The bootrom patch
#     therefore needs --gen: the 1-hart generat's TLROM line window does not
#     apply there (extract_tlrom.py then searches the boundaries itself).
#
#  2. FUNNEL from this repository's own repo-root rtl/ct_L1_funnel.sv, NOT
#     from the encoder MIRROR -- rationale in rocket2_soc_synth_wrap.sv's
#     header (finding F-1: an upstream funnel version parses one 32-bit
#     chunk per beat, the encoder emits four byte chunks).
#     (Migration fix 2026-08-18, same as run_rocket2_bitstream.tcl: the
#     inherited third_party/CTTE/ path is the predecessor repository's vendor copy and
#     does not exist here.)
#
#  3. PLACE STEP (on by default), and that is the actual point of this
#     script: M1's question is "does it fit?", and the BINDING size is CLB
#     occupancy, not the LUT count (Trio: 85.9% LUT at 99.8% CLB). A pure
#     synthesis report CANNOT answer the question -- `report_utilization`
#     after synth_design has no CLB row at all, that only appears once
#     placed. Hence this script additionally runs opt_design + place_design
#     out-of-context and pulls the report a second time. That costs ~20-40
#     min and replaces an estimate with a measurement.

set tag  [lindex $argv 0]
set part [lindex $argv 1]
set ctr  [lindex $argv 2]
set doplace [lindex $argv 3]
if {$tag  eq ""} { set tag  slim2 }
if {$part eq ""} { set part xck26-sfvc784-2LV-c }
if {$doplace eq ""} { set doplace 1 }

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir .. .. .. ..]]
set ref        [file join $repo_root examples kv260 third_party rocket_ref rocket64t2]
if {$ctr eq ""} {
    # See run_rocket2_bitstream.tcl's note: this pinned path does not exist
    # in this repository yet (out-of-scope measurement workflow).
    set ctr [file join $repo_root bld m4_rocket_2hart ctte_slim64]
}

set outdir [file join $repo_root bld m4_rocket_2hart synth_$tag]
file mkdir $outdir

puts "### M4-OOC: two-hart Rocket, Tag=$tag, Part=$part, place=$doplace"
puts "### M4-OOC: encoder tree = $ctr"
set provf [file join $ctr CTTE_M4_PROVENANCE.txt]
if {[file exists $provf]} {
    set fh [open $provf r]
    foreach l [split [read $fh] "\n"] { if {[string trim $l] ne ""} { puts "###   $l" } }
    close $fh
}

# --- 1. Generat with a patched bootrom (build-local) ------------------------
set genorig [file join $ref system-nexys-video.v]
set gen [file join $outdir system-nexys-video_m4.v]
if {![file exists $gen]} {
    if {[catch {exec py [file join $repo_root examples kv260 common tools extract_tlrom.py] \
            [file join $outdir rom.bin] --gen $genorig \
            --patch-hart0 --patch-verilog-out $gen} err]} {
        puts "### ERROR: extract_tlrom.py failed: $err"; exit 1
    }
}
puts "### M4-OOC: generat (bootrom-patched) = $gen"

# --- 2. CTTE encoder from the .abc graph ----------------------------------
if {[catch {set ct_files [exec py [file join $script_dir abc_filelist.py] \
        [file join $ctr rtl ct_encoder.abc] --root $ctr --quiet]} err]} {
    puts "### ERROR: abc_filelist.py failed: $err"; exit 1
}
set ct_files [split [string trim $ct_files] "\n"]

# --- 3. Our own building blocks + the funnel ---------------------------------
set funnel [file join $repo_root third_party CTTE rtl ct_L1_funnel.sv]
puts "### M4-OOC: funnel = $funnel (delta version, MDO_WIDTH=6)"
set rocket1_rtl [file join $repo_root examples kv260 rocket_linux rtl]
set own_files [list \
    [file join $repo_root rtl adapters rocket rocket_tci_to_ctte_tip.sv] \
    [file join $rocket1_rtl rocket_con_8250.sv] \
    [file join $rocket1_rtl rocket_mem_window.sv] \
    $funnel \
    [file join $script_dir .. rtl rocket2_soc_synth_wrap.sv] \
]

read_verilog [list $gen [file join $ref plusarg_reader.v]]
foreach f [concat $ct_files $own_files] {
    if {![file exists $f]} { puts "### ERROR missing: $f"; exit 1 }
    read_verilog -sv $f
}

# ONE thread (synth_rocket_ooc.tcl:96): the multi-threaded optimizer dies on
# the 9 MB flat generat with EXCEPTION_ACCESS_VIOLATION, independent of free RAM.
set_param general.maxThreads 1

puts "### M4-OOC: synth_design rocket2_soc_synth_wrap ..."
if {[catch {synth_design -top rocket2_soc_synth_wrap -part $part -mode out_of_context \
        -verilog_define SYNTHESIS -flatten_hierarchy rebuilt} err]} {
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
puts "### M4_OOC_SYNTH tag=$tag WNS=$wns_s"

if {$doplace} {
    puts "### M4-OOC: opt_design + place_design (for the CLB row) ..."
    if {[catch {opt_design} err]} { puts "### OPT_FAILED ($tag): $err"; exit 1 }
    if {[catch {place_design} err]} {
        # A placement abort IS the result: it means "does not fit".
        puts "### PLACE_FAILED ($tag): $err"
        report_utilization -file [file join $outdir util_place_failed.rpt]
        puts "### M4_OOC_RESULT tag=$tag PLACE=FAILED"
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
    puts "### M4_OOC_RESULT tag=$tag SYNTH_WNS=$wns_s PLACE_WNS=$wns_p"
} else {
    puts "### M4_OOC_RESULT tag=$tag SYNTH_WNS=$wns_s PLACE=skipped"
}
puts "### M4_OOC_DONE tag=$tag -> $outdir"
