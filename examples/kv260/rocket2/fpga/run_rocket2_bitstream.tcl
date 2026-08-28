# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# M4 step 4: bitstream of the TWO-HART Rocket demonstrator (top rocket2_kv260_top).
#
#   vivado -mode batch -notrace -source examples/kv260/rocket2/fpga/run_rocket2_bitstream.tcl \
#          [-tclargs <ctte-root>]
#
# Twin of run_rocket_bitstream.tcl. The four points from its header apply
# unchanged (generat is plain Verilog * SYNTHESIS define for plusarg_reader
# * bootrom single-word patch * GLOBAL instead of OOC for the PS IPs). FOUR
# differences come on top, each with a reason:
#
#  1. GENERAT rocket64t2 (two harts + context port, M2). The bootrom patch
#     therefore needs --gen: the 1-hart generat's TLROM line window does not
#     apply there (extract_tlrom.py then searches the boundaries itself).
#
#  2. ENCODER from the M4 MIRROR, not from the pinned tree. Only the mirror
#     carries CT_XLEN=64 AND CT_CONTEXT_WIDTH=22; the pinned tree does not
#     know CT_XLEN at all. The mirror is frozen to a commit
#     (CTTE_M4_PROVENANCE.txt), because package R1.3 works in the SSOT tree.
#
#  3. FUNNEL from this repository's own repo-root rtl/ct_L1_funnel.sv, NOT
#     from the encoder MIRROR -- finding F-1: an upstream funnel version
#     parses ONE 32-bit chunk per beat, while this design's encoder emits
#     four byte chunks (NEXUS_MDO_WIDTH = 6). It would switch channels
#     mid-message, and elaboration turns nothing red.
#     (Migration fix 2026-08-18: the path inherited from the predecessor repository named
#     third_party/CTTE/rtl/ct_L1_funnel.sv, that repository's vendor copy
#     of the encoder. It does not exist here -- THIS repository is the
#     encoder. Same correction as the sibling
#     ../../cva6_2/fpga/run_cva6_2_bitstream.tcl, whose header point 3 had
#     already flagged this script's dangling path.)
#
#  4. TIMING IS A GATE. The one-hart flow only prints WNS; here a negative
#     WNS leads to exit 5. A bitstream that does not hold the target
#     frequency is not a result, it is a file.
#
# EN_ETRACE is FIXED at 0, not a tclarg: the funnel parses MSEO, an E-Trace
# backend delivers raw bytes (rocket2_soc_synth_wrap aborts at 1 in
# elaboration), and CT_XLEN=64 forbids it anyway (R1.1 D-7).

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir .. .. .. ..]]
set part       xck26-sfvc784-2LV-c

set ctte [lindex $argv 0]
if {$ctte eq ""} {
    # NOTE (migration, 2026-08-17): in the predecessor repository this pointed at a pinned
    # measurement worktree under that repo's own bld/ (bld/m4_rocket_2hart/
    # ctte_slim64), produced by a session-specific CT_XLEN=64 +
    # CT_CONTEXT_WIDTH=22 measurement workflow that has not been ported into
    # this repository yet. bld/ here is gitignored and currently empty for
    # this path -- kept structurally intact, but NOT functional today. Open
    # item, see the migration report / README.
    set ctte [file join $repo_root bld m4_rocket_2hart ctte_slim64]
}

set enet      0
set proj_name rocket2_kv260
set proj_dir  [file join $script_dir proj_rocket2]
set rpt_pfx   rocket2
set bld       [file join $repo_root bld m4_rocket_2hart]
set ref       [file join $repo_root examples kv260 third_party rocket_ref rocket64t2]
set rtl       [file join $script_dir .. rtl]
file mkdir $bld

# The widths are read back FROM the tree, not assumed (lesson R4a/W1).
set ct_pkg_file [file join $ctte rtl pkg ct_pkg.sv]
if {![file exists $ct_pkg_file]} { puts "### ERROR: $ct_pkg_file missing"; exit 1 }
set fh [open $ct_pkg_file r]; set ct_pkg_txt [read $fh]; close $fh
set have_xlen 0; set have_ctx 0
regexp {localparam int unsigned CT_XLEN = (\d+);}          $ct_pkg_txt -> have_xlen
regexp {localparam int unsigned CT_CONTEXT_WIDTH = (\d+);} $ct_pkg_txt -> have_ctx
if {$have_xlen ne "64"} {
    puts "### ERROR: encoder tree carries CT_XLEN=$have_xlen, requested is 64 ($ctte)"; exit 1
}
# 22 = the live width of satp.PPN on this generat (M3-1). Below that, the
# ownership key would not be unique, and the wrapper silently disables the
# context path -- so abort loudly here instead.
if {$have_ctx ne "22"} {
    puts "### ERROR: encoder tree carries CT_CONTEXT_WIDTH=$have_ctx, requested is 22 (M3-1)"; exit 1
}
puts "### ENCODER: $ctte  (CT_XLEN=$have_xlen, CT_CONTEXT_WIDTH=$have_ctx, EN_ETRACE=$enet)"
foreach provname {CTTE_M4_PROVENANCE.txt CTTE_XLEN_PROVENANCE.txt} {
    set prov [file join $ctte $provname]
    if {[file exists $prov]} {
        set fh [open $prov r]
        foreach ln [split [string trim [read $fh]] "\n"] { puts "###   $ln" }
        close $fh
    }
}

