# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# create_project_kv260.tcl -- KV260 app project (stage 1/2). Entry point.
#
# Usage:
#   vivado -mode batch -source examples/kv260/mbv/fpga/create_project_kv260.tcl          # project + elab check
#   MBV_KV260_SYNTH=1 vivado -mode batch -source .../create_project_kv260.tcl            # + full synth/impl/bitstream
#
# Layout: xck26 project + CTTE encoder (file list from the .abc graph, via
# abc_filelist.py) + adapter RTL + the mbv-specific SoC RTL (../rtl/) + the
# common/tgc5b-shared sink RTL (ct_trace_sinks and its three sinks since D2)
# + this example's PIB pin constraints + the `mbv_ctrace_soc` block design in
# MBV_KV260=1 mode (BRAM ports at the edge, 75 MHz) + the 4 standalone
# PS-glue IPs (gen_ip.tcl, reused verbatim from the tgc5b KV260 flow -- its
# own $abc::proj_dir is served here via a namespace shim).
#
# The default run ends with `synth_design -rtl -top mbv_soc_top` as an
# elaboration gate: this checks every new RTL building block + the
# block-design wrapper port names (ilmb_bram_*/dlmb_bram_*), WITHOUT having
# to wait for the PS IP generation.
#
# Migrated from an internal predecessor repository
# (2026-08-17). Path handling was adapted for
# the new location: `repo_root` now resolves to this repository's root (the
# CTTE encoder sources needed here are `rtl/ct_encoder.abc` at that same
# root -- the predecessor repository used a vendored copy that no longer
# applies once the flow lives inside the encoder's own repository), and the
# board RTL that used to sit together in `rtl/board_kv260/` is now split
# across its post-AP4.0-migration homes: the mbv-only SoC RTL in `../rtl/`,
# and the shared sink RTL in `examples/kv260/common/` (`ct_soc_trace_ring`,
# renamed from `ct_soc_trace_buf` on migration, decision A-04) and
# `examples/kv260/common/tgc5b/rtl/` (`ct_axil_to_wb`, `ct_soc_axis_buf` -- measured
# functionally identical to the former board copies and therefore not
# duplicated here). The stays-TCL-for-now flow
# otherwise runs unchanged; the abc-flow conversion is a later, separate step
# with its own board gate.

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir .. .. .. ..]]
set proj_name  mbv_kv260
set proj_dir   [file join $script_dir proj]
# Project directory overridable via env, so a measurement build does not throw
# away an existing proj/ tree (reference bitstream!).
if {[info exists ::env(MBV_PROJ_DIR)] && $::env(MBV_PROJ_DIR) ne ""} {
    set proj_dir [file join $script_dir $::env(MBV_PROJ_DIR)]
}
set part       xck26-sfvc784-2LV-c

file delete -force $proj_dir
create_project $proj_name $proj_dir -part $part
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property xpm_libraries {XPM_MEMORY XPM_CDC XPM_FIFO} [current_project]

# --- CTTE encoder sources (pinned, UNCHANGED -- AD-01) in compile order ---
# Encoder source overridable via env -- a measurement build must build from a
# FROZEN CTTE worktree (RTL state pinnable to a commit, while the working
# branch moves in parallel). The gold-standard encoder (the frozen
# reference line, e.g. 444467c) has NO atb_te_raw port and no EN_ETRACE/EN_NTRACE
# instance parameters (both vendored-only, trio dual-protocol) -- the override
# therefore sets the MBV_CT_ENC_GOLD define for mbv_soc_synth_wrap. Without
# MBV_CTTE_DIR the flow builds from this same repository's own rtl/.
if {[info exists ::env(MBV_CTTE_DIR)] && $::env(MBV_CTTE_DIR) ne ""} {
    set ctte [file normalize $::env(MBV_CTTE_DIR)]
    set_property verilog_define {MBV_CT_ENC_GOLD=1} [current_fileset]
    puts "### CTTE-OVERRIDE: $ctte (MBV_CT_ENC_GOLD set)"
} else {
    set ctte $repo_root
}
set filelist_tool [file join $script_dir abc_filelist.py]
if {[catch {set ct_files [exec py $filelist_tool [file join $ctte rtl ct_encoder.abc] --quiet]} err]} {
    puts "### ERROR: abc_filelist.py failed: $err"
    exit 1
}
set ct_files [split [string trim $ct_files] "\n"]
puts "### CTTE sources resolved from .abc: [llength $ct_files]"

# --- Adapter RTL (order: pkg -> if -> modules) ---
set adapter_dir [file join $repo_root rtl adapters amd_microblaze_v]
set our_files [list \
    [file join $adapter_dir mbv_trace_pkg.sv] \
    [file join $adapter_dir mbv_trace_if.sv] \
    [file join $adapter_dir mbv_riscv_itype_decoder.sv] \
    [file join $adapter_dir mbv_trap_mapper.sv] \
    [file join $adapter_dir mbv_to_ctte_tip.sv] \
]

