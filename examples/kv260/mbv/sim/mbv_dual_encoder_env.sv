// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
//
// Migrated 2026-08-18 from the evidence archive
// (package D3b). Body verbatim apart from the SPDX line (this repository
// runs fsfe/reuse-action and licenses under CERN-OHL-S-2.0 OR the commercial
// option) and this note; the original German comments -- the verdict strings
// the archived G0/G1/G4/G5 evidence quotes -- were translated to English for
// publication.
//
// NEEDS VIVADO. This bench instantiates
// `mbv_ctrace_soc_wrapper` -- the module Vivado's make_wrapper generates from
// the `mbv_ctrace_soc` block design at build time, around the ENCRYPTED
// MicroBlaze-V core. It has no in-repo .sv source by design, so there is no
// path through Verilator for this bench: it runs under xsim, inside a project created
// by ../fpga/create_project_kv260.tcl. Recipe and the measured failure signature:
// this directory's README.md.
//
//
// mbv_dual_encoder_env -- two-encoder cross-validation on ONE real MicroBlaze-V core.
//
// The same program run, two independent N-Trace encoders:
//
//   mbv_ctrace_soc_wrapper (MBV with MBV_NATIVE_TRACE=1)
//     |                                        |
//     | AMD TRACE bus                          | Dbg_Trace_Data[0:35] (AMD's NATIVE encoder)
//     v                                        v
//   mbv_to_ctte_tip (adapter)          amd_native_trace_dump
//     | tip                                    -> <name>.native.trace.hex   [branch A]
//     v                                           (un-framer -> NexRv -> PC seq A)
//   ct_encoder (CTTE)
//     | atb -> atb_dump -> <name>.atb.bin  [branch B]  (NexRv -> PC seq B)
//
// Comparison (logical, not byte-identical): PC seq A <-> PC seq B <-> object-dump oracle
// (tools/compare_dual_encoder.py). The CTTE branch is the verified G4/G5 chain; the
// AMD branch complements it.
//
// >>> KNOWN BLOCKER: AMD's native encoder only emits after runtime programming of its
//     N-Trace registers (probe tb_mbv_native_probe: 0 beats without enable). The enable path goes
//     through S_AXI_DEBUG (debug register block), whose register map (UG1629/UG1580) is not
//     available here. Until then <name>.native.trace.hex stays empty -- the CTTE branch runs
//     to completion INDEPENDENTLY of that. Details: doc/microblaze_v_native_trace_port.md.
`timescale 1ns/1ps
`default_nettype none

