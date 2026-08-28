# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# R4a step 3: bitstream of the Rocket RV64 demonstrator (top rocket_kv260_top).
#
#   vivado -mode batch -notrace -source examples/kv260/rocket_linux/fpga/run_rocket_bitstream.tcl \
#          [-tclargs <en_etrace>]
#
# OWN project (proj_rocket/), not the Trio/Linux project: the Rocket generat
# brings 173 modules with it, some of them named (`Repeater`, `Queue`,
# `Xbar`) that could collide with a CVA6 fileset in the same project.
# Separate projects are cheaper here than any collision diagnosis. The four
# PS glue IPs are (re)generated with gen_ip.tcl in this project (the same
# configuration as the Trio/CVA6, including S_AXI_GP3 for the core's memory
# path).
#
# FOUR points this flow needs on top of run_cva6_linux_bitstream.tcl -- all
# proven in synth_rocket_ooc.tcl already:
#  1. The generat is PLAIN Verilog: file_type Verilog, NOT SystemVerilog.
#  2. `SYNTHESIS` must be set as a Verilog define, otherwise the
#     $value$plusargs branch stays in the FIRRTL blackbox plusarg_reader.
#     Vivado does NOT define this on its own.
#  3. The bootrom needs the single-word patch (D-L2-4/D-R32a-1): the reset
#     vector otherwise branches hart 0 into the SD-card bootloader, which
#     this design does not have. The patch produces a BUILD-LOCAL copy; the
#     upstream generat stays untouched.
#  4. GLOBAL instead of OOC for the PS IPs -- same rationale as for the Trio
#     (run_trio_bitstream.tcl:99-114, six documented attempts: the realtime
#     stub generator kept stubbornly emitting a stale port list).
#
# ---------------------------------------------------------------------------
# ARGUMENTS (package W1, 2026-08-08)
#   tclarg 0 = EN_ETRACE (default 1)          tclarg 1 = CT_XLEN, 32|64 (default 32)
#
#   without tclargs -> bit-for-bit the R4a run (pinned tree, proj_rocket/,
#                       reports rocket_*.rpt)
#   ... 0 64        -> CT_XLEN=64 mirror, proj_rocket_x64/, reports rocket_x64_*.rpt
#
# `enet` was read all the way up to W1 but NEVER wired up -- the top carried
# `.EN_ETRACE (1'b1)` as a literal (B-W1-2). It now goes to the top as a
# synthesis generic. At CT_XLEN=64, EN_ETRACE=0 is mandatory (R1.1 D-7):
# ct_encoder otherwise aborts elaboration with $fatal.
set enet [lindex $argv 0]
if {$enet eq ""} { set enet 1 }
set ct_xlen [lindex $argv 1]
if {$ct_xlen eq ""} { set ct_xlen 32 }
if {$ct_xlen ne "32" && $ct_xlen ne "64"} {
    puts "### ERROR: second tclarg must be 32 or 64 (was '$ct_xlen')"; exit 1
}

set script_dir [file dirname [file normalize [info script]]]
# This script now sits 4 levels under the repo root
# (examples/kv260/rocket_linux/fpga/), unlike the predecessor repository's
# vivado/kv260_app/ (2 levels) -- path-depth fix, mirrors the mbv migration.
set repo_root  [file normalize [file join $script_dir .. .. .. ..]]
set part       xck26-sfvc784-2LV-c

if {$ct_xlen eq "64"} {
    if {$enet != 0} {
        puts "### ERROR: CT_XLEN=64 requires EN_ETRACE=0 (X2b not implemented)."
        puts "###        Call: -tclargs 0 64"
        exit 1
    }
    # NOTE (migration, 2026-08-17): in the predecessor repository this pointed at a pinned
    # measurement worktree under that repo's own bld/ (bld/w1_rv64_decode/
    # ctte_xlen64), produced by a session-specific CT_XLEN=64 measurement
    # workflow that has not been ported into this repository yet. bld/ here
    # is gitignored and currently empty for this path -- the x64 branch is
    # kept structurally intact (so a future port of that workflow only has
    # to populate the directory, not rewrite this script), but it is NOT
    # functional today. Open item, see the migration report / README.
    set ctte    [file join $repo_root bld w1_rv64_decode ctte_xlen64]
    set proj_name rocket_x64_kv260
    set proj_dir  [file join $script_dir proj_rocket_x64]
    set rpt_pfx   rocket_x64
    set bld       [file join $repo_root bld w1_rv64_decode]
} else {
    # This repository IS the CTTE encoder (unlike the predecessor repository, which built
    # against a third_party/CTTE/ vendor copy) -- default source is the
    # repo root itself, same adaptation as examples/kv260/mbv/fpga's
    # create_project_kv260.tcl.
    set ctte    $repo_root
    set proj_name rocket_kv260
    set proj_dir  [file join $script_dir proj_rocket]
    set rpt_pfx   rocket
    set bld       [file join $repo_root bld r4a_rocket_bit]
}

