// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @file    ct_tb__directed.sv
 * @brief   Directed regression testbench for the C-Trace encoder.
 * @description Exercises the C-Trace encoder with directed smoke and data-
 *   trace scenarios and decodes Nexus output for end-to-end checking.
 * @environment Instantiates ct_encoder, AXIS and Nexus decoders, Wishbone
 *   control helpers, and the ATB path across tip, proc, wb, wall, and ATB
 *   clocks.
 * @stimulus Queues directed sync smoke and DF scenarios.
 * @checking Uses decoded Nexus messages to verify data-trace read and write
 *   messages, timestamp presence, and overall smoke test progress.
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
*/
module ct_tb__directed;

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

	localparam TIP_CLK_PERIOD       =  5.0;   // trace source clock
	localparam PROC_CLK_PERIOD      =  3.3;   // trace encoder internal processing clock
	localparam WALL_CLK_PERIOD      = 50.0;   // wall clock
	localparam WB_CLK_PERIOD        =  5.0;   // wishbone clock
	localparam ATB_CLK_PERIOD       =  5.0;   // ATB clock

	localparam int DELAY_CYCLES = 0;
	localparam int PHASE_IDLE_TIP_CYCLES = 32;
	localparam int ETIP_TIMEOUT_CYCLES = 200000;

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
	int             sync_msg_count = 0;
	int             df_read_msg_count = 0;
	int             df_write_msg_count = 0;
	logic           saw_tstamp = 0;

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
	// Keep legacy instance name "tip" for wave configs / debug scripts.
	tip_if              tip       ();
	tip_if              tip_dir   ();

	// Always provide a monotonic time base (timestamp source) to the DUT-facing TIP.
	assign tip._time = tip_time;

	axis_if #( .TDATA_WIDTH(ACT_CAP_AXIS_TDATA_WIDTH),
			   .TID_WIDTH  (ACT_CAP_AXIS_TID_WIDTH))
	  axis (.aclk (tip_clk), .aresetn(!tip_rst));

	atb_if  atb  ();
	assign  atb.syncreq     = '0;
	assign  atb.afvalid     = atb_afvalid;

	wb_if #(.DATA_WIDTH(WB_DATA_WIDTH), .ADDR_WIDTH(WB_DATA_WIDTH))	wb();

	// Instantiate ct_cs_wb module
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

	tip_t           tipt;    // struct with tip_if signals

	//========================================================================
	// TIP time base (timestamp source)
	//========================================================================
	// The implementation path uses tip._time as timestamp source in the eTIP composer.
	// We need a monotonic time base so we can assert TSTAMP behavior.
	always_ff @(posedge tip_clk) begin
		if (tip_rst) begin
			tip_time <= 0;
		end else begin
			tip_time <= tip_time + 1;
		end
	end

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
				void'(tt_assert(!dec_msg_error,
					$sformatf("%0.2f: Line %0d: decoder error on captured msg_id=%0d tcode=%0d",
						$realtime, `__LINE__, dec_msg.id, dec_msg.fields[0].data[5:0])));
			end
		end
	end

	//========================================================================
	// CONFIGURATION TASK
	//========================================================================

	// Configure for Phase-1 MVP:
	// - trace-all for CF/DF (disable filter masks) so stimuli aren't accidentally blocked
	// - enable InstTracing/DataTracing
	// - enable periodic sync with small threshold
	// - enable timestamps in nexus formatter
	task automatic configure_decoder();
		// --- Make CF path unconditionally active (required for periodic sync messages) ---
		// Rationale:
		// The sync generator produces `sync.reason`, but the ETIP composer only emits a
		// PROGRAM_TRACE_SYNC message when the CF-qualifier pipeline (`ct_L23_preproc_cf`)
		// indicates a CF hit. With default filter enable state, CF can be blocked even
		// though InstFilters mask is set to 0.
		//
		// Therefore we enable filter[0] with no active match predicates, which makes
		// pred_ok==1 and thus cf_filter.hit==1 (trace-all).
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

		// Keep SRC inhibited so the internal decoder and NexRv replay use the
		// same no-SRC message format.
		ct_cs_wb.Set_te_trTeControl_InhibitSrc(1'b1);
		ct_cs_wb.Set_te_trTeInstFeatures_SrcBits(4'd4);
		ct_cs_wb.Set_te_trTeInstFeatures_SrcID(12'h001);

		// Comparator config doesn't matter when masks are 0, but keep it deterministic.
		ct_cs_wb.Set_te_trTeComp_Control_PFunction(0, ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_RESERVED_MATCH);
		ct_cs_wb.Set_te_trTeComp_Control_MatchMode(0, ct_cs_cpuif__te__trTeComp__Control__trTeCompMatchMode_e__TR_COMP_MATCH_MODE0);

		// TRACE-ALL policy per spec / comp_filters implementation:
		// if filter selection mask is zero, unconditional tracing is performed.
		// IMPORTANT: use the full-field writer, not SetMask_ (which does read-modify-write).
		// We want to force the whole selection vector to 0.
		ct_cs_wb.Set_te_trTeDataFilters_Filters(16'h0);
		ct_cs_wb.Set_te_trTeInstFilters_Filters(16'h0);

		// Enable tracing
		// DataTracing lives in trTeDataControl (not trTeControl)
		ct_cs_wb.Set_te_trTeDataControl_DataTracing(1);
		ct_cs_wb.Set_te_trTeControl_InstTracing(1);

		// Periodic sync: count TIP clock cycles; small threshold => fast in sim.
		// NOTE:
		// The current sync generator (ct_L23_preproc_sync) only updates its internal
		// state on tip.iretire. When using CLK_CYCLES, long gaps can cause the
		// cycle counter to overflow while SyncCntClr is still asserted, which can
		// prevent periodic sync from ever being emitted.
		//
		// Therefore for this Phase-1 MVP integration TB we use instruction-count
		// based periodic sync. With InstSyncMax=0 => sync_count_max = 1 << (0+4) = 16
		ct_cs_wb.Set_te_trTeControl_InstSyncMode(ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_INSTRUCTIONS);
		ct_cs_wb.Set_te_trTeControl_InstSyncMax(4'd0);

		ct_cs_wb.Set_te_trTsControl_Type(ct_cs_cpuif__te__trTsControl__trTsType_e__TR_TS_CORE);
		ct_cs_wb.Set_te_trTsControl_Enable(1'b1);
		ct_cs_wb.Set_te_trTsControl_Active(1'b1);
		ct_cs_wb.Set_te_trTsControl_Count(1'b1);

		// Finally enable the encoder (locks down swwe-gated registers)
		ct_cs_wb.Set_te_trTeControl_Active(1);
		// Master enable — must be the LAST write per spec ("This write
		// of 1 should be done after all other settings are done").
		ct_cs_wb.Set_te_trTeControl_Enable(1);
	endtask

	//========================================================================
	// Directed phase items / helpers
	//========================================================================

	typedef struct {
		tip_t       	tip;                    // input
		int				delay;					// tip delay cycles
		string      	desc;                   // test case description
		int        		test_id;                // test number
	} test_queue_item_t;

	task automatic send_tip_item(input test_queue_item_t item);
		$display("%0.2f: Send phase item / Test %0d: %s", $realtime, item.test_id, item.desc);
		TipSendMsg(tip_dir, tip_clk, item.tip, item.delay);
		repeat (PHASE_IDLE_TIP_CYCLES) @(posedge tip_clk);
	endtask

	//========================================================================
	// ETIP/NEXUS stream checking helpers (Phase-1 MVP)
	//========================================================================
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

	//========================================================================
	// Decoder-driven phase helpers
	//========================================================================
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
					$display("%0.2f: DEC phase=%s ignoring explicit FLUSH msg_id=%0d",
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

	task automatic check_decoded_sync(input string phase);
		int sw;
		logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] sdata;

		void'(tt_assert(field_present(SYNC),
			$sformatf("%0.2f: Line %0d: phase=%s missing SYNC field", $realtime, `__LINE__, phase)));
		sdata = get_field_data(SYNC, sw);
		void'(tt_assert(nexus_sync_reason_e'(sdata[$bits(nexus_sync_reason_e)-1:0]) == NEXUS_SYNC_EXIT_FROM_SYS_RST,
			$sformatf("%0.2f: Line %0d: phase=%s unexpected SYNC reason=%0d",
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

		// Initialize
		tip_rst         <= '1;
		ct_cs_rst       <= '1;
		proc_rst       	<= '1;
		wb_rst          <= '1;
		wall_clk_rst    <= '1;
		atb_atresetn    <= 1'b0;
		atb_afvalid     <= '0;

		timeout_cycles = 300000;
		void'($value$plusargs("CT_TIMEOUT_CYCLES=%d", timeout_cycles));
		$display("%0.2f: directed CT TB start: CT_TIMEOUT_CYCLES=%0d",
			$realtime, timeout_cycles);

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

		configure_decoder();
		@(posedge tip_clk);

		// NOTE: Do NOT clobber trTeControl here.
		// Previous versions overwrote the register with a raw write, which destroyed
		// configuration bits (e.g. InhibitSrc) and caused ct_nexus_decoder mis-alignment.
		ct_cs_wb.Read_te_trTeControl(read_data);
		prev_dec_id = -1;
		last_dec_msg_id = -1;
		last_dec_tcode = -1;
		sync_msg_count = 0;
		df_read_msg_count = 0;
		df_write_msg_count = 0;
		saw_tstamp = 1'b0;
		test_id = 0;

		TipTSetDefault(tipt);
		tipt.iretire = '1;
		tipt.itype = OTHER;
		tipt.ilastsize = 2;

		// Phase 1: initial retired instruction -> EXIT_FROM_SYS_RST sync
		item.tip = tipt;
		item.tip.dretire = '0;
		item.delay = 20;
		item.desc = "Initial retired instruction after reset";
		item.test_id = test_id;
		test_id++;
		send_tip_item(item);
		wait_for_decoded_nexus_msg("initial_sync", NEXUS_MSG_PROGRAM_TRACE_SYNC, ETIP_TIMEOUT_CYCLES);
		check_decoded_sync("initial_sync");

		// Phase 2: DF READ
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
		item.desc = "DF LOAD (dsize=4B, daddr=0x8000_0100, data[31:0]=0x01234567)";
		item.test_id = test_id;
		test_id++;
		send_tip_item(item);

		// Phase 3: DF WRITE
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
		item.desc = "DF STORE (dsize=8B, daddr=0x8000_0200, data=0x0123_4567_89AB_CDEF)";
		item.test_id = test_id;
		test_id++;
		send_tip_item(item);

			wait_for_decoded_nexus_msg("df_read", NEXUS_MSG_DATA_TRACE_READ, ETIP_TIMEOUT_CYCLES);
			check_decoded_df_read("df_read");
			wait_for_decoded_nexus_msg("df_write", NEXUS_MSG_DATA_TRACE_WRITE, ETIP_TIMEOUT_CYCLES);
			check_decoded_df_write("df_write");

			void'(tt_assert(sync_msg_count == 1,
				$sformatf("%0.2f: Line %0d: expected exactly 1 sync message, got %0d", $realtime, `__LINE__, sync_msg_count)));
			void'(tt_assert(df_read_msg_count == 1,
				$sformatf("%0.2f: Line %0d: expected exactly 1 DF READ message, got %0d", $realtime, `__LINE__, df_read_msg_count)));
			void'(tt_assert(df_write_msg_count == 1,
				$sformatf("%0.2f: Line %0d: expected exactly 1 DF WRITE message, got %0d", $realtime, `__LINE__, df_write_msg_count)));
			void'(tt_assert(saw_tstamp == 1'b1,
				$sformatf("%0.2f: Line %0d: expected at least one decoded message with TSTAMP field present", $realtime, `__LINE__)));

			FeedingDone <= 1'b1;
			EtipCheckingDone <= 1'b1;

		repeat (10) @(posedge tip_clk);

		tt_evaluate();
		$finish();

	end
endmodule