module mbv_dual_encoder_env #(
    parameter string ATB_DUMP_PATH    = "mbv_dual.atb.bin",      // branch B (CTTE)
    parameter string NATIVE_DUMP_PATH = "mbv_dual.native.hex",   // branch A (AMD native)
    parameter string RETIRED_PCS_PATH = "",                      // oracle reference (retiring PCs)
    parameter bit    RESET_ACTIVE     = 1'b1
) ();

    // ------------------------------------------------------------------ Clocks
    logic clk       = 1'b0;
    logic atb_atclk = 1'b0;
    logic proc_clk  = 1'b0;
    logic wb_clk    = 1'b0;
    logic wall_clk  = 1'b0;
    initial forever #5ns clk       = ~clk;        // 100 MHz SoC/tip
    initial forever #2ns atb_atclk = ~atb_atclk;  // 250 MHz
    initial forever #2ns proc_clk  = ~proc_clk;   // 250 MHz
    initial forever #5ns wb_clk    = ~wb_clk;
    initial forever #5ns wall_clk  = ~wall_clk;

    // AMD trace output clock (its own domain; coupled to the core clock for the sim).
    logic dbg_trace_clk = 1'b0;
    initial forever #5ns dbg_trace_clk = ~clk;

    // ------------------------------------------------------------------ Resets
    logic soc_reset    = RESET_ACTIVE;
    logic tip_rst      = 1'b1;
    logic atb_atresetn = 1'b0;
    logic proc_rst     = 1'b1;
    logic wb_rst       = 1'b1;
    logic ct_cs_rst    = 1'b1;
    logic wall_clk_rst = 1'b1;
    logic reset_released = 1'b0;

    initial begin
        #200ns;
        @(posedge clk);       tip_rst        <= 1'b0;
        @(posedge atb_atclk); atb_atresetn   <= 1'b1;
        @(posedge proc_clk);  proc_rst       <= 1'b0;
        @(posedge wb_clk);    wb_rst         <= 1'b0;
        @(posedge wb_clk);    ct_cs_rst      <= 1'b0;
        @(posedge wall_clk);  wall_clk_rst   <= 1'b0;
        @(posedge clk);       reset_released <= 1'b1;
    end

    task automatic wait_for_reset_release();
        wait (reset_released == 1'b1);
        @(posedge clk);
    endtask
    task automatic release_core();
        @(posedge clk);
        soc_reset <= ~RESET_ACTIVE;
        @(posedge clk);
    endtask
    task automatic wait_cycles(input int n);
        repeat (n) @(posedge clk);
    endtask

    // Interrupt stimulus (as in mbv_ctte_env)
    logic Interrupt_0 = 1'b0;
    logic irq_enable  = 1'b0;
    int unsigned irq_cyc = 0;
    localparam int IRQ_FIRST  = 60;
    localparam int IRQ_PERIOD = 37;
    always_ff @(posedge clk) begin
        if (soc_reset == RESET_ACTIVE) begin
            irq_cyc <= 0; Interrupt_0 <= 1'b0;
        end else begin
            irq_cyc <= irq_cyc + 1;
            if (irq_enable && irq_cyc >= IRQ_FIRST) begin
                if      (((irq_cyc - IRQ_FIRST) % IRQ_PERIOD) == 0) Interrupt_0 <= 1'b1;
                else if (((irq_cyc - IRQ_FIRST) % IRQ_PERIOD) == 3) Interrupt_0 <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------ SoC (native-trace variant)
    wire        TRACE_0_valid_instr, TRACE_0_jump_taken, TRACE_0_exception_taken;
    wire        TRACE_0_of_piperun, TRACE_0_ex_piperun, TRACE_0_mem_piperun, TRACE_0_mb_halted;
    wire [0:31] TRACE_0_pc, TRACE_0_instruction, TRACE_0_new_reg_value;
    wire [0:5]  TRACE_0_exception_kind;
    wire        TRACE_0_data_access, TRACE_0_data_read, TRACE_0_data_write, TRACE_0_reg_write;
    wire [0:31] TRACE_0_data_address, TRACE_0_data_write_value;
    wire [0:3]  TRACE_0_data_byte_enable;
    wire [0:4]  TRACE_0_reg_addr;

    // AMD's native trace port
    logic        dbg_trace_ready = 1'b1;   // sink always ready (no backpressure test)
    wire [0:35]  dbg_trace_data;
    wire         dbg_trace_valid;

    // S_AXI (register access to the native encoder). Master = this env.
    logic [13:0] saxi_awaddr = '0;  logic saxi_awvalid = 1'b0;  wire saxi_awready;
    logic [31:0] saxi_wdata  = '0;  logic saxi_wvalid  = 1'b0;  wire saxi_wready;
    wire  [1:0]  saxi_bresp;        wire saxi_bvalid;           logic saxi_bready  = 1'b0;
    logic [13:0] saxi_araddr = '0;  logic saxi_arvalid = 1'b0;  wire saxi_arready;
    wire  [31:0] saxi_rdata;        wire [1:0] saxi_rresp;      wire saxi_rvalid; logic saxi_rready = 1'b0;

    mbv_ctrace_soc_wrapper soc (
        .clk(clk), .reset(soc_reset), .Interrupt_0(Interrupt_0),
        .TRACE_0_pc(TRACE_0_pc), .TRACE_0_instruction(TRACE_0_instruction),
        .TRACE_0_valid_instr(TRACE_0_valid_instr), .TRACE_0_jump_taken(TRACE_0_jump_taken),
        .TRACE_0_exception_taken(TRACE_0_exception_taken), .TRACE_0_exception_kind(TRACE_0_exception_kind),
        .TRACE_0_of_piperun(TRACE_0_of_piperun), .TRACE_0_ex_piperun(TRACE_0_ex_piperun),
        .TRACE_0_mem_piperun(TRACE_0_mem_piperun), .TRACE_0_mb_halted(TRACE_0_mb_halted),
        .TRACE_0_data_access(TRACE_0_data_access), .TRACE_0_data_address(TRACE_0_data_address),
        .TRACE_0_data_read(TRACE_0_data_read), .TRACE_0_data_write(TRACE_0_data_write),
        .TRACE_0_data_write_value(TRACE_0_data_write_value), .TRACE_0_data_byte_enable(TRACE_0_data_byte_enable),
        .TRACE_0_reg_write(TRACE_0_reg_write), .TRACE_0_reg_addr(TRACE_0_reg_addr),
        .TRACE_0_new_reg_value(TRACE_0_new_reg_value),
        // AMD's native encoder (external sink)
        .dbg_trace_clk(dbg_trace_clk), .dbg_trace_ready(dbg_trace_ready),
        .dbg_trace_data(dbg_trace_data), .dbg_trace_valid(dbg_trace_valid),
        // S_AXI (register access)
        .saxi_awaddr(saxi_awaddr), .saxi_awvalid(saxi_awvalid), .saxi_awready(saxi_awready),
        .saxi_wdata(saxi_wdata), .saxi_wvalid(saxi_wvalid), .saxi_wready(saxi_wready),
        .saxi_bresp(saxi_bresp), .saxi_bvalid(saxi_bvalid), .saxi_bready(saxi_bready),
        .saxi_araddr(saxi_araddr), .saxi_arvalid(saxi_arvalid), .saxi_arready(saxi_arready),
        .saxi_rdata(saxi_rdata), .saxi_rresp(saxi_rresp), .saxi_rvalid(saxi_rvalid), .saxi_rready(saxi_rready)
    );

    // ------------------------------------------------------------------ Arming the AMD encoder
    // Register map from UG1629 (tables 35/36), accessed via the core's own S_AXI (UG1629 p.100).
    //   trTeControl @0x2000: Active(0)|Enable(1)|InstTracing(2)|InstMode6:4 (3=BTM)  -> 0x37
    //   trTsControl  @0x2040 = 0: timestamps OFF (otherwise TSTAMP corrupts the ICNT field -> NexRv
    //                             "ICNT too small"). Empirically confirmed.
    // IMPORTANT: S_AXI responds ONLY while the core is RUNNING (not in reset) -> call after
    // release_core(). The native branch therefore starts ~10 instructions later than CTTE; the
    // three-way comparison anchors both independently against the oracle.
    localparam logic [13:0] TRTE_CONTROL = 14'h2000;
    localparam logic [13:0] TRTS_CONTROL = 14'h2040;

    task automatic saxi_write(input logic [13:0] addr, input logic [31:0] data);
        int guard; bit aw, w;
        aw = 0; w = 0;
        @(posedge clk);
        saxi_awaddr <= addr; saxi_awvalid <= 1'b1;
        saxi_wdata  <= data; saxi_wvalid  <= 1'b1; saxi_bready <= 1'b1;
        guard = 0;
        while (!(aw && w)) begin
            @(posedge clk);
            if (saxi_awready) begin saxi_awvalid <= 1'b0; aw = 1; end
            if (saxi_wready)  begin saxi_wvalid  <= 1'b0; w  = 1; end
            if (++guard > 300) begin saxi_awvalid <= 1'b0; saxi_wvalid <= 1'b0; break; end
        end
        guard = 0;
        while (!saxi_bvalid) begin @(posedge clk); if (++guard > 300) break; end
        @(posedge clk); saxi_bready <= 1'b0;
    endtask

    task automatic arm_native_trace();
        saxi_write(TRTS_CONTROL, 32'h0000_0000);   // timestamps off
        saxi_write(TRTE_CONTROL, 32'h0000_0001);   // trTeActive
        saxi_write(TRTE_CONTROL, 32'h0000_0037);   // Active|Enable|InstTracing|BTM
    endtask

    task automatic flush_native_trace();
        saxi_write(TRTE_CONTROL, 32'h0000_0063);   // InstTracing=0 -> Encoder flusht
    endtask

    // ------------------------------------------------------------------ Zweig A: AMD nativ -> Capture
    amd_native_trace_dump #(.FILEPATH(NATIVE_DUMP_PATH)) amd_recorder (
        .dbg_trace_clk   (dbg_trace_clk),
        .dbg_trace_rst_n (~tip_rst),
        .dbg_trace_valid (dbg_trace_valid),
        .dbg_trace_ready (dbg_trace_ready),
        .dbg_trace_data  (dbg_trace_data)
    );
    int unsigned native_beats = 0;
    always_ff @(posedge dbg_trace_clk) begin
        if (!tip_rst && dbg_trace_valid && dbg_trace_ready) native_beats <= native_beats + 1;
    end

    // ------------------------------------------------------------------ Zweig B: TRACE -> CTTE -> ATB
    mbv_trace_if mbv ();
    assign mbv.trace_pc              = TRACE_0_pc;
    assign mbv.trace_instruction     = TRACE_0_instruction;
    assign mbv.trace_valid_instr     = TRACE_0_valid_instr;
    assign mbv.trace_jump_taken      = TRACE_0_jump_taken;
    assign mbv.trace_exception_taken = TRACE_0_exception_taken;
    assign mbv.trace_exception_kind  = TRACE_0_exception_kind;
    assign mbv.trace_of_piperun      = TRACE_0_of_piperun;
    assign mbv.trace_ex_piperun      = TRACE_0_ex_piperun;
    assign mbv.trace_mem_piperun     = TRACE_0_mem_piperun;
    assign mbv.trace_halted          = TRACE_0_mb_halted;
    assign mbv.trace_data_access     = TRACE_0_data_access;
    assign mbv.trace_data_address    = TRACE_0_data_address;
    assign mbv.trace_data_read       = TRACE_0_data_read;
    assign mbv.trace_data_write      = TRACE_0_data_write;
    assign mbv.trace_data_write_value= TRACE_0_data_write_value;
    assign mbv.trace_data_byte_enable= TRACE_0_data_byte_enable;
    assign mbv.trace_reg_write       = TRACE_0_reg_write;
    assign mbv.trace_reg_addr        = TRACE_0_reg_addr;
    assign mbv.trace_new_reg_value   = TRACE_0_new_reg_value;

    tip_if tip ();
    // sijump via plusarg (+MBV_SIJUMP): the adapter classifies auipc/lui+jalr
    // pairs as inferable -> msg_gen folds them. Decode then needs the
    // -sijump PCInfo (NexRv -conv -objd ... -sijump).
    logic sijump_en;
    initial sijump_en = $test$plusargs("MBV_SIJUMP") ? 1'b1 : 1'b0;
    mbv_to_ctte_tip adapter (.clk(clk), .rst(tip_rst), .sijump_en(sijump_en), .mbv(mbv.sink), .tip(tip.master));

    localparam int WB_DATA_WIDTH = 32;
    localparam int WB_ADDR_WIDTH = 32;
    wb_if #(.DATA_WIDTH(WB_DATA_WIDTH), .ADDR_WIDTH(WB_ADDR_WIDTH)) wb ();
    axis_if axis (.aclk(wb_clk), .aresetn(~wb_rst));
    atb_if  atb ();

    // CORE_XLEN(32): MicroBlaze V is an RV32 hart; the synced encoder (its
    // elaboration guard) requires the explicit setting. This run's tree is the
    // pinned third_party/CTTE (CT_XLEN = 32).
    ct_encoder #(.SPLIT_DATA_ACCESS(0), .CORE_XLEN(32)) encoder (
        .tip_clk(clk), .tip_rst(tip_rst), .tip(tip.slave),
        .wb_clk, .wb_rst, .wb, .ct_cs_rst,
        .axis,
        .atb_atclk, .atb_atresetn, .atb(atb),
        .proc_clk, .proc_rst,
        .wall_clk, .wall_clk_rst
    );

    ct_cs_cpuif_wb_helper csr (.clk(wb_clk), .wb(wb.master));

    logic atb_force_flush = 1'b0;
    logic atb_force_sync  = 1'b0;
    assign atb.atready = 1'b1;
    assign atb.afready = 1'b1;
    assign atb.afvalid = atb_force_flush;
    assign atb.syncreq = atb_force_sync;
    assign axis.tready = 1'b1;

    atb_dump #(.FILEPATH(ATB_DUMP_PATH)) atb_recorder (
        .atb_atclk, .atb_atresetn, .atb(atb.monitor)
    );

    int unsigned atb_beat_count = 0;
    always_ff @(posedge atb_atclk) begin
        if (!atb_atresetn) atb_beat_count <= 0;
        else if (atb.atvalid && atb.atready) atb_beat_count <= atb_beat_count + 1;
    end

    int unsigned tip_retire_count = 0;
    always_ff @(posedge clk) begin
        if (tip_rst) tip_retire_count <= 0;
        else if (tip.iretire) tip_retire_count <= tip_retire_count + 1;
    end

    // ------------------------------------------------------------------ Oracle reference (retiring PCs)
    // Identical to mbv_ctte_env: retiring PCs + the faulting instruction (EXCEPTION_TRAP), NOT the
    // one preempted by an interrupt. This list is encoder-INDEPENDENT and serves as the referee.
    int unsigned pcs_fd = 0;
    initial begin
        if (RETIRED_PCS_PATH != "") begin
            pcs_fd = $fopen(RETIRED_PCS_PATH, "w");
            if (pcs_fd == 0) $fatal(1, "mbv_dual_encoder_env: cannot write %s", RETIRED_PCS_PATH);
        end
    end
    // Ground truth = the instructions RETIRING at TIP (iretire=1). The trapped, non-retiring
    // instruction (iretire=0, EXCEPTION_TRAP) does NOT belong in it -- this is the spec-backed
    // iretire rule and makes the oracle match AMD 1:1 (and the fixed CTTE encoder).
    always_ff @(posedge clk) begin
        if (!tip_rst && pcs_fd != 0 && tip.iretire)
            $fwrite(pcs_fd, "0x%08h\n", tip.iaddr);
    end
    final begin
        if (pcs_fd != 0) $fclose(pcs_fd);
    end

endmodule : mbv_dual_encoder_env

`default_nettype wire
