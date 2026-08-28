# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC

# Out-of-context synthesis of ct_encoder WITH timing constraints and report,
# so that timing and fmax can be reported per profile -- the verification
# table requires "no timing violation in the target configuration".
#
# Clocks: every encoder clock port is given the same target period budget
# (default 5.0 ns = 200 MHz, tclarg 2). Single-clock profiles are driven by
# ONE clock anyway; in the multi-clock case an identical budget per domain is
# the conservative out-of-context approximation. The CDC paths are decoupled
# for the tool by the gray-pointer and handshake structures, and
# set_clock_groups -asynchronous relaxes the inter-clock paths the same way a
# real SoC XDC would.
#   vivado -mode batch -source scripts/synth_encoder_ooc_timing.tcl \
#          -tclargs <part> <period_ns>
# Reports land in bld/synth_ooc_t/ (util_flat, util_hier, timing_summary).
set part   [lindex $argv 0]
set period [lindex $argv 1]
if {$part eq ""}   { set part xck26-sfvc784-2LV-c }
if {$period eq ""} { set period 5.0 }

# Resolve everything relative to the SCRIPT location, not the CWD -- same
# reason as in the sibling script synth_encoder_ooc.tcl (Vivado drops .Xil
# under the CWD; a stale locked .Xil broke consecutive runs, 2026-07-24).
set repo [file dirname [file dirname [file normalize [info script]]]]

set outdir [file join $repo bld synth_ooc_t]
file mkdir $outdir

# Skip blanks AND comment lines: the file list carries an SPDX header since
# 2026-08-05 (commit ecb87b0). Without this filter read_verilog is handed the
# comment text as a file name and the run dies before synthesis -- which is
# why this script, and phase_d_matrix_v2.sh with it, had been unusable ever
# since. The sibling synth_encoder_ooc.tcl always filtered; only this copy
# did not (P10-B).
set fl [open [file join $repo scripts synth_encoder_files.f] r]
set files {}
foreach line [split [read $fl] "\n"] {
    set line [string trim $line]
    if {$line ne "" && ![string match "#*" $line]} { lappend files [file join $repo $line] }
}
close $fl
foreach f $files { read_verilog -sv $f }

# CORE_XLEN: same reason and same source as in the sibling
# synth_encoder_ooc.tcl -- ct_encoder's P0-07 elaboration guard refuses the
# default 0 and accepts exactly ct_pkg::CT_XLEN, so the width is read from the
# package instead of hard-coded. Elaboration-only and resource-neutral
# (measured on both widths). Both copies carry it: this one had
# already drifted from its sibling once (P10-B, the missing comment filter).
set core_xlen ""
set fh [open [file join $repo rtl pkg ct_pkg.sv] r]
foreach line [split [read $fh] "\n"] {
    if {[regexp {localparam\s+int\s+unsigned\s+CT_XLEN\s*=\s*([0-9]+)\s*;} $line -> w]} {
        set core_xlen $w
        break
    }
}
close $fh
if {$core_xlen eq ""} {
    error "CT_XLEN not found in rtl/pkg/ct_pkg.sv -- refusing to guess CORE_XLEN"
}
puts "CORE_XLEN = $core_xlen (from ct_pkg::CT_XLEN)"

puts "=== synth_design ct_encoder for $part (OOC, period ${period} ns) ==="
# Single-threaded, for the same reason as in synth_encoder_ooc.tcl: the
# multithreading helper's child processes fail to read existing install
# files in this environment; results are identical.
set_param general.maxThreads 1
synth_design -top ct_encoder -part $part -mode out_of_context \
             -generic CORE_XLEN=$core_xlen

# Clock constraints on every clock port that still exists post-synthesis
# (single-clock slim profiles tie/trim some domains).
set clkspecs {tip_clk proc_clk wb_clk atb_atclk wall_clk}
set made {}
foreach c $clkspecs {
    if {[llength [get_ports -quiet $c]] > 0} {
        create_clock -name $c -period $period [get_ports $c]
        lappend made $c
    }
}
if {[llength $made] > 1} {
    set cgargs {}
    foreach g $made { lappend cgargs -group $g }
    set_clock_groups -asynchronous {*}$cgargs
}
puts "clocks: $made"

report_utilization               -file $outdir/util_flat.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file $outdir/util_hier.rpt
report_timing_summary -delay_type max -max_paths 5 -file $outdir/timing_summary.rpt

# Concise WNS/Fmax summary to stdout
set rpt [report_timing_summary -delay_type max -no_detailed_paths -return_string]
set wns ""
foreach ln [split $rpt "\n"] {
    if {[regexp {^\s*(-?[0-9.]+)\s+(-?[0-9.]+)\s+[0-9]+\s+[0-9]+\s} $ln m w]} { set wns $w; break }
}
puts "----- ct_encoder OOC timing ($part @ ${period} ns) -----"
if {$wns ne ""} {
    set fmax [expr {1000.0 / ($period - $wns)}]
    puts [format "WNS=%s ns  -> Fmax ~= %.1f MHz" $wns $fmax]
} else {
    puts "WNS: see $outdir/timing_summary.rpt (the parser found no matching line)"
}
puts "OK"
