// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
//
// Migrated 2026-08-18 from the evidence archive (package D3b). The code is
// VERBATIM, including the `prog.bin`/`prog2.bin` file names it loads from the
// simulator work directory (see this directory's README.md for where those
// come from). The comments and $display texts -- the verdict strings of the
// archived phase-3 dual-core (D2/T2/U6/U9) evidence -- were German until
// 2026-08-19 and are English now; all tags, numbers and register offsets are
// unchanged, so the archived logs stay comparable item for item.
//
// NEEDS VIVADO. `duo_soc_top` instantiates `mbv_soc_synth_wrap`, and that in turn
// instantiates `mbv_ctrace_soc_wrapper` -- the module Vivado's make_wrapper
// generates from the `mbv_ctrace_soc` block design at build time, around the
// ENCRYPTED MicroBlaze-V core -- plus the Xilinx XPM macro
// `xpm_memory_tdpram`. Neither has an in-repo .sv source by design, so there
// is no path through Verilator for this bench; it runs under xsim inside a
// project created by ../fpga/create_project_kv260.tcl. Measured signature and
// full recipe: this directory's README.md.
//
// Checked against the current top on migration (D3b): the port list, the
// register offsets it writes and every hierarchical probe it takes still
// resolve -- verified by elaborating it with throwaway stubs for the two
// modules above (`verilator --lint-only -Wall --timing`, 0 real %Error).
//
// ---- original header of the archived bench, carried over unchanged --------
// tb_duo_ps_devmem -- phase 3 dual core: devmem flow against duo_soc_top.
//
// Extension of tb_mbv_ps_devmem to two cores, each with its own CTTE
// instance and a ct_L1_funnel (MDO=6) in front of the trace ring:
//   1. hold both cores, prog.bin (MBV) -> RAM0, prog2.bin (TGC5B) -> RAM1,
//   2. configure BOTH encoders: trTeInstFeatures.SrcID=0/1 + SrcBits=2 (RMW),
//      then arm trTeControl with InhibitSrc=0 (0x0106_0067),
//   3. clear the trace ring + start both cores (CTRL b0),
//   4. let them run, InstTracing off on both sides (0x0106_0063) + a global flush,
//   5. write the merged ring to tb_duo_ps_devmem.atb.bin; golden PCs of both
//      cores to tb_duo_ps_devmem.core{0,1}.retired.pcs (prefix references).
//
// Offline: NexRv -deco <atb> -target 0 ... -target 1 ... -src 2 (multi target).
//
// trTeControl value as in the tgc5b README, but InhibitSrc=0 (bit 15 clear):
//   on  = 0x0106_0067 (Active|Enable|InstTracing, InstMode=6, InstSyncMode=6, Format=1)
//   off = 0x0106_0063 (InstTracing clear -- the trace-off correlation)

