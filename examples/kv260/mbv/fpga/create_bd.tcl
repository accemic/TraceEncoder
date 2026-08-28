# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Minimal MicroBlaze-V SoC block design. EXPLICIT construction throughout.
# Sourced by create_project_kv260.tcl (open project context). Every IP VLNV,
# interface and pin name was verified empirically (Vivado 2026.1, introspection
# 2026-07-15). No apply_bd_automation -- the RISC-V rule needs version-specific
# config values; an explicit build is reproducible and the clean basis for the
# later adapter/CTTE integration.
#
# Baseline configuration: RV32 - C extension OFF - M extension ON - MMU OFF -
# trace bus ON - native N-Trace OFF.
# Topology: mbv + ILMB/DLMB (lmb_v10) + 2x lmb_bram_if_cntlr + 1x true-dual-port
#           BRAM (128 KiB @ 0x0) + proc_sys_reset + mdm_riscv. Trace bus brought
#           outward (ILA/sim). clk/reset external (sim-friendly).
#
# Migrated from an internal predecessor repository
# (2026-08-17). Still an active build dependency of
# create_project_kv260.tcl -- NOT the superseded standalone G0 project that used
# to live alongside it (vivado/microblaze_v_ctrace_demo/create_project.tcl, which
# stayed behind in the predecessor repository).

set bd_name mbv_ctrace_soc
create_bd_design $bd_name

# C extension: baseline default OFF. Only switchable to 1 for the RVC-raw-encoding
# measurement via env: MBV_USE_COMPRESSION=1.
set mbv_rvc 0
if {[info exists ::env(MBV_USE_COMPRESSION)]} { set mbv_rvc $::env(MBV_USE_COMPRESSION) }
puts "### C_USE_COMPRESSION = $mbv_rvc  (baseline default 0)"

# Native N-Trace encoder (for the two-encoder cross-validation). Baseline default
# OFF -- the core gate sequence runs unchanged against the plain TRACE bus. Via env
# MBV_NATIVE_TRACE=1, additionally instantiate AMD's own native N-Trace encoder with
# an EXTERNAL sink: a 36-bit valid/ready trace port then appears at the IP edge
# (Dbg_Trace_Clk/Data[0:35]/Valid/Ready; verified by introspection 2026-07-17,
# Vivado 2026.1). C_TRACE stays on -> both encoders coexist on the same core.
set mbv_native 0
if {[info exists ::env(MBV_NATIVE_TRACE)]} { set mbv_native $::env(MBV_NATIVE_TRACE) }
puts "### MBV_NATIVE_TRACE = $mbv_native  (0 = TRACE bus/CTTE only; 1 = + native AMD encoder)"

# KV260 app mode: BRAM moves out of the block design into the SV wrapper
# (mbv_soc_synth_wrap) -- port A stays ILMB, port B gets a DLMB<->PS-loader mux
# there (load the program while the core is held; tgc5b semantics). Both LMB
# BRAM-controller BRAM ports go to the block-design edge; clk port constraint
# 75 MHz (= the KV260 app's PS pl_clk0, instead of the 100 MHz sim default).
set mbv_kv260 0
if {[info exists ::env(MBV_KV260)]} { set mbv_kv260 $::env(MBV_KV260) }
puts "### MBV_KV260 = $mbv_kv260  (1 = BRAM external + BRAM ports at the edge, 75 MHz)"

# ---------------------------------------------------------------- MicroBlaze V
set mbv [create_bd_cell -type ip -vlnv xilinx.com:ip:microblaze_riscv:1.0 mbv]
set_property -dict [list \
    CONFIG.C_TRACE {1} \
    CONFIG.C_DEBUG_TRACE_SIZE {0} \
    CONFIG.C_DEBUG_EXTERNAL_TRACE {0} \
    CONFIG.C_USE_COMPRESSION $mbv_rvc \
    CONFIG.C_USE_MMU {0} \
    CONFIG.C_USE_MULDIV {1} \
    CONFIG.C_USE_BARREL {1} \
    CONFIG.C_ADDR_SIZE {32} \
    CONFIG.C_DATA_SIZE {32} \
    CONFIG.C_BASE_VECTORS {0x0000000000000000} \
    CONFIG.C_I_LMB {1} \
    CONFIG.C_D_LMB {1} \
    CONFIG.C_USE_ICACHE {0} \
    CONFIG.C_USE_DCACHE {0} \
    CONFIG.C_DEBUG_ENABLED {1} \
    CONFIG.C_USE_INTERRUPT {1} \
    CONFIG.C_INTERRUPT_IS_EDGE {1} \
] $mbv