# --- 0. Generat with a patched bootrom (build-local) ------------------------
set genorig [file join $ref system-nexys-video.v]
set gen     [file join $bld system-nexys-video_m4.v]
if {![file exists $gen]} {
    # extract_tlrom.py lives in examples/kv260/common/tools/ since
    # 2026-08-18 (facf54cfbd) -- see run_rocket_bitstream.tcl's note.
    if {[catch {exec py [file join $repo_root examples kv260 common tools extract_tlrom.py] \
            [file join $bld rom.bin] --gen $genorig \
            --patch-hart0 --patch-verilog-out $gen} err]} {
        puts "### ERROR: extract_tlrom.py failed: $err"; exit 1
    }
}
puts "### M4: generat (bootrom-patched) = $gen"

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

# --- 2. Our own SystemVerilog building blocks --------------------------------
set funnel [file join $repo_root rtl ct_L1_funnel.sv]
puts "### M4: funnel = $funnel (delta version, MDO_WIDTH=6)"
set common_dir [file join $repo_root examples kv260 common]
set tgc5b_dir  [file join $repo_root examples kv260 common tgc5b rtl]
set rocket1_rtl [file join $repo_root examples kv260 rocket_linux rtl]
set sv_files [list \
    [file join $repo_root rtl adapters rocket rocket_tci_to_ctte_tip.sv] \
    [file join $rocket1_rtl rocket_con_8250.sv] \
    [file join $rocket1_rtl rocket_mem_window.sv] \
    $funnel \
    [file join $rtl rocket2_soc_synth_wrap.sv] \
    [file join $tgc5b_dir ct_axil_to_wb.sv] \
    [file join $common_dir ct_soc_trace_ring.sv] \
    [file join $common_dir ct_soc_ddr_sink.sv] \
    [file join $common_dir ct_soc_pib.sv] \
    [file join $rtl rocket2_soc_top.sv] \
    [file join $script_dir rocket2_kv260_top.sv] \
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
# plusarg_reader.v sits one level ABOVE $ref: it is the FIRRTL blackbox stub,
# shared by both generats, and this tree keeps exactly one copy of it next to
# the one-hart system-nexys-video.v (third_party/ROCKET_PIN.md). $ref points
# into rocket64t2/, which holds only the two-hart generat -- taking the stub
# from there would have died on this loop's own existence check (fixed
# 2026-08-18; ../rocket_linux/fpga/run_rocket_bitstream.tcl:180 always had it
# right, because its $ref is the parent directory).
set rocket_common [file join $repo_root examples kv260 third_party rocket_ref]
foreach f [list $gen [file join $rocket_common plusarg_reader.v]] {
    set f [file normalize $f]
    if {![file exists $f]} { puts "### ERROR missing: $f"; exit 1 }
    add_files -fileset sources_1 -norecurse $f
    set_property file_type Verilog [get_files -of_objects [get_filesets sources_1] $f]
}

set xdc [file normalize [file join $script_dir rocket_pib_pmod.xdc]]
add_files -fileset constrs_1 -norecurse $xdc

# --- 4. PS glue IPs (verbatim as for the one-hart branch, incl. S_AXI_GP3) --
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

set_property verilog_define {SYNTHESIS} [get_filesets sources_1]
puts "### VERILOG_DEFINE: [get_property verilog_define [get_filesets sources_1]]"

set_property top rocket2_kv260_top [current_fileset]
set_property generic "EN_ETRACE=1'b$enet" [get_filesets sources_1]
puts "### GENERIC: [get_property generic [get_filesets sources_1]]"
update_compile_order -fileset sources_1

# --- 5. Synthesis -> implementation -> bitstream -----------------------------
# TCL.PRE hook: a project run executes in its OWN Vivado process, a
# `set_param` here does NOT apply there (rationale in the hook itself).
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
foreach line [split [report_utilization -return_string] "\n"] {
    if {[regexp {^\| CLB +\||CLB LUTs|CLB Registers|Block RAM Tile|URAM |DSPs} $line]} {
        puts "### UTIL $line"
    }
}

# Difference 4: timing is a GATE, not a note.
if {$wns < 0 || $whs < 0} {
    puts "### M4_BIT_FAIL timing violated (WNS $wns / WHS $whs)"
    exit 5
}
puts "### M4_BIT_OK  WNS=$wns  WHS=$whs  -> $bit"
exit 0
