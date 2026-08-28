// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
//
// Migrated 2026-08-18 from the evidence archive
// (package D3b). Body verbatim; only
// this header was added.
//
// SCOPE NOTE: D3b was scoped to sim/amd_microblaze_v and the three
// *_ps_devmem benches. This file came with tb_trio_ps_devmem, which
// instantiates it as the CVA6 memory model -- without it that bench is
// incomplete (verilator: "Cannot find file containing module:
// axi_ram_sim"). It lives in common/sim rather than trio/sim because it is
// core-generic: any future cva6_linux/cva6_2 simulation leg needs the same
// model. The rest of the archive's sim/cva6/ group was NOT migrated.
//
/*
 * axi_ram_sim -- simple AXI4 slave for the CVA6 sim (gate C1/C3).
 *
 * 64-bit data path, INCR bursts of arbitrary length, 1 outstanding read/write each
 * (enough for the cv32a60x: WT-I$/HPDCACHE-WT with sequential refills). RAM is
 * a 64-bit word array, loaded via $readmemh (+HEX=..., 16 hex characters/line,
 * little-endian word; tools/cva6_hex64.py generates this from objcopy -O binary).
 *
 * Address window == board window (SPEC_board_memory_map): RAM @BASE (default
 * 0x6400_0000, CVA6 code window). Accesses above the RAM (BASE+RAM_BYTES..)
 * are testbench MMIO:
 *   +0x00  EXIT    write != 0 ends the sim (exit code = wdata, 1 = PASS)
 *   +0x08  IRQTRIG write: level for time_irq_o (b0), wired by the TB to the core
 * AMOs/atops are not supported (assertion) -- test programs do not use any.
 */
`timescale 1ns/1ps

module axi_ram_sim #(
    parameter longint unsigned BASE      = 64'h6400_0000,
    parameter int unsigned     RAM_BYTES = 4*1024*1024,
    parameter int unsigned     ID_WIDTH  = 4
) (
    input  logic clk_i,
    input  logic rst_ni,

    input  logic [ID_WIDTH-1:0] awid,
    input  logic [63:0]         awaddr,
    input  logic [7:0]          awlen,
    input  logic [2:0]          awsize,
    input  logic [1:0]          awburst,
    input  logic [5:0]          awatop,
    input  logic                awvalid,
    output logic                awready,
    input  logic [63:0]         wdata,
    input  logic [7:0]          wstrb,
    input  logic                wlast,
    input  logic                wvalid,
    output logic                wready,
    output logic [ID_WIDTH-1:0] bid,
    output logic [1:0]          bresp,
    output logic                bvalid,
    input  logic                bready,
    input  logic [ID_WIDTH-1:0] arid,
    input  logic [63:0]         araddr,
    input  logic [7:0]          arlen,
    input  logic [2:0]          arsize,
    input  logic [1:0]          arburst,
    input  logic                arvalid,
    output logic                arready,
    output logic [ID_WIDTH-1:0] rid,
    output logic [63:0]         rdata,
    output logic [1:0]          rresp,
    output logic                rlast,
    output logic                rvalid,
    input  logic                rready,

    output logic        exit_valid_o,
    output logic [31:0] exit_code_o,
    output logic        irq_level_o
);

    localparam int unsigned RAM_WORDS = RAM_BYTES/8;
    logic [63:0] mem [0:RAM_WORDS-1];

    initial begin
        string hex;
        int fd;
        if ($value$plusargs("HEX=%s", hex)) $readmemh(hex, mem);
        else begin
            // Fallback without a plusarg (Vivado project sim: batch files split
            // options containing '='): a fixed image in the run dir, if present.
            fd = $fopen("cva6_prog.hex", "r");
            if (fd != 0) begin
                $fclose(fd);
                $readmemh("cva6_prog.hex", mem);
            end
        end
    end

    // ---------------- Write channel ----------------
    typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wstate_e;
    wstate_e wstate;
    logic [63:0] waddr_q;
    logic [7:0]  wlen_q;
    logic [ID_WIDTH-1:0] wid_q;

    assign awready = (wstate == W_IDLE);
    assign wready  = (wstate == W_DATA);
    assign bresp   = 2'b00;
    assign bid     = wid_q;
    assign bvalid  = (wstate == W_RESP);

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            wstate       <= W_IDLE;
            exit_valid_o <= 1'b0;
            exit_code_o  <= '0;
            irq_level_o  <= 1'b0;
        end else begin
            unique case (wstate)
                W_IDLE: if (awvalid) begin
                    // pragma translate_off
                    assert (awatop == '0) else $fatal(1, "axi_ram_sim: AMO not supported");
                    // pragma translate_on
                    waddr_q <= awaddr;
                    wlen_q  <= awlen;
                    wid_q   <= awid;
                    wstate  <= W_DATA;
                end
                W_DATA: if (wvalid) begin
                    automatic longint unsigned off = waddr_q - BASE;
                    if (off < RAM_BYTES) begin
                        for (int b = 0; b < 8; b++)
                            if (wstrb[b]) mem[off[31:3]][8*b +: 8] <= wdata[8*b +: 8];
                    end else begin
                        // MMIO
                        if (off - RAM_BYTES == 0 && wstrb[3:0] != '0 && wdata[31:0] != 0) begin
                            exit_valid_o <= 1'b1;
                            exit_code_o  <= wdata[31:0];
                        end
                        if (off - RAM_BYTES == 8 && wstrb[0])
                            irq_level_o <= wdata[0];
                    end
                    waddr_q <= waddr_q + 8;  // INCR, 64-bit-aligned beats (cache writes)
                    if (wlast) wstate <= W_RESP;
                    else       wlen_q <= wlen_q - 1;
                end
                W_RESP: if (bready) wstate <= W_IDLE;
                default: wstate <= W_IDLE;
            endcase
        end
    end

    // ---------------- Read channel ----------------
    typedef enum logic [0:0] {R_IDLE, R_DATA} rstate_e;
    rstate_e rstate;
    logic [63:0] raddr_q;
    logic [7:0]  rlen_q;
    logic [ID_WIDTH-1:0] rid_q;

    assign arready = (rstate == R_IDLE);
    assign rvalid  = (rstate == R_DATA);
    assign rid     = rid_q;
    assign rresp   = 2'b00;
    assign rlast   = (rstate == R_DATA) && (rlen_q == 0);

    always_comb begin
        automatic longint unsigned off = raddr_q - BASE;
        rdata = 64'hDEAD_BEEF_DEAD_BEEF;
        if (off < RAM_BYTES) rdata = mem[off[31:3]];
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            rstate <= R_IDLE;
        end else begin
            unique case (rstate)
                R_IDLE: if (arvalid) begin
                    raddr_q <= {araddr[63:3], 3'b0};
                    rlen_q  <= arlen;
                    rid_q   <= arid;
                    rstate  <= R_DATA;
                end
                R_DATA: if (rready) begin
                    raddr_q <= raddr_q + 8;
                    if (rlen_q == 0) rstate <= R_IDLE;
                    else             rlen_q <= rlen_q - 1;
                end
                default: rstate <= R_IDLE;
            endcase
        end
    end

endmodule
