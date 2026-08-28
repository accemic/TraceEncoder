// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    System testbench / trace host for the TGC5B + CEDARtools.TraceEncoder example SoC.
 *
 * @details
 *   Acts as the debug host: it programs the encoder CSRs over the SoC's external
 *   config port (so the program under trace needs NO CEDARtools.TraceEncoder awareness), loads
 *   the active program image into RAM, runs the core, captures the encoder's ATB
 *   output, and records the golden PC reference straight from what the encoder
 *   ingests.
 *
 *   Program slot (populated by `make sim-tgc5b-soc`):
 *     prog/prog.hex     $readmemh image loaded into ct_soc_ram
 *     prog/prog.pcinfo  NexRv instruction map (staged here as <test>.nexrv.info)
 *
 *   Outputs (checked/dumped offline via scripts/decode_and_check.sh / sim.sh):
 *     ct_soc_tb.atb.bin      the encoder N-Trace byte stream (atb_dump)
 *     ct_soc_tb.expected.pcs the PCs the encoder actually traced (golden)
 *     ct_soc_tb.nexrv.info   the program pcinfo
 *
 *   The core is held in reset while tracing is switched on, so the whole
 *   program is covered. Tracing runs until the core parks on a stable PC (a halt
 *   loop) or TRACE_MAX_CYCLES elapse, then it is switched off and the encoder
 *   flushed.
 */