# --- Board RTL + bitstream top. The sink RTL is the shared three-sink
# subsystem ct_trace_sinks (URAM ring + DDR4 sink + PIB) since D2; before
# that mbv instantiated ct_soc_trace_ring alone and needed neither
# ct_soc_ddr_sink nor ct_soc_pib. ---
set common_dir [file join $repo_root examples kv260 common]
set tgc5b_dir  [file join $repo_root examples kv260 common tgc5b rtl]
set mbv_rtl_dir [file join $script_dir .. rtl]
set board_files [list \
    [file join $tgc5b_dir ct_axil_to_wb.sv] \
    [file join $common_dir ct_soc_trace_ring.sv] \
    [file join $common_dir ct_soc_ddr_sink.sv] \
    [file join $common_dir ct_soc_pib.sv] \
    [file join $common_dir ct_trace_sinks.sv] \
    [file join $tgc5b_dir ct_soc_axis_buf.sv] \
    [file join $mbv_rtl_dir mbv_soc_synth_wrap.sv] \
    [file join $mbv_rtl_dir mbv_soc_top.sv] \
    [file join $script_dir mbv_kv260_top.sv] \
]

foreach f [concat $ct_files $our_files $board_files] {
    set f [file normalize $f]
    if {![file exists $f]} { puts "### WARN missing: $f"; continue }
    add_files -fileset sources_1 -norecurse $f
    set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1] $f]
}

# --- Constraints (PIB pinout; D2 -- the three-sink subsystem brought the
# parallel trace port out to PMOD J2, same pin contract as duo/trio) ---
set xdc [file normalize [file join $script_dir mbv_pib_pmod.xdc]]
add_files -fileset constrs_1 -norecurse $xdc

# --- Block design in KV260 mode (BRAM external, 75 MHz) ---
set ::env(MBV_KV260) 1
source [file join $script_dir create_bd.tcl]

set bd_file [get_files *mbv_ctrace_soc.bd]
make_wrapper -files $bd_file -top
set wrapper [file join $proj_dir ${proj_name}.gen sources_1 bd mbv_ctrace_soc hdl mbv_ctrace_soc_wrapper.v]
if {![file exists $wrapper]} {
    set wrapper [lindex [glob -nocomplain [file join $proj_dir *.gen sources_1 bd mbv_ctrace_soc hdl *wrapper.v]] 0]
}
add_files -norecurse $wrapper
puts "### WRAPPER: $wrapper"

# Print the wrapper's BRAM/TRACE port names (verification point).
set wf [open $wrapper r]; set wtxt [read $wf]; close $wf
foreach line [split $wtxt "\n"] {
    if {[regexp {^\s*(input|output)\s.*(bram|TRACE_0_pc|Interrupt)} $line]} { puts "### PORT: [string trim $line]" }
}

# --- PS-glue IPs (verbatim gen_ip.tcl; abc namespace shim) ---
namespace eval abc { variable proj_dir }
set abc::proj_dir $proj_dir
source [file join $script_dir gen_ip.tcl]

set_property top mbv_kv260_top [current_fileset]
update_compile_order -fileset sources_1

# Synthesize the block design globally (no OOC-per-IP checkpoint) -- otherwise
# the elaboration is missing the generated IP submodules (mbv_ctrace_soc_dlmb_0 ...).
set_property synth_checkpoint_mode None $bd_file
generate_target all $bd_file

# --- Elaboration gate: mbv_soc_top (without the PS IPs) ---
puts "### ELAB-CHECK: synth_design -rtl -top mbv_soc_top"
if {[catch {synth_design -rtl -top mbv_soc_top -mode out_of_context} elab_err]} {
    puts "### ELAB_FAIL: $elab_err"
    exit 2
}
puts "### ELAB_OK (mbv_soc_top elaborated)"
close_design
# synth_design -rtl -top switches the fileset top -- restore it to the
# bitstream top for the runs (otherwise synth_1 would implement mbv_soc_top
# with bare I/O ports -> DRC NSTD-1/UCIO-1).
set_property top mbv_kv260_top [current_fileset]
update_compile_order -fileset sources_1

if {[info exists ::env(MBV_KV260_SYNTH)] && $::env(MBV_KV260_SYNTH) eq "1"} {
    puts "### SYNTH: full flow (synth_1 -> impl_1 -> bitstream)"
    # Generate ONLY the 4 standalone PS-glue IPs -- block-design-internal IPs
    # (mbv_ctrace_soc_*) are generated exclusively by the block design itself
    # (Vivado 12-3563).
    generate_target all [get_ips ct_soc_kv260_*]
    launch_runs synth_1 -jobs 8
    wait_on_run synth_1
    if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { puts "### SYNTH_FAIL"; exit 3 }
    launch_runs impl_1 -to_step write_bitstream -jobs 8
    wait_on_run impl_1
    if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { puts "### IMPL_FAIL"; exit 4 }
    # Timing proof (WNS >= 0 must be documented).
    open_run impl_1
    set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    puts "### WNS: $wns"
    puts "### BITSTREAM_OK: [glob -nocomplain [file join $proj_dir ${proj_name}.runs impl_1 *.bit]]"
}

puts "### PROJECT READY: $proj_dir  TOP: [get_property top [current_fileset]]"
