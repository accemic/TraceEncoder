// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @file    ct_tb__daq_directed.sv
 * @brief   Directed regression testbench for C-Trace DAQ encoder behavior.
 * @description Exercises DAQ-oriented ACT_CAP commands on the full encoder
 *   path and checks decoded AXIS and Nexus outputs end to end.
 * @environment Instantiates ct_encoder, AXIS and Nexus decoders, Wishbone
 *   control helpers, and the ATB path across tip, proc, wb, wall, and ATB
 *   clocks.
 * @stimulus Queues directed ACT_CAP DAQ scenarios plus seed data accesses used
 *   to populate PrevData/PrevDAddr state in the composers.
 * @checking Verifies currently implemented DAQ packing on AXIS and the widened
 *   Nexus DAQ path that now carries all three ETIP DAQ payload elements.
 * @note    DAQ_DATA_DADDR still combines context and DirectData into the third
 *   64-bit ETIP element because that command has four logical payload pieces.
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
*/
module ct_tb__daq_directed;

	localparam WB_DATA_WIDTH = 32;
	localparam WB_ADDR_WIDTH = 32;

	import tt::*;
	import nexus_vendor::*;
	import nexus::*;
	import tip_pkg::*;
	import ct_pkg::*;
	import ct_cs_cpuif_pkg::*;
	import ct_cs_cpuif_types_pkg::*;
	import atb_pkg::*;
	import ct_cs_cpuif_wb_pkg::*;
	import file_pkg::*;
	import tip_utils_pkg::*;

	localparam TIP_CLK_PERIOD       = 1;
	localparam PROC_CLK_PERIOD      = 2;
	localparam WALL_CLK_PERIOD      = 10;
	localparam WB_CLK_PERIOD        = 4;
	localparam ATB_CLK_PERIOD       = 5;

	localparam int PHASE_IDLE_TIP_CYCLES = 32;
	localparam int AXIS_TIMEOUT_CYCLES = 20000;
	localparam int ETIP_TIMEOUT_CYCLES = 200000;
	localparam int FLUSH_TIMEOUT_CYCLES = 20000;
	localparam int PRE_FLUSH_IDLE_ATB_CYCLES = 32;

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
	uwire           dec_axis_valid;
	uwire           dec_axis_error;
	ct_axis_decoder_pkg::ct_axis_msg_t dec_axis_msg;
	int             tip_time;
	int             prev_dec_id = -1;
	int             last_dec_msg_id = -1;
	int             last_dec_tcode = -1;
	int             last_axis_msg_id = -1;
	nexus_message_t curr_dec_msg;
	nexus_message_t decoded_msg_queue[$];
	typedef struct {
		bit error;
		ct_axis_decoder_pkg::ct_axis_msg_t msg;
	} axis_decoded_item_t;
	axis_decoded_item_t decoded_axis_queue[$];
	int             sync_msg_count = 0;
	int             axis_msg_count = 0;
	int             daq_nexus_msg_count = 0;
	logic           saw_tstamp = 0;

	logic [WB_DATA_WIDTH-1:0]    read_data;

	ct_cs_cpuif__trActCapStCmd__out_t	cmd;

	logic tip_clk = 0; always #TIP_CLK_PERIOD tip_clk = ~tip_clk;
	logic wb_clk = 0; always #WB_CLK_PERIOD wb_clk = ~wb_clk;
	logic proc_clk = 0; always #PROC_CLK_PERIOD proc_clk = ~proc_clk;
	logic wall_clk = 0; always #WALL_CLK_PERIOD wall_clk = ~wall_clk;
	logic atb_atclk = 0; always #ATB_CLK_PERIOD atb_atclk = ~atb_atclk;

	logic FeedingDone = 0;
	logic AxisCheckingDone = 0;
	logic EtipCheckingDone = 0;

	tip_if tip ();
	tip_if tip_dir ();

	assign tip._time = tip_time;

	axis_if #(
		.TDATA_WIDTH(ACT_CAP_AXIS_TDATA_WIDTH),
		.TID_WIDTH(ACT_CAP_AXIS_TID_WIDTH)
	) axis (.aclk(tip_clk), .aresetn(!tip_rst));

	atb_if atb ();
	assign atb.syncreq = '0;
	assign atb.afvalid = atb_afvalid;

	wb_if #(.DATA_WIDTH(WB_DATA_WIDTH), .ADDR_WIDTH(WB_DATA_WIDTH)) wb();

	ct_cs_cpuif_wb_helper #(
		.WB_DATA_WIDTH(WB_DATA_WIDTH),
		.WB_ADDR_WIDTH(WB_DATA_WIDTH)
	) ct_cs_wb (wb_clk, wb);

	ct_encoder ct_encoder_inst (
	  .tip_clk,   .tip_rst,      .tip,
	  .wb_clk,    .wb_rst,       .wb,
	  .axis,
	  .atb_atclk, .atb_atresetn, .atb,
	  .proc_clk,  .proc_rst,
	  .ct_cs_rst,
	  .wall_clk,  .wall_clk_rst
	);

	atb_dump #(.FILEPATH("atb_dump.bin")) atb_dump_inst (
		.atb_atclk, .atb_atresetn, .atb
	);

	ct_axis_dump ct_axis_dump_inst (.axis);

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
		.INCLUDE_SRC(1'b0),
		.INCLUDE_TSTAMP(1'b1)
	) ct_nexus_decoder_inst (
		.atb_atclk, .atb_atresetn, .atb,
		.dec_msg_valid,
		.dec_msg_error,
		.dec_msg
	);

	ct_axis_decoder ct_axis_decoder_inst (
		.clk(tip_clk), .rst(tip_rst), .axis,
		.dec_axis_valid,
		.dec_axis_error,
		.dec_axis_msg
	);

	tip_t tipt;

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

	initial begin
		last_axis_msg_id = -1;
		decoded_axis_queue.delete();
		forever begin
			@(posedge tip_clk);
			if (tip_rst) begin
				last_axis_msg_id = -1;
				decoded_axis_queue.delete();
			end
			else if (dec_axis_valid) begin
				axis_decoded_item_t axis_item;
				axis_item.error = dec_axis_error;
				axis_item.msg = dec_axis_msg;
				last_axis_msg_id = dec_axis_msg.id;
				decoded_axis_queue.push_back(axis_item);
			end
		end
	end

	task automatic configure_decoder();
		ct_cs_wb.Set_te_trTeControl_InhibitSrc(1'b1);
		ct_cs_wb.Set_te_trTeInstFeatures_SrcBits(4'd4);
		ct_cs_wb.Set_te_trTeInstFeatures_SrcID(12'h001);

		// DAQ-focused bench: keep instruction tracing and data tracing disabled so
		// the bench observes only directed DAQ traffic.
		ct_cs_wb.Set_te_trTeDataControl_DataTracing(1'b0);
		ct_cs_wb.Set_te_trTeControl_InstTracing(1'b0);

		ct_cs_wb.Set_te_trTsControl_Type(ct_cs_cpuif__te__trTsControl__trTsType_e__TR_TS_CORE);
		ct_cs_wb.Set_te_trTsControl_Enable(1'b1);
		ct_cs_wb.Set_te_trTsControl_Active(1'b1);
		ct_cs_wb.Set_te_trTsControl_Count(1'b1);

		ct_cs_wb.Set_te_trTeControl_Active(1);
		// Master enable — must be the LAST write per spec ("This write
		// of 1 should be done after all other settings are done").
		ct_cs_wb.Set_te_trTeControl_Enable(1);
	endtask

	typedef struct {
		tip_t tip;
		int delay;
		string desc;
		int test_id;
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

	function automatic tip_xaddr_data_t pack_expected_daq_direct_elem(
		input logic [23:0] direct_data
	);
		pack_expected_daq_direct_elem = tip_xaddr_data_t'(direct_data);
	endfunction

	function automatic tip_xaddr_data_t pack_expected_daq_dtype_dsize_elem(
		input tip_dtype_t dtype,
		input tip_dsize_t dsize
	);
		pack_expected_daq_dtype_dsize_elem = tip_xaddr_data_t'({dtype, dsize});
	endfunction

	function automatic tip_xaddr_data_t pack_expected_daq_context_direct_elem(
		input tip_dtype_t dtype,
		input tip_dsize_t dsize,
		input logic [23:0] direct_data
	);
		pack_expected_daq_context_direct_elem =
			tip_xaddr_data_t'({{(TIP_XADDR_DATA_WIDTH-24-TIP_DTYPE_WIDTH-TIP_DSIZE_WIDTH){1'b0}}, direct_data, dtype, dsize});
	endfunction

	function automatic logic [NEXUS_DQDATA_WIDTH-1:0] pack_expected_daq_payload(
		input tip_xaddr_data_t data0,
		input tip_xaddr_data_t data1,
		input tip_xaddr_data_t data2
	);
		pack_expected_daq_payload = {data2, data1, data0};
	endfunction

	function automatic logic [NEXUS_DQDATA_WIDTH-1:0] pack_expected_daq_pc_curr(
		input logic [31:0] iaddr,
		input logic [23:0] direct_data
	);
		pack_expected_daq_pc_curr =
			pack_expected_daq_payload(tip_xaddr_data_t'(iaddr), pack_expected_daq_direct_elem(direct_data), '0);
	endfunction

	function automatic logic [NEXUS_DQDATA_WIDTH-1:0] pack_expected_daq_direct_data(
		input logic [23:0] direct_data
	);
		pack_expected_daq_direct_data =
			pack_expected_daq_payload(pack_expected_daq_direct_elem(direct_data), '0, '0);
	endfunction

	function automatic logic [NEXUS_DQDATA_WIDTH-1:0] pack_expected_daq_data(
		input tip_data_t data,
		input tip_dtype_t dtype,
		input tip_dsize_t dsize,
		input logic [23:0] direct_data
	);
		pack_expected_daq_data =
			pack_expected_daq_payload(data, pack_expected_daq_dtype_dsize_elem(dtype, dsize), pack_expected_daq_direct_elem(direct_data));
	endfunction

	function automatic logic [NEXUS_DQDATA_WIDTH-1:0] pack_expected_daq_daddr(
		input tip_daddr_t daddr,
		input tip_dtype_t dtype,
		input tip_dsize_t dsize,
		input logic [23:0] direct_data
	);
		pack_expected_daq_daddr =
			pack_expected_daq_payload(tip_xaddr_data_t'(daddr), pack_expected_daq_dtype_dsize_elem(dtype, dsize), pack_expected_daq_direct_elem(direct_data));
	endfunction

	function automatic logic [NEXUS_DQDATA_WIDTH-1:0] pack_expected_daq_data_daddr(
		input tip_data_t data,
		input tip_daddr_t daddr,
		input tip_dtype_t dtype,
		input tip_dsize_t dsize,
		input logic [23:0] direct_data
	);
		pack_expected_daq_data_daddr =
			pack_expected_daq_payload(data, tip_xaddr_data_t'(daddr), pack_expected_daq_context_direct_elem(dtype, dsize, direct_data));
	endfunction

	function automatic logic [31:0] pack_expected_axis_direct_data(
		input logic [23:0] direct_data
	);
		pack_expected_axis_direct_data = {8'h00, direct_data};
	endfunction

	function automatic logic [31:0] pack_expected_axis_dtype_dsize(
		input tip_dtype_t dtype,
		input tip_dsize_t dsize
	);
		pack_expected_axis_dtype_dsize =
			{{(32-TIP_DTYPE_WIDTH-TIP_DSIZE_WIDTH){1'b0}}, dtype, dsize};
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
						$display("%0.2f: DEC phase=%s ignoring explicit FLUSH msg_id=%0d",
							$realtime, phase, curr_dec_msg.id);
						continue;
					end

					if ((got_tcode == NEXUS_MSG_PROGRAM_TRACE_SYNC) && (expected_tcode != NEXUS_MSG_PROGRAM_TRACE_SYNC)) begin
						$display("%0.2f: DEC phase=%s ignoring interleaved sync msg_id=%0d",
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

	task automatic wait_for_axis_msg(
		input string phase,
		input int test_id,
		input string desc,
		input ct_cs_cpuif__trActCapStCmd_e_e expected_cmd,
		input logic [2:0] expected_elem_valid,
		input logic [31:0] expected_elem0,
		input logic [31:0] expected_elem1,
		input logic [31:0] expected_elem2,
		input int timeout_cycles
	);
		int cycles_waited;
		axis_decoded_item_t axis_item;
		logic [31:0] expected_elem[3];

		expected_elem[0] = expected_elem0;
		expected_elem[1] = expected_elem1;
		expected_elem[2] = expected_elem2;
		cycles_waited = 0;
		while (1) begin
			@(posedge tip_clk);
			cycles_waited++;

			while (decoded_axis_queue.size() > 0) begin
				axis_item = decoded_axis_queue.pop_front();
				void'(tt_assert(!axis_item.error,
					$sformatf("%0.2f: Line %0d / Test %0d (%s) phase=%s axis decode error",
						$realtime, `__LINE__, test_id, desc, phase)));
				void'(tt_assert(axis_item.msg.cmd == expected_cmd,
					$sformatf("%0.2f: Line %0d / Test %0d (%s) phase=%s unexpected axis cmd exp=%0d got=%0d",
						$realtime, `__LINE__, test_id, desc, phase, expected_cmd, axis_item.msg.cmd)));
				for (int i = 0; i < 3; i++) begin
					void'(tt_assert(axis_item.msg.elem_valid[i] == expected_elem_valid[i],
						$sformatf("%0.2f: Line %0d / Test %0d (%s) phase=%s axis elem%0d valid mismatch exp=%0b got=%0b (tstrb=%0h)",
							$realtime, `__LINE__, test_id, desc, phase, i, expected_elem_valid[i], axis_item.msg.elem_valid[i], axis_item.msg.raw_tstrb)));
					if (expected_elem_valid[i]) begin
						void'(tt_assert(axis_item.msg.elem[i] == expected_elem[i],
							$sformatf("%0.2f: Line %0d / Test %0d (%s) phase=%s axis elem%0d mismatch exp=%0h got=%0h",
								$realtime, `__LINE__, test_id, desc, phase, i, expected_elem[i], axis_item.msg.elem[i])));
					end
				end
				axis_msg_count++;
				return;
			end

			if (cycles_waited > timeout_cycles) begin
				void'(tt_assert(0,
					$sformatf("%0.2f: Line %0d / Test %0d (%s) phase=%s timeout waiting for AXIS decode",
						$realtime, `__LINE__, test_id, desc, phase)));
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

	task automatic check_decoded_daq(
		input string phase,
		input ct_cs_cpuif__trActCapStCmd_e_e expected_cmd,
		input logic [NEXUS_DQDATA_WIDTH-1:0] expected_dqdata
	);
		int idw, dqdw;
		logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] idtag_d, dqdata_d;

		idtag_d = get_field_data(IDTAG, idw);
		dqdata_d = get_field_data(DQDATA, dqdw);

		void'(tt_assert(idtag_d[$bits(nexus_idtag_t)-1:0] == nexus_idtag_t'(expected_cmd),
			$sformatf("%0.2f: Line %0d: phase=%s DAQ IDTAG mismatch exp=%0h got=%0h",
				$realtime, `__LINE__, phase, expected_cmd, idtag_d)));
		void'(tt_assert(dqdata_d[NEXUS_DQDATA_WIDTH-1:0] == expected_dqdata,
			$sformatf("%0.2f: Line %0d: phase=%s DAQ DQDATA mismatch exp=%0h got=%0h",
					$realtime, `__LINE__, phase, expected_dqdata, dqdata_d[NEXUS_DQDATA_WIDTH-1:0])));
		daq_nexus_msg_count++;
	endtask

	task automatic issue_atb_flush(input string phase);
		int cycles_waited;
		logic saw_afready_low;

		cycles_waited = 0;
		saw_afready_low = 1'b0;
		atb_afvalid <= 1'b1;
		while (1) begin
			@(posedge atb_atclk);
			cycles_waited++;
			if (!atb.afready) begin
				saw_afready_low = 1'b1;
			end
			if (saw_afready_low && atb.afready) begin
				atb_afvalid <= 1'b0;
				@(posedge atb_atclk);
				return;
			end
			if (cycles_waited > FLUSH_TIMEOUT_CYCLES) begin
				atb_afvalid <= 1'b0;
				void'(tt_assert(0,
					$sformatf("%0.2f: Line %0d: phase=%s timeout waiting for ATB flush handshake",
						$realtime, `__LINE__, phase)));
				return;
			end
		end
	endtask

	initial begin
		int timeout_cycles;
		int test_id;
		test_queue_item_t item;

		tip_rst <= '1;
		ct_cs_rst <= '1;
		proc_rst <= '1;
		wb_rst <= '1;
		wall_clk_rst <= '1;
		atb_atresetn <= 1'b0;
		atb_afvalid <= '0;

		timeout_cycles = 300000;
		void'($value$plusargs("CT_TIMEOUT_CYCLES=%d", timeout_cycles));
		$display("%0.2f: directed DAQ CT TB start: CT_TIMEOUT_CYCLES=%0d",
			$realtime, timeout_cycles);

		TipTSetDefault(tipt);
		TipSendMsg(tip_dir, tip_clk, tipt, 3);
		@(posedge tip_clk);
		tip_rst <= '0;
		@(posedge tip_clk);
		@(posedge proc_clk);
		proc_rst <= '0;
		@(posedge proc_clk);
		ct_cs_rst <= '0;
		@(posedge wb_clk);
		wb_rst <= '0;
		@(posedge wall_clk);
		wall_clk_rst <= '0;
		@(posedge atb_atclk);
		atb_atresetn <= 1'b1;

		configure_decoder();
		@(posedge tip_clk);

		ct_cs_wb.Read_te_trTeControl(read_data);
		prev_dec_id = -1;
		last_dec_msg_id = -1;
		last_dec_tcode = -1;
		sync_msg_count = 0;
		axis_msg_count = 0;
		daq_nexus_msg_count = 0;
		saw_tstamp = 1'b0;
		test_id = 0;

		TipTSetDefault(tipt);
		tipt.iretire = '1;
		tipt.itype = OTHER;
		tipt.ilastsize = 2;

		item.tip = tipt;
		item.tip.iaddr = 32'h1234_0000;
		cmd = '{default: '0};
		cmd.DirectData.value = 24'h11_2233;
		cmd.Sink.value = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS;
		cmd.Cmd.value = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR;
		item.tip.dtype = CSR_READ_WRITE;
		item.tip.daddr = ACT_CAP_CMD;
		item.tip.data = cmd_to_tip_data(cmd);
		item.tip.dsize = 2;
		item.tip.dretire = '1;
		item.tip.iretire = '1;
		item.delay = 0;
		item.desc = "AXIS-only DAQ_PC_CURR with DirectData";
		item.test_id = test_id;
		test_id++;
		send_tip_item(item);
		wait_for_axis_msg(
			"axis_pc_curr",
			item.test_id,
			item.desc,
			ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR,
			3'b011,
			32'h1234_0000,
			pack_expected_axis_direct_data(24'h11_2233),
			32'h0,
			AXIS_TIMEOUT_CYCLES
		);

		item.tip = tipt;
		item.tip.iaddr = 32'h1234_1000;
		cmd = '{default: '0};
		cmd.DirectData.value = 24'h42_0000;
		cmd.Sink.value = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS;
		cmd.Cmd.value = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR;
		item.tip.dtype = CSR_READ_WRITE;
		item.tip.daddr = ACT_CAP_CMD;
		item.tip.data = cmd_to_tip_data(cmd);
		item.tip.dsize = 2;
		item.tip.dretire = '1;
		item.tip.iretire = '1;
		item.delay = 0;
		item.desc = "NEXUS-only DAQ_PC_CURR with DirectData";
		item.test_id = test_id;
		test_id++;
		send_tip_item(item);

		item.tip = tipt;
		item.tip.iaddr = 32'h1234_2000;
		cmd = '{default: '0};
		cmd.DirectData.value = 24'h00_0043;
		cmd.Sink.value = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS_NEXUS;
		cmd.Cmd.value = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR;
		item.tip.dtype = CSR_READ_WRITE;
		item.tip.daddr = ACT_CAP_CMD;
		item.tip.data = cmd_to_tip_data(cmd);
		item.tip.dsize = 2;
		item.tip.dretire = '1;
		item.tip.iretire = '1;
		item.delay = 0;
		item.desc = "AXIS+NEXUS DAQ_PC_CURR with DirectData";
		item.test_id = test_id;
		test_id++;
		send_tip_item(item);
		wait_for_axis_msg(
			"axis_nexus_pc_curr_axis",
			item.test_id,
			item.desc,
			ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR,
			3'b011,
			32'h1234_2000,
			pack_expected_axis_direct_data(24'h00_0043),
			32'h0,
			AXIS_TIMEOUT_CYCLES
		);

		item.tip = tipt;
		item.tip.iaddr = 32'h1234_3000;
		cmd = '{default: '0};
		cmd.DirectData.value = 24'h00_A5C3;
		cmd.Sink.value = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS;
		cmd.Cmd.value = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DIRECT_DATA;
		item.tip.dtype = CSR_READ_WRITE;
		item.tip.daddr = ACT_CAP_CMD;
		item.tip.data = cmd_to_tip_data(cmd);
		item.tip.dsize = 2;
		item.tip.dretire = '1;
		item.tip.iretire = '1;
		item.delay = 0;
		item.desc = "AXIS-only DAQ_DIRECT_DATA";
		item.test_id = test_id;
		test_id++;
		send_tip_item(item);
		wait_for_axis_msg(
			"axis_direct_data",
			item.test_id,
			item.desc,
			ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DIRECT_DATA,
			3'b001,
			pack_expected_axis_direct_data(24'h00_A5C3),
			32'h0,
			32'h0,
			AXIS_TIMEOUT_CYCLES
		);

		item.tip = tipt;
		item.tip.iaddr = 32'h1234_4000;
		cmd = '{default: '0};
		cmd.DirectData.value = 24'h00_CC66;
		cmd.Sink.value = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS;
		cmd.Cmd.value = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DIRECT_DATA;
		item.tip.dtype = CSR_READ_WRITE;
		item.tip.daddr = ACT_CAP_CMD;
		item.tip.data = cmd_to_tip_data(cmd);
		item.tip.dsize = 2;
		item.tip.dretire = '1;
		item.tip.iretire = '1;
		item.delay = 0;
		item.desc = "NEXUS-only DAQ_DIRECT_DATA";
		item.test_id = test_id;
		test_id++;
		send_tip_item(item);

		item.tip = tipt;
		item.tip.iaddr = 32'h2000_0000;
		item.tip.iretire = '1;
		item.tip.itype = OTHER;
		item.tip.dretire = '1;
		item.tip.dtype = STORE;
		item.tip.daddr = 32'h8000_0300;
		item.tip.dsize = 3;
		item.tip.data = 64'h0123_4567_89AB_CDEF;
		item.delay = 0;
		item.desc = "Seed previous data context for DAQ_DATA";
		item.test_id = test_id;
		test_id++;
		send_tip_item(item);

		item.tip = tipt;
		item.tip.iaddr = 32'h1234_5000;
		cmd = '{default: '0};
		cmd.DirectData.value = 24'h00_1234;
		cmd.Sink.value = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS;
		cmd.Cmd.value = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA;
		item.tip.dtype = CSR_READ_WRITE;
		item.tip.daddr = ACT_CAP_CMD;
		item.tip.data = cmd_to_tip_data(cmd);
		item.tip.dsize = 2;
		item.tip.dretire = '1;
		item.tip.iretire = '1;
		item.delay = 0;
		item.desc = "AXIS-only DAQ_DATA";
		item.test_id = test_id;
		test_id++;
		send_tip_item(item);
			wait_for_axis_msg(
				"axis_data",
				item.test_id,
				item.desc,
			ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA,
			3'b011,
			32'h89AB_CDEF,
			pack_expected_axis_dtype_dsize(STORE, tip_dsize_t'(3)),
				32'h0,
				AXIS_TIMEOUT_CYCLES
			);

			item.tip = tipt;
			item.tip.iaddr = 32'h2000_0002;
			item.tip.iretire = '1;
			item.tip.itype = OTHER;
			item.tip.dretire = '1;
			item.tip.dtype = STORE;
			item.tip.daddr = 32'h8000_0310;
			item.tip.dsize = 3;
			item.tip.data = 64'hFEDC_BA98_7654_3210;
			item.delay = 0;
			item.desc = "Reseed previous data context for NEXUS DAQ_DATA";
			item.test_id = test_id;
			test_id++;
			send_tip_item(item);

			item.tip = tipt;
			item.tip.iaddr = 32'h1234_5800;
			cmd = '{default: '0};
			cmd.DirectData.value = 24'h00_3456;
			cmd.Sink.value = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS;
			cmd.Cmd.value = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA;
			item.tip.dtype = CSR_READ_WRITE;
			item.tip.daddr = ACT_CAP_CMD;
			item.tip.data = cmd_to_tip_data(cmd);
			item.tip.dsize = 2;
			item.tip.dretire = '1;
			item.tip.iretire = '1;
			item.delay = 0;
			item.desc = "NEXUS-only DAQ_DATA";
			item.test_id = test_id;
			test_id++;
			send_tip_item(item);

		item.tip = tipt;
		item.tip.iaddr = 32'h2000_0004;
		item.tip.iretire = '1;
		item.tip.itype = OTHER;
		item.tip.dretire = '1;
		item.tip.dtype = STORE;
		item.tip.daddr = 32'h8000_0300;
		item.tip.dsize = 3;
		item.tip.data = 64'h0123_4567_89AB_CDEF;
		item.delay = 0;
		item.desc = "Seed previous data context for DAQ_DADDR";
		item.test_id = test_id;
		test_id++;
		send_tip_item(item);

		item.tip = tipt;
		item.tip.iaddr = 32'h1234_6000;
		cmd = '{default: '0};
		cmd.DirectData.value = 24'h00_5678;
		cmd.Sink.value = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS;
		cmd.Cmd.value = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DADDR;
		item.tip.dtype = CSR_READ_WRITE;
		item.tip.daddr = ACT_CAP_CMD;
		item.tip.data = cmd_to_tip_data(cmd);
		item.tip.dsize = 2;
		item.tip.dretire = '1;
		item.tip.iretire = '1;
		item.delay = 0;
		item.desc = "AXIS-only DAQ_DADDR";
		item.test_id = test_id;
		test_id++;
		send_tip_item(item);
			wait_for_axis_msg(
				"axis_daddr",
				item.test_id,
				item.desc,
			ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DADDR,
			3'b011,
			32'h8000_0300,
			pack_expected_axis_dtype_dsize(STORE, tip_dsize_t'(3)),
				32'h0,
				AXIS_TIMEOUT_CYCLES
			);

			item.tip = tipt;
			item.tip.iaddr = 32'h2000_0006;
			item.tip.iretire = '1;
			item.tip.itype = OTHER;
			item.tip.dretire = '1;
			item.tip.dtype = LOAD;
			item.tip.daddr = 32'h8000_0410;
			item.tip.dsize = 2;
			item.tip.data = 64'hDEAD_BEEF_0123_4567;
			item.delay = 0;
			item.desc = "Reseed previous data context for NEXUS DAQ_DADDR";
			item.test_id = test_id;
			test_id++;
			send_tip_item(item);

			item.tip = tipt;
			item.tip.iaddr = 32'h1234_6800;
			cmd = '{default: '0};
			cmd.DirectData.value = 24'h00_89AB;
			cmd.Sink.value = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS;
			cmd.Cmd.value = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DADDR;
			item.tip.dtype = CSR_READ_WRITE;
			item.tip.daddr = ACT_CAP_CMD;
			item.tip.data = cmd_to_tip_data(cmd);
			item.tip.dsize = 2;
			item.tip.dretire = '1;
			item.tip.iretire = '1;
			item.delay = 0;
			item.desc = "NEXUS-only DAQ_DADDR";
			item.test_id = test_id;
			test_id++;
			send_tip_item(item);

		item.tip = tipt;
		item.tip.iaddr = 32'h2000_0008;
		item.tip.iretire = '1;
		item.tip.itype = OTHER;
		item.tip.dretire = '1;
		item.tip.dtype = STORE;
		item.tip.daddr = 32'h8000_0300;
		item.tip.dsize = 3;
		item.tip.data = 64'h0123_4567_89AB_CDEF;
		item.delay = 0;
		item.desc = "Seed previous data context for DAQ_DATA_DADDR";
		item.test_id = test_id;
		test_id++;
		send_tip_item(item);

		item.tip = tipt;
		item.tip.iaddr = 32'h1234_7000;
		cmd = '{default: '0};
		cmd.DirectData.value = 24'h00_9ABC;
		cmd.Sink.value = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS;
		cmd.Cmd.value = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_DADDR;
		item.tip.dtype = CSR_READ_WRITE;
		item.tip.daddr = ACT_CAP_CMD;
		item.tip.data = cmd_to_tip_data(cmd);
		item.tip.dsize = 2;
		item.tip.dretire = '1;
		item.tip.iretire = '1;
		item.delay = 0;
		item.desc = "AXIS-only DAQ_DATA_DADDR";
		item.test_id = test_id;
		test_id++;
		send_tip_item(item);
			wait_for_axis_msg(
				"axis_data_daddr",
				item.test_id,
				item.desc,
			ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_DADDR,
			3'b111,
			32'h89AB_CDEF,
			32'h8000_0300,
				pack_expected_axis_dtype_dsize(STORE, tip_dsize_t'(3)),
				AXIS_TIMEOUT_CYCLES
			);

			item.tip = tipt;
			item.tip.iaddr = 32'h2000_000A;
			item.tip.iretire = '1;
			item.tip.itype = OTHER;
			item.tip.dretire = '1;
			item.tip.dtype = STORE;
			item.tip.daddr = 32'h8000_0510;
			item.tip.dsize = 4;
			item.tip.data = 64'h1357_9BDF_2468_ACE0;
			item.delay = 0;
			item.desc = "Reseed previous data context for NEXUS DAQ_DATA_DADDR";
			item.test_id = test_id;
			test_id++;
			send_tip_item(item);

			item.tip = tipt;
			item.tip.iaddr = 32'h1234_7800;
			cmd = '{default: '0};
			cmd.DirectData.value = 24'h00_CDEF;
			cmd.Sink.value = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS;
			cmd.Cmd.value = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_DADDR;
			item.tip.dtype = CSR_READ_WRITE;
			item.tip.daddr = ACT_CAP_CMD;
			item.tip.data = cmd_to_tip_data(cmd);
			item.tip.dsize = 2;
			item.tip.dretire = '1;
			item.tip.iretire = '1;
			item.delay = 0;
			item.desc = "NEXUS-only DAQ_DATA_DADDR";
			item.test_id = test_id;
			test_id++;
			send_tip_item(item);

		repeat (PRE_FLUSH_IDLE_ATB_CYCLES) @(posedge atb_atclk);
		issue_atb_flush("daq_nexus_flush");
		wait_for_decoded_nexus_msg("daq_nexus_pc_curr", NEXUS_MSG_DATA_ACQUISITION, ETIP_TIMEOUT_CYCLES);
		check_decoded_daq(
			"daq_nexus_pc_curr",
			ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR,
			pack_expected_daq_pc_curr(32'h1234_1000, 24'h42_0000)
		);
		wait_for_decoded_nexus_msg("daq_axis_nexus_pc_curr", NEXUS_MSG_DATA_ACQUISITION, ETIP_TIMEOUT_CYCLES);
		check_decoded_daq(
			"daq_axis_nexus_pc_curr",
			ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR,
			pack_expected_daq_pc_curr(32'h1234_2000, 24'h00_0043)
		);
		wait_for_decoded_nexus_msg("daq_nexus_direct_data", NEXUS_MSG_DATA_ACQUISITION, ETIP_TIMEOUT_CYCLES);
			check_decoded_daq(
				"daq_nexus_direct_data",
				ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DIRECT_DATA,
				pack_expected_daq_direct_data(24'h00_CC66)
			);
			wait_for_decoded_nexus_msg("daq_nexus_data", NEXUS_MSG_DATA_ACQUISITION, ETIP_TIMEOUT_CYCLES);
			check_decoded_daq(
				"daq_nexus_data",
				ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA,
				pack_expected_daq_data(64'hFEDC_BA98_7654_3210, STORE, tip_dsize_t'(3), 24'h00_3456)
			);
			wait_for_decoded_nexus_msg("daq_nexus_daddr", NEXUS_MSG_DATA_ACQUISITION, ETIP_TIMEOUT_CYCLES);
			check_decoded_daq(
				"daq_nexus_daddr",
				ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DADDR,
				pack_expected_daq_daddr(32'h8000_0410, LOAD, tip_dsize_t'(2), 24'h00_89AB)
			);
			wait_for_decoded_nexus_msg("daq_nexus_data_daddr", NEXUS_MSG_DATA_ACQUISITION, ETIP_TIMEOUT_CYCLES);
			check_decoded_daq(
				"daq_nexus_data_daddr",
				ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_DADDR,
				pack_expected_daq_data_daddr(64'h1357_9BDF_2468_ACE0, 32'h8000_0510, STORE, tip_dsize_t'(4), 24'h00_CDEF)
			);

		void'(tt_assert(sync_msg_count == 0,
			$sformatf("%0.2f: Line %0d: expected no sync messages, got %0d",
				$realtime, `__LINE__, sync_msg_count)));
		void'(tt_assert(axis_msg_count == 6,
			$sformatf("%0.2f: Line %0d: expected exactly 6 AXIS DAQ messages, got %0d",
				$realtime, `__LINE__, axis_msg_count)));
			void'(tt_assert(daq_nexus_msg_count == 6,
				$sformatf("%0.2f: Line %0d: expected exactly 6 Nexus DAQ messages, got %0d",
					$realtime, `__LINE__, daq_nexus_msg_count)));
		void'(tt_assert(saw_tstamp == 1'b1,
			$sformatf("%0.2f: Line %0d: expected at least one decoded message with TSTAMP field present",
				$realtime, `__LINE__)));

		FeedingDone <= 1'b1;
		AxisCheckingDone <= 1'b1;
		EtipCheckingDone <= 1'b1;

		repeat (10) @(posedge tip_clk);

		tt_evaluate();
		$finish();
	end

endmodule
