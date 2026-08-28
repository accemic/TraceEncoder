// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Test 19 -- feature and filter matrix.
 *
 * @details
 *   A sequence of short configuration phases over a linear workload.
 *
 *   Key constraint: the configuration CSRs (comparator, filter, perfcnt,
 *   timestamp, SyncMode, InhibitSrc, features) are ENABLE-LOCKED -- writes
 *   while trTeControl.Enable=1 have no effect. Every phase therefore
 *   configures inside an enable cycle (InstTracing/Enable off -> configure ->
 *   Enable/InstTracing on) with drain idles around the transitions, because
 *   an enable transition needs the pipeline drained on both sides.
 *
 *   Phasen: (1) Comparator-P-Funktions-Sweep EQ..ALWAYS  (2) Input-Mux
 *   CONTEXT/TVAL/DADDR  (3) S-Funktions-Sweep + MODE1-Latch  (4) Filter-
 *   chain MatchComp1/all_comps_hit + ecause / interrupt predicates
 *   (5) Perfcnt-TH  (6) DF-Range-Memory (64-bit-Paar) + Data-Trace
 *   (7) TS Prescale 1/2/3 + Core-Quelle  (8) SRC-Feld  (9) ExtSync ATB/
 *   halfwords  (10) ACT station watchpoint -> SINK_TE (sorted entries,
 *   binary search)  (10b) ACT-CAP direct path  (10c) boundary slots +
 *   indirect readback  (10d) Enable=1 load-path rejection (audit B-3)
 *   (11) soft-reset persistence of the watchpoint table (audit B-4).
 *
 *   Pass criterion: a clean run with no testtools assertion and ATB bytes
 *   present (rc=0). There is deliberately no byte or PC contract, because the
 *   stream shape changes between phases;
 *   Feature CORRECTNESS is proven by the dedicated tests (11, 12, 15, 16, ...).
 */

