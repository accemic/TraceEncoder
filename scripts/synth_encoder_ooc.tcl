# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC

# Out-of-context synthesis of the CTTE encoder (ct_encoder) for resource
# comparison against the AMD MicroBlaze V native N-Trace encoder.
# Run from the CTTE repo root:
#   vivado -mode batch -source scripts/synth_encoder_ooc.tcl -tclargs <part>
# Reports land in bld/synth_ooc/.
set part [lindex $argv 0]
if {$part eq ""} { set part xck26-sfvc784-2LV-c }

# Resolve everything relative to the SCRIPT location, not the CWD -- allows
# launching from a scratch dir (Vivado drops .Xil under the CWD; a stale
# locked .Xil in the repo root broke consecutive runs, 2026-07-24).
set repo [file dirname [file dirname [file normalize [info script]]]]

set outdir [file join $repo bld synth_ooc]
file mkdir $outdir

# Read the RTL file list (relative to repo root, packages first).
set fl [open [file join $repo scripts synth_encoder_files.f] r]
set files {}
foreach line [split [read $fl] "\n"] {
    set line [string trim $line]
    # Skip blanks and comment lines (the list carries an SPDX header).
    if {$line ne "" && ![string match "#*" $line]} { lappend files [file join $repo $line] }
}
close $fl

foreach f $files { read_verilog -sv $f }

# CORE_XLEN (P0-07 elaboration guard, 1415a02524): ct_encoder refuses to
# elaborate while CORE_XLEN is at its default 0, and its second guard
# (genCoreXlenMismatch) accepts exactly ONE value -- ct_pkg::CT_XLEN. So the
# width is read from the package rather than hard-coded to 32: a driver that
# flips the knob in the file (r11_ooc_xlen_pair.sh seds CT_XLEN in a detached
# worktree and passes nothing on the command line) is then measured at the
# width it actually asked for, and a hard-coded 32 would turn its 64 leg into
# a mismatch fatal. The parameter drives no logic -- it occurs only in those
# two guards (grep -rl CORE_XLEN rtl/ -> ct_encoder.sv alone) -- so passing it
# is resource-neutral, measured on both widths.
set core_xlen ""
set fh [open [file join $repo rtl pkg ct_pkg.sv] r]
foreach line [split [read $fh] "\n"] {
    if {[regexp {localparam\s+int\s+unsigned\s+CT_XLEN\s*=\s*([0-9]+)\s*;} $line -> w]} {
        set core_xlen $w
        break
    }
}
close $fh
# Refuse to guess: a silent default is the exact failure mode this fixes.
if {$core_xlen eq ""} {
    error "CT_XLEN not found in rtl/pkg/ct_pkg.sv -- refusing to guess CORE_XLEN"
}
puts "CORE_XLEN = $core_xlen (from ct_pkg::CT_XLEN)"

puts "=== synth_design ct_encoder for $part (OOC) ==="
# Single-threaded: the multithreading helper's spawned child processes fail
# to read existing install files in this environment (observed 2026-07-24,
# "couldn't read file .../rt/data/lib_core.tcl"); results are identical.
set_param general.maxThreads 1
synth_design -top ct_encoder -part $part -mode out_of_context \
             -generic CORE_XLEN=$core_xlen

report_utilization             -file $outdir/util_flat.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file $outdir/util_hier.rpt
puts "=== utilization written to $outdir ==="

# Concise summary to stdout
set rpt [report_utilization -return_string]
puts "----- ct_encoder OOC utilization ($part) -----"
foreach ln [split $rpt "\n"] {
    if {[regexp {CLB LUTs|LUT as Logic|LUT as Memory|CLB Registers|Register as Flip Flop|Block RAM Tile|RAMB36|RAMB18|DSPs|F7 Muxes|CARRY8} $ln]} { puts $ln }
}
puts "OK"