# Native encoder: enable the external trace sink (brings Dbg_Trace_* to the IP
# edge) AND the S_AXI slave interface used to address the N-Trace registers.
#   - C_DEBUG_EXTERNAL_TRACE=1: Dbg_Trace_* at the edge (36-bit valid/ready
#     stream). Streaming instead of on-chip RAM -- we tap it in the TB, not via
#     MDM out of a RAM.
#   - C_S_AXI=1: AXI4-Lite slave "to access core trace and profiling registers"
#     (UG1629 p. 100). This is what the TB writes `trTeControl` (@0x2000) through
#     and arms the encoder -- the reason the encoder emits 0 beats without
#     programming (verified: probe 2026-07-17). S_AXI: 14-bit address, 32-bit
#     data, NO WSTRB; runs in the clk domain (no separate ACLK).
if {$mbv_native == 1} {
    set_property -dict [list CONFIG.C_DEBUG_EXTERNAL_TRACE {1} CONFIG.C_S_AXI {1}] $mbv
    puts "### NATIVE N-TRACE active: C_DEBUG_EXTERNAL_TRACE=1 + C_S_AXI=1 (register access)"
}

# ---------------------------------------------------------------- LMB buses
set ilmb [create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_v10:* ilmb]
set dlmb [create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_v10:* dlmb]

# ---------------------------------------------------------------- LMB BRAM controllers
set ilmb_c [create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_bram_if_cntlr:* ilmb_cntlr]
set dlmb_c [create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_bram_if_cntlr:* dlmb_cntlr]
set_property CONFIG.C_ECC {0} $ilmb_c
set_property CONFIG.C_ECC {0} $dlmb_c

# ---------------------------------------------------------------- Shared true-dual-port BRAM
# Stand-alone (not BRAM-controller-auto), so the COE sim-init stays available (in
# controller mode Load_Init_File is disabled). Byte write-enable (4b WE) + EN/RST
# pins matching the LMB controller.
if {$mbv_kv260 == 0} {
set bram [create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:* lmb_bram]
set_property -dict [list \
    CONFIG.Memory_Type {True_Dual_Port_RAM} \
    CONFIG.use_bram_block {Stand_Alone} \
    CONFIG.Enable_32bit_Address {true} \
    CONFIG.Use_Byte_Write_Enable {true} \
    CONFIG.Byte_Size {8} \
    CONFIG.Write_Width_A {32} \
    CONFIG.Write_Depth_A {32768} \
    CONFIG.Read_Width_A {32} \
    CONFIG.Write_Width_B {32} \
    CONFIG.Read_Width_B {32} \
    CONFIG.Enable_A {Use_ENA_Pin} \
    CONFIG.Enable_B {Use_ENB_Pin} \
    CONFIG.Use_RSTA_Pin {true} \
    CONFIG.Use_RSTB_Pin {true} \
    CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
    CONFIG.Register_PortB_Output_of_Memory_Primitives {false} \
    CONFIG.Fill_Remaining_Memory_Locations {true} \
    CONFIG.Remaining_Memory_Locations {0} \
] $bram
# Program preload via COE (sim). Coe_File + Load_Init_File must be set together.
if {[info exists ::MBV_INIT_COE] && [file exists $::MBV_INIT_COE]} {
    set_property -dict [list CONFIG.Coe_File $::MBV_INIT_COE CONFIG.Load_Init_File {true}] $bram
    puts "### BRAM_INIT_COE: $::MBV_INIT_COE"
} else {
    puts "### WARN: no COE loaded (MBV_INIT_COE missing) -- BRAM stays 0"
}
}

# ---------------------------------------------------------------- Reset + MDM
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:* rstgen]
set_property CONFIG.C_EXT_RESET_HIGH {1} $rst
set mdm [create_bd_cell -type ip -vlnv xilinx.com:ip:mdm_riscv:* mdm]

# ---------------------------------------------------------------- external clk/reset ports
set clk_freq 100000000
if {$mbv_kv260 == 1} { set clk_freq 75000000 }
set clk_port   [create_bd_port -dir I -type clk -freq_hz $clk_freq clk]
set reset_port [create_bd_port -dir I -type rst reset]
set_property CONFIG.POLARITY ACTIVE_HIGH [get_bd_ports reset]