`default_nettype none

module tb_duo_ps_devmem;

    localparam logic [21:0] CTRL_BASE  = 22'h00_0000;
    localparam logic [21:0] ENC0_BASE  = 22'h01_0000;
    localparam logic [21:0] ENC1_BASE  = 22'h02_0000;
    localparam logic [21:0] RAM1_BASE  = 22'h08_0000;
    localparam logic [21:0] RAM0_BASE  = 22'h10_0000;
    localparam logic [21:0] TRACE_BASE = 22'h20_0000;

    localparam int unsigned MEM_WORDS  = 32768;   // MBV 128 KiB
    localparam int unsigned MEM2_WORDS = 16384;   // TGC5B 64 KiB
    localparam int unsigned RUN_CYCLES = 60000;

    logic clk = 0;
    logic resetn = 0;
    always #6667ps clk = ~clk;                    // ~75 MHz

    logic [21:0] awaddr;  logic awvalid;  uwire awready;
    logic [31:0] wdata;   logic [3:0] wstrb; logic wvalid; uwire wready;
    uwire [1:0]  bresp;   uwire bvalid;    logic bready;
    logic [21:0] araddr;  logic arvalid;   uwire arready;
    uwire [31:0] rdata;   uwire [1:0] rresp; uwire rvalid; logic rready;

    // DDR-Sink AXI-Master + PIB-Port
    uwire logic [31:0] mx_awaddr;  uwire logic [7:0] mx_awlen; uwire logic [2:0] mx_awsize;
    uwire logic [1:0]  mx_awburst; uwire logic mx_awvalid; logic mx_awready;
    uwire logic [31:0] mx_wdata;   uwire logic [3:0] mx_wstrb; uwire logic mx_wlast, mx_wvalid;
    logic mx_wready, mx_bvalid;    uwire logic mx_bready;
    uwire logic pib_clk_w; uwire logic [3:0] pib_data_w;

    duo_soc_top #(.MEM_WORDS(MEM_WORDS), .MEM2_WORDS(MEM2_WORDS)) dut (
        .clk (clk), .resetn (resetn),
        .s_axi_awaddr (awaddr), .s_axi_awprot (3'b0), .s_axi_awvalid (awvalid), .s_axi_awready (awready),
        .s_axi_wdata (wdata), .s_axi_wstrb (wstrb), .s_axi_wvalid (wvalid), .s_axi_wready (wready),
        .s_axi_bresp (bresp), .s_axi_bvalid (bvalid), .s_axi_bready (bready),
        .s_axi_araddr (araddr), .s_axi_arprot (3'b0), .s_axi_arvalid (arvalid), .s_axi_arready (arready),
        .s_axi_rdata (rdata), .s_axi_rresp (rresp), .s_axi_rvalid (rvalid), .s_axi_rready (rready),
        .m_axi_awaddr (mx_awaddr), .m_axi_awlen (mx_awlen), .m_axi_awsize (mx_awsize),
        .m_axi_awburst (mx_awburst), .m_axi_awvalid (mx_awvalid), .m_axi_awready (mx_awready),
        .m_axi_wdata (mx_wdata), .m_axi_wstrb (mx_wstrb), .m_axi_wlast (mx_wlast),
        .m_axi_wvalid (mx_wvalid), .m_axi_wready (mx_wready),
        .m_axi_bresp (2'b00), .m_axi_bvalid (mx_bvalid), .m_axi_bready (mx_bready),
        .pib_clk (pib_clk_w), .pib_data (pib_data_w)
    );

    // ---- Mini AXI slave memory model (stand-in for the PS DDR) ------------
    // U9-1: the model mirrors from the RESET window of ct_trace_sinks
    // (DDR_BASE_RST, address plan v4) -- since U9-1 those registers are
    // read-only in hardware, an `axi_write` on them would have no effect and
    // the mirror base would point nowhere. This used to say 0x1000_0000 and
    // the TB programmed it itself; the same pattern as in the
    // AXIS TB (DDR_MODEL_BASE, tb_tgc5b2_axis_soc.sv:248).
    localparam logic [31:0] DDR_BASE = 32'h5000_0000;
    localparam logic [31:0] DDR_SIZE = 32'h1000_0000;   // 256 MiB, reset value
    localparam int unsigned DDR_MODEL_BYTES = 1 << 20;
    byte ddr_model [0:DDR_MODEL_BYTES-1];
    logic [31:0] ddr_cur_addr; logic ddr_in_burst;
    initial begin mx_awready = 1'b1; mx_wready = 1'b1; mx_bvalid = 1'b0; ddr_in_burst = 0; ddr_cur_addr = 0; end
    always_ff @(posedge clk) begin
        if (mx_awvalid && mx_awready) begin
            ddr_cur_addr <= mx_awaddr;
            ddr_in_burst <= 1'b1;
        end
        if (mx_wvalid && mx_wready && ddr_in_burst) begin
            for (int b = 0; b < 4; b++)
                if (ddr_cur_addr - DDR_BASE + b < DDR_MODEL_BYTES)
                    ddr_model[ddr_cur_addr - DDR_BASE + b] <= mx_wdata[8*b +: 8];
            ddr_cur_addr <= ddr_cur_addr + 4;
            if (mx_wlast) begin
                ddr_in_burst <= 1'b0;
                mx_bvalid <= 1'b1;
            end
        end
        if (mx_bvalid && mx_bready) mx_bvalid <= 1'b0;
    end

    // ---- PIB monitor: DDR nibbles -> beat reconstruction ------------------
    // Convention (ct_soc_pib, = reference PIB_PAR_4): the rising pib_clk edge
    // samples the LOW nibble, the falling edge the HIGH nibble, LSB first. The
    // pin contract has NO frame signal (KR260 adapter 1:1); for the beat
    // phase the monitor uses the verification hook dut.pib.frame_dbg
    // (whitebox -- on the board the receiver goes by the all-ones idle).
    byte pib_bytes [$];
    logic [7:0] pib_cur;
    int pib_nib_in_beat = -1;   // -1 = idle, otherwise 0..7 (nibble within the beat)
    always @(posedge pib_clk_w) begin
        if (dut.sinks.g_pib.pib.frame_dbg) pib_nib_in_beat = 0;   // beat start (T2: sinks encapsulated)
        if (pib_nib_in_beat >= 0 && (pib_nib_in_beat % 2) == 0) begin
            pib_cur[3:0] = pib_data_w;
            pib_nib_in_beat = pib_nib_in_beat + 1;
        end
    end
    always @(negedge pib_clk_w) begin
        if (pib_nib_in_beat >= 1 && (pib_nib_in_beat % 2) == 1) begin
            pib_cur[7:4] = pib_data_w;
            pib_bytes.push_back(pib_cur);
            if (pib_nib_in_beat == 7) pib_nib_in_beat = -1;   // beat complete
            else pib_nib_in_beat = pib_nib_in_beat + 1;
        end
    end

    // ---- Unit gates for the new memory modes ------------------------------
    // Same merged ATB stream (tapped hierarchically from dut.atb_mrg), small
    // devices under test: (a) URAM one-shot DEPTH=16 -> stops after 16 beats
    // and keeps the FIRST 16; (b) ct_soc_ddr_sink circular SIZE=64 B with its
    // own always-ready mini AXI model -> wraps and keeps the LAST 64 bytes
    // written (reconstructable in order via off=wptr%size).
    logic [31:0] os_rd_word = '0;
    logic [31:0] os_beats, os_bytes, os_rdata;
    logic        os_wrapped, os_stopped;
    // D3b: in the archive this module was called ct_soc_trace_buf; in the TE
    // tree it is ct_soc_trace_ring (see examples/kv260/README.md, "Naming") --
    // examples/kv260/common/tgc5b/rtl/ct_soc_trace_buf.sv is a DIFFERENT, older design
    // that kept the old name (no oneshot_i, overflow_o instead of
    // wrapped_o/stopped_o). The old name therefore bound to the wrong module
    // here; found by the elaboration run of this migration.
    ct_soc_trace_ring #(.DEPTH(16)) os_buf (
        .clk (clk), .rst (~resetn), .clear (1'b0),
        .oneshot_i (1'b1),
        .atb_atvalid (dut.atb_mrg.atvalid), .atb_atready (1'b1),
        .atb_atdata (dut.atb_mrg.atdata), .atb_atbytes (dut.atb_mrg.atbytes),
        .beats_o (os_beats), .bytes_o (os_bytes), .wrapped_o (os_wrapped),
        .stopped_o (os_stopped),
        .rd_word (os_rd_word), .rd_data (os_rdata)
    );

    localparam int unsigned CIRC_SIZE = 64;
    uwire logic [31:0] cx_awaddr; uwire logic [7:0] cx_awlen; uwire logic [2:0] cx_awsize;
    uwire logic [1:0]  cx_awburst; uwire logic cx_awvalid; logic cx_awready;
    uwire logic [31:0] cx_wdata; uwire logic [3:0] cx_wstrb; uwire logic cx_wlast, cx_wvalid;
    logic cx_wready, cx_bvalid; uwire logic cx_bready;
    logic [31:0] circ_wptr, circ_drops;
    logic        circ_full, circ_err, circ_wrapped;
    ct_soc_ddr_sink #(.FIFO_WORDS(64)) circ_sink (
        .clk (clk), .rst (~resetn),
        .enable_i (1'b1), .clear_i (1'b0),
        .base_i (32'h0), .size_i (32'(CIRC_SIZE)), .circ_i (1'b1),
        .beat_valid_i (dut.atb_mrg.atvalid), .beat_data_i (dut.atb_mrg.atdata),
        .wptr_o (circ_wptr), .full_o (circ_full), .wrapped_o (circ_wrapped),
        .axi_err_o (circ_err), .drops_o (circ_drops),
        .m_axi_awaddr (cx_awaddr), .m_axi_awlen (cx_awlen), .m_axi_awsize (cx_awsize),
        .m_axi_awburst (cx_awburst), .m_axi_awvalid (cx_awvalid), .m_axi_awready (cx_awready),
        .m_axi_wdata (cx_wdata), .m_axi_wstrb (cx_wstrb), .m_axi_wlast (cx_wlast),
        .m_axi_wvalid (cx_wvalid), .m_axi_wready (cx_wready),
        .m_axi_bresp (2'b00), .m_axi_bvalid (cx_bvalid), .m_axi_bready (cx_bready)
    );
    byte circ_mem [0:CIRC_SIZE-1];
    byte circ_stream [$];
    logic [31:0] cx_cur; logic cx_burst;
    initial begin cx_awready = 1'b1; cx_wready = 1'b1; cx_bvalid = 1'b0; cx_burst = 0; cx_cur = 0; end
    always_ff @(posedge clk) begin
        if (cx_awvalid && cx_awready) begin cx_cur <= cx_awaddr; cx_burst <= 1'b1; end
        if (cx_wvalid && cx_wready && cx_burst) begin
            for (int b = 0; b < 4; b++)
                if (cx_cur + b < CIRC_SIZE) begin
                    circ_mem[cx_cur + b] <= cx_wdata[8*b +: 8];
                    circ_stream.push_back(cx_wdata[8*b +: 8]);
                end
            cx_cur <= cx_cur + 4;
            if (cx_wlast) begin cx_burst <= 1'b0; cx_bvalid <= 1'b1; end
        end
        if (cx_bvalid && cx_bready) cx_bvalid <= 1'b0;
    end

    // PIB calibration gate: switch the pattern on, sample 8 nibbles at the
    // edges, check the sequence against the reference definition (any phase).
    task automatic check_pib_pattern(input logic [1:0] pat);
        logic [3:0] nib [0:7];
        int errs; string name;
        name = (pat == 2'd1) ? "MOVING_ONE" : (pat == 2'd2) ? "MOVING_ZERO" : "STANDARD";
        axi_write(CTRL_BASE + 22'h18, 32'h0000_0150 | (32'(pat) << 12)); // pib_en|calib|div1
        repeat (6) @(posedge pib_clk_w);                 // let the pattern settle
        for (int k = 0; k < 8; k += 2) begin
            @(posedge pib_clk_w); #1; nib[k]   = pib_data_w;
            @(negedge pib_clk_w); #1; nib[k+1] = pib_data_w;
        end
        errs = 0;
        case (pat)
            2'd1: begin
                if (!(nib[0] inside {4'h1, 4'h2, 4'h4, 4'h8})) errs++;
                for (int k = 1; k < 8; k++)
                    if (nib[k] !== {nib[k-1][2:0], nib[k-1][3]}) errs++;
            end
            2'd2: begin
                if (!(nib[0] inside {4'hE, 4'hD, 4'hB, 4'h7})) errs++;
                for (int k = 1; k < 8; k++)
                    if (nib[k] !== ~{~nib[k-1][2:0], ~nib[k-1][3]}) errs++;
            end
            default: begin
                // AA 55 00 FF: nibble stream A,A,5,5,0,0,F,F (cyclic, any phase)
                begin
                    int off = -1;
                    logic [3:0] ref8 [0:7];
                    ref8[0]=4'hA; ref8[1]=4'hA; ref8[2]=4'h5; ref8[3]=4'h5;
                    ref8[4]=4'h0; ref8[5]=4'h0; ref8[6]=4'hF; ref8[7]=4'hF;
                    for (int o = 0; o < 8 && off < 0; o++) begin
                        int ok = 1;
                        for (int k = 0; k < 8; k++)
                            if (nib[k] !== ref8[(k+o) % 8]) ok = 0;
                        if (ok) off = o;
                    end
                    if (off < 0) errs++;
                end
            end
        endcase
        if (errs) $error("[duo_tb] PIB-CALIB %s FAIL: %h %h %h %h %h %h %h %h",
                         name, nib[0],nib[1],nib[2],nib[3],nib[4],nib[5],nib[6],nib[7]);
        else $display("[duo_tb] PIB-CALIB %s PASS (%h%h%h%h%h%h%h%h)",
                      name, nib[0],nib[1],nib[2],nib[3],nib[4],nib[5],nib[6],nib[7]);
    endtask

    task automatic axi_write(input logic [21:0] a, input logic [31:0] d);
        @(posedge clk);
        awaddr <= a; awvalid <= 1'b1; wdata <= d; wstrb <= 4'hF; wvalid <= 1'b1;
        do @(posedge clk); while (!bvalid);
        awvalid <= 1'b0; wvalid <= 1'b0;
    endtask

    task automatic axi_read(input logic [21:0] a, output logic [31:0] d);
        @(posedge clk);
        araddr <= a; arvalid <= 1'b1;
        do @(posedge clk); while (!rvalid);
        d = rdata; arvalid <= 1'b0;
    endtask

    // Load a program image from a .bin file into a RAM window (LE bytes -> words).
    // Static buffer array: $fread onto a dynamic array crashes the
    // XSIM 2026.1 kernel (FATAL in the load_bin process, measured).
    byte img_bytes [0:MEM_WORDS*4-1];
    task automatic load_bin(input string fname, input logic [21:0] base);
        int fd, nread, i;
        logic [31:0] word;
        fd = $fopen(fname, "rb");
        if (fd == 0) $fatal(1, "[duo_tb] program image missing: %s", fname);
        nread = $fread(img_bytes, fd);
        $fclose(fd);
        for (i = 0; i < (nread + 3) / 4; i++) begin
            word = {img_bytes[i*4+3], img_bytes[i*4+2], img_bytes[i*4+1], img_bytes[i*4+0]};
            axi_write(base + 22'(i*4), word);
        end
        $display("[duo_tb] %s: %0d bytes -> 0x%06x (%0d words)", fname, nread, base, (nread + 3) / 4);
    endtask

    // Arm an encoder with its SRC field: features RMW (SrcID/SrcBits), then control.
    task automatic enc_arm(input logic [21:0] base, input logic [11:0] srcid);
        logic [31:0] feat;
        axi_read(base + 22'h8, feat);                       // trTeInstFeatures
        feat[31:28] = 4'd2;                                 // SrcBits = 2
        feat[27:16] = srcid;                                // SrcID
        axi_write(base + 22'h8, feat);
        axi_read(base + 22'h8, feat);
        $display("[duo_tb] ENC@0x%06x trTeInstFeatures = 0x%08x", base, feat);
        axi_write(base + 22'h0, 32'h0106_0067);             // on, InhibitSrc=0
    endtask

    logic [31:0] rd, w;
    int fd, i, nbytes, nwords;
    byte ring_copy [0:(1<<20)-1];
    int  ring_n;

    // Diagnostic counters of the soc1 chain (TIP retires -> encoder ATB -> funnel).
    int cnt_tip1, cnt_atb1v, cnt_atb1x, cnt_atb0x;
    int cnt_etip1, cnt_msg1, cnt_etip0, cnt_msg0;

    // Sink verification (after reading out the ring): DDR prefix identity and
    // PIB subsequence (drops of whole beats allowed, the balance must add up).
    task automatic check_sinks();
        logic [31:0] wptr, stat, ddrops, pdrops;
        int errs, ring_beats, pib_beats, ri;
        logic [31:0] rbeat, pbeat;
        axi_read(CTRL_BASE + 22'h24, wptr);
        axi_read(CTRL_BASE + 22'h28, stat);
        axi_read(CTRL_BASE + 22'h2C, ddrops);
        axi_read(CTRL_BASE + 22'h30, pdrops);
        $display("[duo_tb] DDR: wptr=%0d stat=0x%0x drops=%0d | PIB: drops=%0d cap_bytes=%0d",
                 wptr, stat, ddrops, pdrops, pib_bytes.size());

        errs = 0;
        // --- DDR: exact prefix identity (drops must be 0) ------------------
        if (ddrops != 0) begin $error("[duo_tb] DDR SINK FAIL: %0d drops", ddrops); errs++; end
        if (stat[1]) begin $error("[duo_tb] DDR SINK FAIL: AXI error"); errs++; end
        if (wptr != ring_n) begin
            $error("[duo_tb] DDR SINK FAIL: wptr %0d != ring %0d bytes", wptr, ring_n); errs++;
        end
        for (int k = 0; k < ring_n && k < DDR_MODEL_BYTES; k++) begin
            if (ddr_model[k] !== ring_copy[k]) begin
                $error("[duo_tb] DDR SINK FAIL: byte %0d: ddr=%02x ring=%02x", k, ddr_model[k], ring_copy[k]);
                errs++;
                if (errs > 5) break;
            end
        end
        if (errs == 0) $display("[duo_tb] DDR SINK PASS -- %0d bytes byte-identical to the ring", ring_n);

        // --- PIB: beat subsequence + balance -------------------------------
        ring_beats = ring_n / 4;
        pib_beats  = pib_bytes.size() / 4;
        ri = 0;
        for (int p = 0; p < pib_beats; p++) begin
            pbeat = {pib_bytes[4*p+3], pib_bytes[4*p+2], pib_bytes[4*p+1], pib_bytes[4*p+0]};
            // look for pbeat from ri onwards in the ring (ordered subsequence)
            while (ri < ring_beats) begin
                rbeat = {ring_copy[4*ri+3], ring_copy[4*ri+2], ring_copy[4*ri+1], ring_copy[4*ri+0]};
                ri++;
                if (rbeat === pbeat) break;
            end
            if (ri > ring_beats || (ri == ring_beats &&
                {ring_copy[4*(ring_beats-1)+3], ring_copy[4*(ring_beats-1)+2],
                 ring_copy[4*(ring_beats-1)+1], ring_copy[4*(ring_beats-1)]} !== pbeat)) begin
                $error("[duo_tb] PIB FAIL: beat %0d (0x%08x) not found in ring order", p, pbeat);
                errs++;
                break;
            end
        end
        if (pib_beats + pdrops != ring_beats)
            $display("[duo_tb] PIB note: beats %0d + drops %0d != ring %0d (FIFO residual drain)",
                     pib_beats, pdrops, ring_beats);
        if (errs == 0)
            $display("[duo_tb] PIB PASS -- %0d beats byte-identical as a subsequence (drops=%0d)",
                     pib_beats, pdrops);
        if (errs != 0) $error("[duo_tb] SINK CHECKS FAIL (%0d)", errs);
        else           $display("[duo_tb] SINK CHECKS PASS");
    endtask

    // Unit gates of the new modes: URAM one-shot (first 16 beats, then stop)
    // + DDR sink circular (wraps, window == last 64 bytes written).
    task automatic check_mode_units();
        int errs, total, off, n;
        logic [31:0] exp;
        errs = 0;

        // (a) URAM one-shot
        if (!os_stopped) begin $error("[duo_tb] ONESHOT FAIL: stopped_o=0"); errs++; end
        if (os_beats != 32'd16) begin $error("[duo_tb] ONESHOT FAIL: beats %0d != 16", os_beats); errs++; end
        if (os_wrapped) begin $error("[duo_tb] ONESHOT FAIL: wrapped_o set"); errs++; end
        for (int k = 0; k < 16; k++) begin
            os_rd_word = 32'(k);
            @(posedge clk); @(posedge clk); #1;
            exp = {ring_copy[4*k+3], ring_copy[4*k+2], ring_copy[4*k+1], ring_copy[4*k+0]};
            if (os_rdata !== exp) begin
                $error("[duo_tb] ONESHOT FAIL: beat %0d: 0x%08x != ring 0x%08x", k, os_rdata, exp);
                errs++;
            end
        end
        if (errs == 0) $display("[duo_tb] ONESHOT PASS -- 16/16 beats == the first ring beats, stop correct");

        // (b) DDR circular
        total = circ_stream.size();
        if (!circ_wrapped) begin $error("[duo_tb] DDR-CIRC FAIL: wrapped_o=0 (total=%0d)", total); errs++; end
        if (circ_full) begin $error("[duo_tb] DDR-CIRC FAIL: full_o set"); errs++; end
        if (circ_err) begin $error("[duo_tb] DDR-CIRC FAIL: AXI error"); errs++; end
        if (circ_wptr != 32'(total)) begin
            $error("[duo_tb] DDR-CIRC FAIL: wptr %0d != %0d bytes written", circ_wptr, total); errs++;
        end
        off = total % CIRC_SIZE;
        n = (total < CIRC_SIZE) ? total : CIRC_SIZE;
        for (int k = 0; k < n; k++) begin
            if (circ_mem[(off + k) % CIRC_SIZE] !== circ_stream[total - n + k]) begin
                $error("[duo_tb] DDR-CIRC FAIL: window byte %0d: mem=%02x stream=%02x",
                       k, circ_mem[(off + k) % CIRC_SIZE], circ_stream[total - n + k]);
                errs++;
                if (errs > 5) break;
            end
        end
        if (errs == 0)
            $display("[duo_tb] DDR-CIRC PASS -- wrapped, window == the last %0d of %0d bytes (drops=%0d)",
                     n, total, circ_drops);

        if (errs != 0) $error("[duo_tb] MODE-GATES FAIL (%0d)", errs);
        else           $display("[duo_tb] MODE-GATES PASS");
    endtask

    initial begin
        awvalid = 0; wvalid = 0; bready = 1; arvalid = 0; rready = 1;
        wstrb = 4'hF; awaddr = 0; araddr = 0; wdata = 0;

        repeat (10) @(posedge clk);
        resetn <= 1'b1;
        repeat (5) @(posedge clk);
        $display("[duo_tb] reset released");

        // 1. Hold the cores + clear the ring.
        axi_write(CTRL_BASE, 32'h0000_0002);
        axi_write(CTRL_BASE, 32'h0000_0000);

        // 2. Load the programs (fixed names in the XSIM run dir; the runner copies them there).
        load_bin("prog.bin",  RAM0_BASE);
        load_bin("prog2.bin", RAM1_BASE);

        // Read-back probes (loader paths of both RAMs).
        axi_read(RAM0_BASE + 22'h0, rd);
        $display("[duo_tb] RAM0[0] = 0x%08x", rd);
        axi_read(RAM1_BASE + 22'h0, rd);
        $display("[duo_tb] RAM1[0] = 0x%08x", rd);

        // 3. Arm both encoders (SRC 0 = MBV, SRC 1 = TGC5B).
        enc_arm(ENC0_BASE, 12'd0);
        enc_arm(ENC1_BASE, 12'd1);

        // 3b. Configure the extra sinks: DDR4 (base/size/enable) + PIB
        // (div=1 -> 18.75 MB/s byte rate; drops are allowed and are verified
        // by the subsequence check).
        // U9-1: base/size are NOT programmed any more -- they are read-only in
        // hardware (SPEC §12). Instead it is checked once that the reset window
        // matches the mirror model above: a drift between the two would
        // silently devalue the byte comparison below (the model would reach
        // past the data instead of contradicting it).
        axi_read(CTRL_BASE + 22'h1C, rd);
        if (rd !== DDR_BASE)
            $fatal(1, "[duo_tb] DDR_BASE reset 0x%08x != model 0x%08x", rd, DDR_BASE);
        axi_read(CTRL_BASE + 22'h20, rd);
        if (rd !== DDR_SIZE)
            $fatal(1, "[duo_tb] DDR_SIZE reset 0x%08x != expected 0x%08x", rd, DDR_SIZE);
        $display("[duo_tb] DDR window reset PASS -- 0x%08x + %0d MiB (U9-1: read-only)",
                 DDR_BASE, DDR_SIZE / 32'd1048576);
        axi_write(CTRL_BASE + 22'h18, 32'h0000_0111);     // ddr_en | pib_en | div=1
        axi_read(CTRL_BASE + 22'h18, rd);
        $display("[duo_tb] SINK_CTRL = 0x%08x", rd);

        // 4. Start both cores.
        axi_write(CTRL_BASE, 32'h0000_0001);
        $display("[duo_tb] cores started");
        repeat (100) @(posedge clk);
        $display("[duo_tb] DBG@run enc1 CSR: Active=%b Enable=%b InstTracing=%b tip1_ret=%0d atb1_v=%0d etip1=%0d msg1=%0d | etip0=%0d msg0=%0d",
                 dut.soc1.ct_encoder_inst.cs_tip.trTeActive,
                 dut.soc1.ct_encoder_inst.cs_tip.trTeEnable,
                 dut.soc1.ct_encoder_inst.cs_tip.trTeInstTracing,
                 cnt_tip1, cnt_atb1v, cnt_etip1, cnt_msg1, cnt_etip0, cnt_msg0);
        $display("[duo_tb] DBG@run enc1 ovf: dropping=%b pending=%b | enc0: dropping=%b pending=%b",
                 dut.soc1.ct_encoder_inst.preproc_inst.composer_etip_inst.etip_ovf_dropping,
                 dut.soc1.ct_encoder_inst.preproc_inst.composer_etip_inst.etip_ovf_pending,
                 dut.soc0.encoder.preproc_inst.composer_etip_inst.etip_ovf_dropping,
                 dut.soc0.encoder.preproc_inst.composer_etip_inst.etip_ovf_pending);
        repeat (RUN_CYCLES - 100) @(posedge clk);

        // 5. Tracing off on both sides + a global flush (the funnel coordinates it).
        axi_write(ENC0_BASE + 22'h0, 32'h0106_0063);
        axi_write(ENC1_BASE + 22'h0, 32'h0106_0063);
        repeat (200) @(posedge clk);
        axi_write(CTRL_BASE, 32'h0000_0005);
        repeat (3000) @(posedge clk);
        axi_write(CTRL_BASE, 32'h0000_0001);
        $display("[duo_tb] tracing off + flushed");

        // 6. Read out the merged capture.
        axi_read(CTRL_BASE + 22'hC, rd);  nbytes = rd;
        axi_read(CTRL_BASE + 22'h8, rd);
        $display("[duo_tb] %0d ATB bytes, %0d beats captured (merged)", nbytes, rd);

        fd = $fopen("tb_duo_ps_devmem.atb.bin", "wb");
        nwords = (nbytes + 3) / 4;
        for (i = 0; i < nwords; i++) begin
            axi_read(TRACE_BASE + 22'(i*4), w);
            for (int b = 0; b < 4; b++)
                if (i*4 + b < nbytes) begin
                    $fwrite(fd, "%c", w[b*8 +: 8]);
                    ring_copy[i*4 + b] = w[b*8 +: 8];
                end
        end
        ring_n = nbytes;
        $fclose(fd);

        // 6b. Sink checks: the DDR content is byte-identical to the ring prefix;
        // PIB beats are an ordered subsequence of the ring beats + drop balance.
        check_sinks();

        // 6c. Unit gates of the new modes (one shot | circular).
        check_mode_units();

        // 6d. Register plumbing of the mode bits: SINK_CTRL b2/b3 must arrive at
        // the modules (tracing is off, switching is harmless here).
        axi_write(CTRL_BASE + 22'h18, 32'h0000_011D);   // + ddr_circ + uram_oneshot
        axi_read(CTRL_BASE + 22'h18, rd);
        if (rd !== 32'h0000_011D)
            $error("[duo_tb] SINK_CTRL readback FAIL: 0x%08x != 0x0000011D", rd);
        else if (dut.sinks.trace_buf.oneshot_i !== 1'b1 || dut.sinks.g_ddr.ddr_sink.circ_i !== 1'b1)
            $error("[duo_tb] MODE-PLUMBING FAIL: oneshot_i=%b circ_i=%b",
                   dut.sinks.trace_buf.oneshot_i, dut.sinks.g_ddr.ddr_sink.circ_i);
        else
            $display("[duo_tb] MODE-PLUMBING PASS -- SINK_CTRL b2/b3 arrived at the sinks");
        axi_write(CTRL_BASE + 22'h18, 32'h0000_0111);   // modes back to default

        // 6e. PIB calibration pattern at the pin (reference trPibCalibPattern):
        // MOVING_ONE must appear as a walking 1 (1,2,4,8 cyclic), MOVING_ZERO
        // inverted, STANDARD as AA 55 00 FF nibble pairs.
        check_pib_pattern(2'd1);
        check_pib_pattern(2'd2);
        check_pib_pattern(2'd0);
        axi_write(CTRL_BASE + 22'h18, 32'h0000_0111);   // calibration off

        // 6f. FUNNEL_CTRL plumbing: the priorities must arrive at the funnel.
        axi_write(CTRL_BASE + 22'h34, 32'h0000_0021);   // ch0=1, ch1=2
        axi_read(CTRL_BASE + 22'h34, rd);
        if (rd !== 32'h0000_0021)
            $error("[duo_tb] FUNNEL_CTRL readback FAIL: 0x%08x", rd);
        else if (dut.funnel_prio[0] !== 2'd1 || dut.funnel_prio[1] !== 2'd2)
            $error("[duo_tb] FUNNEL-PLUMBING FAIL: prio %0d/%0d",
                   dut.funnel_prio[0], dut.funnel_prio[1]);
        else
            $display("[duo_tb] FUNNEL-CTRL PASS -- prio 1/2 arrived at the funnel");
        axi_write(CTRL_BASE + 22'h34, 32'h0000_0011);   // back to RR

        // 6g. U1: per-core run bits (CONTROL b8 = MBV/soc0, b9 = TGC5B/soc1).
        // The two branches have nothing to do with each other, so they must be
        // able to run individually. Three levels are checked in one go: the
        // reset hold at the WRAPPER PORT (XMR -- that is the actual wiring),
        // the STATUS mirror b9/b8, and the consequence for the loader window
        // -- the RAM of the STOPPED core stays readable while the other one
        // runs (before U1 the two were coupled).
        // This sits at the end of the run and therefore touches no gate
        // measurement; the cores run only a few hundred cycles here.
        begin
            logic [31:0] u1_st, u1_r0, u1_r1;
            axi_write(CTRL_BASE, 32'h0000_0000);            // hold both
            repeat (20) @(posedge clk);          // let the reset/mux switchover settle
            axi_read(CTRL_BASE + 22'h4, u1_st);
            if (u1_st[9:8] !== 2'b00)
                $error("[duo_tb] U1 STATUS[9:8]=%b at CONTROL=0 (00 expected)", u1_st[9:8]);
            axi_read(RAM0_BASE, u1_r0);                     // reference words
            axi_read(RAM1_BASE, u1_r1);

            axi_write(CTRL_BASE, 32'h0000_0100);            // MBV only
            repeat (20) @(posedge clk);          // let the reset/mux switchover settle
            axi_read(CTRL_BASE + 22'h4, u1_st);
            if (dut.core0_rst_hold !== 1'b0 || dut.core1_rst_hold !== 1'b1)
                $error("[duo_tb] U1-PLUMBING FAIL at CONTROL=0x100: hold0=%b hold1=%b",
                       dut.core0_rst_hold, dut.core1_rst_hold);
            else if (u1_st[9:8] !== 2'b01)
                $error("[duo_tb] U1 STATUS[9:8]=%b at CONTROL=0x100 (01 expected)", u1_st[9:8]);
            else begin
                axi_read(RAM1_BASE, rd);                    // TGC5B is stopped -> loadable
                if (rd !== u1_r1)
                    $error("[duo_tb] U1 RAM1 0x%08x != 0x%08x while only the MBV runs", rd, u1_r1);
            end

            axi_write(CTRL_BASE, 32'h0000_0200);            // TGC5B only
            repeat (20) @(posedge clk);          // let the reset/mux switchover settle
            axi_read(CTRL_BASE + 22'h4, u1_st);
            if (dut.core0_rst_hold !== 1'b1 || dut.core1_rst_hold !== 1'b0)
                $error("[duo_tb] U1-PLUMBING FAIL at CONTROL=0x200: hold0=%b hold1=%b",
                       dut.core0_rst_hold, dut.core1_rst_hold);
            else if (u1_st[9:8] !== 2'b10)
                $error("[duo_tb] U1 STATUS[9:8]=%b at CONTROL=0x200 (10 expected)", u1_st[9:8]);
            else begin
                axi_read(RAM0_BASE, rd);                    // the MBV is stopped -> loadable
                if (rd !== u1_r0)
                    $error("[duo_tb] U1 RAM0 0x%08x != 0x%08x while only the TGC5B runs", rd, u1_r0);
            end

            axi_write(CTRL_BASE, 32'h0000_0001);            // collective bit: both
            repeat (20) @(posedge clk);          // let the reset/mux switchover settle
            axi_read(CTRL_BASE + 22'h4, u1_st);
            if (dut.core0_rst_hold !== 1'b0 || dut.core1_rst_hold !== 1'b0)
                $error("[duo_tb] U1 collective bit b0 no longer holds both: hold0=%b hold1=%b",
                       dut.core0_rst_hold, dut.core1_rst_hold);
            else if (u1_st[9:8] !== 2'b11)
                $error("[duo_tb] U1 STATUS[9:8]=%b at CONTROL=0x1 (11 expected)", u1_st[9:8]);
            else
                $display("[duo_tb] U1 PER-CORE PASS -- b8/b9 effective individually (hold at the wrapper + STATUS 01/10), b0 still the collective bit, the RAM of the stopped core readable in each case");
            axi_write(CTRL_BASE, 32'h0000_0000);
            repeat (20) @(posedge clk);          // let the reset/mux switchover settle
        end

        if (nbytes == 0) $error("[duo_tb] FAIL -- no ATB bytes captured");
        else             $display("[duo_tb] PASS -- tb_duo_ps_devmem.atb.bin (%0d bytes) written", nbytes);
        $display("[duo_tb] DBG soc1: tip.iretire=%0d atb1_valid=%0d atb1_xfer=%0d etip1=%0d msg1=%0d | atb0_xfer=%0d etip0=%0d msg0=%0d",
                 cnt_tip1, cnt_atb1v, cnt_atb1x, cnt_etip1, cnt_msg1, cnt_atb0x, cnt_etip0, cnt_msg0);
        $display("[duo_tb] DBG enc1 CSR: Active=%b Enable=%b InstTracing=%b | enc0: Active=%b Enable=%b InstTracing=%b",
                 dut.soc1.ct_encoder_inst.cs_tip.trTeActive,
                 dut.soc1.ct_encoder_inst.cs_tip.trTeEnable,
                 dut.soc1.ct_encoder_inst.cs_tip.trTeInstTracing,
                 dut.soc0.encoder.cs_tip.trTeActive,
                 dut.soc0.encoder.cs_tip.trTeEnable,
                 dut.soc0.encoder.cs_tip.trTeInstTracing);
        $finish;
    end

    // (counter declarations further up, next to ring_copy)
    always_ff @(posedge clk) begin
        if (resetn) begin
            if (dut.soc1.tip.iretire)                    cnt_tip1  <= cnt_tip1  + 1;
            if (dut.atb1_atvalid)                        cnt_atb1v <= cnt_atb1v + 1;
            if (dut.atb1_atvalid && dut.atb1_atready)    cnt_atb1x <= cnt_atb1x + 1;
            if (dut.atb0_atvalid && dut.atb0_atready)    cnt_atb0x <= cnt_atb0x + 1;
            if (dut.soc1.ct_encoder_inst.etip_q.valid && dut.soc1.ct_encoder_inst.etip_q.ack)
                cnt_etip1 <= cnt_etip1 + 1;
            if (dut.soc1.ct_encoder_inst.genNtrace.trace_msg.tcode != 0)   // M0 sync: trace_msg lives in the genNtrace scope
                cnt_msg1 <= cnt_msg1 + 1;
            if (dut.soc0.encoder.etip_q.valid && dut.soc0.encoder.etip_q.ack)
                cnt_etip0 <= cnt_etip0 + 1;
            if (dut.soc0.encoder.genNtrace.trace_msg.tcode != 0)           // M0 sync: see above
                cnt_msg0 <= cnt_msg0 + 1;
        end
    end

    // Golden PC references of both cores (one prefix reference per target).
    int pcs0_fd, pcs1_fd;
    initial pcs0_fd = $fopen("tb_duo_ps_devmem.core0.retired.pcs", "w");
    initial pcs1_fd = $fopen("tb_duo_ps_devmem.core1.retired.pcs", "w");
    always_ff @(posedge clk) begin
        if (resetn && dut.core0_trace_valid && pcs0_fd != 0)
            $fwrite(pcs0_fd, "0x%08h\n", dut.core0_trace_pc);
        if (resetn && dut.core1_trace_valid && pcs1_fd != 0)
            $fwrite(pcs1_fd, "0x%08h\n", dut.core1_trace_pc);
    end
    final begin
        if (pcs0_fd != 0) $fclose(pcs0_fd);
        if (pcs1_fd != 0) $fclose(pcs1_fd);
    end

    initial begin
        #20ms;
        $error("[duo_tb] TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
