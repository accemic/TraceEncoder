# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# R4a step 1 (coordinator decision D-R1: OOC BEFORE the bitstream):
# out-of-context synthesis of the WHOLE Rocket SoC branch
# (rocket_soc_synth_wrap = Rocket64t1 generat + 8250 console + window guard
# + shim + ct_encoder) -- the measurement basis for the one question that
# has to be answered before every bitstream run: "does this even fit on the
# xck26?"
#
#   vivado -mode batch -notrace -source examples/kv260/rocket_linux/fpga/synth_rocket_ooc.tcl \
#          -tclargs <tag> [<part>] [<en_etrace>] [<ctte-root>]
#
# Examples:
#   ... -tclargs full                 (pinned full profile, DUAL encoder)
#   ... -tclargs featparity 0 <ct-copy>    (reduced profile, N-Trace-only)
#
# Template: synth_cva6_cfg_ooc.tcl (gate L0 of the CVA6 Linux plan).
# Deliberately OOC and without the PS IP -- what is measured is the PL share
# of the Rocket branch, comparable against the documented CVA6 numbers, not
# the complete board top.
#
# THREE pitfalls this flow has on top of the CVA6 template:
#  1. The generat is PLAIN Verilog (no -sv). With -sv the parser trips over
#     constructs that are Verilog-2001 there (L4 compile_rocket_soc.ps1).
#  2. `plusarg_reader` (the only FIRRTL blackbox) is only synthesizable
#     under `SYNTHESIS` -- without that define, the $value$plusargs branch
#     stays in place. Vivado does NOT define SYNTHESIS on its own, hence
#     explicit.
#  3. The bootrom needs the single-word patch from D-L2-4/D-R32a-1 (the
#     reset vector otherwise branches hart 0 into the SD-card bootloader,
#     which does not exist here). The patch produces a BUILD-LOCAL copy of
#     the generat; the upstream rocket_ref stays untouched.

set tag  [lindex $argv 0]
set part [lindex $argv 1]
set enet [lindex $argv 2]
set ctr  [lindex $argv 3]
set flat [lindex $argv 4]
if {$tag  eq ""} { set tag  full }
if {$part eq ""} { set part xck26-sfvc784-2LV-c }
if {$enet eq ""} { set enet 1 }
if {$flat eq ""} { set flat rebuilt }

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir .. .. .. ..]]
set ref        [file join $repo_root examples kv260 third_party rocket_ref]
if {$ctr eq ""} { set ctr $repo_root }

set outdir [file join $repo_root bld r4a_rocket_bit synth_rocket_$tag]
file mkdir $outdir

puts "### R4a-OOC: Rocket branch, Tag=$tag, EN_ETRACE=$enet, Part=$part"
puts "### R4a-OOC: CTTE tree = $ctr"

# --- 1. Generat with a patched bootrom (build-local) ------------------------
set gen [file join $outdir system-nexys-video_r4a.v]
if {![file exists $gen]} {
    # extract_tlrom.py lives in examples/kv260/common/tools/ since
    # 2026-08-18 (facf54cfbd); see run_rocket_bitstream.tcl's note.
    if {[catch {exec py [file join $repo_root examples kv260 common tools extract_tlrom.py] \
            [file join $outdir rom.bin] --patch-hart0 --patch-verilog-out $gen} err]} {
        puts "### ERROR: extract_tlrom.py failed: $err"; exit 1
    }
}
puts "### R4a-OOC: generat (bootrom-patched) = $gen"

# --- 2. CTTE encoder from the .abc graph (compile order) -----------------
if {[catch {set ct_files [exec py [file join $script_dir abc_filelist.py] \
        [file join $ctr rtl ct_encoder.abc] --root $ctr --quiet]} err]} {
    puts "### ERROR: abc_filelist.py failed: $err"; exit 1
}
set ct_files [split [string trim $ct_files] "\n"]
# E-Trace backend for the DUAL build -- same addition as in the CVA6/Trio
# flows. TODAY a no-op (B-R4a-3): the pinned .abc graph already carries both
# files itself; read_verilog then reads them in a second time.
# Deliberately left in, rationale in run_rocket_bitstream.tcl.
lappend ct_files [file join $ctr rtl ct_L2_te_inst_gen.sv]
lappend ct_files [file join $ctr rtl ct_L2_te_packetizer.sv]

# --- 3. Our own building blocks ----------------------------------------------
set own_files [list \
    [file join $repo_root rtl adapters rocket rocket_tci_to_ctte_tip.sv] \
    [file join $script_dir .. rtl rocket_con_8250.sv] \
    [file join $script_dir .. rtl rocket_mem_window.sv] \
    [file join $script_dir .. rtl rocket_soc_synth_wrap.sv] \
]

read_verilog [list $gen [file join $ref plusarg_reader.v]]
foreach f [concat $ct_files $own_files] {
    if {![file exists $f]} { puts "### ERROR missing: $f"; exit 1 }
    read_verilog -sv $f
}

# ONE thread -- as synth_cva6_cfg_ooc.tcl:72 also does. Not cosmetic: the
# first R4a run (2026-08-08 12:55) died with EXCEPTION_ACCESS_VIOLATION mid
# "Cross Boundary and Area Optimization"
# (the predecessor repository), with 25 GiB of free
# RAM -- so not a memory problem, but the multi-threaded optimizer on an
# 8.8 MB flat generat. The template flow did not set the parameter without a
# reason.
set_param general.maxThreads 1

puts "### R4a-OOC: synth_design rocket_soc_synth_wrap (flatten=$flat) ..."
if {[catch {synth_design -top rocket_soc_synth_wrap -part $part -mode out_of_context \
        -verilog_define SYNTHESIS -flatten_hierarchy $flat \
        -generic [list EN_ETRACE=$enet]} err]} {
    puts "### SYNTH_FAILED ($tag): $err"
    exit 1
}

report_utilization               -file [file join $outdir util_flat.rpt]
report_utilization -hierarchical -hierarchical_depth 3 -file [file join $outdir util_hier.rpt]

# 75 MHz board clock as a timing anchor (OOC approximation; pl_clk0 of the
# sibling branches, L4 §4.1 measured the two new blocks with it).
create_clock -period 13.333 -name clk [get_ports clk]
report_timing_summary -file [file join $outdir timing.rpt]

set rpt [report_utilization -return_string]
foreach line [split $rpt "\n"] {
    if {[regexp {CLB LUTs|CLB Registers|Block RAM Tile|URAM |DSPs} $line]} { puts "### $line" }
}
set wns [get_property SLACK [get_timing_paths -delay_type max]]
puts "### R4A_OOC_RESULT tag=$tag WNS=$wns"
puts "### R4A_OOC_DONE tag=$tag -> $outdir"
