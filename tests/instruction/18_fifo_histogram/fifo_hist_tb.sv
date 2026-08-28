// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    eTIP-CVS-FIFO fill-level histogram (I-02) -- exercise + read.
 *
 * @details
 *   Puts real pressure on the eTIP CVS FIFO (multi-slot beats: dense
 *   periodic syncs + Ownership + config message under the serialized
 *   1-slot/cycle drain, back-to-back retires with CYCLES_PER_INSTR=1),
 *   then -- with the trace quiescent (Enable=0, the documented no-CDC
 *   read contract) -- reads the 16 histogram bins via the PeakRDL CSRs
 *   trTeTipFifoHist0..7 @ te:0xE14..0xE30 and prints them.
 *
 *   Checks (script gates on the log):
 *     1. at least one bin counted (>0)      -> "HIST_NONZERO"
 *     2. HistClear zeroes all bins          -> "HIST_CLEARED"
 *     3. a second run counts again (re-arm) -> "HIST_REARMED"
 *   PC-losslessness of the stream itself is checked by the script
 *   (NexRv decode against the expected-PC reference as usual).
 */

module fifo_hist_tb;

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (1),
		.ATB_DUMP_PATH       ("fifo_hist_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("fifo_hist_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("fifo_hist_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("fifo_hist_tb.expected.pcs")
	) env ();

	localparam logic [3:0] ITR_SYNC_CLK_CYCLES = 4'd2;
	localparam logic [3:0] INST_SYNC_MAX       = 4'd0; // 16-cycle window: dense syncs -> multi-slot beats

	localparam logic [31:0] MAIN_PC = 32'h0000_7000;

	localparam int unsigned BINS = ct_pkg::CT_FIFO_HIST_BINS;
	logic [31:0] hist [BINS];

	// SERIAL read-out protocol: rewind the pointer (keeps the counters),
	// then BINS/2 consecutive reads of the SAME data register -- each read
	// returns one bin pair and auto-increments the pointer.
	task automatic read_hist();
		logic [31:0] w;
		string       s;
		env.csr.write(15'h0E10, 32'h0000_0002); // RdRewind (singlepulse)
		for (int i = 0; i < BINS / 2; i++) begin
			env.csr.read(15'h0E14, w);
			hist[2*i]   = {16'd0, w[15:0]};
			hist[2*i+1] = {16'd0, w[31:16]};
		end
		s = "";
		foreach (hist[i]) s = {s, $sformatf(" %0d", hist[i])};
		$display("[fifo_hist_tb] %0t: HIST%s", $time, s);
	endtask

	function automatic int unsigned hist_sum();
		int unsigned s = 0;
		for (int i = 0; i < BINS; i++) s += hist[i];
		return s;
	endfunction

	task automatic pressure_run(input logic [31:0] pc0);
		env.cpu.enter(.start_pc(pc0));
		env.cpu.run(16);
		// Back-to-back UNINFERABLE jumps: each one is a REAL IndirectBranch
		// (History) message (BTYPE+ICNT+UADDR+HIST+TSTAMP = several
		// formatter/slicer cycles per message) produced at 1 eTIP slot per
		// clk (CYCLES_PER_INSTR=1) -- the msg_gen/formatter back-pressure
		// stalls the CVS drain and the fill actually climbs. Direct
		// branches would NOT work here: HTM books them silently as HIST
		// bits without a message. Dense periodic syncs + Ownership add
		// multi-slot beats on top.
		// 180 back-to-back jumps to strictly fresh, disjoint targets (no
		// overlap with any run() PC -> no JI/L pcinfo type conflict). The
		// downstream stall must first fill the PO prefetch + CDC FIFO
		// before back-pressure reaches the CVS stage, hence the length.
		for (int i = 0; i < 180; i++) begin
			env.cpu.uninferable_jump(.target(pc0 + 32'h1000 + 32'(i + 1) * 32'h40));
		end
		env.cpu.run(16);
		env.cpu.exit_trace();
		// Trace-off drain (env.cpu.idle -- wait_cycles XSIM anomaly).
		env.cpu.idle(50);
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.cpu.idle(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.cpu.idle(4000);
		env.atb_force_flush = 1'b0;
		env.cpu.idle(500);
	endtask

	initial begin
		$display("[fifo_hist_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();

		env.csr.clear();
		env.csr.Set_te_trTsControl_Active       (1'b0);
		env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_CLK_CYCLES);
		env.csr.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX);
		env.csr.Set_te_trTeControl_Context      (1'b1); // Ownership after every sync -> multi-slot beats
		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.cpu.idle(20);

		// ---- Run 1: pressure, then read with the trace quiescent ----
		pressure_run(MAIN_PC);
		read_hist();
		if (hist_sum() > 0) $display("[fifo_hist_tb] HIST_NONZERO (sum=%0d)", hist_sum());
		else                $error("[fifo_hist_tb] FAIL: histogram empty after pressure run");

		// ---- Clear (trace quiescent -- the documented contract) ----
		env.csr.Set_te_trTeTipFifoHistCtrl_HistClear(1'b1);
		env.cpu.idle(10);
		env.csr.Set_te_trTeTipFifoHistCtrl_HistClear(1'b0);
		env.cpu.idle(10);
		read_hist();
		if (hist_sum() == 0) $display("[fifo_hist_tb] HIST_CLEARED");
		else                 $error("[fifo_hist_tb] FAIL: histogram not cleared (sum=%0d)", hist_sum());

		// ---- Run 2: re-armed counting ----
		env.csr.Set_te_trTeControl_Enable      (1'b1);
		env.csr.Set_te_trTeControl_InstTracing (1'b1);
		env.cpu.idle(20);
		pressure_run(MAIN_PC + 32'h4000);
		read_hist();
		if (hist_sum() > 0) $display("[fifo_hist_tb] HIST_REARMED (sum=%0d)", hist_sum());
		else                $error("[fifo_hist_tb] FAIL: histogram empty after re-arm");

		env.csr.Set_te_trTeControl_Active(1'b0);
		env.cpu.idle(1000);

		if (env.cpu.event_count() == 0) $error("[fifo_hist_tb] cpu_model event log empty");
		if (env.atb_bytes_seen == 0)    $error("[fifo_hist_tb] no ATB bytes observed");
		$display("[fifo_hist_tb] PASS (sim); decode verified by scripts/cli_fifohist_test.sh");
		$finish;
	end

	// Hard timeout
	initial begin
		#40ms;
		$error("[fifo_hist_tb] TIMEOUT - test exceeded 40 ms wall time");
		$finish;
	end

endmodule : fifo_hist_tb

`default_nettype wire
