# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Bitstream of the Linux CVA6 demonstrator (top cva6_linux_kv260_top).
#
#   vivado -mode batch -notrace -source examples/kv260/cva6_linux/fpga/run_cva6_linux_bitstream.tcl
#
# OWN project (proj_linux/), not a shared project: the Linux configuration
# cv32a6_ima_sv32_fpga brings a different CVA6 config_pkg than cv32a60x --
# both in the same fileset would supply the same package declaration twice.
# The four PS glue IPs are (re)generated with gen_ip.tcl in this project
# (the same configuration as the trio example, incl. S_AXI_GP3 for the CVA6
# memory path).

set script_dir [file dirname [file normalize [info script]]]
# This script now sits 4 levels under the repo root
# (examples/kv260/cva6_linux/fpga/), unlike the predecessor repository's vivado/kv260_app/
# (2 levels) -- path-depth fix, same adaptation as the mbv/rocket_linux
# migrations before it.
set repo_root  [file normalize [file join $script_dir .. .. .. ..]]
set proj_name  cva6_linux_kv260
set proj_dir   [file join $script_dir proj_linux]
set part       xck26-sfvc784-2LV-c

file delete -force $proj_dir
create_project $proj_name $proj_dir -part $part
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property xpm_libraries {XPM_MEMORY XPM_CDC XPM_FIFO} [current_project]

# This repository IS the CTTE encoder (unlike the predecessor repository, which built
# against a third_party/CTTE/ vendor copy) -- default source is the repo
# root itself, same adaptation as examples/kv260/mbv/fpga's
# create_project_kv260.tcl and examples/kv260/rocket_linux/fpga's
# run_rocket_bitstream.tcl.
set ctte [file normalize $repo_root]
# CVA6-with-ITI reference core: NOT vendored in this repository (AP4.4 --
# reference cores are pinned by commit, not copied into the tree). See
# ../../third_party/CVA6_PIN.md and ../../third_party/fetch.sh. This step
# therefore fails with a clear "file missing" error until that fetch step
# has been run locally.
set ref    [file join $repo_root examples kv260 third_party cva6_ref]
set pulp   [file join $ref vendor pulp-platform]
set rtl    [file join $script_dir .. rtl]
set common_dir [file join $repo_root examples kv260 common]
set tgc5b_dir  [file join $repo_root examples kv260 common tgc5b rtl]

# --- 1. CTTE encoder (from the .abc graph, unchanged -- AD-01) -----------
if {[catch {set ct_files [exec py [file join $script_dir abc_filelist.py] \
        [file join $ctte rtl ct_encoder.abc] --root $ctte --quiet]} err]} {
	puts "### ERROR: abc_filelist.py failed: $err"; exit 1
}
set ct_files [split [string trim $ct_files] "\n"]
# E-Trace backend: NOT in the .abc graph (that file describes the N-Trace
# path only), but mandatory for the DUAL build -- the same addition as in
# the trio example's sim flow.
lappend ct_files [file join $ctte rtl ct_L2_te_inst_gen.sv]
lappend ct_files [file join $ctte rtl ct_L2_te_packetizer.sv]

# --- 2. CVA6 in the Linux configuration -------------------------------------
# --exclude counter.sv: common_cells' `counter` collides with CTTE's
#   module of the same name (different port list). PULP consumers instead
#   pull the renamed copy pulp_counter.sv (vendoring delta, CVA6_PIN.md).
# --exclude tc_sram_wrapper.sv: behavioral == simulation only; synthesis
#   uses tc_sram_fpga_wrapper + SyncSpRamBeNx64 instead (otherwise DRC INBB-3).
set flist [file join $ref core Flist.cva6]
set cva6_files [split [string trim [exec py [file join $script_dir cva6_filelist.py] \
    $flist --target cv32a6_ima_sv32_fpga --exclude counter.sv --exclude tc_sram_wrapper.sv]] "\n"]
lappend cva6_files [file join $ref common local util tc_sram_fpga_wrapper.sv]
lappend cva6_files [file join $ref vendor pulp-platform fpga-support rtl SyncSpRamBeNx64.sv]
set cva6_incs [split [string trim [exec py [file join $script_dir cva6_filelist.py] $flist --incdirs]] "\n"]
lappend cva6_incs [file join $ref corev_apu instr_tracing ITI include]

# --- 3. ITI + PULP AXI infrastructure + our own SoC building blocks --------
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
    [file join $rtl cva6_soc_synth_wrap.sv] \
    [file join $tgc5b_dir ct_axil_to_wb.sv] \
    [file join $common_dir ct_soc_trace_ring.sv] \
    [file join $common_dir ct_soc_ddr_sink.sv] \
    [file join $common_dir ct_soc_pib.sv] \
    [file join $rtl cva6_linux_periph.sv] \
    [file join $rtl cva6_linux_mem_xbar.sv] \
    [file join $rtl cva6_linux_soc_top.sv] \
    [file join $script_dir cva6_linux_kv260_top.sv] \
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

# --- 4. PS glue IPs (verbatim as for the trio example, incl. S_AXI_GP3) -----
namespace eval abc { variable proj_dir }
set abc::proj_dir $proj_dir
source [file join $script_dir gen_ip.tcl]
catch { config_ip_cache -clear_output_repo }
catch { config_ip_cache -disable_cache }
# GLOBAL instead of OOC: the realtime stub generator stubbornly emitted a
# stale port list during the trio bring-up (6th attempt). Without a synth
# checkpoint there is no stub path -- the four small IPs are inline
# co-synthesized instead.
foreach ipname {ct_soc_kv260_ps ct_soc_kv260_rst ct_soc_kv260_dwc ct_soc_kv260_pc} {
	set xci [get_files -quiet -all */${ipname}.xci]
	if {[llength $xci]} { set_property generate_synth_checkpoint false $xci }
}
generate_target all [get_ips ct_soc_kv260_*]

set_property top cva6_linux_kv260_top [current_fileset]
update_compile_order -fileset sources_1

# --- 5. Synthesis -> implementation -> bitstream -----------------------------
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { puts "### SYNTH_FAIL"; exit 3 }
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { puts "### IMPL_FAIL"; exit 4 }

set bit [glob -nocomplain [file join $proj_dir ${proj_name}.runs impl_1 *.bit]]
puts "### BITSTREAM_OK: $bit"

open_run impl_1
report_timing_summary -file [file join $script_dir cva6_linux_timing_summary.rpt]
report_utilization    -file [file join $script_dir cva6_linux_utilization.rpt]
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "### WNS: $wns ns"
exit 0
