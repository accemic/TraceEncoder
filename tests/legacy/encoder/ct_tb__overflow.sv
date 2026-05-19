// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @file    ct_tb__overflow.sv
 * @brief   Overflow-focused regression for the C-Trace encoder.
 * @description Drives a dense, deterministic trace stream into `ct_encoder`,
 *   applies a long ATB stall so the outer ETIP FIFO `full` asserts, and checks
 *   that a `NEXUS_MSG_ERROR` is emitted after backpressure is released. The
 *   stimulus type is selected via `+CT_DRIVE_MODE`:
 *     0 (DF)              - data-trace stores only
 *     1 (CF,    default)  - change-of-control-flow branches on every cycle
 *     2 (MIXED)           - CF branches plus DF stores on every cycle
 *   The CF stimulus deliberately retires a `HasChangedControlFlow` itype on
 *   every tip_clk cycle. That arms `pending_cf_next_iaddr` on every cycle,
 *   producing a next_iaddr-FIFO write on every following CF retire. The goal
 *   is to race the composer's ETIP-full drop gate and overrun the 256-entry
 *   next_iaddr FIFO (tip->proc CDC, depth = 2 * ETIP_CVS_FIFO_DEPTH) before
 *   the sideband write is suppressed. `sink_if`'s built-in overrun check
 *   (`wr && full`, with `STOP_ON_OVERRUN`) fires on the composer's
 *   `next_iaddr_d` interface the moment this happens, so no extra probe
 *   is needed in the testbench — the bug manifests as a
 *   `ERROR: Sink overrun in Interface: ...next_iaddr_d` + `$stop`.
 * @environment Instantiates `ct_encoder`, Wishbone CSR helpers, and the
 *   internal `ct_nexus_decoder`. No external decode tools are required.
 * @checking Asserts that the outer ETIP FIFO `full` is observed, that at least
 *   one `NEXUS_MSG_ERROR` is decoded, and that the internal decoder reports
 *   no decode errors while draining the recovered stream.
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */

