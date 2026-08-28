# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# run_bitstream.tcl -- AXIS watchpoint testbed: full bitstream run.
#
# Requires the project to already exist (create_project.tcl). Then
# synth_1 -> impl_1 -> write_bitstream with top tgc5b2_kv260_top, a WNS
# check, and utilization/timing reports written to reports/ (raw-data
# obligation).
#
#   vivado -mode batch -notrace -source examples/kv260/tgc5b2_axis_wp/fpga/run_bitstream.tcl
#
# Migrated from an internal predecessor repository
#. the predecessor repository's original script
# selected a report/marker tag per RTL leg (D1/D1B/D2/T2); this migration
# carries only the T2 configuration (see create_project.tcl), so the leg
# switch and its now-single-valued tag were dropped.

set script_dir [file dirname [file normalize [info script]]]
set proj       [file join $script_dir proj tgc5b2_axis_wp.xpr]
set rpt_tag    tgc5b2_axis_wp
set rpt_dir    [file join $script_dir reports]

if {![file exists $proj]} {
	puts "### ERROR: project missing: $proj (run create_project.tcl first)"
	exit 1
}
open_project $proj
file mkdir $rpt_dir

set_property top tgc5b2_kv260_top [current_fileset]
update_compile_order -fileset sources_1

generate_target all [get_ips ct_soc_kv260_* wp_axi_fifo]

# Single synthesis thread: with multiple threads Vivado 2026.1 occasionally
# dies in "Cross Boundary and Area Optimization" -- the same failure mode the
# cva6 flows already guard against (see examples/kv260/cva6_2/fpga/
# synth_cva6_2_ooc.tcl:196-199). MEASURED HERE on 2026-08-18: with the default
# thread count this run died at exactly that step with
# EXCEPTION_ACCESS_VIOLATION (hs_err_pid*.log in the synth_1 directory), after
# 23 minutes and without a single RTL error -- and `vivado` still exited 0, so
# only the run's PROGRESS property gives it away.
set_param general.maxThreads 1

reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { puts "### SYNTH_FAIL"; exit 3 }
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { puts "### IMPL_FAIL"; exit 4 }

set bit [glob -nocomplain [file join [file dirname $proj] ${rpt_tag}.runs impl_1 *.bit]]
puts "### BITSTREAM_OK: $bit"

# Timing + resource evidence (gate: WNS >= 0; reports are raw data)
open_run impl_1
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "### TIMING WNS: $wns ns"
report_timing_summary -file [file join $rpt_dir ${rpt_tag}_timing_summary.rpt]
report_utilization -file [file join $rpt_dir ${rpt_tag}_utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 4 \
	-file [file join $rpt_dir ${rpt_tag}_utilization_hier.rpt]
puts "### REPORTS: $rpt_dir"
if {$wns < 0} { puts "### TIMING_FAIL (WNS < 0)"; exit 5 }
puts "### BITSTREAM_DONE"