module feature_matrix_tb;

	import cpu_model_pkg::*;
	import ct_cs_cpuif_wb_pkg::*;   // BITPOS_* field positions (Ph.10e)

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("feature_matrix_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("feature_matrix_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("feature_matrix_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("feature_matrix_tb.expected.pcs")
	) env ();

	// Disjoint regions -- the NexRv pcinfo model allows one type per PC, so
	// linear flow stays below ~0x2400 and the special regions are only
	// entered by a jump.
	localparam logic [31:0] BASE_PC = 32'h0000_2000;
	localparam logic [31:0] MODE1_A = 32'h0000_2800;   // P-Match (Latch set)
	localparam logic [31:0] MODE1_B = 32'h0000_2900;   // S-Match (Latch clear)
	localparam logic [31:0] ACT_PC  = 32'h0000_2600;   // Watchpoint-Key
	localparam logic [31:0] IRQ_PC  = 32'h0000_3000;
	localparam logic [31:0] HI_PC   = 32'h0000_5000;

	// C0b boundary-slot keys (Ph.10c). Two constraints meet here:
	//  1. table sort order -- keys strictly ascending across all 1023
	//     slots (dummies are ODD addresses, the core forces PC[0]=0, so
	//     they can sit inside executed regions without ever matching):
	//     ACT_PC..+0x28 < 0x3041.. (odd dummies 4..510) < WP_PC_511
	//     < 0x6001.. (odd dummies 512..1021) < WP_PC_1022.
	//  2. the cpu_model pcinfo file is a DENSE array from min to max
	//     visited PC (write_nexrv_info gap-fills every 4-byte slot, same
	//     contract as NexRv itself). Boundary PCs must therefore stay in
	//     the compact region -- a first cut at 0x5000_0000/0x7000_0000
	//     turned the final block into a ~470-million-line gap fill that
	//     looked exactly like a hung simulator (measured C0b, 2026-08-13).
	localparam logic [31:0] WP_PC_511   = 32'h0000_6000;  // slot 511 = tree root
	localparam logic [31:0] WP_PC_1022  = 32'h0000_7000;  // slot 1022 = last leaf
	localparam logic [31:0] WP_NOHIT_PC = 32'h0000_6800;  // armed nowhere

	// trActCapStCmd word (RDL layout, act_st.unpack_act_st_cmd):
	//   [5:0] Cmd=ACT_CAP_TE_INSTR_TRACING(0) [7:6] Sink=SINK_TE(3)
	//   [31:8] DirectData=1 (the InstTracing value)
	localparam logic [31:0] ACT_CMD = {24'h000001, 2'd3, 6'd0};

	// A dretire WITHOUT an iretire. cpu_model couples the two, so this is
	// driven hierarchically to reach the perfcnt threshold state
	// TH_CNT_IRETIRE, which counts cycles between a dretire and the NEXT
	// iretire.
	task automatic pulse_dretire_only();
		@(negedge env.tip_clk);
		env.cpu.r_dretire = 1;
		env.cpu.r_dtype   = STORE;
		env.cpu.r_daddr   = 32'h8000_0400;
		env.cpu.r_dsize   = 2;
		@(posedge env.tip_clk);
		@(negedge env.tip_clk);
		env.cpu.r_dretire = 0;
	endtask

	// C0b: free-running ACT-ST hit counter for the boundary-slot phase
	// (Ph.10c). Same hierarchical act_st probe the Ph.10 debug fork uses;
	// the phases compare DELTAS around their own jump windows, so hits
	// from earlier phases do not disturb the verdicts.
	int act_hit_count = 0;
	always @(posedge env.tip_clk)
		if (env.dut.preproc_inst.genAct.act_st_inst.hit_valid
		    && env.dut.preproc_inst.genAct.act_st_inst.hit)
			act_hit_count++;

	// Enable cycle wrapped around enable-locked configuration writes.
	task automatic reconfig_begin();
		env.cpu.idle(60);
		env.csr.Set_te_trTeControl_InstTracing(1'b0);
		env.cpu.idle(60);
		env.csr.Set_te_trTeControl_Enable(1'b0);
		env.cpu.idle(20);
	endtask
	task automatic reconfig_end();
		env.csr.Set_te_trTeControl_Enable(1'b1);
		env.csr.Set_te_trTeControl_InstTracing(1'b1);
		env.cpu.idle(20);
	endtask

	initial begin
		$display("[fm_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		env.csr.clear();
		env.csr.Set_te_trTsControl_Active       (1'b0);
		env.csr.Set_te_trTeControl_InstSyncMode (4'd0);   // syncs deterministically off
		env.csr.Set_te_trTeControl_SendConfig   (2'd0);
		env.csr.Set_te_trTeComp_PMatchLow_Value (0, 32'h0000_2000);
		// High half of the primary bound. The value used to be a range END
		// (0x2FFF) from a range semantics the RTL never implemented -- and it
		// was never read, so it never showed. {High,Low} IS the bound since
		// X2a, so it is 0 here.
		env.csr.Set_te_trTeComp_PMatchHigh_Value(0, 32'h0);
		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active      (1'b1);
		env.cpu.idle(20);
		$display("[fm_tb] %0t: scenario start", $time);
		env.cpu.enter(.start_pc(BASE_PC));
		env.cpu.run(16);

		// -- Ph.1: P-Funktions-Sweep (comp0, Input IADDR) ----------------
		$display("[fm_tb] PHASE Ph.1");
		for (int f = 0; f < 8; f++) begin
			reconfig_begin();
			env.csr.Set_te_trTeComp_Control_PFunction(0, f[2:0]);
			reconfig_end();
			env.cpu.run(16);
		end

		// -- Ph.2: Input-Mux CONTEXT/TVAL/DADDR --------------------------
		$display("[fm_tb] PHASE Ph.2");
		for (int inp = 1; inp <= 3; inp++) begin
			reconfig_begin();
			env.csr.Set_te_trTeComp_Control_PInput(0, inp[1:0]);
			reconfig_end();
			env.cpu.run(8);
			env.cpu.store_data(.addr(32'h8000_0100), .size(2), .data(64'hAB));
			env.cpu.run(8);
		end
		reconfig_begin();
		env.csr.Set_te_trTeComp_Control_PInput(0, 2'd0);   // back to IADDR
		reconfig_end();

		// -- Ph.3: S-Funktions-Sweep + MODE1-Latch -----------------------
		$display("[fm_tb] PHASE Ph.3");
		reconfig_begin();
		env.csr.Set_te_trTeComp_SMatchLow_Value (0, MODE1_B);
		// SMatchHigh is the HIGH HALF of the secondary bound since X2a (it is
		// only read when CT_XLEN = 64), so the PMASK mask has its own
		// register: SFunction = 6 matches (value AND SMask) == SMatch.
		env.csr.Set_te_trTeComp_SMaskLow_Value  (0, 32'hFFFF_FFC0);
		reconfig_end();
		for (int f = 0; f < 8; f++) begin
			reconfig_begin();
			env.csr.Set_te_trTeComp_Control_SFunction(0, f[2:0]);
			reconfig_end();
			env.cpu.run(16);
		end
		reconfig_begin();
		env.csr.Set_te_trTeComp_Control_PFunction(0, 3'd0);   // EQ (exakter PC!)
		env.csr.Set_te_trTeComp_Control_SFunction(0, 3'd0);
		env.csr.Set_te_trTeComp_PMatchLow_Value (0, MODE1_A + 32'h10);
		env.csr.Set_te_trTeComp_SMatchLow_Value (0, MODE1_B + 32'h10);
		// High halves 0: the bound is {High,Low}, and every address this
		// testbench produces lives in the low 4 GiB. (They used to be a copy
		// of the Low value, which was harmless while nothing read them and
		// would be wrong the moment CT_XLEN = 64.)
		env.csr.Set_te_trTeComp_PMatchHigh_Value(0, 32'h0);
		env.csr.Set_te_trTeComp_SMatchHigh_Value(0, 32'h0);
		// The latch mode is MODE3 ('h3): the latch arm explicitly checks
		// MatchMode==MODE3 (CompLatchM3).
		env.csr.Set_te_trTeComp_Control_MatchMode(0, 2'd3);
		reconfig_end();
		env.cpu.run(16);
		env.cpu.jump_to(.target(MODE1_A + 32'h10));           // set window
		env.cpu.run(32);
		env.cpu.jump_to(.target(MODE1_B + 32'h10));           // clear window
		env.cpu.run(32);
		reconfig_begin();
		env.csr.Set_te_trTeComp_Control_MatchMode(0, 2'd0);
		env.csr.Set_te_trTeComp_PMatchLow_Value (0, 32'h0000_2000);
		env.csr.Set_te_trTeComp_PMatchHigh_Value(0, 32'h0);   // see above
		reconfig_end();

		// -- Ph.4: filter chain ------------------------------------------
		$display("[fm_tb] PHASE Ph.4");
		reconfig_begin();
		env.csr.Set_te_trTeComp_Control_PFunction(0, 3'd7);   // ALWAYS_MATCH
		env.csr.Set_te_trTeFilter_Control_Comp1     (0, 2'd0);
		env.csr.Set_te_trTeFilter_Control_MatchComp1(0, 1'b1);
		env.csr.Set_te_trTeFilter_Control_Enable    (0, 1'b1);
		env.csr.Set_te_trTeInstFilters_Filters      (4'b0001);
		reconfig_end();
		env.cpu.run(32);
		reconfig_begin();
		env.csr.Set_te_trTeFilter_MatchChoiceEcauseLow_Value (0, 6'd0);
		env.csr.Set_te_trTeFilter_MatchChoiceEcauseHigh_Value(0, 6'd31);
		env.csr.Set_te_trTeFilter_Control_MatchEcause(0, 1'b1);
		reconfig_end();
		env.cpu.interrupt(.cause(11), .handler(IRQ_PC), .async(1));
		env.cpu.run(16);
		env.cpu.mret();
		env.cpu.run(16);
		reconfig_begin();
		env.csr.Set_te_trTeFilter_Control_MatchEcause(0, 1'b0);
		env.csr.Set_te_trTeFilter_Match_ValueInterrupt(0, 1'b1);
		env.csr.Set_te_trTeFilter_Control_MatchInterrupt(0, 1'b1);
		reconfig_end();
		env.cpu.interrupt(.cause(7), .handler(IRQ_PC), .async(1));
		env.cpu.run(16);
		env.cpu.mret();
		env.cpu.run(16);
		reconfig_begin();
		env.csr.Set_te_trTeFilter_Control_MatchInterrupt(0, 1'b0);
		env.csr.Set_te_trTeFilter_Control_Enable    (0, 1'b0);
		env.csr.Set_te_trTeInstFilters_Filters      (4'b0000);
		reconfig_end();

		// -- Ph.5: Perfcnt-Threshold TH_CNT_IRETIRE ----------------------
		$display("[fm_tb] PHASE Ph.5");
		reconfig_begin();
		env.csr.Set_pc_trPerfCntControl_IFetchThreshold(8'd4);
		reconfig_end();
		// On a long idle, TH_IDLE moves into TH_ITH_OVERFLOW by itself
		// because the counter keeps running in IDLE -- a single pulse would
		// then only exit the overflow instead of entering TH_CNT. Sequence:
		// pulse (exit the overflow if needed) + run (reset IThCnt via
		// iretire) -> pulse (IDLE -> TH_CNT) -> run (the iretire exit arm),
		// repeated twice for determinism, then saturation.
		for (int e = 0; e < 2; e++) begin
			pulse_dretire_only();
			env.cpu.run(8);
			pulse_dretire_only();
			env.cpu.run(8);
		end
		pulse_dretire_only();
		env.cpu.idle(300);             // > 2^8 cycles without iretire -> saturation arm
		env.cpu.run(32);

		// -- Ph.6: DF-Range-Memory (mem1-64-bit-Paar) + Data-Trace -------
		$display("[fm_tb] PHASE Ph.6");
		reconfig_begin();
		env.csr.Write_DF_RangeFilter_Memory(0, {32'h8000_0FFF, 32'h8000_0000});
		env.csr.Set_te_trTeDataControl_DataTracing(1'b1);
		reconfig_end();
		env.cpu.store_data(.addr(32'h8000_0300), .size(2), .data(64'h33));
		env.cpu.run(16);
		env.cpu.load_data (.addr(32'h8000_0304), .size(2));
		env.cpu.run(16);
		reconfig_begin();
		env.csr.Set_te_trTeDataControl_DataTracing(1'b0);
		reconfig_end();

		// -- Ph.6b: the DF range table is Enable-locked too (U10 F-3) ----
		$display("[fm_tb] PHASE Ph.6b");
		// mem1 was the one configuration store of this block with no lock at
		// all, while its structural twin -- the watchpoint table, same
		// vector_binary_search engine -- is locked twice. A mid-trace write
		// does not just change one range: an out-of-order key at an inner
		// node sends every concurrent lookup down the wrong branch, so ranges
		// nobody touched stop matching (ct_L23_preproc_df_range.sv:88, and
		// the identical rule in trWpDataHigh). SystemRDL swwel cannot express
		// it for a `mem`, so the lock sits in the wrapper
		// (ct_cs_cpuif_wb.sv, mem1_wr_allowed) and this phase is its guard.
		begin
			logic [63:0] df_before, df_locked, df_open;
			env.csr.Read_DF_RangeFilter_Memory(0, df_before);
			// deliberately an ORDER-BREAKING key pair, the destructive case
			env.csr.Write_DF_RangeFilter_Memory(0, {32'h0000_00FF, 32'hFFFF_0000});
			env.csr.Read_DF_RangeFilter_Memory(0, df_locked);
			if (df_locked != df_before)
				$error("[fm_tb] Enable=1: DF range entry 0 changed %016x -> %016x on a locked write",
					df_before, df_locked);
			// counter-proof: the same write lands with the window open, and
			// the original entry is restored before it closes.
			reconfig_begin();
			env.csr.Write_DF_RangeFilter_Memory(0, {32'h0000_00FF, 32'hFFFF_0000});
			env.csr.Read_DF_RangeFilter_Memory(0, df_open);
			if (df_open != {32'h0000_00FF, 32'hFFFF_0000})
				$error("[fm_tb] Enable=0: DF range write did not take (entry 0 = %016x)", df_open);
			env.csr.Write_DF_RangeFilter_Memory(0, df_before);
			reconfig_end();
		end

		// -- Ph.7: timestamps: prescale steps + core source --------------
		$display("[fm_tb] PHASE Ph.7");
		// Enum pitfall: TR_TS_SYSTEM='h2 and TR_TS_CORE='h3; 0 and 1 are
		// reserved, so a Type=1 write lands in the default arm.
		for (int p = 1; p <= 3; p++) begin
			reconfig_begin();
			env.csr.Set_te_trTsControl_Active  (1'b0);
			env.csr.Set_te_trTsControl_Type    (3'd2);        // TR_TS_SYSTEM
			env.csr.Set_te_trTsControl_Prescale(p[1:0]);
			env.csr.Set_te_trTsControl_Enable  (1'b1);
			env.csr.Set_te_trTsControl_Count   (1'b1);
			env.csr.Set_te_trTsControl_Active  (1'b1);
			reconfig_end();
			env.cpu.run(24);
		end
		reconfig_begin();
		env.csr.Set_te_trTsControl_Active(1'b0);
		env.csr.Set_te_trTsControl_Enable(1'b0);
		env.csr.Set_te_trTsControl_Type  (3'd3);              // TR_TS_CORE
		env.csr.Set_te_trTsControl_Enable(1'b1);
		env.csr.Set_te_trTsControl_Count (1'b1);
		env.csr.Set_te_trTsControl_Active(1'b1);
		reconfig_end();
		env.cpu.run(24);
		// TS field-width sweep (slicer edge arms: nbits==0 mask, message end
		// exactly on a slice boundary): width 0/1/3/7.
		for (int wdt = 0; wdt <= 7; wdt += (wdt == 0) ? 1 : ((wdt == 1) ? 2 : 4)) begin
			reconfig_begin();
			env.csr.Set_te_trTsControl_Active(1'b0);
			env.csr.Set_te_trTsControl_Width (wdt[5:0]);
			env.csr.Set_te_trTsControl_Active(1'b1);
			reconfig_end();
			env.cpu.run(24);
			env.cpu.uninferable_jump(.target(HI_PC + 32'h800 + 32'h40 * wdt));
			env.cpu.run(16);
		end
		reconfig_begin();
		env.csr.Set_te_trTsControl_Active(1'b0);
		env.csr.Set_te_trTsControl_Enable(1'b0);
		reconfig_end();

		// -- Ph.8: SRC-Feld ----------------------------------------------
		$display("[fm_tb] PHASE Ph.8");
		reconfig_begin();
		env.csr.Set_te_trTeInstFeatures_SrcBits(4'd4);
		env.csr.Set_te_trTeInstFeatures_SrcID  (8'd5);
		env.csr.Set_te_trTeControl_InhibitSrc  (1'b0);
		reconfig_end();
		env.cpu.run(32);
		env.cpu.uninferable_jump(.target(HI_PC));
		env.cpu.run(16);
		// SRC with SrcBits=0 (an nbits==0 field -> the slicer's zero-mask arm)
		reconfig_begin();
		env.csr.Set_te_trTeInstFeatures_SrcBits(4'd0);
		reconfig_end();
		env.cpu.run(24);
		env.cpu.uninferable_jump(.target(HI_PC + 32'h400));
		env.cpu.run(16);
		reconfig_begin();
		env.csr.Set_te_trTeControl_InhibitSrc  (1'b1);
		reconfig_end();

		// -- Ph.9: ExtSync-Quellen ---------------------------------------
		$display("[fm_tb] PHASE Ph.9");
		reconfig_begin();
		env.csr.Set_te_trTeControl_InstSyncMode(4'd7);        // ITR_SYNC_ATB
		reconfig_end();
		env.cpu.run(16);
		env.atb_force_sync = 1'b1;
		env.cpu.run(24);
		env.atb_force_sync = 1'b0;
		env.cpu.run(16);
		reconfig_begin();
		env.csr.Set_te_trTeControl_InstSyncMode(4'd3);        // ITR_SYNC_HALFWORDS
		// InstSyncMax was 4'd2 and this leg was VACUOUS (V1, measured
		// 2026-08-09). The cadence threshold is 2^(Max+4) half-words
		// (ct_L23_preproc_sync.sv:71), so Max=2 means 64. `run()` takes
		// BYTES, not instructions -- run(96) is 24 instructions, and at the
		// model's default ilastsize=1 that is 48 half-words. The window
		// ended before the counter ever reached its first tick, so this
		// phase produced exactly ZERO periodic syncs whether the half-word
		// counter was broken (B-R13-1) or repaired: there was never a
		// difference to observe. Max=0 makes the threshold 16 half-words,
		// and the same 24 instructions now cross it twice. Deliberately NOT
		// done by lengthening the run: that would move cur_pc and the
		// following phases depend on the linear region staying where it is.
		env.csr.Set_te_trTeControl_InstSyncMax (4'd0);
		reconfig_end();
		env.cpu.run(96);
		reconfig_begin();
		env.csr.Set_te_trTeControl_InstSyncMode(4'd0);
		reconfig_end();

		// -- Ph.10: ACT-Station: Watchpoint -> SINK_TE-Kommando ----------
		$display("[fm_tb] PHASE Ph.10");
		// Binary-search memory: write ALL entries in sorted order --
		// uninitialized keys break the search.
		reconfig_begin();
		// The watchpoint memory is the backing store of a PERFECT BINARY
		// TREE (vector_binary_search, DIM=M0_DIM, M0_N nodes). The flat
		// index is the position in the SORTED array, distributed in-order
		// over the tree layout: even indices are leaves, odd ones map to
		// the inner levels by their trailing-ones count, and the root is
		// the median.
		//
		// Software contract: fill ALL M0_N slots in ascending order over
		// the INDIRECT path (C0b -- the direct 0x4100 window is gone):
		// trWpIndex once, then per slot DataLow (Addr) + DataHigh (Cmd,
		// commits and advances the index). Filling only the first few
		// leaves the root empty (key 0) and the search runs into nothing.
		begin
			logic [31:0] cap;
			logic [15:0] idx_rb;
			env.csr.Read_trWpCap(cap);
			if (32'(cap[15:0]) != ct_pkg::M0_N)
				$error("[fm_tb] trWpCap.Entries=%0d != M0_N=%0d",
					cap[15:0], ct_pkg::M0_N);
			// Autoincrement contract: start at 5, commit 3 pairs, the
			// index must read 8 (the readback is the CURRENT pointer,
			// not the last written slot).
			env.wp_set_index(16'd5);
			for (int s = 5; s < 8; s++)
				env.wp_write_next({32'h0, 32'hF000_0000 + 32'h10 * s});
			env.wp_read_index(idx_rb);
			if (idx_rb != 16'd8)
				$error("[fm_tb] trWpIndex after 3 commits from 5 reads %0d, expected 8", idx_rb);
		end
		// Full table, ascending keys. Boundary slots carry REAL entries
		// (0 / 511 / 1022); everything else is a sorted dummy key in a
		// region the CPU never executes.
		env.wp_set_index(16'd0);
		env.wp_write_next({ACT_CMD, ACT_PC});
		env.wp_write_next(
			{{24'h000000, 2'd3, 6'd1}, ACT_PC + 32'h10});        // SINK_TE DATA_TRACING (TE-Sub-Arm)
		env.wp_write_next(
			{{16'hFFFF, 8'h00, 2'd1, 6'd8}, ACT_PC + 32'h20});   // DAQ_IFETCH_TH out-of-range -> else-Arm
		env.wp_write_next(
			{{24'h000000, 2'd1, 6'd63}, ACT_PC + 32'h28});       // unknown command -> default arm
		for (int s = 4; s < 511; s++)
			env.wp_write_next({32'h0, 32'h0000_3041 + 32'h10 * (s - 4)});  // odd dummy keys, ascending
		env.wp_write_next({ACT_CMD, WP_PC_511});                 // slot 511 (tree root)
		for (int s = 512; s < 1022; s++)
			env.wp_write_next({32'h0, 32'h0000_6001 + 32'h2 * (s - 512)}); // odd dummy keys, ascending
		env.wp_write_next({ACT_CMD, WP_PC_1022});                // slot 1022 (last)
		begin
			logic [15:0] idx_rb;
			env.wp_read_index(idx_rb);
			if (idx_rb != 16'd0)
				$error("[fm_tb] trWpIndex after full-table load reads %0d, expected wrap to 0", idx_rb);
		end
		env.csr.Set_te_trTeControl_InstTrigEnable(1'b1);
		reconfig_end();
		// A hierarchical probe into the cs_tip interface crashes Verilator
		// 5.040, so the PInput / MatchMode CDC question stays open here.
		env.cpu.run(16);
		fork begin : act_probe                          // debug: does the search hit fire?
			// window covers the 4*M0_DIM+1 search latency (41 at DIM=10)
			for (int k = 0; k < 96; k++) begin
				@(posedge env.tip_clk);
				if (env.dut.preproc_inst.genAct.act_st_inst.hit_valid)
					$display("[fm_tb][ACTDBG] t=%0t hit=%0d value=%08x",
						$time, env.dut.preproc_inst.genAct.act_st_inst.hit,
						env.dut.preproc_inst.genAct.act_st_inst.hit_value);
			end
		end join_none
		env.cpu.jump_to(.target(ACT_PC));
		env.cpu.run(48);
		// ACT (SINK_TE INSTR_TRACING) may have toggled it -- turn it back on.
		env.cpu.idle(40);
		env.csr.Set_te_trTeControl_InstTracing(1'b1);
		env.cpu.run(16);

		// -- Ph.10b: ACT-CAP direct path -- the TRACED CPU writes the ACT
		$display("[fm_tb] PHASE Ph.10b");
		// command CSR (ACT_CAP_CMD = 0x0B10, dtype CSR_READ_WRITE). Covers
		// the act_cap capture, the AXIS sink routing and the composer_axis
		// DAQ arms (in range, out of range -> else, unknown command ->
		// default).
		env.cpu.drive_dretire_pulse(.dtype_(CSR_READ_WRITE),
			.daddr_(32'h0000_0B10), .dsize_(tip_dsize_t'(2)),
			.data_({24'h000000, 2'd1, 6'd8}));    // DAQ_IFETCH_TH idx 0 (in-range)
		env.cpu.run(16);
		env.cpu.drive_dretire_pulse(.dtype_(CSR_READ_WRITE),
			.daddr_(32'h0000_0B10), .dsize_(tip_dsize_t'(2)),
			.data_({16'hFFFF, 8'h00, 2'd1, 6'd8})); // out-of-range -> else-Arm
		env.cpu.run(16);
		env.cpu.drive_dretire_pulse(.dtype_(CSR_READ_WRITE),
			.daddr_(32'h0000_0B10), .dsize_(tip_dsize_t'(2)),
			.data_({24'h000000, 2'd1, 6'd63}));   // unbekanntes Cmd -> default-Arm
		env.cpu.run(16);

		// -- Ph.10c: boundary slots 511/1022, non-hit, indirect readback --
		$display("[fm_tb] PHASE Ph.10c");
		// C0b: the table now has M0_N = 1023 slots; the phases above prove
		// slot 0 (plus 1-3), this one proves the tree ROOT (slot 511), the
		// LAST leaf (slot 1022), that an unarmed PC stays silent, and that
		// the shadow reads back over the indirect path.
		begin
			int h0;
			h0 = act_hit_count;
			env.cpu.jump_to(.target(WP_PC_511));
			env.cpu.run(32);
			env.cpu.idle(96);          // drain the 4*M0_DIM+1 search latency
			if (act_hit_count != h0 + 1)
				$error("[fm_tb] slot-511 watchpoint: %0d hit(s), expected exactly 1",
					act_hit_count - h0);
			h0 = act_hit_count;
			env.cpu.jump_to(.target(WP_NOHIT_PC));
			env.cpu.run(32);
			env.cpu.idle(96);
			if (act_hit_count != h0)
				$error("[fm_tb] non-armed PC produced %0d watchpoint hit(s)",
					act_hit_count - h0);
			h0 = act_hit_count;
			env.cpu.jump_to(.target(WP_PC_1022));
			env.cpu.run(32);
			env.cpu.idle(96);
			if (act_hit_count != h0 + 1)
				$error("[fm_tb] slot-1022 watchpoint: %0d hit(s), expected exactly 1",
					act_hit_count - h0);
		end
		// The two boundary hits dispatched SINK_TE INSTR_TRACING again --
		// restore, then verify the shadow over the indirect read path
		// (index writes are enable-locked, so inside a reconfig window).
		env.cpu.idle(40);
		env.csr.Set_te_trTeControl_InstTracing(1'b1);
		env.cpu.run(16);
		reconfig_begin();
		begin
			logic [63:0] rb;
			logic [15:0] idx_rb;
			env.wp_set_index(16'd0);
			env.wp_read_next(rb);
			if (rb != {ACT_CMD, ACT_PC})
				$error("[fm_tb] readback slot 0 = %016x, expected %08x_%08x",
					rb, ACT_CMD, ACT_PC);
			env.wp_set_index(16'd511);
			env.wp_read_next(rb);
			if (rb != {ACT_CMD, WP_PC_511})
				$error("[fm_tb] readback slot 511 = %016x, expected %08x_%08x",
					rb, ACT_CMD, WP_PC_511);
			env.wp_set_index(16'd1022);
			env.wp_read_next(rb);
			if (rb != {ACT_CMD, WP_PC_1022})
				$error("[fm_tb] readback slot 1022 = %016x, expected %08x_%08x",
					rb, ACT_CMD, WP_PC_1022);
			// the ReadHigh at the last slot wrapped the pointer
			env.wp_read_index(idx_rb);
			if (idx_rb != 16'd0)
				$error("[fm_tb] readback pointer after slot 1022 reads %0d, expected wrap to 0",
					idx_rb);
		end
		reconfig_end();

		// -- Ph.10d: Enable=1 rejection -- the load path is HW-locked ----
		$display("[fm_tb] PHASE Ph.10d");
		// C0b audit B-3: while trTeControl.Enable=1 the three load
		// registers are swwel-locked AND the shim suppresses the commit
		// explicitly (the generated swmod strobe fires even on a BLOCKED
		// write, so without the !Enable gate a locked trWpDataHigh access
		// would commit the stale staging content). Both halves must hold:
		// the index must not move and nothing may reach the table.
		// (Readback stays live at Enable=1 by design -- a trWpReadHigh
		// READ still advances the pointer -- so the checks here use the
		// side-effect-free trWpIndex read.)
		begin
			logic [15:0] idx_before, idx_after;
			logic [63:0] rb;
			env.wp_read_index(idx_before);
			env.wp_set_index(16'd7);                           // swwel-locked, must be ignored
			env.wp_write_next({32'hDEAD_BEEF, 32'hDEAD_BEE0}); // must neither stage nor commit
			env.wp_read_index(idx_after);
			if (idx_after != idx_before)
				$error("[fm_tb] Enable=1: trWpIndex moved %0d -> %0d on locked writes",
					idx_before, idx_after);
			// table proof after re-opening the window: slot 0 unharmed
			reconfig_begin();
			env.wp_set_index(16'd0);
			env.wp_read_next(rb);
			if (rb != {ACT_CMD, ACT_PC})
				$error("[fm_tb] Enable=1 write reached the table: slot 0 = %016x, expected %08x_%08x",
					rb, ACT_CMD, ACT_PC);
			reconfig_end();
		end

		// -- Ph.10e: Enable=1 rejection of the FEATURE bits (U10 F-1) ----
		$display("[fm_tb] PHASE Ph.10e");
		// Same class as Ph.10d, one register further out: trTeInstFeatures
		// is Enable-locked configuration. It was NOT until 2026-08-16 --
		// the register's own description ("Only accessible on trTeControl.
		// Enable=0") and doc/integration.adoc promised the lock, the RDL
		// swwel list did not implement it, so a compression feature could be
		// flipped mid-session and change the grammar of a stream the decoder
		// had already been configured for (and TCODE 58 had advertised).
		// This is the regression guard for that fix, and it is byte-neutral
		// by construction: a rejected write emits nothing, a CSR read emits
		// nothing, and the bit set in the counter-proof window is taken back
		// before that window closes.
		begin
			logic [31:0] feat_armed, feat_locked, feat_open, feat_restored;
			env.csr.Read_te_trTeInstFeatures(feat_armed);
			env.csr.Set_te_trTeInstFeatures_InstEnBranchPrediction(1'b1);
			env.csr.Set_te_trTeInstFeatures_InstEnRepeatInstr     (1'b1);
			env.csr.Read_te_trTeInstFeatures(feat_locked);
			if (feat_locked != feat_armed)
				$error("[fm_tb] Enable=1: trTeInstFeatures moved %08x -> %08x on locked writes",
					feat_armed, feat_locked);
			// Counter-proof that the register is not simply dead: the very
			// same write lands while the window is open.
			reconfig_begin();
			env.csr.Set_te_trTeInstFeatures_InstEnBranchPrediction(1'b1);
			env.csr.Read_te_trTeInstFeatures(feat_open);
			if (feat_open[BITPOS_te_trTeInstFeatures_InstEnBranchPrediction] !== 1'b1)
				$error("[fm_tb] Enable=0: InstEnBranchPrediction did not take (trTeInstFeatures = %08x)",
					feat_open);
			env.csr.Set_te_trTeInstFeatures_InstEnBranchPrediction(1'b0);
			env.csr.Read_te_trTeInstFeatures(feat_restored);
			if (feat_restored != feat_armed)
				$error("[fm_tb] Ph.10e left trTeInstFeatures at %08x, expected %08x",
					feat_restored, feat_armed);
			reconfig_end();
		end

		env.cpu.exit_trace();

		// ---- Trace-off drain (cpu.idle -- wait_cycles XSIM anomaly) ----
		env.cpu.idle(50);
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.cpu.idle(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.cpu.idle(4000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.cpu.idle(2000);

		// -- Ph.11: soft-reset persistence of the watchpoint table -------
		$display("[fm_tb] PHASE Ph.11");
		// C0b audit B-4: a ct_cs_rst pulse (CSR soft reset, the
		// overrun_recovery phase-E pattern) resets the POINTER and every
		// CSR, but the table content -- readback shadow BRAM and search
		// tree ocram -- persists by documented contract ([#wp-indirect]).
		// This is the regression guard against reintroducing a shadow
		// reset loop (the historical reset-cleared array, 65k FFs at this
		// depth, would clear the readback and turn these checks red).
		// Placed AFTER the trace-off drain on purpose: the wire stream is
		// already closed, so the reset cannot disturb the decode floors.
		begin
			logic [63:0] rb;
			logic [15:0] idx_rb;
			// fresh commit right before the reset (Enable=0 after the
			// drain). Slot 5 keeps its sorted dummy key -- odd address,
			// unmatchable by construction -- with a distinctive cmd word.
			env.wp_set_index(16'd5);
			env.wp_write_next({32'h00C0_B400, 32'h0000_3051});
			env.ct_cs_rst = 1'b1;
			env.cpu.idle(20);
			env.ct_cs_rst = 1'b0;
			env.cpu.idle(20);
			env.wp_read_index(idx_rb);
			if (idx_rb != 16'd0)
				$error("[fm_tb] trWpIndex after soft reset reads %0d, expected reset value 0",
					idx_rb);
			env.wp_set_index(16'd5);
			env.wp_read_next(rb);
			if (rb != {32'h00C0_B400, 32'h0000_3051})
				$error("[fm_tb] slot 5 (committed right before the reset) lost across soft reset: %016x",
					rb);
			env.wp_set_index(16'd0);
			env.wp_read_next(rb);
			if (rb != {ACT_CMD, ACT_PC})
				$error("[fm_tb] slot 0 (committed long before the reset) lost across soft reset: %016x, expected %08x_%08x",
					rb, ACT_CMD, ACT_PC);
		end

		if (env.cpu.event_count() == 0)
			$error("[fm_tb] cpu_model event log empty");
		else
			$display("[fm_tb] cpu_model logged %0d events", env.cpu.event_count());
		if (env.atb_bytes_seen == 0)
			$error("[fm_tb] no ATB bytes observed");
		else
			$display("[fm_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		$display("[fm_tb] PASS (sim)");
		$finish;
	end

	// Hard timeout
	initial begin
		#100ms;
		$error("[fm_tb] TIMEOUT - test exceeded 100 ms wall time");
		$finish;
	end

endmodule : feature_matrix_tb

`default_nettype wire