set ref    [file join $repo_root examples kv260 third_party rocket_ref]
set rtl    [file join $script_dir .. rtl]
file mkdir $bld

# The width switch is read back FROM the tree, not assumed.
set ct_pkg_file [file join $ctte rtl pkg ct_pkg.sv]
if {![file exists $ct_pkg_file]} { puts "### ERROR: $ct_pkg_file missing"; exit 1 }
set fh [open $ct_pkg_file r]; set ct_pkg_txt [read $fh]; close $fh
set have_xlen 32
if {[regexp {localparam int unsigned CT_XLEN = (\d+);} $ct_pkg_txt -> m]} {
    set have_xlen $m
} elseif {$ct_xlen eq "64"} {
    puts "### ERROR: $ct_pkg_file does not know CT_XLEN (encoder stand predates X2a)"; exit 1
}
if {$have_xlen ne $ct_xlen} {
    puts "### ERROR: encoder tree carries CT_XLEN=$have_xlen, requested is $ct_xlen ($ctte)"
    exit 1
}
puts "### ENCODER: $ctte  (CT_XLEN=$have_xlen, EN_ETRACE=$enet)"
set prov [file join $ctte CTTE_XLEN_PROVENANCE.txt]
if {[file exists $prov]} {
    set fh [open $prov r]
    foreach ln [split [string trim [read $fh]] "\n"] { puts "###   $ln" }
    close $fh
}

# --- 0. Generat with a patched bootrom (build-local) ------------------------
set gen [file join $bld system-nexys-video_r4a.v]
if {![file exists $gen]} {
    # extract_tlrom.py (sim/rocket/ in the predecessor repository) was migrated to
    # examples/kv260/common/tools/ on 2026-08-18 (facf54cfbd); it is shared
    # by rocket_linux and rocket2. Its relative search for
    # ../../third_party/rocket_ref/system-nexys-video.v resolves from that
    # location on its own -- no path logic inside the tool was changed.
    if {[catch {exec py [file join $repo_root examples kv260 common tools extract_tlrom.py] \
            [file join $bld rom.bin] --patch-hart0 --patch-verilog-out $gen} err]} {
        puts "### ERROR: extract_tlrom.py failed: $err"; exit 1
    }
}
puts "### R4a: generat (bootrom-patched) = $gen"

file delete -force $proj_dir
create_project $proj_name $proj_dir -part $part
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property xpm_libraries {XPM_MEMORY XPM_CDC XPM_FIFO} [current_project]

# --- 1. CTTE encoder (from the .abc graph, unchanged -- AD-01) -----------
if {[catch {set ct_files [exec py [file join $script_dir abc_filelist.py] \
        [file join $ctte rtl ct_encoder.abc] --root $ctte --quiet]} err]} {
    puts "### ERROR: abc_filelist.py failed: $err"; exit 1
}
set ct_files [split [string trim $ct_files] "\n"]
# E-Trace backend for the DUAL build -- the same addition as in the
# CVA6/Trio flows. TODAY a no-op (B-R4a-3): the pinned .abc graph already
# carries both files itself, and Vivado acknowledges that with "cannot be
# added to the project because it already exists in the project, skipping
# this file". Deliberately LEFT IN rather than removed: should the backend
# ever fall back out of the graph on a later pin, the build stays complete
# -- and if one of the files is missing, elaboration aborts loudly instead
# of silently losing E-Trace.
lappend ct_files [file join $ctte rtl ct_L2_te_inst_gen.sv]
lappend ct_files [file join $ctte rtl ct_L2_te_packetizer.sv]