module ct_soc_tb;

	localparam string PROG_HEX        = "../../examples/kv260/common/tgc5b/prog/prog.hex";
	localparam string PROG_PCINFO     = "../../examples/kv260/common/tgc5b/prog/prog.pcinfo";
	localparam int    TRACE_MAX_CYCLES = 200000;
	localparam int    HALT_STABLE_PCS  = 6;     // same PC this many retires => halted

	logic clk = 0;
	logic rst = 1;
	logic core_rst_hold = 1;

	always #5ns clk = ~clk;   // 100 MHz

	// -- Flat ATB from the DUT + always-ready sink -------------------------
	logic [31:0] atb_atdata;
	logic [1:0]  atb_atbytes;
	logic [6:0]  atb_atid;
	logic        atb_atvalid;
	logic        atb_afready;
	logic        force_flush = 1'b0;
	logic        axis_tvalid;
	logic [95:0] axis_tdata;
	logic [11:0] axis_tkeep;
	logic [7:0]  axis_tid;
	logic        axis_tlast;
	logic [31:0] core_trace_pc;
	logic        core_trace_valid;

	// -- Host CSR config port (Wishbone) -----------------------------------
	wb_if #(.DATA_WIDTH(32), .ADDR_WIDTH(32)) cfg();

	ct_soc_synth_wrap #(
		.RESET_VECTOR  (32'h0000_0000),
		.MEM_WORDS     (16384),
		.MEM_INIT_FILE (PROG_HEX)
	) dut (
		.clk              (clk),
		.rst              (rst),
		.core_rst_hold    (core_rst_hold),
		.atb_atdata       (atb_atdata),
		.atb_atbytes      (atb_atbytes),
		.atb_atid         (atb_atid),
		.atb_atvalid      (atb_atvalid),
		.atb_atready      (1'b1),          // always-ready trace sink
		.atb_afready      (atb_afready),
		.atb_afvalid      (force_flush),   // end-of-run flush
		.atb_syncreq      (1'b0),
		.axis_tdata       (axis_tdata),
		.axis_tkeep       (axis_tkeep),
		.axis_tid         (axis_tid),
		.axis_tlast       (axis_tlast),
		.axis_tvalid      (axis_tvalid),
		.axis_tready      (1'b1),
		.cfg_wb_en        (1'b1),          // host owns the encoder CSRs
		.cfg_wb_cyc       (cfg.cyc),
		.cfg_wb_stb       (cfg.stb),
		.cfg_wb_we        (cfg.we),
		.cfg_wb_addr      (cfg.addr),
		.cfg_wb_data_m2s  (cfg.data_m2s),
		.cfg_wb_sel       (cfg.sel),
		.cfg_wb_data_s2m  (cfg.data_s2m),
		.cfg_wb_ack       (cfg.ack),
		.cfg_wb_err       (cfg.err),
		.core_trace_pc    (core_trace_pc),
		.core_trace_valid (core_trace_valid)
	);

	// Host-side CSR access helper (drives the cfg Wishbone master).
	ct_cs_cpuif_wb_helper csr (
		.clk (clk),
		.wb  (cfg.master)
	);

	// -- Rebuild an atb_if from the flat outputs for atb_dump --------------
	atb_if atbm();
	assign atbm.atdata  = atb_atdata;
	assign atbm.atbytes = atb_atbytes;
	assign atbm.atid    = atb_atid;
	assign atbm.atvalid = atb_atvalid;
	assign atbm.afready = atb_afready;
	assign atbm.atready = 1'b1;
	assign atbm.afvalid = force_flush;
	assign atbm.syncreq = 1'b0;

	atb_dump #(.FILEPATH("ct_soc_tb.atb.bin")) atb_recorder (
		.atb_atclk    (clk),
		.atb_atresetn (~rst),
		.atb          (atbm.monitor)
	);

	// -- Golden PC capture -------------------------------------------------
	uwire logic trace_on =
		dut.ct_encoder_inst.cs_tip.trTeEnable &&
		dut.ct_encoder_inst.cs_tip.trTeInstTracing;

	int fd_pcs;
	initial fd_pcs = $fopen("ct_soc_tb.expected.pcs", "w");

	always @(posedge clk) begin
		if (!rst && dut.tip.iretire && trace_on) begin
			$fwrite(fd_pcs, "0x%08x\n", dut.tip.iaddr);
		end
	end

	// Copy a text file without shelling out. $system("cp ...") makes the
	// testbench depend on the simulator being able to spawn a coreutils
	// child, and that is not portable: on a Windows host with a
	// cygwin-family DLL clash, cp.exe dies with "error while loading
	// shared libraries" and the decode step then finds no instruction map
	// -- the simulation itself having passed. Staging the file in
	// SystemVerilog has no such dependency (AP0, 2026-08-16).
	task automatic stage_text_file(input string src, input string dst);
		int fi, fo, c;
		fi = $fopen(src, "r");
		if (fi == 0) begin
			$error("stage_text_file: cannot read %s", src);
			return;
		end
		fo = $fopen(dst, "w");
		if (fo == 0) begin
			$error("stage_text_file: cannot write %s", dst);
			$fclose(fi);
			return;
		end
		c = $fgetc(fi);
		while (c != -1) begin
			$fwrite(fo, "%c", c);
			c = $fgetc(fi);
		end
		$fclose(fi);
		$fclose(fo);
	endtask

	// Stage the program pcinfo next to the ATB dump (CWD is the sim work dir).
	initial begin
		stage_text_file(PROG_PCINFO, "ct_soc_tb.nexrv.info");
	end

	// -- Halt detection: core parked on a stable PC ------------------------
	logic [31:0] last_pc = 32'hFFFF_FFFF;
	int          stable_pcs = 0;
	always @(posedge clk) begin
		if (core_rst_hold) begin
			stable_pcs <= 0;
		end
		else if (core_trace_valid) begin
			if (core_trace_pc == last_pc) stable_pcs <= stable_pcs + 1;
			else                          stable_pcs <= 0;
			last_pc <= core_trace_pc;
		end
	end
	uwire logic core_halted = (stable_pcs >= HALT_STABLE_PCS);

	// -- Sequencing --------------------------------------------------------
	initial begin
		cfg.clear_master();
		repeat (10) @(posedge clk);
		rst <= 1'b0;                       // encoder + peripherals out of reset

		// Host configures + enables instruction tracing while the core is held.
		// Periodic sync (mode 6 = ITR_SYNC_INSTRUCTIONS, max 0 => every
		// 2^(0+4)=16 instructions) flushes the branch history regularly so the
		// trace stays decodable for any program, not just ones with rich control
		// flow. InstSyncMode/Max are writable only while Enable=0, so set them
		// first.
		repeat (4) @(posedge clk);
		csr.Set_te_trTeControl_InstSyncMode (4'd6);
		csr.Set_te_trTeControl_InstSyncMax  (4'd0);
		csr.Set_te_trTeControl_Enable       (1'b1);
		csr.Set_te_trTeControl_InstTracing  (1'b1);
		csr.Set_te_trTeControl_Active       (1'b1);
		repeat (20) @(posedge clk);        // let the enable cross into tip_clk

		core_rst_hold <= 1'b0;             // release the core -> program runs
		$display("[ct_soc_tb] %0t: core released, tracing", $time);

		// Run until the program parks (halt loop) or the cap is reached.
		begin
			automatic int cyc = 0;
			while (!core_halted && cyc < TRACE_MAX_CYCLES) begin
				@(posedge clk);
				cyc++;
			end
			$display("[ct_soc_tb] %0t: %0s after %0d cycles", $time,
				core_halted ? "core halted" : "cycle cap reached", cyc);
		end

		// Host disables tracing (InstTracing=0 -> trace-off correlation), lets it
		// drain, then flushes the ATB.
		csr.Set_te_trTeControl_InstTracing (1'b0);
		repeat (50) @(posedge clk);
		force_flush <= 1'b1;
		repeat (3000) @(posedge clk);
		force_flush <= 1'b0;
		csr.Set_te_trTeControl_Enable      (1'b0);
		repeat (50) @(posedge clk);

		$fclose(fd_pcs);
		$display("[ct_soc_tb] done; ATB trace:");
		$system("realpath ct_soc_tb.atb.bin");
		$finish;
	end

	// Global timeout guard.
	initial begin
		#5ms;
		$fclose(fd_pcs);
		$error("[ct_soc_tb] TIMEOUT — SoC did not finish in 5 ms");
		$finish;
	end

endmodule

`default_nettype wire