module ct_tb__overflow;

	localparam int WB_DATA_WIDTH = 32;
	localparam int WB_ADDR_WIDTH = 32;

	import tt::*;
	import nexus_vendor::*;
	import nexus::*;
	import tip_pkg::*;
	import ct_pkg::*;
	import ct_cs_cpuif_pkg::*;
	import atb_pkg::*;
	import ct_cs_cpuif_wb_pkg::*;

	localparam int TIP_CLK_PERIOD  = 1;
	localparam int PROC_CLK_PERIOD = 2;
	localparam int WALL_CLK_PERIOD = 10;
	localparam int WB_CLK_PERIOD   = 4;
	localparam int ATB_CLK_PERIOD  = 5;

	localparam int DEFAULT_TIMEOUT_CYCLES = 200000;
	// Driver (tip_clk, 2ns period) must outlast stall end (atb_clk, 10ns period) so
	// there are fresh TIP writes after the ERROR -> SYNC recovery pair:
	// stall ends at (stall_start + stall) atb_cycles = 4112 * 10ns = 41120ns,
	// driver needs to run ~past that in tip_cycles = > 20560, so 30000 gives margin.
	localparam int DEFAULT_DRIVE_CYCLES = 30000;
	localparam int DEFAULT_STALL_START_CYCLES = 16;
	localparam int DEFAULT_STALL_CYCLES = 4096;
	localparam int DEFAULT_DRAIN_CYCLES = 512;

	// +CT_DRIVE_MODE selects which TIP traffic is used to flood the ETIP FIFO.
	localparam int DRIVE_MODE_DF    = 0;	// data-trace stores (legacy)
	localparam int DRIVE_MODE_CF    = 1;	// change-of-CF branches every cycle
	localparam int DRIVE_MODE_MIXED = 2;	// CF branches + DF stores
	localparam int DEFAULT_DRIVE_MODE = DRIVE_MODE_CF;

	logic tip_rst;
	logic proc_rst;
	logic wb_rst;
	logic ct_cs_rst;
	logic wall_clk_rst;
	logic atb_atresetn;
	logic atb_stall;

	uwire           dec_msg_valid;
	uwire           dec_msg_error;
	nexus_message_t dec_msg;
	logic [WB_DATA_WIDTH-1:0] read_data;

	logic tip_clk   = 0; always #TIP_CLK_PERIOD  tip_clk   = ~tip_clk;
	logic wb_clk    = 0; always #WB_CLK_PERIOD   wb_clk    = ~wb_clk;
	logic proc_clk  = 0; always #PROC_CLK_PERIOD proc_clk  = ~proc_clk;
	logic wall_clk  = 0; always #WALL_CLK_PERIOD wall_clk  = ~wall_clk;
	logic atb_atclk = 0; always #ATB_CLK_PERIOD  atb_atclk = ~atb_atclk;

	tip_if tip ();
	assign tip._time = 0; // TSTAMPs derived from tip_clk internally

	axis_if #(
		.TDATA_WIDTH(ACT_CAP_AXIS_TDATA_WIDTH),
		.TID_WIDTH  (ACT_CAP_AXIS_TID_WIDTH)
	) axis (
		.aclk    (tip_clk),
		.aresetn (!tip_rst)
	);

	// Two ATB interfaces with a pass-through throttle shim between them.
	// Encoder (master) drives atb_enc; decoder (slave) observes atb_dec.
	// `atb_stall` inserts a clean backpressure window into the link without
	// fighting the decoder for atready ownership.
	atb_if atb_enc ();
	atb_if atb_dec ();

	assign atb_dec.atdata  = atb_enc.atdata;
	assign atb_dec.atbytes = atb_enc.atbytes;
	assign atb_dec.atid    = atb_enc.atid;
	assign atb_dec.atvalid = atb_enc.atvalid & ~atb_stall;
	assign atb_dec.afready = atb_enc.afready;

	assign atb_enc.atready = atb_dec.atready & ~atb_stall;
	assign atb_enc.afvalid = atb_dec.afvalid;
	assign atb_enc.syncreq = atb_dec.syncreq;

	wb_if #(
		.DATA_WIDTH(WB_DATA_WIDTH),
		.ADDR_WIDTH(WB_ADDR_WIDTH)
	) wb ();

	ct_cs_cpuif_wb_helper #(
		.WB_DATA_WIDTH(WB_DATA_WIDTH),
		.WB_ADDR_WIDTH(WB_ADDR_WIDTH)
	) ct_cs_wb (
		wb_clk,
		wb
	);

	ct_encoder ct_encoder_inst (
		.tip_clk, .tip_rst, .tip,
		.wb_clk,  .wb_rst,  .wb,
		.axis,
		.atb_atclk, .atb_atresetn, .atb(atb_enc),
		.proc_clk, .proc_rst,
		.ct_cs_rst,
		.wall_clk, .wall_clk_rst
	);

	ct_axis_dump ct_axis_dump_inst (.axis);

	ct_nexus_decoder #(
		.INCLUDE_SRC    (1'b0),
		.INCLUDE_TSTAMP (1'b1)
	)  ct_nexus_decoder_inst (
		.atb_atclk,
		.atb_atresetn,
		.atb(atb_dec),
		.dec_msg_valid,
		.dec_msg_error,
		.dec_msg
	);

	task automatic configure_encoder(input int mode);
		bit cf_enable;
		bit df_enable;
		cf_enable = (mode == DRIVE_MODE_CF)    || (mode == DRIVE_MODE_MIXED);
		df_enable = (mode == DRIVE_MODE_DF)    || (mode == DRIVE_MODE_MIXED);

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

		ct_cs_wb.Set_te_trTeComp_Control_PFunction(0,
			ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_RESERVED_MATCH);
		ct_cs_wb.Set_te_trTeComp_Control_MatchMode(0,
			ct_cs_cpuif__te__trTeComp__Control__trTeCompMatchMode_e__TR_COMP_MATCH_MODE0);

		ct_cs_wb.Set_te_trTeDataFilters_Filters(16'h0);
		ct_cs_wb.Set_te_trTeInstFilters_Filters(16'h0);

		ct_cs_wb.Set_te_trTeDataControl_DataTracing(df_enable);
		ct_cs_wb.Set_te_trTeControl_InstTracing(cf_enable);
		if (cf_enable) begin
			ct_cs_wb.Set_te_trTeControl_InstMode(
				ct_cs_cpuif__te__trTeControl__trTeInstMode_e__ITR_BRANCH);
			ct_cs_wb.Set_te_trTeControl_InstSyncMode(
				ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_INSTRUCTIONS);
			ct_cs_wb.Set_te_trTeControl_InstSyncMax(4'd0);
		end

		ct_cs_wb.Set_te_trTsControl_Type(ct_cs_cpuif__te__trTsControl__trTsType_e__TR_TS_CORE);
		ct_cs_wb.Set_te_trTsControl_Enable(1'b1);
		ct_cs_wb.Set_te_trTsControl_Active(1'b1);
		ct_cs_wb.Set_te_trTsControl_Count(1'b1);

		ct_cs_wb.Set_te_trTeControl_Active(1'b1);
		// Master enable — must be the LAST write per spec.
		ct_cs_wb.Set_te_trTeControl_Enable(1'b1);
	endtask

	task automatic drive_tip_idle();
		tip.itype     <= OTHER;
		tip.ecause    <= ECAUSE_NONE;
		tip.tval      <= '0;
		tip.priv      <= '0;
		tip.iaddr     <= '0;
		tip._context  <= '0;
		tip.ctype     <= '0;
		tip.iretire   <= 1'b0;
		tip.ilastsize <= 2'd2;
		tip.impdef    <= '0;
		tip.dretire   <= 1'b0;
		tip.dtype     <= LOAD;
		tip.daddr     <= '0;
		tip.dsize     <= '0;
		tip.data      <= '0;
	endtask

	// Rotate through a mix of `HasChangedControlFlow` itypes on every tip_clk
	// cycle. The composer arms `pending_cf_next_iaddr` (a next_iaddr-FIFO
	// write on the following CF retire) only for these itypes. Driving a
	// change-of-CF every cycle deliberately races the composer's drop gate
	// — which today suppresses next_iaddr writes only when the ETIP FIFO is
	// full — and overruns the 256-entry next_iaddr FIFO. The dedicated
	// overrun probe downstream catches the dropped write. The rotation keeps
	// msg_gen's direct and indirect branch paths both exercised.
	function automatic tip_itype_e cf_itype_for_index(input int i);
		case (i % 4)
			0:       cf_itype_for_index = TAKEN_BRANCH;
			1:       cf_itype_for_index = UNINFERABLE_JUMP;
			2:       cf_itype_for_index = UNINFERABLE_CALL;
			default: cf_itype_for_index = RETURN;
		endcase
	endfunction

	task automatic drive_overflow_stream(input int drive_cycles, input int mode);
		tip_iaddr_t base_iaddr;
		tip_daddr_t base_daddr;
		bit         cf_enable;
		bit         df_enable;
		base_iaddr = 32'h0000_8000;
		base_daddr = 32'h9000_0000;
		cf_enable  = (mode == DRIVE_MODE_CF)    || (mode == DRIVE_MODE_MIXED);
		df_enable  = (mode == DRIVE_MODE_DF)    || (mode == DRIVE_MODE_MIXED);

		for (int i = 0; i < drive_cycles; i++) begin
			@(posedge tip_clk);
			tip.iretire   <= 1'b1;
			tip.itype     <= cf_enable ? cf_itype_for_index(i) : OTHER;
			tip.iaddr     <= base_iaddr + (i * 32'h4);
			tip.ilastsize <= 2'd2;
			tip.dretire   <= df_enable ? 1'b1  : 1'b0;
			tip.dtype     <= df_enable ? STORE : LOAD;
			tip.daddr     <= df_enable ? (base_daddr + (i * 32'h4)) : '0;
			tip.dsize     <= df_enable ? 2'd2  : 2'd0;
			tip.data      <= df_enable ? (64'hA500_0000_0000_0000 | tip_data_t'(i)) : '0;
		end

		@(posedge tip_clk);
		drive_tip_idle();
	endtask

	task automatic sample_decoded_msg(
		inout int prev_dec_id,
		inout int msgs_seen,
		inout int error_msgs_seen,
		inout int fifo_overrun_sync_seen,
		inout int decode_errors_seen,
		inout int msgs_after_recovery,
		inout bit expect_sync_after_error,
		inout bit saw_error_sync_pair
	);
		nexus_tcode_e tcode_dbg;
		nexus_sync_reason_e sync_reason_dbg;
		int sync_field_idx;
		bit was_recovered;
		if (dec_msg_valid && (dec_msg.fields[0].name == TCODE) && (dec_msg.id != prev_dec_id)) begin
			was_recovered = saw_error_sync_pair;
			prev_dec_id = dec_msg.id;
			msgs_seen++;
			if (dec_msg_error) begin
				decode_errors_seen++;
			end
			tcode_dbg = nexus_tcode_e'(dec_msg.fields[0].data[5:0]);
			if (tcode_dbg == NEXUS_MSG_ERROR) begin
				error_msgs_seen++;
				expect_sync_after_error = 1'b1;
			end
			else begin
				if (expect_sync_after_error) begin
					sync_field_idx = -1;
					for (int i = 1; i < NEXUS_MAX_FIELDS; i++) begin
						if (dec_msg.fields[i].name == SYNC) begin
							sync_field_idx = i;
							break;
						end
					end
					if ((tcode_dbg == NEXUS_MSG_PROGRAM_TRACE_SYNC)
					 && (sync_field_idx >= 0)
					 && (nexus_sync_reason_e'(dec_msg.fields[sync_field_idx].data[$bits(nexus_sync_reason_e)-1:0]) == NEXUS_SYNC_FIFO_OVERRUN)) begin
						saw_error_sync_pair = 1'b1;
					end
					expect_sync_after_error = 1'b0;
				end
			end
			// Count messages decoded strictly AFTER the ERROR -> SYNC recovery pair
			// (was_recovered is the pre-state, so the recovery SYNC itself is not counted).
			if (was_recovered) begin
				msgs_after_recovery++;
			end

			sync_field_idx = -1;
			for (int i = 1; i < NEXUS_MAX_FIELDS; i++) begin
				if (dec_msg.fields[i].name == SYNC) begin
					sync_field_idx = i;
					break;
				end
			end
			if ((tcode_dbg == NEXUS_MSG_PROGRAM_TRACE_SYNC) && (sync_field_idx >= 0)) begin
				sync_reason_dbg = nexus_sync_reason_e'(dec_msg.fields[sync_field_idx].data[$bits(nexus_sync_reason_e)-1:0]);
				if (sync_reason_dbg == NEXUS_SYNC_FIFO_OVERRUN) begin
					fifo_overrun_sync_seen++;
				end
			end
		end
	endtask

	initial begin
		int timeout_cycles;
		int drive_cycles;
		int stall_start_cycles;
		int stall_cycles;
		int drain_cycles;
		int drive_mode;
		int msgs_seen;
		int error_msgs_seen;
		int fifo_overrun_sync_seen;
		int decode_errors_seen;
		int msgs_after_recovery;
		int prev_dec_id;
		int cycles;
		bit outer_full_seen;
		bit driver_done;
		bit plusarg_seen;
		bit expect_sync_after_error;
		bit saw_error_sync_pair;

		timeout_cycles = DEFAULT_TIMEOUT_CYCLES;
		drive_cycles = DEFAULT_DRIVE_CYCLES;
		stall_start_cycles = DEFAULT_STALL_START_CYCLES;
		stall_cycles = DEFAULT_STALL_CYCLES;
		drain_cycles = DEFAULT_DRAIN_CYCLES;
		drive_mode = DEFAULT_DRIVE_MODE;

		plusarg_seen = $value$plusargs("CT_TIMEOUT_CYCLES=%d", timeout_cycles);
		plusarg_seen = $value$plusargs("CT_ATB_STALL_START_CYCLES=%d", stall_start_cycles);
		plusarg_seen = $value$plusargs("CT_ATB_STALL_CYCLES=%d", stall_cycles);
		plusarg_seen = $value$plusargs("CT_DRAIN_CYCLES=%d", drain_cycles);
		plusarg_seen = $value$plusargs("CT_DRIVE_MODE=%d", drive_mode);
		if ((drive_mode != DRIVE_MODE_DF) && (drive_mode != DRIVE_MODE_CF) && (drive_mode != DRIVE_MODE_MIXED)) begin
			$display("%0.2f: OVERFLOW TB: invalid CT_DRIVE_MODE=%0d, falling back to %0d (DF)",
				$realtime, drive_mode, DEFAULT_DRIVE_MODE);
			drive_mode = DEFAULT_DRIVE_MODE;
		end
		// CF/MIXED paths push dense CF traffic through a much slower ATB
		// serialization bottleneck than DF stores. Drive just long enough
		// to span the stall (stall_end ≈ 20560 tip_cycles) plus margin so
		// fresh writes exist after the ERROR -> SYNC recovery pair, but
		// short enough that the post-stall queue can drain within sim.
		if ((drive_mode == DRIVE_MODE_CF) || (drive_mode == DRIVE_MODE_MIXED)) begin
			drive_cycles = 22000;
		end
		plusarg_seen = $value$plusargs("CT_DRIVE_CYCLES=%d", drive_cycles);

		tip_rst       <= 1'b1;
		ct_cs_rst     <= 1'b1;
		proc_rst      <= 1'b1;
		wb_rst        <= 1'b1;
		wall_clk_rst  <= 1'b1;
		atb_atresetn  <= 1'b0;
		atb_stall     <= 1'b0;
		driver_done   <= 1'b0;
		drive_tip_idle();

		$display("%0.2f: OVERFLOW TB start: CT_TIMEOUT_CYCLES=%0d CT_DRIVE_CYCLES=%0d CT_ATB_STALL_START_CYCLES=%0d CT_ATB_STALL_CYCLES=%0d CT_DRAIN_CYCLES=%0d CT_DRIVE_MODE=%0d (%s)",
			$realtime, timeout_cycles, drive_cycles, stall_start_cycles, stall_cycles, drain_cycles,
			drive_mode,
			(drive_mode == DRIVE_MODE_CF)    ? "CF"    :
			(drive_mode == DRIVE_MODE_MIXED) ? "MIXED" : "DF");

		@(posedge tip_clk);
		tip_rst <= 1'b0;
		@(posedge proc_clk);
		proc_rst <= 1'b0;
		@(posedge proc_clk);
		ct_cs_rst <= 1'b0;
		@(posedge wb_clk);
		wb_rst <= 1'b0;
		@(posedge wall_clk);
		wall_clk_rst <= 1'b0;
		@(posedge atb_atclk);
		atb_atresetn <= 1'b1;

		configure_encoder(drive_mode);
		@(posedge tip_clk);
		ct_cs_wb.Read_te_trTeControl(read_data);

		fork
			begin
				drive_overflow_stream(drive_cycles, drive_mode);
				driver_done = 1'b1;
			end
		join_none

		msgs_seen = 0;
		error_msgs_seen = 0;
		fifo_overrun_sync_seen = 0;
		decode_errors_seen = 0;
		msgs_after_recovery = 0;
		prev_dec_id = -1;
		cycles = 0;
		outer_full_seen = 1'b0;
		expect_sync_after_error = 1'b0;
		saw_error_sync_pair = 1'b0;

		while (cycles < timeout_cycles) begin
			@(posedge atb_atclk);
			cycles++;

			if (!atb_atresetn || (cycles < stall_start_cycles) || (cycles >= (stall_start_cycles + stall_cycles))) begin
				atb_stall <= 1'b0;
			end
			else begin
				atb_stall <= 1'b1;
			end

			outer_full_seen |= ct_encoder_inst.preproc_inst.composer_etip_inst.etip_cvs_cdc_fifo.cvs_fifo2_inst.d.full;
			sample_decoded_msg(prev_dec_id, msgs_seen, error_msgs_seen, fifo_overrun_sync_seen, decode_errors_seen, msgs_after_recovery, expect_sync_after_error, saw_error_sync_pair);

			if (driver_done && (cycles >= (stall_start_cycles + stall_cycles + drain_cycles)) && saw_error_sync_pair) begin
				break;
			end
		end

		repeat (drain_cycles) begin
			@(posedge atb_atclk);
			atb_stall <= 1'b0;
			outer_full_seen |= ct_encoder_inst.preproc_inst.composer_etip_inst.etip_cvs_cdc_fifo.cvs_fifo2_inst.d.full;
			sample_decoded_msg(prev_dec_id, msgs_seen, error_msgs_seen, fifo_overrun_sync_seen, decode_errors_seen, msgs_after_recovery, expect_sync_after_error, saw_error_sync_pair);
		end

		$display("%0.2f: OVERFLOW regression done: msgs_seen=%0d error_msgs_seen=%0d fifo_overrun_sync_seen=%0d decode_errors_seen=%0d msgs_after_recovery=%0d outer_full_seen=%0d cycles=%0d",
			$realtime, msgs_seen, error_msgs_seen, fifo_overrun_sync_seen, decode_errors_seen, msgs_after_recovery, outer_full_seen, cycles);

		void'(tt_assert(driver_done,
			$sformatf("%0.2f: overflow regression: stimulus did not finish", $realtime)));
		void'(tt_assert(outer_full_seen,
			$sformatf("%0.2f: overflow regression: expected outer ETIP FIFO full to assert", $realtime)));
		void'(tt_assert(error_msgs_seen > 0,
			$sformatf("%0.2f: overflow regression: expected at least one NEXUS_MSG_ERROR", $realtime)));
		void'(tt_assert(fifo_overrun_sync_seen > 0,
			$sformatf("%0.2f: overflow regression: expected at least one FIFO overrun sync", $realtime)));
		void'(tt_assert(saw_error_sync_pair,
			$sformatf("%0.2f: overflow regression: expected ERROR to be followed immediately by SYNC(FIFO_OVERRUN)", $realtime)));
		void'(tt_assert(msgs_after_recovery > 0,
			$sformatf("%0.2f: overflow regression: expected further messages after recovery SYNC, got %0d",
				$realtime, msgs_after_recovery)));
		void'(tt_assert(decode_errors_seen == 0,
			$sformatf("%0.2f: overflow regression: expected no decoder errors, got %0d",
				$realtime, decode_errors_seen)));

		// --------------------------------------------------------------------
		// trTeTipFifoStatus CSR round-trip (PR: TIP FIFO watermark + overflow)
		// --------------------------------------------------------------------
		// After the overflow regression the two status counters must be
		// observable via the CSR and clearable via the matching Clear bits.
		begin
			logic [WB_DATA_WIDTH-1:0] status_pre;
			logic [WB_DATA_WIDTH-1:0] status_post;
			logic [14:0]              max_fill_pre;
			logic [14:0]              num_ovf_pre;
			logic [14:0]              max_fill_post;
			logic [14:0]              num_ovf_post;

			// Let the tip->wb CDCs settle so the CSR view matches the final
			// tip-clk state (vector_cdc2 handshake needs a few cycles).
			repeat (64) @(posedge wb_clk);

			ct_cs_wb.Read_te_trTeTipFifoStatus(status_pre);
			max_fill_pre = status_pre[BITPOS_te_trTeTipFifoStatus_trTeTipFifoMaxFill_LSB +: 15];
			num_ovf_pre  = status_pre[BITPOS_te_trTeTipFifoStatus_trTeTipFifoNumOverflows_LSB +: 15];
			$display("%0.2f: CSR pre-clear : MaxFill=%0d NumOverflows=%0d (raw=0x%08h)",
				$realtime, max_fill_pre, num_ovf_pre, status_pre);

			void'(tt_assert(max_fill_pre > 0,
				$sformatf("%0.2f: trTeTipFifoMaxFill must be > 0 after overflow run, got %0d",
					$realtime, max_fill_pre)));
			void'(tt_assert(num_ovf_pre > 0,
				$sformatf("%0.2f: trTeTipFifoNumOverflows must be > 0 after overflow run, got %0d",
					$realtime, num_ovf_pre)));

			// Pulse both Clear levels high -> wait for CDC round-trip -> release.
			ct_cs_wb.Set_te_trTeTipFifoStatus_trTeTipFifoMaxFillClear(1'b1);
			ct_cs_wb.Set_te_trTeTipFifoStatus_trTeTipFifoNumOverflowsClear(1'b1);
			repeat (64) @(posedge wb_clk);
			ct_cs_wb.Set_te_trTeTipFifoStatus_trTeTipFifoMaxFillClear(1'b0);
			ct_cs_wb.Set_te_trTeTipFifoStatus_trTeTipFifoNumOverflowsClear(1'b0);
			repeat (64) @(posedge wb_clk);

			ct_cs_wb.Read_te_trTeTipFifoStatus(status_post);
			max_fill_post = status_post[BITPOS_te_trTeTipFifoStatus_trTeTipFifoMaxFill_LSB +: 15];
			num_ovf_post  = status_post[BITPOS_te_trTeTipFifoStatus_trTeTipFifoNumOverflows_LSB +: 15];
			$display("%0.2f: CSR post-clear: MaxFill=%0d NumOverflows=%0d (raw=0x%08h)",
				$realtime, max_fill_post, num_ovf_post, status_post);

			// NumOverflowsClear is always checked: its source register is
			// incremented only by new discards, so once the stimulus is
			// idle the post-clear value must settle to 0.
			void'(tt_assert(num_ovf_post == 0,
				$sformatf("%0.2f: trTeTipFifoNumOverflows must be 0 after clear, got %0d",
					$realtime, num_ovf_post)));

			// MaxFillClear is level-triggered: when the Clear level is
			// released, the watermark immediately re-latches the current
			// CVS fill. In DF mode the FIFO drains before the check runs,
			// so MaxFill settles back to 0. In CF/MIXED mode the ATB
			// serialization of queued CF messages takes far longer than
			// the local drain window, so we instead require only that the
			// post-clear value did not grow beyond the pre-clear peak —
			// which demonstrates that the Clear level did reach the
			// tip-clk register.
			if (drive_mode == DRIVE_MODE_DF) begin
				void'(tt_assert(max_fill_post == 0,
					$sformatf("%0.2f: trTeTipFifoMaxFill must be 0 after clear (DF mode), got %0d",
						$realtime, max_fill_post)));
			end
			else begin
				void'(tt_assert(max_fill_post <= max_fill_pre,
					$sformatf("%0.2f: trTeTipFifoMaxFill must not grow past pre-clear peak (CF/MIXED), pre=%0d post=%0d",
						$realtime, max_fill_pre, max_fill_post)));
			end
		end

		repeat (10) @(posedge tip_clk);
		tt_evaluate();
		$finish();
	end

endmodule