# --- 2. Our own SystemVerilog building blocks --------------------------------
set common_dir [file join $repo_root examples kv260 common]
set tgc5b_dir  [file join $repo_root examples kv260 common tgc5b rtl]
set sv_files [list \
    [file join $repo_root rtl adapters rocket rocket_tci_to_ctte_tip.sv] \
    [file join $rtl rocket_con_8250.sv] \
    [file join $rtl rocket_mem_window.sv] \
    [file join $rtl rocket_soc_synth_wrap.sv] \
    [file join $tgc5b_dir ct_axil_to_wb.sv] \
    [file join $common_dir ct_soc_trace_ring.sv] \
    [file join $common_dir ct_soc_ddr_sink.sv] \
    [file join $common_dir ct_soc_pib.sv] \
    [file join $rtl rocket_soc_top.sv] \
    [file join $script_dir rocket_kv260_top.sv] \
]

# EVERYTHING in xil_defaultlib (NO separate library) -- CTTE's counter.sv
# carries MODE_SATURATION as a $unit-scope declaration; a library split
# would cut the compilation-unit groups apart (C4 finding 2026-07-24).
foreach f [concat $ct_files $sv_files] {
    set f [file normalize $f]
    if {![file exists $f]} { puts "### ERROR missing: $f"; exit 1 }
    add_files -fileset sources_1 -norecurse $f
    set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1] $f]
}

# --- 3. Rocket generat: plain Verilog ----------------------------------------
foreach f [list $gen [file join $ref plusarg_reader.v]] {
    set f [file normalize $f]
    if {![file exists $f]} { puts "### ERROR missing: $f"; exit 1 }
    add_files -fileset sources_1 -norecurse $f
    set_property file_type Verilog [get_files -of_objects [get_filesets sources_1] $f]
}

set xdc [file normalize [file join $script_dir rocket_pib_pmod.xdc]]
add_files -fileset constrs_1 -norecurse $xdc

# --- 4. PS glue IPs (verbatim as for the Trio/CVA6, incl. S_AXI_GP3) --------
namespace eval abc { variable proj_dir }
set abc::proj_dir $proj_dir
source [file join $script_dir gen_ip.tcl]
catch { config_ip_cache -clear_output_repo }
catch { config_ip_cache -disable_cache }
foreach ipname {ct_soc_kv260_ps ct_soc_kv260_rst ct_soc_kv260_dwc ct_soc_kv260_pc} {
    set xci [get_files -quiet -all */${ipname}.xci]
    if {[llength $xci]} { set_property generate_synth_checkpoint false $xci }
}
generate_target all [get_ips ct_soc_kv260_*]

# SYNTHESIS define for plusarg_reader (point 2 above). Set as a fileset
# property so it applies to the project's synthesis run.
set_property verilog_define {SYNTHESIS} [get_filesets sources_1]
puts "### VERILOG_DEFINE: [get_property verilog_define [get_filesets sources_1]]"

set_property top rocket_kv260_top [current_fileset]
# EN_ETRACE as a synthesis generic on the top (B-W1-2: the tclarg was
# ineffective up to W1). Read back, not assumed.
set_property generic "EN_ETRACE=1'b$enet" [get_filesets sources_1]
puts "### GENERIC: [get_property generic [get_filesets sources_1]]"
update_compile_order -fileset sources_1

# --- 5. Synthesis -> implementation -> bitstream -----------------------------
# TCL.PRE hook: a project run executes in its OWN Vivado process, a
# `set_param` here does NOT apply there. The hook sets general.maxThreads 1
# -- without it, the first R4a OOC run died with EXCEPTION_ACCESS_VIOLATION
# in cross-boundary optimization (rationale + evidence in the hook itself).
set pre [file normalize [file join $script_dir rocket_synth_pre.tcl]]
set_property STEPS.SYNTH_DESIGN.TCL.PRE $pre [get_runs synth_1]
set_property STEPS.OPT_DESIGN.TCL.PRE   $pre [get_runs impl_1]

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { puts "### SYNTH_FAIL"; exit 3 }
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { puts "### IMPL_FAIL"; exit 4 }

set bit [glob -nocomplain [file join $proj_dir ${proj_name}.runs impl_1 *.bit]]
puts "### BITSTREAM_OK: $bit"

open_run impl_1
report_timing_summary -file [file join $script_dir ${rpt_pfx}_timing_summary.rpt]
report_utilization    -file [file join $script_dir ${rpt_pfx}_utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 3 \
    -file [file join $script_dir ${rpt_pfx}_utilization_hier.rpt]
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "### WNS: $wns ns"
puts "### WHS: $whs ns"
exit 0
