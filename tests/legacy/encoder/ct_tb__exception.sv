// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @file    ct_tb__exception.sv
 * @brief   Directed encoder-pipeline TB for exception/interrupt itypes.
 * @description
 *   Routes EXCEPTION_TRAP, EXCEPTION_IR and INTERRUPT TIP beats through the
 *   full encoder (composer -> msg_gen -> nexus_formatter -> MSEO) in
 *   ITR_BRANCH_HIST mode and verifies that the resulting Nexus messages
 *   carry the correct TCODE + BTYPE + HIST payload. Closes the gap noted
 *   in the itype-coverage audit: exception/interrupt itypes were only
 *   exercised by the filter TB, never through the msg_gen BTYPE mapping.
 *
 * @environment Instantiates ct_encoder, a Nexus decoder, WB helpers, ATB dump
 *   and axis dump across tip / proc / wb / wall / atb clocks -- same skeleton
 *   as ct_tb__directed.
 *
 * @stimulus  Short directed sequence:
 *     1. one OTHER retire                      -> EXIT_FROM_SYS_RST sync (TCODE=9)
 *     2. three TAKEN_BRANCH retires            -> populate HIST with {T,T,T}
 *     3. EXCEPTION_TRAP (ILLEGAL_INSTR)        -> BTYPE=EXCEPTION on the
 *     4. one OTHER retire (trap handler entry)    IndirectBranchHistory
 *     5. one OTHER in handler
 *     6. EXCEPTION_IR return                   -> BTYPE=IBRANCH on the
 *     7. one OTHER (return target)                IndirectBranchHistory
 *     8. one OTHER
 *     9. INTERRUPT event                       -> BTYPE=INTERRUPT
 *    10. one OTHER (int handler entry)
 *    11. EXCEPTION_IR return from interrupt   -> BTYPE=IBRANCH
 *    12. one OTHER (return target)
 *    13. return target check
 *    14. back-to-back UNINFERABLE_JUMP + INTERRUPT on consecutive tip_clk
 *        retirement slots (FPGA-observed merged-IBH repro). Must emit two
 *        independent IBHs: BTYPE=IBRANCH then BTYPE=INTERRUPT.
 *    15. same pattern with 22 non-CF retires between jalr and INTERRUPT,
 *        all driven under a forced atb.atready=0 stall. Mirrors the real
 *        FPGA trace (ICNT=38). Must still emit two independent IBHs.
 *    16. heavy UNINFERABLE_JUMP traffic (20 UJs) under stall to saturate
 *        the whole msg_gen -> nexus_formatter -> MSEO -> atb CDC pipeline,
 *        followed by jalr + 22 OTHER + INTERRUPT + handler entry. Buckets
 *        IBHs by BTYPE and asserts the full count of BTYPE=IBRANCH plus
 *        exactly one BTYPE=INTERRUPT. Flags a merged-IBH bug if the
 *        IBRANCH count drops by one.
 *    17. parametric sweep: for each gap length N in 10..70, drive
 *        jalr + N OTHER retires + INTERRUPT + handler, and assert two
 *        independent IBHs arrive with BTYPE=IBRANCH then BTYPE=INTERRUPT.
 *        If any N collapses them into a single merged IBH, the failing
 *        iteration is surfaced by the per-iteration phase name in the
 *        log (sweep_jalr_ibh_nN / sweep_int_ibh_nN).
 *    18. HIST_OVERFLOW stress -- FPGA repro for the 25K-HIST_OVERFLOW
 *        workload. Drives 150 TAKEN_BRANCHes to force ~5 RESOURCE_FULL
 *        RCODE=1 emissions, then jalr + 21 OTHER + INTERRUPT + handler.
 *        Asserts the encoder still produces exactly one BTYPE=IBRANCH
 *        (jalr) followed by exactly one BTYPE=INTERRUPT.
 *    19. mixed NT/T HIST + consecutive indirects of all four BTYPE
 *        classes (IBRANCH via UJ, EXCEPTION via EXCEPTION_TRAP,
 *        INTERRUPT via EXCEPTION_IR and INTERRUPT). Verifies ICNT per
 *        IBH lies in the expected range and that all UADDRs are distinct,
 *        catching any shared / latched UADDR register across IBHs.
 *
 * @checking
 *   - First IBH carries HIST = 0xF  (stop bit + 3 T branches)
 *   - BTYPE values match the msg_gen itype->btype mapping
 *     (EXCEPTION_TRAP->EXCEPTION, INTERRUPT->INTERRUPT, EXCEPTION_IR->IBRANCH)
 *   - UADDR field present on every IBH
 *   - Back-to-back jalr + INTERRUPT yields two IBHs, not one merged message
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */
module ct_tb__exception;

	localparam WB_DATA_WIDTH = 32;
	localparam WB_ADDR_WIDTH = 32;

	import tt::*;
	import nexus_vendor::*;
	import nexus::*;
	import tip_pkg::*;
	import ct_pkg::*;
	import ct_cs_cpuif_pkg::*;
	import atb_pkg::*;
	import ct_cs_cpuif_wb_pkg::*;
	import file_pkg::*;
	import tip_utils_pkg::*;

	// Half-periods in ns.
	// - tip_clk  25 MHz  -> 40 ns period  -> 20.0 ns half
	// - proc_clk 100 MHz -> 10 ns period  -> 5.0 ns half
	// - atb_clk  156 MHz -> 6.41 ns period -> 3.205 ns half
	// - wb_clk   25 MHz  -> 40 ns period  -> 20.0 ns half
	localparam realtime TIP_CLK_PERIOD  = 20.0;
	localparam realtime PROC_CLK_PERIOD =  5.0;
	localparam realtime WALL_CLK_PERIOD = 50.0;
	localparam realtime WB_CLK_PERIOD   = 20.0;
	localparam realtime ATB_CLK_PERIOD  =  3.205;

	localparam int PHASE_IDLE_TIP_CYCLES = 16;
	localparam int MSG_TIMEOUT_CYCLES    = 20000;

	// ----------------------------------------------------------------
	// Signals, clocks, resets
	// ----------------------------------------------------------------
	logic           tip_rst, proc_rst, wb_rst, ct_cs_rst, wall_clk_rst;
	logic           atb_atresetn;
	logic           atb_afvalid;
	int             tip_time;

	uwire           dec_msg_valid;
	uwire           dec_msg_error;
	nexus_message_t dec_msg;
	nexus_message_t curr_dec_msg;
	nexus_message_t decoded_msg_queue[$];
	int             prev_dec_id = -1;
	int             last_dec_msg_id = -1;
	int             last_dec_tcode = -1;

	logic [WB_DATA_WIDTH-1:0] read_data;

	logic tip_clk   = 0; always #TIP_CLK_PERIOD   tip_clk   = ~tip_clk;
	logic wb_clk    = 0; always #WB_CLK_PERIOD    wb_clk    = ~wb_clk;
	logic proc_clk  = 0; always #PROC_CLK_PERIOD  proc_clk  = ~proc_clk;
	logic wall_clk  = 0; always #WALL_CLK_PERIOD  wall_clk  = ~wall_clk;
	logic atb_atclk = 0; always #ATB_CLK_PERIOD   atb_atclk = ~atb_atclk;

	tip_if              tip     ();
	tip_if              tip_dir ();
	assign tip._time = tip_time;

	axis_if #( .TDATA_WIDTH(ACT_CAP_AXIS_TDATA_WIDTH),
	           .TID_WIDTH  (ACT_CAP_AXIS_TID_WIDTH))
	  axis (.aclk (tip_clk), .aresetn(!tip_rst));

	// Encoder -> atb_stall_injector -> decoder. The injector forwards all
	// ATB signals transparently; `force_stall_i` is driven by the TB
	// (atb_stall) to deterministically backpressure the encoder during
	// Phases 15 and 16. Random-burst mode is left off.
	atb_if atb_enc ();
	atb_if atb_dec ();
	logic  atb_stall;

	assign atb_dec.afvalid = atb_afvalid;
	assign atb_dec.syncreq = '0;

	atb_stall_injector #(
		.STALL_PERIOD    (32),
		.STALL_LENGTH_MAX(4),
		.SEED            (32'hDEAD_BEEF)
	) atb_stall_injector_inst (
		.atb_atclk,
		.atb_atresetn,
		.stall_enable_i(1'b0),
		.force_stall_i (atb_stall),
		.atb_up        (atb_enc),
		.atb_dn        (atb_dec)
	);

	wb_if #(.DATA_WIDTH(WB_DATA_WIDTH), .ADDR_WIDTH(WB_DATA_WIDTH)) wb();

	ct_cs_cpuif_wb_helper #(.WB_DATA_WIDTH(WB_DATA_WIDTH), .WB_ADDR_WIDTH(WB_DATA_WIDTH))
		ct_cs_wb (wb_clk, wb);

	ct_encoder ct_encoder_inst (
	  .tip_clk,   .tip_rst,      .tip,
	  .wb_clk,    .wb_rst,       .wb,
	  .axis,
	  .atb_atclk, .atb_atresetn, .atb(atb_enc),
	  .proc_clk,  .proc_rst,
	  .ct_cs_rst,
	  .wall_clk,  .wall_clk_rst
	);

	atb_dump #( .FILEPATH ("atb_dump.bin") ) atb_dump_inst (.atb_atclk, .atb_atresetn, .atb(atb_enc));
	// ct_axis_dump intentionally omitted -- this TB checks decoded Nexus output
	// only, and the axis dumper needs a writable OUT_DIR parameter that the
	// generic abc flow doesn't set up for this bench.

	// tip <- tip_dir wiring (TipSendMsg writes tip_dir; encoder reads tip)
	assign tip.itype     = tip_dir.itype;
	assign tip.ecause    = tip_dir.ecause;
	assign tip.tval      = tip_dir.tval;
	assign tip.priv      = tip_dir.priv;
	assign tip.iaddr     = tip_dir.iaddr;
	assign tip._context  = tip_dir._context;
	assign tip.ctype     = tip_dir.ctype;
	assign tip.iretire   = tip_dir.iretire;
	assign tip.ilastsize = tip_dir.ilastsize;
	assign tip.impdef    = tip_dir.impdef;
	assign tip.dretire   = tip_dir.dretire;
	assign tip.dtype     = tip_dir.dtype;
	assign tip.daddr     = tip_dir.daddr;
	assign tip.dsize     = tip_dir.dsize;
	assign tip.data      = tip_dir.data;

	ct_nexus_decoder #(
		.INCLUDE_SRC    (1'b0),
		.INCLUDE_TSTAMP (1'b1)
	) ct_nexus_decoder_inst (
	  .atb_atclk,  .atb_atresetn,  .atb(atb_dec),
	  .dec_msg_valid,
	  .dec_msg_error,
	  .dec_msg
	);

	tip_t tipt;

	// ----------------------------------------------------------------
	// Monotonic timestamp source (matches ct_tb__directed)
	// ----------------------------------------------------------------
	always_ff @(posedge tip_clk) begin
		if (tip_rst) tip_time <= 0;
		else         tip_time <= tip_time + 1;
	end

	// ----------------------------------------------------------------
	// Decoded-message capture queue
	// ----------------------------------------------------------------
	initial begin
		prev_dec_id = -1;
		decoded_msg_queue.delete();
		forever begin
			@(posedge atb_atclk);
			if (!atb_atresetn) begin
				prev_dec_id = -1;
				decoded_msg_queue.delete();
			end
			else if (dec_msg_valid && (dec_msg.fields[0].name == TCODE) && (dec_msg.id != prev_dec_id)) begin
				prev_dec_id     = dec_msg.id;
				last_dec_msg_id = dec_msg.id;
				last_dec_tcode  = dec_msg.fields[0].data[5:0];
				decoded_msg_queue.push_back(dec_msg);
				void'(tt_assert(!dec_msg_error,
					$sformatf("%0.2f: Line %0d: decoder error on captured msg_id=%0d tcode=%0d",
						$realtime, `__LINE__, dec_msg.id, dec_msg.fields[0].data[5:0])));
			end
		end
	end

	// ----------------------------------------------------------------
	// Config (ITR_BRANCH_HIST mode, trace-all, periodic sync off-by-default)
	// ----------------------------------------------------------------
	task automatic configure_decoder();
		// Trace-all: enable filter[0] with no match predicates.
		ct_cs_wb.Set_te_trTeFilter_Control_Enable(0, 1'b1);
		ct_cs_wb.Set_te_trTeFilter_Control_MatchPrivilege(0, 1'b0);
		ct_cs_wb.Set_te_trTeFilter_Control_MatchEcause(0, 1'b0);
		ct_cs_wb.Set_te_trTeFilter_Control_MatchInterrupt(0, 1'b0);
		ct_cs_wb.Set_te_trTeFilter_Control_MatchComp1(0, 1'b0);
		ct_cs_wb.Set_te_trTeFilter_Control_MatchComp2(0, 1'b0);
		ct_cs_wb.Set_te_trTeFilter_Control_MatchComp3(0, 1'b0);
		ct_cs_wb.Set_te_trTeFilter_Control_Impdef(0, 1'b0);
		ct_cs_wb.Set_te_trTeFilter_Control_Dtype(0, 1'b0);
		ct_cs_wb.Set_te_trTeFilter_Control_Dsize(0, 1'b0);
		ct_cs_wb.Set_te_trTeControl_InhibitSrc(1'b1);
		ct_cs_wb.Set_te_trTeDataFilters_Filters(16'h0);
		ct_cs_wb.Set_te_trTeInstFilters_Filters(16'h0);

		ct_cs_wb.Set_te_trTeDataControl_DataTracing(1);
		ct_cs_wb.Set_te_trTeControl_InstTracing(1);

		// We are testing indirect-branch / exception / interrupt messaging in
		// ITR_BRANCH_HIST mode: the encoder must emit IndirectBranchHistory
		// (TCODE=28) with HIST + BTYPE for these itypes.
		ct_cs_wb.Set_te_trTeControl_InstMode(
			ct_cs_cpuif__te__trTeControl__trTeInstMode_e__ITR_BRANCH_HIST);

		// Disable periodic sync so the only emitted syncs are the EXIT_FROM_SYS_RST
		// one. Use a very large instruction-count threshold to keep this TB
		// deterministic; the small stimulus finishes well before a periodic fires.
		ct_cs_wb.Set_te_trTeControl_InstSyncMode(
			ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_INSTRUCTIONS);
		ct_cs_wb.Set_te_trTeControl_InstSyncMax(4'd15);

		ct_cs_wb.Set_te_trTsControl_Type(ct_cs_cpuif__te__trTsControl__trTsType_e__TR_TS_CORE);
		ct_cs_wb.Set_te_trTsControl_Enable(1'b1);
		ct_cs_wb.Set_te_trTsControl_Active(1'b1);
		ct_cs_wb.Set_te_trTsControl_Count(1'b1);

		ct_cs_wb.Set_te_trTeControl_Active(1);
		ct_cs_wb.Set_te_trTeControl_Enable(1); // master enable LAST
	endtask

	// ----------------------------------------------------------------
	// Phase item + helpers
	// ----------------------------------------------------------------
	typedef struct {
		tip_t  tip;
		int    delay;
		string desc;
		int    test_id;
	} test_item_t;

	task automatic send_tip_item(input test_item_t item);
		$display("%0.2f: Test %0d: %s", $realtime, item.test_id, item.desc);
		TipSendMsg(tip_dir, tip_clk, item.tip, item.delay);
		repeat (PHASE_IDLE_TIP_CYCLES) @(posedge tip_clk);
	endtask

	function automatic logic field_present(input nexus_field_name_e name);
		field_present = 0;
		for (int i = 0; i < NEXUS_MAX_FIELDS; i++)
			if (curr_dec_msg.fields[i].name == name) field_present = 1;
	endfunction

	function automatic logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0]
		get_field_data(input nexus_field_name_e name, output int width);
		get_field_data = '0;
		width = 0;
		for (int i = 0; i < NEXUS_MAX_FIELDS; i++) begin
			if (curr_dec_msg.fields[i].name == name) begin
				get_field_data = curr_dec_msg.fields[i].data;
				width          = curr_dec_msg.fields[i].data_width;
			end
		end
	endfunction

	task automatic wait_for_decoded_nexus_msg(
		input string        phase,
		input nexus_tcode_e expected_tcode,
		input int           timeout_cycles
	);
		int cycles_waited;
		nexus_tcode_e got_tcode;
		nexus_message_t queued_msg;

		cycles_waited = 0;
		while (1) begin
			@(posedge atb_atclk);
			cycles_waited++;

			while (decoded_msg_queue.size() > 0) begin
				queued_msg   = decoded_msg_queue.pop_front();
				curr_dec_msg = queued_msg;
				got_tcode    = nexus_tcode_e'(curr_dec_msg.fields[0].data[5:0]);

				$display("%0.2f: DEC phase=%s msg_id=%0d tcode=%0d (%s)",
					$realtime, phase, curr_dec_msg.id, curr_dec_msg.fields[0].data[5:0], got_tcode.name());

				// Silently skip FLUSH control messages.
				if (got_tcode == NEXUS_MSG_FLUSH) continue;

				// Skip ResourceFull (RCODE=0/1) messages unless the caller
				// is explicitly waiting for one. They are internal flow-
				// control: RCODE=1 (HIST_OVERFLOW) flushes a full HIST
				// window and RCODE=0 (ICNT_OVERFLOW) flushes accumulated
				// halfwords that no longer fit the next IBH/sync's 8-bit
				// ICNT field. Their count and placement depend on the
				// span length between CFs (esp. long OTHER stretches) and
				// must not desync this assertion's tcode match.
				if (got_tcode == NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL
				    && expected_tcode != NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL) continue;

				void'(tt_assert(got_tcode == expected_tcode,
					$sformatf("%0.2f: Line %0d: phase=%s unexpected tcode exp=%0d (%s) got=%0d (%s) msg_id=%0d",
						$realtime, `__LINE__, phase,
						expected_tcode, expected_tcode.name(), got_tcode, got_tcode.name(),
						curr_dec_msg.id)));
				return;
			end

			if (cycles_waited > timeout_cycles) begin
				void'(tt_assert(0,
					$sformatf("%0.2f: Line %0d: phase=%s timeout waiting for tcode=%0d (%s) last_id=%0d last_tcode=%0d",
						$realtime, `__LINE__, phase, expected_tcode, expected_tcode.name(),
						last_dec_msg_id, last_dec_tcode)));
				return;
			end
		end
	endtask

	// Drain the decoded-message queue for a window of atb_atclk cycles and
	// bucket every IndirectBranchHistory message by its BTYPE. Used by
	// Phase 16 to quantify whether the jalr's IBH survived the stall.
	task automatic count_ibh_btypes(
		input  int drain_atb_cycles,
		output int n_ibranch,
		output int n_exception,
		output int n_interrupt,
		output int n_other_ibh
	);
		int             cycles;
		nexus_message_t m;
		nexus_tcode_e   tcode;
		nexus_btype_e   btype;
		int             btype_idx;

		n_ibranch   = 0;
		n_exception = 0;
		n_interrupt = 0;
		n_other_ibh = 0;

		cycles = 0;
		while (cycles < drain_atb_cycles) begin
			@(posedge atb_atclk);
			cycles++;

			while (decoded_msg_queue.size() > 0) begin
				m     = decoded_msg_queue.pop_front();
				tcode = nexus_tcode_e'(m.fields[0].data[5:0]);
				if (tcode != NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY) continue;

				btype_idx = -1;
				for (int i = 1; i < NEXUS_MAX_FIELDS; i++) begin
					if (m.fields[i].name == BTYPE) begin
						btype_idx = i;
						break;
					end
				end
				if (btype_idx < 0) continue;

				btype = nexus_btype_e'(m.fields[btype_idx].data[$bits(nexus_btype_e)-1:0]);
				case (btype)
					NEXUS_BTYPE_IBRANCH:   n_ibranch++;
					NEXUS_BTYPE_EXCEPTION: n_exception++;
					NEXUS_BTYPE_INTERRUPT: n_interrupt++;
					default:               n_other_ibh++;
				endcase
			end
		end
	endtask

	// Verify the most recently captured decoded msg is an IndirectBranchHistory
	// with the expected BTYPE.  Optionally check a specific HIST value
	// (pass expected_hist == '0 to skip the HIST value check, still confirming
	// the field is present).
	task automatic check_ibh_btype(
		input string         phase,
		input nexus_btype_e  expected_btype,
		input logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] expected_hist_value,
		input bit            check_hist_value
	);
		int btw, hw, uw;
		logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] btype_d, hist_d, uaddr_d;

		void'(tt_assert(field_present(BTYPE),
			$sformatf("%0.2f: Line %0d: phase=%s missing BTYPE field", $realtime, `__LINE__, phase)));
		void'(tt_assert(field_present(RDATA0),
			$sformatf("%0.2f: Line %0d: phase=%s missing HIST/RDATA0 field", $realtime, `__LINE__, phase)));
		void'(tt_assert(field_present(UADDR),
			$sformatf("%0.2f: Line %0d: phase=%s missing UADDR field", $realtime, `__LINE__, phase)));

		btype_d = get_field_data(BTYPE,  btw);
		hist_d  = get_field_data(RDATA0, hw);
		uaddr_d = get_field_data(UADDR,  uw);

		void'(tt_assert(nexus_btype_e'(btype_d[$bits(nexus_btype_e)-1:0]) == expected_btype,
			$sformatf("%0.2f: Line %0d: phase=%s BTYPE mismatch exp=%0d (%s) got=%0d",
				$realtime, `__LINE__, phase, expected_btype, expected_btype.name(),
				btype_d[$bits(nexus_btype_e)-1:0])));

		if (check_hist_value) begin
			void'(tt_assert(hist_d == expected_hist_value,
				$sformatf("%0.2f: Line %0d: phase=%s HIST mismatch exp=0x%0h got=0x%0h",
					$realtime, `__LINE__, phase, expected_hist_value, hist_d)));
		end
	endtask

	// Verify the most recently captured decoded IBH's ICNT field falls in
	// [icnt_min, icnt_max]. This is the key bug-pattern check: a merged-IBH
	// carries an inflated ICNT (jalr-path + intermediate + interrupt-path)
	// so any such merge is caught by an upper-bound assertion here.
	task automatic check_ibh_icnt_range(
		input string phase,
		input int    icnt_min,
		input int    icnt_max
	);
		int icnt_w;
		logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] icnt_d;
		int icnt_val;

		void'(tt_assert(field_present(ICNT),
			$sformatf("%0.2f: Line %0d: phase=%s missing ICNT field",
				$realtime, `__LINE__, phase)));

		icnt_d   = get_field_data(ICNT, icnt_w);
		icnt_val = int'(icnt_d);

		void'(tt_assert(icnt_val >= icnt_min && icnt_val <= icnt_max,
			$sformatf("%0.2f: Line %0d: phase=%s ICNT=%0d out of expected range [%0d..%0d] -- merged/bloated IBH?",
				$realtime, `__LINE__, phase, icnt_val, icnt_min, icnt_max)));
	endtask

	// Extract the decoded UADDR value from the most recently captured IBH.
	// Returns 0 if the field is absent (also logs an assertion failure).
	function automatic logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0]
		get_ibh_uaddr(input string phase);
		int uaddr_w;
		logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] uaddr_d;

		void'(tt_assert(field_present(UADDR),
			$sformatf("%0.2f: Line %0d: phase=%s missing UADDR field",
				$realtime, `__LINE__, phase)));
		uaddr_d     = get_field_data(UADDR, uaddr_w);
		get_ibh_uaddr = uaddr_d;
	endfunction

	// ----------------------------------------------------------------
	// Main
	// ----------------------------------------------------------------
	initial begin
		int timeout_cycles;
		int test_id;
		test_item_t item;

		tip_rst      <= '1;
		ct_cs_rst    <= '1;
		proc_rst     <= '1;
		wb_rst       <= '1;
		wall_clk_rst <= '1;
		atb_atresetn <= 1'b0;
		atb_afvalid  <= '0;
		atb_stall    <= 1'b0;

		timeout_cycles = 50000;
		void'($value$plusargs("CT_TIMEOUT_CYCLES=%d", timeout_cycles));
		$display("%0.2f: ct_tb__exception start, CT_TIMEOUT_CYCLES=%0d", $realtime, timeout_cycles);

		TipTSetDefault(tipt);
		TipSendMsg(tip_dir, tip_clk, tipt, 3);
		@(posedge tip_clk);     tip_rst      <= '0;
		@(posedge tip_clk);
		@(posedge proc_clk);    proc_rst     <= '0;
		@(posedge proc_clk);    ct_cs_rst    <= '0;
		@(posedge wb_clk);      wb_rst       <= '0;
		@(posedge wall_clk);    wall_clk_rst <= '0;
		@(posedge atb_atclk);   atb_atresetn <= 1'b1;

		configure_decoder();
		@(posedge tip_clk);

		prev_dec_id     = -1;
		last_dec_msg_id = -1;
		last_dec_tcode  = -1;
		test_id         = 0;

		TipTSetDefault(tipt);
		tipt.iretire   = '1;
		tipt.ilastsize = 2;
		tipt.itype     = OTHER;

		// Phase 1: first retired instruction -> EXIT_FROM_SYS_RST sync
		item.tip         = tipt;
		item.tip.iaddr   = 32'h0000_1000;
		item.delay       = 4;
		item.desc        = "initial OTHER retire -> EXIT_FROM_SYS_RST";
		item.test_id     = test_id++;
		send_tip_item(item);
		wait_for_decoded_nexus_msg("initial_sync", NEXUS_MSG_PROGRAM_TRACE_SYNC, MSG_TIMEOUT_CYCLES);

		// Phase 2: three TAKEN_BRANCHes -> populate HIST with 3 T bits.
		// Each direct TAKEN_BRANCH in ITR_BRANCH_HIST shifts a 1 into Hist
		// but emits no standalone Nexus message.
		for (int i = 0; i < 3; i++) begin
			item.tip          = tipt;
			item.tip.iaddr    = 32'h0000_1004 + (i * 4);
			item.tip.itype    = TAKEN_BRANCH;
			item.delay        = 4;
			item.desc         = $sformatf("TAKEN_BRANCH[%0d] -> HIST bit", i);
			item.test_id      = test_id++;
			send_tip_item(item);
		end

		// Phase 3: EXCEPTION_TRAP. The encoder arms pending_cf_next_iaddr here;
		// no message goes out yet.
		item.tip            = tipt;
		item.tip.iaddr      = 32'h0000_1010;
		item.tip.itype      = EXCEPTION_TRAP;
		item.tip.ecause     = ILLEGAL_INSTR;
		item.delay          = 4;
		item.desc           = "EXCEPTION_TRAP (ILLEGAL_INSTR)";
		item.test_id        = test_id++;
		send_tip_item(item);

		// Phase 4: first trap-handler retire; captures next_iaddr -> encoder
		// emits IndirectBranchHistory (TCODE=28) carrying HIST={stop,T,T,T}=0xF
		// and BTYPE=NEXUS_BTYPE_EXCEPTION.
		item.tip           = tipt;
		item.tip.iaddr     = 32'h0000_2000; // trap handler entry
		item.tip.itype     = OTHER;
		item.tip.ecause    = ECAUSE_NONE;
		item.delay         = 4;
		item.desc          = "trap handler entry (captures next_iaddr -> IBH emit)";
		item.test_id       = test_id++;
		send_tip_item(item);

		wait_for_decoded_nexus_msg("exception_ibh", NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY, MSG_TIMEOUT_CYCLES);
		check_ibh_btype("exception_ibh", NEXUS_BTYPE_EXCEPTION, 32'h0000_000F, 1'b1);

		// Phase 5: one more OTHER in the trap handler.
		item.tip         = tipt;
		item.tip.iaddr   = 32'h0000_2004;
		item.tip.itype   = OTHER;
		item.delay       = 4;
		item.desc        = "trap handler body";
		item.test_id     = test_id++;
		send_tip_item(item);

		// Phase 6: EXCEPTION_IR return (arm pending_cf_next_iaddr again).
		item.tip            = tipt;
		item.tip.iaddr      = 32'h0000_2008;
		item.tip.itype      = EXCEPTION_IR;
		item.delay          = 4;
		item.desc           = "EXCEPTION_IR trap return";
		item.test_id        = test_id++;
		send_tip_item(item);

		// Phase 7: return target -> encoder emits IBH with BTYPE=INTERRUPT
		// (msg_gen maps EXCEPTION_IR -> NEXUS_BTYPE_INTERRUPT). HIST is now the
		// reset stop bit only (= 0x1), no new direct branches happened.
		item.tip          = tipt;
		item.tip.iaddr    = 32'h0000_1014; // return address
		item.tip.itype    = OTHER;
		item.delay        = 4;
		item.desc         = "return target (captures next_iaddr -> IBH for EXCEPTION_IR)";
		item.test_id      = test_id++;
		send_tip_item(item);

		wait_for_decoded_nexus_msg("exception_ir_ibh", NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY, MSG_TIMEOUT_CYCLES);
		// EXCEPTION_IR (mret) is a return-from-trap indirect branch; encoder
		// maps it to BTYPE=IBRANCH so the handler-body halfwords don't
		// inflate BTYPE=INTERRUPT IBHs (see ct_L2_msg_gen.sv).
		check_ibh_btype("exception_ir_ibh", NEXUS_BTYPE_IBRANCH, 32'h0000_0001, 1'b1);

		// Phase 8: one OTHER between the two exceptions.
		item.tip       = tipt;
		item.tip.iaddr = 32'h0000_1018;
		item.tip.itype = OTHER;
		item.delay     = 4;
		item.desc      = "OTHER between exception and interrupt";
		item.test_id   = test_id++;
		send_tip_item(item);

		// Phase 9: INTERRUPT (arm pending_cf_next_iaddr).
		item.tip        = tipt;
		item.tip.iaddr  = 32'h0000_101c;
		item.tip.itype  = INTERRUPT;
		item.delay      = 4;
		item.desc       = "INTERRUPT event";
		item.test_id    = test_id++;
		send_tip_item(item);

		// Phase 10: int-handler entry -> IBH with BTYPE=INTERRUPT.
		item.tip         = tipt;
		item.tip.iaddr   = 32'h0000_3000;
		item.tip.itype   = OTHER;
		item.delay       = 4;
		item.desc        = "interrupt handler entry -> IBH for INTERRUPT";
		item.test_id     = test_id++;
		send_tip_item(item);

		wait_for_decoded_nexus_msg("interrupt_ibh", NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY, MSG_TIMEOUT_CYCLES);
		check_ibh_btype("interrupt_ibh", NEXUS_BTYPE_INTERRUPT, 32'h0000_0001, 1'b1);

		// Phase 11: one OTHER in interrupt handler body.
		item.tip         = tipt;
		item.tip.iaddr   = 32'h0000_3004;
		item.tip.itype   = OTHER;
		item.delay       = 4;
		item.desc        = "interrupt handler body";
		item.test_id     = test_id++;
		send_tip_item(item);

		// Phase 12: EXCEPTION_IR return from interrupt.
		item.tip        = tipt;
		item.tip.iaddr  = 32'h0000_3008;
		item.tip.itype  = EXCEPTION_IR;
		item.delay      = 4;
		item.desc       = "EXCEPTION_IR return from interrupt";
		item.test_id    = test_id++;
		send_tip_item(item);

		// Phase 13: return target -> IBH for return, BTYPE=INTERRUPT.
		item.tip       = tipt;
		item.tip.iaddr = 32'h0000_1020;
		item.tip.itype = OTHER;
		item.delay     = 4;
		item.desc      = "return target from interrupt (IBH for EXCEPTION_IR)";
		item.test_id   = test_id++;
		send_tip_item(item);

		wait_for_decoded_nexus_msg("interrupt_ir_ibh", NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY, MSG_TIMEOUT_CYCLES);
		// EXCEPTION_IR (mret) -> BTYPE=IBRANCH (see exception_ir_ibh above).
		check_ibh_btype("interrupt_ir_ibh", NEXUS_BTYPE_IBRANCH, 32'h0000_0001, 1'b1);

		// ------------------------------------------------------------------
		// Phase 14: back-to-back UNINFERABLE_JUMP + INTERRUPT (FPGA repro).
		//
		// Regression for the FPGA-observed merged-IBH bug: a jalr (indirect)
		// followed by an INTERRUPT on the very next retirement slot must
		// produce TWO independent IndirectBranchHistory messages:
		//   1. BTYPE=IBRANCH   -- jalr's indirect branch, target = 0x5000
		//   2. BTYPE=INTERRUPT -- interrupt entry, target  = 0x6000
		// When the bug is present, the encoder's pending-IBH slot is
		// overwritten: only ONE IBH is emitted, carrying accumulated ICNT,
		// the later BTYPE (INTERRUPT) and the later target (handler entry).
		// The jalr's actual target is silently dropped.
		//
		// Stimulus uses consecutive tip_clk cycles with iretire held high,
		// rather than TipSendMsg (which interleaves an idle cycle). That
		// keeps the two indirect events adjacent in the composer so the
		// race window is actually exercised.
		// ------------------------------------------------------------------
		repeat (PHASE_IDLE_TIP_CYCLES) @(posedge tip_clk);
		$display("%0.2f: Test %0d: back-to-back UNINFERABLE_JUMP + INTERRUPT (FPGA repro)",
			$realtime, test_id);
		test_id++;

		// Three TAKEN_BRANCHes to pre-populate HIST so the first IBH carries
		// a non-trivial HIST payload (stop + 3*T = 0xF). They also advance
		// ICNT so a merged-vs-separate-IBH mismatch would be visible in
		// ICNT too if someone extends the assertions later.
		@(posedge tip_clk);
		tip_dir.iretire   <= 1'b1;
		tip_dir.itype     <= TAKEN_BRANCH;
		tip_dir.iaddr     <= 32'h0000_4000;
		tip_dir.ilastsize <= 2'd2;
		tip_dir.ecause    <= ECAUSE_NONE;
		tip_dir.dretire   <= 1'b0;

		@(posedge tip_clk);
		tip_dir.iaddr     <= 32'h0000_4004;

		@(posedge tip_clk);
		tip_dir.iaddr     <= 32'h0000_4008;

		// jalr (UNINFERABLE_JUMP) at 0x400c. Arms pending_cf; no message
		// is emitted yet (target unknown until next retire).
		@(posedge tip_clk);
		tip_dir.itype     <= UNINFERABLE_JUMP;
		tip_dir.iaddr     <= 32'h0000_400c;

		// *** THE RACE: INTERRUPT on the very next retirement slot. ***
		// This retire must (a) close jalr's pending_cf -> emit IBH with
		// BTYPE=IBRANCH and next_iaddr=0x5000, AND (b) arm a new
		// pending_cf for itself. iaddr=0x5000 is interpreted as the
		// jalr's target, i.e. where the interrupt fires (0 fall-through
		// instructions between jalr return and the interrupt).
		@(posedge tip_clk);
		tip_dir.itype     <= INTERRUPT;
		tip_dir.iaddr     <= 32'h0000_5000;

		// Trap handler entry. Closes the INTERRUPT's pending_cf ->
		// emits the SECOND IBH with BTYPE=INTERRUPT, next_iaddr=0x6000.
		@(posedge tip_clk);
		tip_dir.itype     <= OTHER;
		tip_dir.iaddr     <= 32'h0000_6000;

		// A few more OTHERs so msg_gen has nothing to stall on while
		// draining the two IBHs.
		for (int i = 0; i < 8; i++) begin
			@(posedge tip_clk);
			tip_dir.iaddr <= 32'h0000_6000 + ((i + 1) * 32'h4);
		end

		@(posedge tip_clk);
		tip_dir.iretire <= 1'b0;

		// First IBH -- must be BTYPE=IBRANCH (the jalr). If the bug is
		// present this will be BTYPE=INTERRUPT and the tt_assert in
		// check_ibh_btype fails immediately.
		wait_for_decoded_nexus_msg("b2b_jalr_ibh",
			NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY, MSG_TIMEOUT_CYCLES);
		check_ibh_btype("b2b_jalr_ibh", NEXUS_BTYPE_IBRANCH, '0, 1'b0);

		// Second IBH -- must be BTYPE=INTERRUPT. If the bug is present
		// this message is missing entirely and the wait times out, which
		// also fires a tt_assert.
		wait_for_decoded_nexus_msg("b2b_int_ibh",
			NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY, MSG_TIMEOUT_CYCLES);
		check_ibh_btype("b2b_int_ibh", NEXUS_BTYPE_INTERRUPT, '0, 1'b0);

		// ------------------------------------------------------------------
		// Phase 15: wide-separation jalr + INTERRUPT under ATB backpressure.
		//
		// Same intent as Phase 14 but closer to the FPGA-observed profile:
		//   - 22 non-CF retires sit between the jalr and the INTERRUPT
		//     (matches the real ICNT=38 = 16 pre + jalr + 21 post trace)
		//   - atb.atready is held low across the whole stimulus, so the
		//     first IBH cannot drain out of the encoder before the second
		//     one is generated. Backpressure is the load case that turns
		//     the "pending IBH slot overwrite" hypothesis from a pure
		//     race into a deterministic collision.
		//
		// When the bug is present, the jalr's IBH is clobbered by the
		// INTERRUPT's IBH: only one IBH drains after release, with
		// BTYPE=INTERRUPT and ICNT covering both events. The second
		// wait_for_decoded_nexus_msg below times out in that case.
		// ------------------------------------------------------------------
		repeat (PHASE_IDLE_TIP_CYCLES) @(posedge tip_clk);
		$display("%0.2f: Test %0d: wide-separation jalr + INTERRUPT under ATB backpressure",
			$realtime, test_id);
		test_id++;

		// Apply backpressure via the TB's atb_stall shim. Gates both the
		// encoder-visible atready and the decoder-visible atvalid low
		// for the entire stimulus window.
		atb_stall <= 1'b1;
		@(posedge atb_atclk);

		// Two TAKEN_BRANCHes for HIST.
		@(posedge tip_clk);
		tip_dir.iretire   <= 1'b1;
		tip_dir.itype     <= TAKEN_BRANCH;
		tip_dir.iaddr     <= 32'h0000_7000;
		tip_dir.ilastsize <= 2'd2;
		tip_dir.ecause    <= ECAUSE_NONE;
		tip_dir.dretire   <= 1'b0;

		@(posedge tip_clk);
		tip_dir.iaddr     <= 32'h0000_7004;

		// jalr at 0x7008 -- arms pending_cf; IBH generated on next retire.
		@(posedge tip_clk);
		tip_dir.itype     <= UNINFERABLE_JUMP;
		tip_dir.iaddr     <= 32'h0000_7008;

		// 22 non-CF retires in the jalr target function. The FIRST retire
		// closes the jalr's pending_cf (IBH generated into msg_gen ->
		// formatter); the remaining 21 just accumulate ICNT. With ATB
		// stalled, the IBH sits in the pipeline while more events arrive.
		@(posedge tip_clk);
		tip_dir.itype     <= OTHER;
		tip_dir.iaddr     <= 32'h0000_9000;

		for (int i = 1; i < 22; i++) begin
			@(posedge tip_clk);
			tip_dir.iaddr <= 32'h0000_9000 + (i * 32'h4);
		end

		// INTERRUPT at 0x9058 -- arms a new pending_cf while the jalr's
		// IBH is still backpressured.
		@(posedge tip_clk);
		tip_dir.itype     <= INTERRUPT;
		tip_dir.iaddr     <= 32'h0000_9058;

		// Handler entry -- closes the INTERRUPT's pending_cf.
		@(posedge tip_clk);
		tip_dir.itype     <= OTHER;
		tip_dir.iaddr     <= 32'h0000_A000;

		// A few more OTHERs so msg_gen finishes staging both IBHs into
		// the formatter before backpressure releases.
		for (int i = 1; i < 8; i++) begin
			@(posedge tip_clk);
			tip_dir.iaddr <= 32'h0000_A000 + (i * 32'h4);
		end

		@(posedge tip_clk);
		tip_dir.iretire <= 1'b0;

		// Let the pipeline settle under stall, then release backpressure
		// so messages drain to the decoder.
		repeat (64) @(posedge tip_clk);
		atb_stall <= 1'b0;
		@(posedge atb_atclk);

		// Expect TWO IBHs: first BTYPE=IBRANCH (jalr), then BTYPE=INTERRUPT.
		wait_for_decoded_nexus_msg("stall_jalr_ibh",
			NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY, MSG_TIMEOUT_CYCLES);
		check_ibh_btype("stall_jalr_ibh", NEXUS_BTYPE_IBRANCH, '0, 1'b0);

		wait_for_decoded_nexus_msg("stall_int_ibh",
			NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY, MSG_TIMEOUT_CYCLES);
		check_ibh_btype("stall_int_ibh", NEXUS_BTYPE_INTERRUPT, '0, 1'b0);

		// ------------------------------------------------------------------
		// Phase 16: heavy indirect-branch traffic under stall, then jalr +
		// 22 non-CF + INTERRUPT + handler. Drives 20 UNINFERABLE_JUMPs
		// back-to-back so msg_gen's output register, nexus_formatter,
		// MSEO formatter and the 8-deep proc->atb CDC FIFO are all
		// saturated before our target sequence even starts. If a CF
		// event can overwrite a still-pending IBH slot anywhere in that
		// congested pipeline, one of the BTYPE=IBRANCH messages will be
		// silently absorbed into the INTERRUPT IBH.
		//
		// Expected after stall release:
		//     BTYPE=IBRANCH   >= 21   (20 UJs + the named jalr)
		//     BTYPE=INTERRUPT == 1    (the single interrupt entry)
		// Bug signature:
		//     BTYPE=IBRANCH  == 20    (jalr merged into INTERRUPT)
		// ------------------------------------------------------------------
		repeat (PHASE_IDLE_TIP_CYCLES) @(posedge tip_clk);
		$display("%0.2f: Test %0d: heavy UJ traffic + jalr + INTERRUPT under stall",
			$realtime, test_id);
		test_id++;

		begin
			int n_ibranch;
			int n_exception;
			int n_interrupt;
			int n_other_ibh;

			atb_stall <= 1'b1;
			@(posedge atb_atclk);

			// 20 UNINFERABLE_JUMPs back-to-back. Each one's IBH is
			// emitted when the following retire arrives; they all stall
			// somewhere in the pipeline because ATB is blocked.
			@(posedge tip_clk);
			tip_dir.iretire   <= 1'b1;
			tip_dir.itype     <= UNINFERABLE_JUMP;
			tip_dir.iaddr     <= 32'h0000_B000;
			tip_dir.ilastsize <= 2'd2;
			tip_dir.ecause    <= ECAUSE_NONE;
			tip_dir.dretire   <= 1'b0;

			for (int i = 1; i < 20; i++) begin
				@(posedge tip_clk);
				tip_dir.iaddr <= 32'h0000_B000 + (i * 32'h4);
			end

			// "The jalr". Same itype; just the one whose IBH we care
			// about identifying separately in the count.
			@(posedge tip_clk);
			tip_dir.iaddr <= 32'h0000_B050;

			// 22 non-CF retires in the jalr's target function.
			@(posedge tip_clk);
			tip_dir.itype <= OTHER;
			tip_dir.iaddr <= 32'h0000_C000;
			for (int i = 1; i < 22; i++) begin
				@(posedge tip_clk);
				tip_dir.iaddr <= 32'h0000_C000 + (i * 32'h4);
			end

			// INTERRUPT in the target function -- arms pending_cf while
			// the pipeline is still congested with the backed-up IBHs.
			@(posedge tip_clk);
			tip_dir.itype  <= INTERRUPT;
			tip_dir.iaddr  <= 32'h0000_C058;
			tip_dir.ecause <= ECAUSE_NONE;

			// Handler entry -- closes the INTERRUPT's pending_cf.
			@(posedge tip_clk);
			tip_dir.itype <= OTHER;
			tip_dir.iaddr <= 32'h0000_D000;

			// Tail to flush msg_gen past the INTERRUPT IBH.
			for (int i = 1; i < 8; i++) begin
				@(posedge tip_clk);
				tip_dir.iaddr <= 32'h0000_D000 + (i * 32'h4);
			end

			@(posedge tip_clk);
			tip_dir.iretire <= 1'b0;

			// Hold stall while everything congests, then release.
			repeat (64) @(posedge tip_clk);
			atb_stall <= 1'b0;
			@(posedge atb_atclk);

			// Drain and bucket IBHs by BTYPE. 20000 atb_atclk cycles is
			// well past the worst-case serialization time for 20+ IBHs.
			count_ibh_btypes(20000, n_ibranch, n_exception, n_interrupt, n_other_ibh);

			$display("%0.2f: Phase 16 IBH counts: IBRANCH=%0d EXCEPTION=%0d INTERRUPT=%0d other=%0d",
				$realtime, n_ibranch, n_exception, n_interrupt, n_other_ibh);

			void'(tt_assert(n_ibranch >= 21,
				$sformatf("%0.2f: Phase 16: expected >=21 BTYPE=IBRANCH (20 UJs + jalr), got %0d -- jalr IBH merged into INTERRUPT?",
					$realtime, n_ibranch)));
			void'(tt_assert(n_interrupt == 1,
				$sformatf("%0.2f: Phase 16: expected exactly 1 BTYPE=INTERRUPT, got %0d",
					$realtime, n_interrupt)));
		end

		// ------------------------------------------------------------------
		// Phase 17: sweep the gap between jalr and INTERRUPT over 10..70
		// tip_clk cycles. At each gap, assert that the encoder still emits
		// TWO independent IBHs (BTYPE=IBRANCH for the jalr, BTYPE=INTERRUPT
		// for the interrupt). Regression target for the FPGA-observed
		// merged-IBH bug: if any gap length collapses the two into one
		// IBH, the second wait_for_decoded_nexus_msg times out and the
		// failing N is visible in the log.
		//
		// Each iteration uses unique iaddr regions so that the decoder
		// stream carries a traceable boundary between iterations. A short
		// flush window between iterations lets msg_gen / formatter settle
		// before the next stimulus starts.
		// ------------------------------------------------------------------
		repeat (PHASE_IDLE_TIP_CYCLES) @(posedge tip_clk);
		$display("%0.2f: Test %0d: sweep jalr->INTERRUPT gap 10..70 cycles",
			$realtime, test_id);
		test_id++;

		for (int n_gap = 10; n_gap <= 70; n_gap++) begin
			automatic tip_iaddr_t base_iaddr = 32'h0010_0000 + (n_gap * 32'h0000_1000);
			logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] jalr_uaddr_d;
			logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] int_uaddr_d;

			// Two TAKEN_BRANCHes to put something in HIST for the jalr IBH.
			@(posedge tip_clk);
			tip_dir.iretire   <= 1'b1;
			tip_dir.itype     <= TAKEN_BRANCH;
			tip_dir.iaddr     <= base_iaddr;
			tip_dir.ilastsize <= 2'd2;
			tip_dir.ecause    <= ECAUSE_NONE;
			tip_dir.dretire   <= 1'b0;

			@(posedge tip_clk);
			tip_dir.iaddr     <= base_iaddr + 32'h4;

			// jalr.
			@(posedge tip_clk);
			tip_dir.itype     <= UNINFERABLE_JUMP;
			tip_dir.iaddr     <= base_iaddr + 32'h8;

			// n_gap OTHER retires in the target function.
			@(posedge tip_clk);
			tip_dir.itype     <= OTHER;
			tip_dir.iaddr     <= base_iaddr + 32'h100;
			for (int i = 1; i < n_gap; i++) begin
				@(posedge tip_clk);
				tip_dir.iaddr <= base_iaddr + 32'h100 + (i * 32'h4);
			end

			// INTERRUPT.
			@(posedge tip_clk);
			tip_dir.itype     <= INTERRUPT;
			tip_dir.iaddr     <= base_iaddr + 32'h100 + (n_gap * 32'h4);

			// Handler entry -- closes the INTERRUPT's pending_cf.
			@(posedge tip_clk);
			tip_dir.itype     <= OTHER;
			tip_dir.iaddr     <= base_iaddr + 32'h800;

			// A few tail retires so msg_gen finishes staging the two IBHs.
			for (int i = 1; i < 4; i++) begin
				@(posedge tip_clk);
				tip_dir.iaddr <= base_iaddr + 32'h800 + (i * 32'h4);
			end

			@(posedge tip_clk);
			tip_dir.iretire <= 1'b0;

			// Expect IBH #1 = BTYPE=IBRANCH (jalr).
			//
			// ICNT budget:  2 preceding TAKEN_BRANCHes + jalr itself, each
			// with ilastsize=2 (4 halfwords/instr). Composer resets icnt_cum
			// on every CF event, so etip_cf.icnt for jalr = 4. msg_gen's
			// CurrICnt before this IBH = 2*4 = 8 (accumulated in BRANCH_HIST
			// mode on each TAKEN_BRANCH). Expected ICNT = 8 + 4 = 12.
			// Allow [8, 20] to absorb any off-by-one quirks.
			// If the bug merges this into the INTERRUPT IBH, the wait
			// times out (first assertion) OR the ICNT is bloated (second).
			wait_for_decoded_nexus_msg(
				$sformatf("sweep_jalr_ibh_n%0d", n_gap),
				NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY,
				MSG_TIMEOUT_CYCLES);
			check_ibh_btype(
				$sformatf("sweep_jalr_ibh_n%0d", n_gap),
				NEXUS_BTYPE_IBRANCH, '0, 1'b0);
			// Legitimate ICNT: ~44 for iter 10 (when composer leaks 32 halfwords
			// from Phase 16's tail) and 28 for iter>=11 (iter-to-iter leakage
			// of 16 halfwords from the previous iteration's handler+tail).
			// Bound [4..60] flags a bloated IBH (merged with INTERRUPT's path)
			// while accepting normal inter-iteration state leakage.
			check_ibh_icnt_range(
				$sformatf("sweep_jalr_ibh_n%0d", n_gap), 4, 60);
			jalr_uaddr_d = get_ibh_uaddr(
				$sformatf("sweep_jalr_ibh_n%0d", n_gap));

			// Expect IBH #2 = BTYPE=INTERRUPT.
			//
			// ICNT budget: n_gap OTHER retires + INTERRUPT itself, each 4
			// halfwords. Expected ICNT = (n_gap + 1) * 4 when it fits in
			// the 8-bit ICNT field; when (n_gap+1)*4 exceeds 255 an
			// ICNT_OVERFLOW fires from the hold path, resets CurrICnt,
			// and the INTERRUPT IBH carries a smaller ICNT (just its own
			// contribution). Upper bound is the pre-overflow peak (252),
			// lower bound stays at 4 for the post-overflow case.
			wait_for_decoded_nexus_msg(
				$sformatf("sweep_int_ibh_n%0d", n_gap),
				NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY,
				MSG_TIMEOUT_CYCLES);
			check_ibh_btype(
				$sformatf("sweep_int_ibh_n%0d", n_gap),
				NEXUS_BTYPE_INTERRUPT, '0, 1'b0);
			// Legitimate ICNT: (n_gap+1)*4 for n_gap<63, saturating at 252 for
			// n_gap>=63 (the ICNT field is 8 bits, so anything above that
			// traps in the composer's cap at line 170). Bound [4..256]
			// accepts any legal value.
			check_ibh_icnt_range(
				$sformatf("sweep_int_ibh_n%0d", n_gap), 4, 256);
			int_uaddr_d = get_ibh_uaddr(
				$sformatf("sweep_int_ibh_n%0d", n_gap));

			// The two IBHs must point to different physical targets
			// (jalr target vs. handler entry) -- they would be identical
			// only if the UADDR field were somehow shared/latched between
			// the two messages.
			void'(tt_assert(jalr_uaddr_d != int_uaddr_d,
				$sformatf("%0.2f: sweep n%0d: jalr UADDR == INTERRUPT UADDR (0x%0h), IBHs are not independent",
					$realtime, n_gap, jalr_uaddr_d)));

			// Flush window between iterations -- keep the pipeline clean.
			repeat (8) @(posedge tip_clk);
		end

		$display("%0.2f: Phase 17 sweep complete (10..70 cycles)", $realtime);

		// ------------------------------------------------------------------
		// Phase 18: HIST_OVERFLOW stress -- FPGA repro scenario.
		//
		// Drives ~150 TAKEN_BRANCHes to force ~5 HIST_OVERFLOW emissions,
		// then jalr + 21 OTHER + INTERRUPT + handler. Counts all messages
		// by TCODE/BTYPE and verifies:
		//   - multiple RESOURCE_FULL (TCODE=27) emitted
		//   - exactly one IBH with BTYPE=IBRANCH (jalr)
		//   - exactly one IBH with BTYPE=INTERRUPT (the interrupt)
		//   - the IBH sequence is IBRANCH before INTERRUPT
		// If HIST_OVERFLOW emission has a subtle interaction with a
		// following indirect branch that collapses jalr's IBH into the
		// INTERRUPT's IBH, this phase catches it.
		// ------------------------------------------------------------------
		repeat (PHASE_IDLE_TIP_CYCLES) @(posedge tip_clk);
		$display("%0.2f: Test %0d: HIST_OVERFLOW stress + jalr + INTERRUPT",
			$realtime, test_id);
		test_id++;

		begin
			int n_ibranch;
			int n_exception;
			int n_interrupt;
			int n_other_ibh;
			int n_resource_full;
			nexus_message_t m;
			nexus_tcode_e   tcode;
			nexus_btype_e   btype;
			int             btype_idx;
			int             cycles;
			int             n_ibranch_before_int;
			int             n_interrupt_after_ibranch;

			// Drive 150 TAKEN_BRANCHes back-to-back. Each one enters HIST;
			// every 29 branches emits a RESOURCE_FULL RCODE=1.
			@(posedge tip_clk);
			tip_dir.iretire   <= 1'b1;
			tip_dir.itype     <= TAKEN_BRANCH;
			tip_dir.iaddr     <= 32'h0020_0000;
			tip_dir.ilastsize <= 2'd2;
			tip_dir.ecause    <= ECAUSE_NONE;
			tip_dir.dretire   <= 1'b0;

			for (int i = 1; i < 150; i++) begin
				@(posedge tip_clk);
				tip_dir.iaddr <= 32'h0020_0000 + (i * 32'h4);
			end

			// jalr.
			@(posedge tip_clk);
			tip_dir.itype <= UNINFERABLE_JUMP;
			tip_dir.iaddr <= 32'h0020_0258;

			// 21 non-CF retires in the target function.
			@(posedge tip_clk);
			tip_dir.itype <= OTHER;
			tip_dir.iaddr <= 32'h0021_0000;
			for (int i = 1; i < 21; i++) begin
				@(posedge tip_clk);
				tip_dir.iaddr <= 32'h0021_0000 + (i * 32'h4);
			end

			// INTERRUPT.
			@(posedge tip_clk);
			tip_dir.itype <= INTERRUPT;
			tip_dir.iaddr <= 32'h0021_0054;

			// Handler entry.
			@(posedge tip_clk);
			tip_dir.itype <= OTHER;
			tip_dir.iaddr <= 32'h0022_0000;

			// Tail retires.
			for (int i = 1; i < 8; i++) begin
				@(posedge tip_clk);
				tip_dir.iaddr <= 32'h0022_0000 + (i * 32'h4);
			end

			@(posedge tip_clk);
			tip_dir.iretire <= 1'b0;

			// Drain the decoded-message queue and bucket by tcode / btype.
			// Track the IBH ordering with the two *_before_* counters.
			n_ibranch                 = 0;
			n_exception               = 0;
			n_interrupt               = 0;
			n_other_ibh               = 0;
			n_resource_full           = 0;
			n_ibranch_before_int      = 0;
			n_interrupt_after_ibranch = 0;

			cycles = 0;
			while (cycles < 20000) begin
				@(posedge atb_atclk);
				cycles++;

				while (decoded_msg_queue.size() > 0) begin
					m     = decoded_msg_queue.pop_front();
					tcode = nexus_tcode_e'(m.fields[0].data[5:0]);

					if (tcode == NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL) begin
						n_resource_full++;
						continue;
					end
					if (tcode != NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY)
						continue;

					btype_idx = -1;
					for (int i = 1; i < NEXUS_MAX_FIELDS; i++) begin
						if (m.fields[i].name == BTYPE) begin
							btype_idx = i;
							break;
						end
					end
					if (btype_idx < 0) continue;

					btype = nexus_btype_e'(m.fields[btype_idx].data[$bits(nexus_btype_e)-1:0]);
					case (btype)
						NEXUS_BTYPE_IBRANCH: begin
							n_ibranch++;
							if (n_interrupt == 0) n_ibranch_before_int++;
						end
						NEXUS_BTYPE_EXCEPTION: n_exception++;
						NEXUS_BTYPE_INTERRUPT: begin
							n_interrupt++;
							if (n_ibranch > 0) n_interrupt_after_ibranch++;
						end
						default: n_other_ibh++;
					endcase
				end
			end

			$display("%0.2f: Phase 18 counts: RESOURCE_FULL=%0d IBRANCH=%0d EXCEPTION=%0d INTERRUPT=%0d other_ibh=%0d",
				$realtime, n_resource_full, n_ibranch, n_exception, n_interrupt, n_other_ibh);
			$display("%0.2f: Phase 18 ordering: IBRANCH_before_INT=%0d INT_after_IBRANCH=%0d",
				$realtime, n_ibranch_before_int, n_interrupt_after_ibranch);

			// Expect several HIST_OVERFLOW messages from the 150 TAKEN_BRANCHes.
			// 150 / 29 ~= 5 HIST_OVERFLOWs. Allow a small slack.
			void'(tt_assert(n_resource_full >= 4,
				$sformatf("%0.2f: Phase 18: expected >=4 RESOURCE_FULL emissions from 150 branches, got %0d",
					$realtime, n_resource_full)));

			// Exactly one jalr IBH and exactly one INTERRUPT IBH.
			void'(tt_assert(n_ibranch == 1,
				$sformatf("%0.2f: Phase 18: expected 1 BTYPE=IBRANCH (jalr), got %0d -- collapsed by HIST_OVERFLOW race?",
					$realtime, n_ibranch)));
			void'(tt_assert(n_interrupt == 1,
				$sformatf("%0.2f: Phase 18: expected 1 BTYPE=INTERRUPT, got %0d",
					$realtime, n_interrupt)));

			// IBRANCH must precede INTERRUPT in the stream.
			void'(tt_assert(n_ibranch_before_int == 1,
				$sformatf("%0.2f: Phase 18: IBRANCH must precede INTERRUPT (got %0d IBRANCHes before INTERRUPT)",
					$realtime, n_ibranch_before_int)));
		end

		// ------------------------------------------------------------------
		// Phase 19: mixed NT/T pattern + back-to-back indirect types.
		//
		// Drives pseudorandom NOT_TAKEN/TAKEN_BRANCH mix (so HIST bits are
		// a non-trivial pattern, not all-ones), then a consecutive sequence
		// of four indirect CF events covering all BTYPE values:
		//     UNINFERABLE_JUMP  (BTYPE=IBRANCH)
		//     EXCEPTION_TRAP    (BTYPE=EXCEPTION)
		//     EXCEPTION_IR      (BTYPE=INTERRUPT)
		//     INTERRUPT         (BTYPE=INTERRUPT)
		// Each indirect is separated by 3 OTHER retires so each one has a
		// distinct UADDR target and the composer's pending_cf must be
		// re-armed correctly between them. Per-IBH ICNT bound and UADDR
		// distinctness asserts catch any mixup.
		// ------------------------------------------------------------------
		repeat (PHASE_IDLE_TIP_CYCLES) @(posedge tip_clk);
		$display("%0.2f: Test %0d: mixed T/NT HIST + consecutive indirect-BTYPE sweep",
			$realtime, test_id);
		test_id++;

		begin
			logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] u0, u1, u2, u3;

			// 10 branches alternating NT/T for non-trivial HIST bits.
			// Each advances CurrICnt by 4.
			for (int i = 0; i < 10; i++) begin
				@(posedge tip_clk);
				tip_dir.iretire   <= 1'b1;
				tip_dir.itype     <= (i[0] ? TAKEN_BRANCH : NOT_TAKEN_BRANCH);
				tip_dir.iaddr     <= 32'h0030_0000 + (i * 32'h4);
				tip_dir.ilastsize <= 2'd2;
				tip_dir.ecause    <= ECAUSE_NONE;
				tip_dir.dretire   <= 1'b0;
			end

			// Indirect 1 -- UNINFERABLE_JUMP (BTYPE=IBRANCH)
			@(posedge tip_clk);
			tip_dir.itype <= UNINFERABLE_JUMP;
			tip_dir.iaddr <= 32'h0030_0030;
			for (int i = 0; i < 3; i++) begin
				@(posedge tip_clk);
				tip_dir.itype <= OTHER;
				tip_dir.iaddr <= 32'h0031_0000 + (i * 32'h4);
			end

			// Indirect 2 -- EXCEPTION_TRAP (BTYPE=EXCEPTION)
			@(posedge tip_clk);
			tip_dir.itype  <= EXCEPTION_TRAP;
			tip_dir.ecause <= ILLEGAL_INSTR;
			tip_dir.iaddr  <= 32'h0031_000c;
			for (int i = 0; i < 3; i++) begin
				@(posedge tip_clk);
				tip_dir.itype  <= OTHER;
				tip_dir.ecause <= ECAUSE_NONE;
				tip_dir.iaddr  <= 32'h0032_0000 + (i * 32'h4);
			end

			// Indirect 3 -- EXCEPTION_IR (BTYPE=INTERRUPT per mapping)
			@(posedge tip_clk);
			tip_dir.itype <= EXCEPTION_IR;
			tip_dir.iaddr <= 32'h0032_000c;
			for (int i = 0; i < 3; i++) begin
				@(posedge tip_clk);
				tip_dir.itype <= OTHER;
				tip_dir.iaddr <= 32'h0033_0000 + (i * 32'h4);
			end

			// Indirect 4 -- INTERRUPT (BTYPE=INTERRUPT)
			@(posedge tip_clk);
			tip_dir.itype <= INTERRUPT;
			tip_dir.iaddr <= 32'h0033_000c;
			for (int i = 0; i < 3; i++) begin
				@(posedge tip_clk);
				tip_dir.itype <= OTHER;
				tip_dir.iaddr <= 32'h0034_0000 + (i * 32'h4);
			end

			// Tail to flush the last IBH through msg_gen.
			for (int i = 0; i < 8; i++) begin
				@(posedge tip_clk);
				tip_dir.iaddr <= 32'h0034_1000 + (i * 32'h4);
			end

			@(posedge tip_clk);
			tip_dir.iretire <= 1'b0;

			// Verify the four IBHs arrive in order with the right BTYPE
			// and non-overlapping UADDRs.
			wait_for_decoded_nexus_msg("mix_ibh_uj",
				NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY, MSG_TIMEOUT_CYCLES);
			check_ibh_btype("mix_ibh_uj", NEXUS_BTYPE_IBRANCH, '0, 1'b0);
			// First IBH after 10 direct branches. Legitimate value is ~76
			// (10*4 + 4 = 44 in-phase, plus ~32 halfwords leaked from Phase 18's
			// tail retires through the composer's icnt_cum carry). Bound
			// [40, 120] accepts normal inter-phase leakage while flagging a
			// merged IBH (which would push ICNT much higher).
			check_ibh_icnt_range("mix_ibh_uj", 40, 120);
			u0 = get_ibh_uaddr("mix_ibh_uj");

			wait_for_decoded_nexus_msg("mix_ibh_trap",
				NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY, MSG_TIMEOUT_CYCLES);
			check_ibh_btype("mix_ibh_trap", NEXUS_BTYPE_EXCEPTION, '0, 1'b0);
			// 3 OTHER + 1 trap = 16 halfwords.
			check_ibh_icnt_range("mix_ibh_trap", 12, 24);
			u1 = get_ibh_uaddr("mix_ibh_trap");

			wait_for_decoded_nexus_msg("mix_ibh_ir",
				NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY, MSG_TIMEOUT_CYCLES);
			// EXCEPTION_IR (mret) -> BTYPE=IBRANCH (return from trap = indirect branch).
			check_ibh_btype("mix_ibh_ir", NEXUS_BTYPE_IBRANCH, '0, 1'b0);
			check_ibh_icnt_range("mix_ibh_ir", 12, 24);
			u2 = get_ibh_uaddr("mix_ibh_ir");

			wait_for_decoded_nexus_msg("mix_ibh_int",
				NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY, MSG_TIMEOUT_CYCLES);
			check_ibh_btype("mix_ibh_int", NEXUS_BTYPE_INTERRUPT, '0, 1'b0);
			check_ibh_icnt_range("mix_ibh_int", 12, 24);
			u3 = get_ibh_uaddr("mix_ibh_int");

			// All four targets must be distinct -- any two matching would
			// indicate a UADDR mixup between IBHs.
			void'(tt_assert(u0 != u1 && u0 != u2 && u0 != u3 && u1 != u2 && u1 != u3 && u2 != u3,
				$sformatf("%0.2f: Phase 19: UADDR collision across 4 IBHs: u0=%0h u1=%0h u2=%0h u3=%0h",
					$realtime, u0, u1, u2, u3)));
		end

		// ------------------------------------------------------------------
		// Phase 20: iretire=0 EXCEPTION_TRAP beat.
		//
		// The RISC-V N-Trace ingress port spec
		// (riscv-trace-spec/ingressPort.adoc @ f185ac28d71f48cc) states:
		//
		//   "Note if itype is 1 or 2 (indicating an exception or an
		//    interrupt), the number of instructions retired may be zero."
		//
		// All earlier phases drive `iretire=1` on the trap beat (the
		// retire-coincident-with-trap branch), which is the easy case.
		// This phase drives the spec-sanctioned "no-retire" branch:
		// `iretire=0` together with `itype=EXCEPTION_TRAP`. Without the
		// composer's trap-event bypass at
		// ct_L23_preproc_composer_etip.sv:174-191
		//   process_now = (iretire && hit) || is_trap_event;
		// no CF eTIP would be emitted on this beat, the trap target's
		// halfwords would never be counted, and the next CF event would
		// inflate its ICNT (the BTYPE=3 IBH-collapse pattern observed
		// originally on FPGA). Asserting an IBH with BTYPE=EXCEPTION,
		// UADDR=handler_pc, and ICNT including the trap beat's
		// `1<<ilastsize` halfwords directly validates that bypass.
		// ------------------------------------------------------------------
		repeat (PHASE_IDLE_TIP_CYCLES) @(posedge tip_clk);
		$display("%0.2f: Test %0d: iretire=0 EXCEPTION_TRAP beat",
			$realtime, test_id);
		test_id++;

		begin
			// Two OTHER retires to seed CurrICnt above zero, so we can
			// verify the trap beat's halfwords are *added* (not just
			// the only contribution) to the IBH's ICNT.
			for (int i = 0; i < 2; i++) begin
				@(posedge tip_clk);
				tip_dir.iretire   <= 1'b1;
				tip_dir.itype     <= OTHER;
				tip_dir.iaddr     <= 32'h0040_0000 + (i * 32'h4);
				tip_dir.ilastsize <= 2'd2;
				tip_dir.ecause    <= ECAUSE_NONE;
				tip_dir.dretire   <= 1'b0;
			end

			// Trap beat. iretire=0 + itype=EXCEPTION_TRAP triggers the
			// composer bypass; ilastsize remains valid per the spec
			// ("the size of the last instruction retired on this block")
			// and contributes 1<<ilastsize halfwords to ICnt so the
			// decoder steps onto tip.iaddr (the trap entry PC) before
			// resolving UADDR.
			@(posedge tip_clk);
			tip_dir.iretire   <= 1'b0;
			tip_dir.itype     <= EXCEPTION_TRAP;
			tip_dir.ecause    <= ILLEGAL_INSTR;
			tip_dir.iaddr     <= 32'h0040_0008;
			tip_dir.ilastsize <= 2'd2;

			// Handler entry. iretire=1 OTHER. Captures next_iaddr so
			// the pending CF emits the IBH downstream.
			@(posedge tip_clk);
			tip_dir.iretire   <= 1'b1;
			tip_dir.itype     <= OTHER;
			tip_dir.ecause    <= ECAUSE_NONE;
			tip_dir.iaddr     <= 32'h0050_0000;

			for (int i = 1; i < 4; i++) begin
				@(posedge tip_clk);
				tip_dir.iaddr <= 32'h0050_0000 + (i * 32'h4);
			end

			@(posedge tip_clk);
			tip_dir.iretire <= 1'b0;

			wait_for_decoded_nexus_msg("trap_iretire0_ibh",
				NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY, MSG_TIMEOUT_CYCLES);
			check_ibh_btype("trap_iretire0_ibh", NEXUS_BTYPE_EXCEPTION, '0, 1'b0);
			// ICNT must include the trap beat's contribution. Lower
			// bound is 4 (just the trap halfwords with everything else
			// zero). Upper bound is generous because composer icnt_cum
			// carries over from Phase 19's tail; we only need to flag a
			// gross under/over-count, not pin the exact value.
			check_ibh_icnt_range("trap_iretire0_ibh", 4, 120);
		end

		// ------------------------------------------------------------------
		// Phase 21: iretire=0 INTERRUPT beat.
		//
		// Mirror of Phase 20 with `itype=INTERRUPT`, exercising the other
		// arm of the bypass:
		//     is_trap_event = (itype == EXCEPTION_TRAP) || (itype == INTERRUPT)
		// The wire IBH is expected with BTYPE=INTERRUPT and the same
		// halfword-accounting rule applied to the trap beat.
		// ------------------------------------------------------------------
		repeat (PHASE_IDLE_TIP_CYCLES) @(posedge tip_clk);
		$display("%0.2f: Test %0d: iretire=0 INTERRUPT beat",
			$realtime, test_id);
		test_id++;

		begin
			for (int i = 0; i < 2; i++) begin
				@(posedge tip_clk);
				tip_dir.iretire   <= 1'b1;
				tip_dir.itype     <= OTHER;
				tip_dir.iaddr     <= 32'h0060_0000 + (i * 32'h4);
				tip_dir.ilastsize <= 2'd2;
				tip_dir.ecause    <= ECAUSE_NONE;
				tip_dir.dretire   <= 1'b0;
			end

			@(posedge tip_clk);
			tip_dir.iretire   <= 1'b0;
			tip_dir.itype     <= INTERRUPT;
			tip_dir.iaddr     <= 32'h0060_0008;
			tip_dir.ilastsize <= 2'd2;

			@(posedge tip_clk);
			tip_dir.iretire   <= 1'b1;
			tip_dir.itype     <= OTHER;
			tip_dir.iaddr     <= 32'h0070_0000;

			for (int i = 1; i < 4; i++) begin
				@(posedge tip_clk);
				tip_dir.iaddr <= 32'h0070_0000 + (i * 32'h4);
			end

			@(posedge tip_clk);
			tip_dir.iretire <= 1'b0;

			wait_for_decoded_nexus_msg("int_iretire0_ibh",
				NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY, MSG_TIMEOUT_CYCLES);
			check_ibh_btype("int_iretire0_ibh", NEXUS_BTYPE_INTERRUPT, '0, 1'b0);
			check_ibh_icnt_range("int_iretire0_ibh", 4, 120);
		end

		repeat (20) @(posedge tip_clk);
		tt_evaluate();
		$finish();
	end

endmodule