# ---------------------------------------------------------------- interface connections
connect_bd_intf_net [get_bd_intf_pins mbv/ILMB]        [get_bd_intf_pins ilmb/LMB_M]
connect_bd_intf_net [get_bd_intf_pins mbv/DLMB]        [get_bd_intf_pins dlmb/LMB_M]
connect_bd_intf_net [get_bd_intf_pins ilmb/LMB_Sl_0]   [get_bd_intf_pins ilmb_cntlr/SLMB]
connect_bd_intf_net [get_bd_intf_pins dlmb/LMB_Sl_0]   [get_bd_intf_pins dlmb_cntlr/SLMB]
if {$mbv_kv260 == 0} {
    connect_bd_intf_net [get_bd_intf_pins ilmb_cntlr/BRAM_PORT] [get_bd_intf_pins lmb_bram/BRAM_PORTA]
    connect_bd_intf_net [get_bd_intf_pins dlmb_cntlr/BRAM_PORT] [get_bd_intf_pins lmb_bram/BRAM_PORTB]
} else {
    # KV260: the BRAM lives in the SV wrapper -- both controller BRAM ports go to
    # the edge, with fixed names (wrapper signals ilmb_bram_*/dlmb_bram_*).
    # make_bd_intf_pins_external returns no object -- grab the freshly created
    # default port (BRAM_PORT*) by pattern and rename it, one at a time so the
    # pattern only ever hits the new one.
    make_bd_intf_pins_external [get_bd_intf_pins ilmb_cntlr/BRAM_PORT]
    set_property NAME ilmb_bram [get_bd_intf_ports -filter {NAME =~ "BRAM_PORT*"}]
    make_bd_intf_pins_external [get_bd_intf_pins dlmb_cntlr/BRAM_PORT]
    set_property NAME dlmb_bram [get_bd_intf_ports -filter {NAME =~ "BRAM_PORT*"}]
    puts "### MBV_KV260: BRAM ports ilmb_bram/dlmb_bram at the edge (BRAM lives in the SV wrapper)"
}
connect_bd_intf_net [get_bd_intf_pins mbv/DEBUG]       [get_bd_intf_pins mdm/MBDEBUG_0]

# ---------------------------------------------------------------- clock net
set clk_pins [list mbv/Clk ilmb/LMB_Clk dlmb/LMB_Clk ilmb_cntlr/LMB_Clk dlmb_cntlr/LMB_Clk rstgen/slowest_sync_clk]
foreach p $clk_pins { connect_bd_net [get_bd_ports clk] [get_bd_pins $p] }

# ---------------------------------------------------------------- reset nets
connect_bd_net [get_bd_ports reset] [get_bd_pins rstgen/ext_reset_in]
connect_bd_net [get_bd_pins mdm/Debug_SYS_Rst] [get_bd_pins rstgen/mb_debug_sys_rst]
connect_bd_net [get_bd_pins rstgen/mb_reset]   [get_bd_pins mbv/Reset]
set bus_rst_pins [list ilmb/SYS_Rst dlmb/SYS_Rst ilmb_cntlr/LMB_Rst dlmb_cntlr/LMB_Rst]
foreach p $bus_rst_pins { connect_bd_net [get_bd_pins rstgen/bus_struct_reset] [get_bd_pins $p] }

# ---------------------------------------------------------------- trace bus outward (ILA/sim)
if {[catch { make_bd_intf_pins_external [get_bd_intf_pins mbv/TRACE] } e]} { puts "### TRACE_EXT note: $e" }

# ---------------------------------------------------------------- interrupt input outward
# Characterization: an external machine interrupt (edge), pulsed from the
# testbench (no INTC IP needed).
if {[catch { make_bd_pins_external [get_bd_pins mbv/Interrupt] } e]} { puts "### INTR_EXT note: $e" }

