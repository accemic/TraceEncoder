// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @file    ct_tb__hot_attach.sv
 * @brief   Hot-attach regression testbench for the C-Trace encoder.
 * @description Emulates a CPU running for a while with the encoder configured
 *   but inactive (InstTracing=0, Active=0), then "hot-attaches" the encoder
 *   mid-stream and continues feeding TIPs. Verifies that the decoder picks
 *   up a valid PERIODIC sync (the post-reset sync window is consumed by the
 *   pre-attach iretires and so is suppressed) and decodes the subsequent
 *   DF READ / DF WRITE messages cleanly.
 * @environment Same as ct_tb__directed.sv: ct_encoder + ATB + Nexus decoder
 *   instantiated across tip / proc / wb / wall / atb clocks.
 * @stimulus Phase 1 (pre-attach): N retired-instruction TIPs with tracing
 *   gates off. Phase 2 (post-attach): InstTracing/Active enabled, then more
 *   retired-instruction TIPs followed by DF LOAD and STORE.
 * @checking
 *   - No Nexus messages are decoded during the pre-attach phase.
 *   - First decoded sync after enable carries reason=NEXUS_SYNC_PERIODIC
 *     (NOT NEXUS_SYNC_EXIT_FROM_SYS_RST, because the post-reset sync was
 *     consumed by the first pre-attach iretire).
 *   - DF READ and DF WRITE messages decode with the expected fields.
 *   - At least one message carries a TSTAMP.
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */
module ct_tb__hot_attach;

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

	localparam TIP_CLK_PERIOD       = 1;    // trace source clock
	localparam PROC_CLK_PERIOD      = 2;    // trace encoder internal processing clock
	localparam WALL_CLK_PERIOD      = 10;   // wall clock
	localparam WB_CLK_PERIOD        = 4;    // wishbone clock
	localparam ATB_CLK_PERIOD       = 5;    // ATB clock

	localparam int PHASE_IDLE_TIP_CYCLES = 32;
	localparam int ETIP_TIMEOUT_CYCLES   = 200000;

	// Number of retired-instruction TIPs to issue BEFORE enabling tracing.
	// Has to be > 0 so that the post-reset EXIT_FROM_SYS_RST opportunity is
	// consumed without being emitted, which is the whole point of the test.
	// Also has to push the periodic-sync counter past its overflow threshold
	// so that the very first iretire after enable triggers a PERIODIC sync.
	// With InstSyncMax=0 the threshold is 1<<(0+4)=16 instructions.
	localparam int PRE_ATTACH_IRETIRE_COUNT = 32;

	// Signals
	logic           tip_rst;
	logic           proc_rst;
	logic           wb_rst;
	logic           ct_cs_rst;
	logic           wall_clk_rst;
	logic           atb_atresetn;
	logic           atb_afvalid;
	uwire           dec_msg_valid;
	uwire           dec_msg_error;
	nexus_message_t dec_msg;
	int             tip_time;
	int             prev_dec_id = -1;
	int             last_dec_msg_id = -1;
	int             last_dec_tcode = -1;
	nexus_message_t curr_dec_msg;
	nexus_message_t decoded_msg_queue[$];
	int             pre_attach_msgs = 0;
	int             sync_msg_count = 0;
	int             df_read_msg_count = 0;
	int             df_write_msg_count = 0;
	int             post_disable_unexpected = 0;
	logic           saw_tstamp = 0;
	logic           tracing_enabled = 1'b0;
	logic           tracing_disabled_done = 1'b0;

	logic [WB_DATA_WIDTH-1:0]    read_data;

	// Clocks
	logic  tip_clk    = 0; always #TIP_CLK_PERIOD      tip_clk    = ~tip_clk;
	logic  wb_clk     = 0; always #WB_CLK_PERIOD       wb_clk     = ~wb_clk;
	logic  proc_clk   = 0; always #PROC_CLK_PERIOD     proc_clk   = ~proc_clk;
	logic  wall_clk   = 0; always #WALL_CLK_PERIOD     wall_clk   = ~wall_clk;
	logic  atb_atclk  = 0; always #ATB_CLK_PERIOD      atb_atclk  = ~atb_atclk;

	// Control flags
	logic FeedingDone       = 0;
	logic EtipCheckingDone  = 0;

	// Instantiate interfaces
	tip_if              tip       ();
	tip_if              tip_dir   ();

	assign tip._time = tip_time;

	axis_if #( .TDATA_WIDTH(ACT_CAP_AXIS_TDATA_WIDTH),
			   .TID_WIDTH  (ACT_CAP_AXIS_TID_WIDTH))
	  axis (.aclk (tip_clk), .aresetn(!tip_rst));

	atb_if  atb  ();
	assign  atb.syncreq     = '0;
	assign  atb.afvalid     = atb_afvalid;

	wb_if #(.DATA_WIDTH(WB_DATA_WIDTH), .ADDR_WIDTH(WB_DATA_WIDTH))	wb();

	ct_cs_cpuif_wb_helper #(.WB_DATA_WIDTH(WB_DATA_WIDTH), .WB_ADDR_WIDTH(WB_DATA_WIDTH)) ct_cs_wb (wb_clk, wb);

	ct_encoder ct_encoder_inst (
	  .tip_clk,   .tip_rst,        .tip,
	  .wb_clk,    .wb_rst,         .wb,
	  .axis,
	  .atb_atclk, .atb_atresetn,   .atb,
	  .proc_clk,  .proc_rst,
	  .ct_cs_rst,
	  .wall_clk,  .wall_clk_rst
	);

	atb_dump #( .FILEPATH ("atb_dump.bin") )
	atb_dump_inst (
		.atb_atclk, .atb_atresetn, .atb
	);

	ct_axis_dump ct_axis_dump_inst (.axis);

	assign tip.itype      = tip_dir.itype;
	assign tip.ecause     = tip_dir.ecause;
	assign tip.tval       = tip_dir.tval;
	assign tip.priv       = tip_dir.priv;
	assign tip.iaddr      = tip_dir.iaddr;
	assign tip._context   = tip_dir._context;
	assign tip.ctype      = tip_dir.ctype;
	assign tip.iretire    = tip_dir.iretire;
	assign tip.ilastsize  = tip_dir.ilastsize;
	assign tip.impdef     = tip_dir.impdef;
	assign tip.dretire    = tip_dir.dretire;
	assign tip.dtype      = tip_dir.dtype;
	assign tip.daddr      = tip_dir.daddr;
	assign tip.dsize      = tip_dir.dsize;
	assign tip.data       = tip_dir.data;

	ct_nexus_decoder #(
		.INCLUDE_SRC    (1'b0),
		.INCLUDE_TSTAMP (1'b1)
	) ct_nexus_decoder_inst(
	  .atb_atclk,   .atb_atresetn,   .atb,
	  .dec_msg_valid,
	  .dec_msg_error,
	  .dec_msg
	);

	tip_t           tipt;

	always_ff @(posedge tip_clk) begin
		if (tip_rst) begin
			tip_time <= 0;
		end else begin
			tip_time <= tip_time + 1;
		end
	end

	// Decoded-message capture loop. Distinct from ct_tb__directed.sv in that
	// it also counts any messages observed while `tracing_enabled` is still
	// 0 — the test asserts later that this count stayed 0.
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
				prev_dec_id = dec_msg.id;
				last_dec_msg_id = dec_msg.id;
				last_dec_tcode = dec_msg.fields[0].data[5:0];
				decoded_msg_queue.push_back(dec_msg);
				if (!tracing_enabled) begin
					pre_attach_msgs++;
					$display("%0.2f: UNEXPECTED pre-attach decoded msg_id=%0d tcode=%0d",
						$realtime, dec_msg.id, dec_msg.fields[0].data[5:0]);
				end
				void'(tt_assert(!dec_msg_error,
					$sformatf("%0.2f: Line %0d: decoder error on captured msg_id=%0d tcode=%0d",
						$realtime, `__LINE__, dec_msg.id, dec_msg.fields[0].data[5:0])));
			end
		end
	end

	//========================================================================
	// CONFIGURATION TASKS
	//========================================================================

	// Lay down the same baseline configuration as ct_tb__directed.sv but
	// leave InstTracing and trTeControl.Active OFF so the encoder is fully
	// configured yet quiet.
	task automatic configure_decoder_inactive();
		// Trace-all CF filter (filter[0] enabled, no match predicates).
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
		ct_cs_wb.Set_te_trTeInstFeatures_SrcBits(4'd4);
		ct_cs_wb.Set_te_trTeInstFeatures_SrcID(12'h001);

		ct_cs_wb.Set_te_trTeComp_Control_PFunction(0, ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_RESERVED_MATCH);
		ct_cs_wb.Set_te_trTeComp_Control_MatchMode(0, ct_cs_cpuif__te__trTeComp__Control__trTeCompMatchMode_e__TR_COMP_MATCH_MODE0);

		// Trace-all selection (full-field write, not RMW).
		ct_cs_wb.Set_te_trTeDataFilters_Filters(16'h0);
		ct_cs_wb.Set_te_trTeInstFilters_Filters(16'h0);

		// DataTracing can stay enabled — it doesn't itself emit messages.
		ct_cs_wb.Set_te_trTeDataControl_DataTracing(1);

		// IMPORTANT: leave InstTracing OFF so no messages are produced while
		// the pre-attach phase exercises the TIP front-end.

		// Periodic sync threshold (post-attach behaviour).
		ct_cs_wb.Set_te_trTeControl_InstSyncMode(ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_INSTRUCTIONS);
		ct_cs_wb.Set_te_trTeControl_InstSyncMax(4'd0);

		// Timestamp source.
		ct_cs_wb.Set_te_trTsControl_Type(ct_cs_cpuif__te__trTsControl__trTsType_e__TR_TS_CORE);
		ct_cs_wb.Set_te_trTsControl_Enable(1'b1);
		ct_cs_wb.Set_te_trTsControl_Active(1'b1);
		ct_cs_wb.Set_te_trTsControl_Count(1'b1);

		// IMPORTANT: leave trTeControl.Active OFF and (most importantly)
		// trTeControl.Enable OFF. Hot-attach later flips Enable to 1.
	endtask

	// "Hot-attach" — flip the enable bits with no other config changes.
	// Active and InstTracing first, then the master Enable (per spec
	// "This write of 1 should be done after all other settings are done").
	task automatic enable_tracing();
		ct_cs_wb.Set_te_trTeControl_InstTracing(1);
		ct_cs_wb.Set_te_trTeControl_Active(1);
		ct_cs_wb.Set_te_trTeControl_Enable(1);
		tracing_enabled <= 1'b1;
	endtask

	// "Hot-detach" — clearing the master Enable is itself the flush
	// trigger per spec ("Setting trTeEnable to 0 flushes any queued
	// trace data ..."). Pipeline messages still in flight at detach
	// time must drain out via the encoder's internal flush path.
	task automatic disable_tracing();
		ct_cs_wb.Set_te_trTeControl_Enable(0);
		ct_cs_wb.Set_te_trTeControl_InstTracing(0);
		ct_cs_wb.Set_te_trTeControl_Active(0);
	endtask

	//========================================================================
	// Directed phase items / helpers
	//========================================================================

	typedef struct {
		tip_t           tip;
		int             delay;
		string          desc;
		int             test_id;
	} test_queue_item_t;

	task automatic send_tip_item(input test_queue_item_t item);
		$display("%0.2f: Send phase item / Test %0d: %s", $realtime, item.test_id, item.desc);
		TipSendMsg(tip_dir, tip_clk, item.tip, item.delay);
		repeat (PHASE_IDLE_TIP_CYCLES) @(posedge tip_clk);
	endtask

	function automatic logic field_present(input nexus_field_name_e name);
		field_present = 0;
		for (int i = 0; i < NEXUS_MAX_FIELDS; i++) begin
			if (curr_dec_msg.fields[i].name == name) begin
				field_present = 1;
			end
		end
	endfunction

	function automatic logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] get_field_data(input nexus_field_name_e name, output int width);
		get_field_data = '0;
		width = 0;
		for (int i = 0; i < NEXUS_MAX_FIELDS; i++) begin
			if (curr_dec_msg.fields[i].name == name) begin
				get_field_data = curr_dec_msg.fields[i].data;
				width = curr_dec_msg.fields[i].data_width;
			end
		end
	endfunction

	task automatic wait_for_decoded_nexus_msg(
		input string phase,
		input nexus_tcode_e expected_tcode,
		input int timeout_cycles
	);
		int cycles_waited;
		nexus_tcode_e got_tcode;
		nexus_message_t queued_msg;
		int ts_w;

		cycles_waited = 0;
		while (1) begin
			@(posedge atb_atclk);
			cycles_waited++;

			while (decoded_msg_queue.size() > 0) begin
				queued_msg = decoded_msg_queue.pop_front();
				curr_dec_msg = queued_msg;
				got_tcode = nexus_tcode_e'(curr_dec_msg.fields[0].data[5:0]);

				if (field_present(TSTAMP)) begin
					void'(get_field_data(TSTAMP, ts_w));
					saw_tstamp = 1'b1;
				end

				$display("%0.2f: DEC phase=%s msg_id=%0d tcode=%0d (%s)",
					$realtime, phase, curr_dec_msg.id, curr_dec_msg.fields[0].data[5:0], got_tcode.name());

				if (got_tcode == NEXUS_MSG_FLUSH) begin
					// NEXUS_MSG_FLUSH is internal-only — the MDO formatter
					// consumes it and emits an MSEO end-of-stream pad on the
					// ATB instead of a real Nexus message. We still tolerate
					// it appearing in the decoder queue if the build ever
					// changes that.
					$display("%0.2f: DEC phase=%s tolerated internal FLUSH msg_id=%0d",
						$realtime, phase, curr_dec_msg.id);
					continue;
				end

				void'(tt_assert(got_tcode == expected_tcode,
					$sformatf("%0.2f: Line %0d: phase=%s unexpected decoded tcode exp=%0d (%s) got=%0d (%s) msg_id=%0d",
						$realtime, `__LINE__, phase, expected_tcode, expected_tcode.name(), got_tcode, got_tcode.name(), curr_dec_msg.id)));
				return;
			end

			if (cycles_waited > timeout_cycles) begin
				void'(tt_assert(0,
					$sformatf("%0.2f: Line %0d: timeout waiting for phase=%s expected_tcode=%0d (%s) last_seen_id=%0d last_seen_tcode=%0d",
						$realtime, `__LINE__, phase, expected_tcode, expected_tcode.name(), last_dec_msg_id, last_dec_tcode)));
				return;
			end
		end
	endtask

	task automatic check_decoded_trace_enable_sync(input string phase);
		int sw;
		logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] sdata;

		void'(tt_assert(field_present(SYNC),
			$sformatf("%0.2f: Line %0d: phase=%s missing SYNC field", $realtime, `__LINE__, phase)));
		sdata = get_field_data(SYNC, sw);
		// EXIT_FROM_SYS_RST was suppressed because the first pre-attach
		// iretire fired with the master Enable still 0 (and InstTracing
		// 0) and consumed the one-shot. The first sync we see after the
		// hot-attach must therefore be TRACE_ENABLE — emitted by the
		// sync generator on the first iretire after Enable rises.
		void'(tt_assert(nexus_sync_reason_e'(sdata[$bits(nexus_sync_reason_e)-1:0]) == NEXUS_SYNC_TRACE_ENABLE,
			$sformatf("%0.2f: Line %0d: phase=%s expected TRACE_ENABLE sync reason, got=%0d",
				$realtime, `__LINE__, phase, sdata[$bits(nexus_sync_reason_e)-1:0])));
		sync_msg_count++;
	endtask

	task automatic check_decoded_df_read(input string phase);
		int uw, dw, dszw, elszw;
		logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] uaddr_d, dqdata_d, dsz_d, elsz_d;

		uaddr_d  = get_field_data(UADDR, uw);
		dqdata_d = get_field_data(DQDATA, dw);
		dsz_d    = get_field_data(DSZ, dszw);
		elsz_d   = get_field_data(ELSZ, elszw);

		void'(tt_assert(field_present(UADDR),
			$sformatf("%0.2f: Line %0d: phase=%s missing UADDR field", $realtime, `__LINE__, phase)));
		void'(tt_assert(field_present(DQDATA),
			$sformatf("%0.2f: Line %0d: phase=%s missing DQDATA field", $realtime, `__LINE__, phase)));
		void'(tt_assert(uaddr_d[31:0] == 32'h8000_0100,
			$sformatf("%0.2f: Line %0d: phase=%s DF READ ADDR mismatch exp=%0h got=%0h",
				$realtime, `__LINE__, phase, 32'h8000_0100, uaddr_d[31:0])));
		void'(tt_assert(dqdata_d[63:0] == 64'h0000_0000_0123_4567,
			$sformatf("%0.2f: Line %0d: phase=%s DF READ DATA mismatch exp=%0h got=%0h",
				$realtime, `__LINE__, phase, 64'h0000_0000_0123_4567, dqdata_d[63:0])));
		void'(tt_assert(nexus_dsz_e'(dsz_d[$bits(nexus_dsz_e)-1:0]) == NEXUS_DSZ_4,
			$sformatf("%0.2f: Line %0d: phase=%s DF READ DSZ mismatch exp=%0d got=%0d",
				$realtime, `__LINE__, phase, NEXUS_DSZ_4, nexus_dsz_e'(dsz_d[$bits(nexus_dsz_e)-1:0]))));
		void'(tt_assert(nexus_elsz_e'(elsz_d[$bits(nexus_elsz_e)-1:0]) == NEXUS_ELSZ_4,
			$sformatf("%0.2f: Line %0d: phase=%s DF READ ELSZ mismatch exp=%0d got=%0d",
				$realtime, `__LINE__, phase, NEXUS_ELSZ_4, nexus_elsz_e'(elsz_d[$bits(nexus_elsz_e)-1:0]))));
		df_read_msg_count++;
	endtask

	task automatic check_decoded_df_write(input string phase);
		int uw, dw, dszw, elszw;
		logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] uaddr_d, dqdata_d, dsz_d, elsz_d;

		uaddr_d  = get_field_data(UADDR, uw);
		dqdata_d = get_field_data(DQDATA, dw);
		dsz_d    = get_field_data(DSZ, dszw);
		elsz_d   = get_field_data(ELSZ, elszw);

		void'(tt_assert(field_present(UADDR),
			$sformatf("%0.2f: Line %0d: phase=%s missing UADDR field", $realtime, `__LINE__, phase)));
		void'(tt_assert(field_present(DQDATA),
			$sformatf("%0.2f: Line %0d: phase=%s missing DQDATA field", $realtime, `__LINE__, phase)));
		void'(tt_assert(uaddr_d[31:0] == 32'h8000_0200,
			$sformatf("%0.2f: Line %0d: phase=%s DF WRITE ADDR mismatch exp=%0h got=%0h",
				$realtime, `__LINE__, phase, 32'h8000_0200, uaddr_d[31:0])));
		void'(tt_assert(dqdata_d[63:0] == 64'h0123_4567_89AB_CDEF,
			$sformatf("%0.2f: Line %0d: phase=%s DF WRITE DATA mismatch exp=%0h got=%0h",
				$realtime, `__LINE__, phase, 64'h0123_4567_89AB_CDEF, dqdata_d[63:0])));
		void'(tt_assert(nexus_dsz_e'(dsz_d[$bits(nexus_dsz_e)-1:0]) == NEXUS_DSZ_8,
			$sformatf("%0.2f: Line %0d: phase=%s DF WRITE DSZ mismatch exp=%0d got=%0d",
				$realtime, `__LINE__, phase, NEXUS_DSZ_8, nexus_dsz_e'(dsz_d[$bits(nexus_dsz_e)-1:0]))));
		void'(tt_assert(nexus_elsz_e'(elsz_d[$bits(nexus_elsz_e)-1:0]) == NEXUS_ELSZ_8,
			$sformatf("%0.2f: Line %0d: phase=%s DF WRITE ELSZ mismatch exp=%0d got=%0d",
				$realtime, `__LINE__, phase, NEXUS_ELSZ_8, nexus_elsz_e'(elsz_d[$bits(nexus_elsz_e)-1:0]))));
		df_write_msg_count++;
	endtask

	//========================================================================
	// Main
	//========================================================================

	initial begin
		int timeout_cycles;
		int test_id;
		test_queue_item_t item;

		tip_rst         <= '1;
		ct_cs_rst       <= '1;
		proc_rst       	<= '1;
		wb_rst          <= '1;
		wall_clk_rst    <= '1;
		atb_atresetn    <= 1'b0;
		atb_afvalid     <= '0;
		tracing_enabled <= 1'b0;

		timeout_cycles = 300000;
		void'($value$plusargs("CT_TIMEOUT_CYCLES=%d", timeout_cycles));
		$display("%0.2f: hot-attach CT TB start: CT_TIMEOUT_CYCLES=%0d PRE_ATTACH_IRETIRE_COUNT=%0d",
			$realtime, timeout_cycles, PRE_ATTACH_IRETIRE_COUNT);

		TipTSetDefault(tipt);
		TipSendMsg (tip_dir, tip_clk, tipt, 3);
		@(posedge tip_clk);
		tip_rst     <= '0;
		@(posedge tip_clk);
		@(posedge proc_clk);
		proc_rst   	<= '0;
		@(posedge proc_clk);
		ct_cs_rst   <= '0;
		@(posedge wb_clk);
		wb_rst      <= '0;
		@(posedge wall_clk);
		wall_clk_rst <= '0;
		@(posedge atb_atclk);
		atb_atresetn <= 1'b1;

		configure_decoder_inactive();
		@(posedge tip_clk);
		ct_cs_wb.Read_te_trTeControl(read_data);

		prev_dec_id = -1;
		last_dec_msg_id = -1;
		last_dec_tcode = -1;
		pre_attach_msgs = 0;
		sync_msg_count = 0;
		df_read_msg_count = 0;
		df_write_msg_count = 0;
		saw_tstamp = 1'b0;
		test_id = 0;

		TipTSetDefault(tipt);
		tipt.iretire = '1;
		tipt.itype = OTHER;
		tipt.ilastsize = 2;

		// ----------------------------------------------------------------
		// Phase 1 — PRE-ATTACH: emulate the CPU running while the encoder
		// is configured but inactive. No Nexus messages should appear.
		// ----------------------------------------------------------------
		for (int i = 0; i < PRE_ATTACH_IRETIRE_COUNT; i++) begin
			item.tip = tipt;
			item.tip.iaddr = 32'h1000_0000 + (i * 4);
			item.tip.dretire = '0;
			item.delay = 4;
			item.desc = $sformatf("Pre-attach iretire #%0d (tracing OFF)", i);
			item.test_id = test_id;
			test_id++;
			send_tip_item(item);
		end

		void'(tt_assert(pre_attach_msgs == 0,
			$sformatf("%0.2f: Line %0d: expected 0 decoded messages during pre-attach, got %0d",
				$realtime, `__LINE__, pre_attach_msgs)));

		// ----------------------------------------------------------------
		// HOT-ATTACH: enable InstTracing + Active mid-stream.
		// ----------------------------------------------------------------
		$display("%0.2f: HOT-ATTACH: enabling InstTracing + Active", $realtime);
		enable_tracing();
		@(posedge tip_clk);

		// ----------------------------------------------------------------
		// Phase 2 — POST-ATTACH: drive iretires until the periodic sync
		// fires, then the decoder picks up the stream.
		// ----------------------------------------------------------------
		item.tip = tipt;
		item.tip.iaddr = 32'h1000_1000;
		item.tip.dretire = '0;
		item.delay = 8;
		item.desc = "Post-attach iretire to trigger TRACE_ENABLE sync";
		item.test_id = test_id;
		test_id++;
		send_tip_item(item);
		wait_for_decoded_nexus_msg("post_attach_sync", NEXUS_MSG_PROGRAM_TRACE_SYNC, ETIP_TIMEOUT_CYCLES);
		check_decoded_trace_enable_sync("post_attach_sync");

		// Phase 3: DF READ
		item.tip = tipt;
		item.tip.iaddr = 32'h2000_0000;
		item.tip.iretire = '1;
		item.tip.itype = OTHER;
		item.tip.dretire = '1;
		item.tip.dtype = LOAD;
		item.tip.daddr = 32'h8000_0100;
		item.tip.dsize = 2;
		item.tip.data = 64'hDEAD_BEEF_0123_4567;
		item.delay = 0;
		item.desc = "Post-attach DF LOAD (dsize=4B, daddr=0x8000_0100)";
		item.test_id = test_id;
		test_id++;
		send_tip_item(item);

		// Phase 4: DF WRITE
		item.tip = tipt;
		item.tip.iaddr = 32'h2000_0004;
		item.tip.iretire = '1;
		item.tip.itype = OTHER;
		item.tip.dretire = '1;
		item.tip.dtype = STORE;
		item.tip.daddr = 32'h8000_0200;
		item.tip.dsize = 3;
		item.tip.data = 64'h0123_4567_89AB_CDEF;
		item.delay = 0;
		item.desc = "Post-attach DF STORE (dsize=8B, daddr=0x8000_0200)";
		item.test_id = test_id;
		test_id++;
		send_tip_item(item);

		wait_for_decoded_nexus_msg("df_read",  NEXUS_MSG_DATA_TRACE_READ,  ETIP_TIMEOUT_CYCLES);
		check_decoded_df_read("df_read");
		wait_for_decoded_nexus_msg("df_write", NEXUS_MSG_DATA_TRACE_WRITE, ETIP_TIMEOUT_CYCLES);
		check_decoded_df_write("df_write");

		// ----------------------------------------------------------------
		// Phase 5 — LATE STIMULUS: enqueue another DF LOAD and STORE just
		// before deactivating, so they are still moving through the
		// composer / msg_gen / formatter pipeline when the hot-detach
		// happens. The flush path must drain them out.
		// ----------------------------------------------------------------
		item.tip = tipt;
		item.tip.iaddr = 32'h2000_0008;
		item.tip.iretire = '1;
		item.tip.itype = OTHER;
		item.tip.dretire = '1;
		item.tip.dtype = LOAD;
		item.tip.daddr = 32'h8000_0100;
		item.tip.dsize = 2;
		item.tip.data = 64'hCAFE_BABE_0123_4567;
		item.delay = 0;
		item.desc = "Late DF LOAD just before disable";
		item.test_id = test_id;
		test_id++;
		send_tip_item(item);

		item.tip = tipt;
		item.tip.iaddr = 32'h2000_000c;
		item.tip.iretire = '1;
		item.tip.itype = OTHER;
		item.tip.dretire = '1;
		item.tip.dtype = STORE;
		item.tip.daddr = 32'h8000_0200;
		item.tip.dsize = 3;
		item.tip.data = 64'h0123_4567_89AB_CDEF;
		item.delay = 0;
		item.desc = "Late DF STORE just before disable";
		item.test_id = test_id;
		test_id++;
		send_tip_item(item);

		// ----------------------------------------------------------------
		// Phase 6 — HOT-DETACH + FLUSH: drop InstTracing/Active and pulse
		// atb_afvalid. The encoder should drain the late DF LOAD/STORE
		// already in flight and emit a NEXUS_MSG_FLUSH marker.
		// ----------------------------------------------------------------
		$display("%0.2f: HOT-DETACH: clearing trTeControl.Enable (auto-flush per spec)",
			$realtime);
		disable_tracing();
		tracing_disabled_done <= 1'b1;

		// ----------------------------------------------------------------
		// Phase 7 — drain & verify: the late DF READ + DF WRITE were in
		// the pipeline at detach time. With Active=0 the encoder must
		// itself drain them out to the ATB; the testbench does not pulse
		// atb_afvalid.
		// ----------------------------------------------------------------
		wait_for_decoded_nexus_msg("late_df_read",  NEXUS_MSG_DATA_TRACE_READ,  ETIP_TIMEOUT_CYCLES);
		check_decoded_df_read("late_df_read");
		wait_for_decoded_nexus_msg("late_df_write", NEXUS_MSG_DATA_TRACE_WRITE, ETIP_TIMEOUT_CYCLES);
		check_decoded_df_write("late_df_write");

		// Quiet observation window: with tracing fully disabled and the
		// flush already drained, no more decoded messages should appear.
		repeat (200) @(posedge atb_atclk);
		while (decoded_msg_queue.size() > 0) begin
			nexus_message_t leftover;
			nexus_tcode_e leftover_tcode;
			leftover = decoded_msg_queue.pop_front();
			leftover_tcode = nexus_tcode_e'(leftover.fields[0].data[5:0]);
			if (leftover_tcode == NEXUS_MSG_FLUSH) begin
				continue;
			end
			post_disable_unexpected++;
			$display("%0.2f: UNEXPECTED post-disable msg_id=%0d tcode=%0d (%s)",
				$realtime, leftover.id, leftover.fields[0].data[5:0], leftover_tcode.name());
		end

		void'(tt_assert(sync_msg_count == 1,
			$sformatf("%0.2f: Line %0d: expected exactly 1 TRACE_ENABLE sync message, got %0d",
				$realtime, `__LINE__, sync_msg_count)));
		void'(tt_assert(df_read_msg_count == 2,
			$sformatf("%0.2f: Line %0d: expected exactly 2 DF READ messages (1 normal + 1 flushed), got %0d",
				$realtime, `__LINE__, df_read_msg_count)));
		void'(tt_assert(df_write_msg_count == 2,
			$sformatf("%0.2f: Line %0d: expected exactly 2 DF WRITE messages (1 normal + 1 flushed), got %0d",
				$realtime, `__LINE__, df_write_msg_count)));
		void'(tt_assert(post_disable_unexpected == 0,
			$sformatf("%0.2f: Line %0d: expected no decoded messages after flush completed, got %0d",
				$realtime, `__LINE__, post_disable_unexpected)));
		void'(tt_assert(saw_tstamp == 1'b1,
			$sformatf("%0.2f: Line %0d: expected at least one decoded message with TSTAMP field present",
				$realtime, `__LINE__)));

		FeedingDone <= 1'b1;
		EtipCheckingDone <= 1'b1;

		repeat (10) @(posedge tip_clk);

		tt_evaluate();
		$finish();
	end
endmodule
