// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`timescale 1ns / 1ps
`default_nettype none

/**
 * @brief    Self-checking unit TB for ct_axis_wp_shim (examples/kv260/common).
 *
 * @details
 *   Ported from the archive tree (package D0); the
 *   body is unchanged in substance, only the build wiring is new. DEPTH is a
 *   module parameter, and `abc -sim` has no way to pass one, so each leg has
 *   its own two-line wrapper (the repository's own idiom, see
 *   tests/data/05_df_workload/df_workload_full_tb.sv):
 *
 *     tb_axis_wp_shim_d256.sv  FIFO_DEPTH=256, the product default
 *     tb_axis_wp_shim_d16.sv   FIFO_DEPTH=16,  stress -- frequent full/empty
 *                              edges in the soak
 *
 *   `make sim-axis-wp-shim` runs BOTH and is green only if both print their
 *   TB_PASS line.
 *
 *   Black-box scoreboard: the encoder side has no accept signal, so the
 *   TB classifies every driven beat as accepted/dropped via the
 *   `drop_count` delta in the same cycle (design decision D0 handoff §1)
 *   and expects every accepted beat back as an exact 4-word record
 *   (W0..W2 = tdata elements, W3 = {8'h00, CORE_ID, tstrb, tid}, tlast
 *   on W3, tkeep 4'hF, in order, no loss, no duplication).
 *
 *   Scenarios:
 *     (a) single beat
 *     (b) DEPTH back-to-back beats, sink always ready -> 0 drops
 *     (c) sink stalled, gapless input -> exactly DEPTH+1 accepted
 *         (FIFO + holding register), rest dropped, overflow_sticky,
 *         fill_level == DEPTH, then resume without corruption
 *     (d) tstrb/tid patterns + full tid walk land correctly in W3
 *     (e) randomized soak >= 10k beats, random gaps + ready duty cycling
 *     (f) fill_level plausibility (<= DEPTH always, == 0 after drain)
 *     (g) drop_count saturation at 32'hFFFF_FFFF (counter pre-seeded by
 *         hierarchical deposit; 4G real beats are not simulatable)
 *
 *   Continuous checks: AXIS stability (tvalid/tdata/tlast frozen while
 *   stalled), tkeep == 4'hF, tlast position, drop_count == observed
 *   drops (up to scenario g).
 */

module tb_axis_wp_shim #(
	int unsigned DEPTH = 256           // FIFO_DEPTH under test (xelab -generic_top)
);

	localparam logic [3:0] TB_CORE_ID = 4'h5;

	logic clk = 1'b0;
	logic rst = 1'b1;
	always #5 clk = ~clk;              // 100 MHz

	// DUT I/O
	logic        s_tvalid = 1'b0;
	logic [95:0] s_tdata  = '0;
	logic [11:0] s_tstrb  = '0;
	logic [7:0]  s_tid    = '0;

	logic        m_tvalid;
	logic        m_tready = 1'b0;
	logic [31:0] m_tdata;
	logic [3:0]  m_tkeep;
	logic        m_tlast;

	logic [31:0] drop_count;
	logic        overflow_sticky;
	logic [31:0] fill_level;

	ct_axis_wp_shim #(
		.CORE_ID    (TB_CORE_ID),
		.FIFO_DEPTH (DEPTH)
	) dut (
		.clk             (clk),
		.rst             (rst),
		.s_tvalid        (s_tvalid),
		.s_tdata         (s_tdata),
		.s_tstrb         (s_tstrb),
		.s_tid           (s_tid),
		.m_tvalid        (m_tvalid),
		.m_tready        (m_tready),
		.m_tdata         (m_tdata),
		.m_tkeep         (m_tkeep),
		.m_tlast         (m_tlast),
		.drop_count      (drop_count),
		.overflow_sticky (overflow_sticky),
		.fill_level      (fill_level)
	);

	// ------------------------------------------------------------------
	// Scoreboard
	// ------------------------------------------------------------------
	typedef struct packed {
		logic [7:0]  tid;
		logic [11:0] tstrb;
		logic [95:0] tdata;
	} rec_t;

	rec_t exp_q [$];
	int unsigned sent_n          = 0;
	int unsigned accepted_n      = 0;
	int unsigned dropped_obs     = 0;
	int unsigned records_checked = 0;
	bit          sat_phase       = 1'b0;   // scenario g: drop_count preseeded

	// m_tready duty (percent); driven every negedge
	int ready_pct = 100;
	always @(negedge clk) begin
		if (ready_pct >= 100)    m_tready <= 1'b1;
		else if (ready_pct <= 0) m_tready <= 1'b0;
		else                     m_tready <= ($urandom_range(0, 99) < ready_pct);
	end

	// ------------------------------------------------------------------
	// Drivers
	// ------------------------------------------------------------------
	task automatic send_beat(input logic [95:0] d, input logic [11:0] strb,
	                         input logic [7:0] id);
		logic [31:0] dc_before;
		@(negedge clk);
		s_tvalid <= 1'b1;
		s_tdata  <= d;
		s_tstrb  <= strb;
		s_tid    <= id;
		dc_before = drop_count;
		@(posedge clk);
		#1;
		sent_n++;
		if (drop_count !== dc_before) begin
			dropped_obs++;
		end
		else begin
			exp_q.push_back('{tid: id, tstrb: strb, tdata: d});
			accepted_n++;
		end
	endtask

	task automatic send_rand_beat();
		send_beat({$urandom(), $urandom(), $urandom()},
		          12'($urandom()), 8'($urandom()));
	endtask

	task automatic stop_input();
		@(negedge clk);
		s_tvalid <= 1'b0;
	endtask

	task automatic drain(input int timeout_cycles = 200000);
		int idle_cnt = 0;
		ready_pct = 100;
		for (int i = 0; i < timeout_cycles; i++) begin
			@(posedge clk);
			#1;
			if (!m_tvalid && exp_q.size() == 0 && fill_level == 32'd0)
				idle_cnt++;
			else
				idle_cnt = 0;
			if (idle_cnt >= 10) return;
		end
		$fatal(1, "drain: timeout (exp_q=%0d fill=%0d m_tvalid=%b)",
		       exp_q.size(), fill_level, m_tvalid);
	endtask

	// ------------------------------------------------------------------
	// Monitor: reassemble 4-word records, compare against the scoreboard
	// ------------------------------------------------------------------
	logic [31:0] w [0:3];
	int          widx = 0;
	rec_t        mon_exp;

	always @(posedge clk) begin
		if (!rst && m_tvalid) begin
			if (m_tkeep !== 4'hF)
				$fatal(1, "monitor: m_tkeep=%h != 4'hF", m_tkeep);
			if (m_tlast !== (widx == 3))
				$fatal(1, "monitor: m_tlast=%b at word %0d", m_tlast, widx);
			if (m_tready) begin
				w[widx] = m_tdata;
				if (widx == 3) begin
					if (exp_q.size() == 0)
						$fatal(1, "monitor: record received, scoreboard empty");
					mon_exp = exp_q.pop_front();
					if (w[0] !== mon_exp.tdata[31:0] ||
					    w[1] !== mon_exp.tdata[63:32] ||
					    w[2] !== mon_exp.tdata[95:64] ||
					    w[3] !== {8'h00, TB_CORE_ID, mon_exp.tstrb, mon_exp.tid}) begin
						$display("monitor: record %0d MISMATCH", records_checked);
						$display("  got  W0=%h W1=%h W2=%h W3=%h",
						         w[0], w[1], w[2], w[3]);
						$display("  want W0=%h W1=%h W2=%h W3=%h",
						         mon_exp.tdata[31:0], mon_exp.tdata[63:32],
						         mon_exp.tdata[95:64],
						         {8'h00, TB_CORE_ID, mon_exp.tstrb, mon_exp.tid});
						$fatal(1, "monitor: record mismatch");
					end
					records_checked++;
					widx = 0;
				end
				else begin
					widx++;
				end
			end
		end
	end

	// AXIS stability: while stalled, tvalid stays and tdata/tlast freeze
	logic        stall_q = 1'b0;
	logic [31:0] tdata_q;
	logic        tlast_q;
	always @(posedge clk) begin
		if (!rst && stall_q) begin
			if (!m_tvalid || m_tdata !== tdata_q || m_tlast !== tlast_q)
				$fatal(1, "AXIS stability violation during stall");
		end
		stall_q <= !rst && m_tvalid && !m_tready;
		tdata_q <= m_tdata;
		tlast_q <= m_tlast;
	end

	// fill_level plausibility (scenario f, continuous part)
	always @(posedge clk) begin
		if (!rst && fill_level > 32'(DEPTH))
			$fatal(1, "fill_level=%0d > DEPTH=%0d", fill_level, DEPTH);
	end

	// consistency: every drop_count increment was one of our beats
	task automatic check_totals(input string tag);
		if (sent_n != accepted_n + dropped_obs)
			$fatal(1, "%s: sent=%0d != accepted=%0d + dropped=%0d",
			       tag, sent_n, accepted_n, dropped_obs);
		if (!sat_phase && drop_count !== 32'(dropped_obs))
			$fatal(1, "%s: drop_count=%0d != observed drops=%0d",
			       tag, drop_count, dropped_obs);
	endtask

	// ------------------------------------------------------------------
	// Test sequence
	// ------------------------------------------------------------------
	initial begin : watchdog
		#50_000_000;
		$fatal(1, "global watchdog timeout");
	end

	initial begin : main
		int unsigned acc_before, drop_before, rec_before;
		logic [31:0] dc;

		repeat (5) @(negedge clk);
		rst <= 1'b0;
		repeat (2) @(negedge clk);

		// ---- (a) single beat --------------------------------------------
		send_beat(96'hDEAD_BEEF_0123_4567_89AB_CDEF, 12'hFFF, 8'h01);
		stop_input();
		drain();
		if (records_checked != 1 || dropped_obs != 0)
			$fatal(1, "(a): records=%0d dropped=%0d", records_checked, dropped_obs);
		if (overflow_sticky !== 1'b0)
			$fatal(1, "(a): overflow_sticky set without overflow");
		check_totals("(a)");
		$display("TB (a) single beat            : OK");

		// ---- (b) back-to-back, sink always ready ------------------------
		rec_before  = records_checked;
		drop_before = dropped_obs;
		for (int i = 0; i < DEPTH; i++)
			send_beat({32'h0B00_0000 + i, 32'h1B00_0000 + i, 32'h2B00_0000 + i},
			          12'hFFF, 8'h02);
		stop_input();
		drain();
		if (dropped_obs != drop_before)
			$fatal(1, "(b): %0d drops in always-ready burst",
			       dropped_obs - drop_before);
		if (records_checked - rec_before != DEPTH)
			$fatal(1, "(b): records=%0d != %0d", records_checked - rec_before, DEPTH);
		check_totals("(b)");
		$display("TB (b) %0d back-to-back beats : OK (0 drops)", DEPTH);

		// ---- (c) sink stalled until FIFO full ----------------------------
		acc_before  = accepted_n;
		drop_before = dropped_obs;
		ready_pct   = 0;
		@(negedge clk);                 // let m_tready drop before the burst
		for (int i = 0; i < DEPTH + 50; i++)
			send_beat({32'h0C00_0000 + i, 32'h1C00_0000 + i, 32'h2C00_0000 + i},
			          12'hFFF, 8'h03);
		stop_input();
		@(posedge clk); #1;
		if (accepted_n - acc_before != DEPTH + 1)
			$fatal(1, "(c): accepted=%0d != DEPTH+1=%0d",
			       accepted_n - acc_before, DEPTH + 1);
		if (dropped_obs - drop_before != 49)
			$fatal(1, "(c): dropped=%0d != 49", dropped_obs - drop_before);
		if (overflow_sticky !== 1'b1)
			$fatal(1, "(c): overflow_sticky not set");
		if (fill_level !== 32'(DEPTH))
			$fatal(1, "(c)/(f): fill_level=%0d != DEPTH=%0d", fill_level, DEPTH);
		drain();                        // resume: no corruption, order intact
		if (fill_level !== 32'd0)
			$fatal(1, "(c)/(f): fill_level=%0d after drain", fill_level);
		check_totals("(c)");
		$display("TB (c) stall/overflow/resume  : OK (accepted=%0d dropped=49, sticky)",
		         DEPTH + 1);

		// ---- (d) tstrb/tid patterns into W3 ------------------------------
		send_beat(96'h1, 12'h00F, 8'h11);
		send_beat(96'h2, 12'h0FF, 8'h22);
		send_beat(96'h3, 12'hA5A, 8'h5A);
		send_beat(96'h4, 12'h000, 8'h00);
		send_beat(96'h5, 12'h800, 8'hFF);
		stop_input();
		for (int i = 0; i < 256; i++) begin   // full tid walk, rate-limited
			send_beat({3{32'h0D00_0000 + i}}, 12'(i * 13), 8'(i));
			stop_input();
			repeat (2) @(negedge clk);
		end
		drain();
		check_totals("(d)");
		$display("TB (d) tstrb/tid -> W3        : OK (261 patterns)");

		// ---- (e) randomized soak -----------------------------------------
		rec_before = records_checked;
		fork
			begin : soak_ready_duty
				static int duties [5] = '{0, 20, 50, 80, 100};
				forever begin
					repeat (150) @(negedge clk);
					ready_pct = duties[$urandom_range(0, 4)];
				end
			end
		join_none
		for (int i = 0; i < 12000; i++) begin
			send_rand_beat();
			if ($urandom_range(0, 9) < 3) begin
				stop_input();
				repeat ($urandom_range(1, 3)) @(negedge clk);
			end
		end
		stop_input();
		disable soak_ready_duty;
		drain();
		check_totals("(e)");
		if (records_checked != accepted_n)
			$fatal(1, "(e): records_checked=%0d != accepted=%0d",
			       records_checked, accepted_n);
		if (overflow_sticky !== 1'b1)     // soak stalls guarantee drops
			$fatal(1, "(e): overflow_sticky lost");
		$display("TB (e) soak 12000 beats       : OK (%0d records, %0d drops so far)",
		         records_checked - rec_before, dropped_obs);

		// ---- (g) drop_count saturation (hierarchical deposit) ------------
		sat_phase = 1'b1;
		dut.drop_count_q = 32'hFFFF_FFFE;
		ready_pct = 0;
		@(negedge clk);
		for (int i = 0; i < DEPTH + 1; i++)   // refill FIFO + holding reg
			send_beat({3{32'h0E00_0000 + i}}, 12'hFFF, 8'h0E);
		// FIFO full now: next drop must move FFFF_FFFE -> FFFF_FFFF ...
		send_beat(96'hBAD, 12'hFFF, 8'h0F);
		if (drop_count !== 32'hFFFF_FFFF)
			$fatal(1, "(g): drop_count=%h != FFFF_FFFF", drop_count);
		// ... and stay saturated (raw drive, scoreboard untouched)
		for (int i = 0; i < 3; i++) begin
			@(negedge clk);
			s_tvalid <= 1'b1;
			s_tdata  <= 96'hBAD0 + i;
			s_tstrb  <= 12'hFFF;
			s_tid    <= 8'h0F;
			@(posedge clk); #1;
			if (drop_count !== 32'hFFFF_FFFF)
				$fatal(1, "(g): drop_count=%h left saturation", drop_count);
		end
		stop_input();
		if (overflow_sticky !== 1'b1)
			$fatal(1, "(g): overflow_sticky not set");
		drain();                          // pre-fill records still intact
		if (records_checked != accepted_n)
			$fatal(1, "(g): records_checked=%0d != accepted=%0d",
			       records_checked, accepted_n);
		$display("TB (g) drop_count saturation  : OK");

		// ---- summary ------------------------------------------------------
		$display("TB_PASS (tb_axis_wp_shim DEPTH=%0d): sent=%0d accepted=%0d dropped=%0d records_checked=%0d drop_count=%h",
		         DEPTH, sent_n, accepted_n, dropped_obs, records_checked,
		         drop_count);
		$finish;
	end

endmodule

`default_nettype wire