# ------------------------------------------------------- native trace port outward (sim tap)
# Explicit ports (instead of make_bd_pins_external) for predictable wrapper names:
# the dual-encoder env taps dbg_trace_data[0:35]/valid and drives clk/ready.
# Big-endian [0:35] like the TRACE bus.
if {$mbv_native == 1} {
    set pt_clk   [create_bd_port -dir I dbg_trace_clk]
    set pt_rdy   [create_bd_port -dir I dbg_trace_ready]
    set pt_data  [create_bd_port -dir O -from 0 -to 35 dbg_trace_data]
    set pt_valid [create_bd_port -dir O dbg_trace_valid]
    connect_bd_net $pt_clk   [get_bd_pins mbv/Dbg_Trace_Clk]
    connect_bd_net $pt_rdy   [get_bd_pins mbv/Dbg_Trace_Ready]
    connect_bd_net $pt_data  [get_bd_pins mbv/Dbg_Trace_Data]
    connect_bd_net $pt_valid [get_bd_pins mbv/Dbg_Trace_Valid]
    puts "### NATIVE N-TRACE: dbg_trace_clk/ready/data\[0:35\]/valid at the edge"

    # S_AXI (register access) explicit at the edge -- predictable wrapper names saxi_*.
    # AXI4-Lite: 14-bit address, 32-bit data, NO WSTRB (full 32-bit write). clk domain.
    set a_awaddr  [create_bd_port -dir I -from 13 -to 0 saxi_awaddr]
    set a_awvalid [create_bd_port -dir I saxi_awvalid]
    set a_awready [create_bd_port -dir O saxi_awready]
    set a_wdata   [create_bd_port -dir I -from 31 -to 0 saxi_wdata]
    set a_wvalid  [create_bd_port -dir I saxi_wvalid]
    set a_wready  [create_bd_port -dir O saxi_wready]
    set a_bresp   [create_bd_port -dir O -from 1 -to 0 saxi_bresp]
    set a_bvalid  [create_bd_port -dir O saxi_bvalid]
    set a_bready  [create_bd_port -dir I saxi_bready]
    set a_araddr  [create_bd_port -dir I -from 13 -to 0 saxi_araddr]
    set a_arvalid [create_bd_port -dir I saxi_arvalid]
    set a_arready [create_bd_port -dir O saxi_arready]
    set a_rdata   [create_bd_port -dir O -from 31 -to 0 saxi_rdata]
    set a_rresp   [create_bd_port -dir O -from 1 -to 0 saxi_rresp]
    set a_rvalid  [create_bd_port -dir O saxi_rvalid]
    set a_rready  [create_bd_port -dir I saxi_rready]
    connect_bd_net $a_awaddr  [get_bd_pins mbv/S_AXI_AWADDR]
    connect_bd_net $a_awvalid [get_bd_pins mbv/S_AXI_AWVALID]
    connect_bd_net $a_awready [get_bd_pins mbv/S_AXI_AWREADY]
    connect_bd_net $a_wdata   [get_bd_pins mbv/S_AXI_WDATA]
    connect_bd_net $a_wvalid  [get_bd_pins mbv/S_AXI_WVALID]
    connect_bd_net $a_wready  [get_bd_pins mbv/S_AXI_WREADY]
    connect_bd_net $a_bresp   [get_bd_pins mbv/S_AXI_BRESP]
    connect_bd_net $a_bvalid  [get_bd_pins mbv/S_AXI_BVALID]
    connect_bd_net $a_bready  [get_bd_pins mbv/S_AXI_BREADY]
    connect_bd_net $a_araddr  [get_bd_pins mbv/S_AXI_ARADDR]
    connect_bd_net $a_arvalid [get_bd_pins mbv/S_AXI_ARVALID]
    connect_bd_net $a_arready [get_bd_pins mbv/S_AXI_ARREADY]
    connect_bd_net $a_rdata   [get_bd_pins mbv/S_AXI_RDATA]
    connect_bd_net $a_rresp   [get_bd_pins mbv/S_AXI_RRESP]
    connect_bd_net $a_rvalid  [get_bd_pins mbv/S_AXI_RVALID]
    connect_bd_net $a_rready  [get_bd_pins mbv/S_AXI_RREADY]
    puts "### NATIVE N-TRACE: saxi_* (AXI4-Lite register access) at the edge"
}

# ---------------------------------------------------------------- address space (BRAM 128KB @ 0x0)
assign_bd_address -offset 0x00000000 -range 128K [get_bd_addr_segs {ilmb_cntlr/SLMB/Mem}]
assign_bd_address -offset 0x00000000 -range 128K [get_bd_addr_segs {dlmb_cntlr/SLMB/Mem}]

regenerate_bd_layout
save_bd_design

puts "### ADDRESS SEGMENTS:"
catch { foreach s [get_bd_addr_segs -quiet] { puts "  $s : [get_property -quiet OFFSET [get_bd_addr_segs $s]] +[get_property -quiet RANGE [get_bd_addr_segs $s]]" } }
puts "### BD CELLS:"
foreach c [get_bd_cells] { puts "  $c : [get_property VLNV [get_bd_cells $c]]" }
puts "### EXTERNAL PORTS:"
foreach p [get_bd_ports] { puts "  $p [get_property DIR [get_bd_ports $p]]" }
puts "### VALIDATE:"
if {[catch {validate_bd_design} verr]} { puts "### VALIDATE_ERROR: $verr" } else { puts "### VALIDATE_OK" }
save_bd_design
