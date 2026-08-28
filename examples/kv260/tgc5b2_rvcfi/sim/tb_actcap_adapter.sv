// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`timescale 1ns / 1ps
`default_nettype none

/**
 * @brief    Self-checking unit TB for ct_tip_adapter_actcap.
 *
 * @details
 *   Two DUT instances are driven from ONE stimulus stream: `dut_on`
 *   (`EN_DOORBELL=1`) and `dut_off` (`EN_DOORBELL=0`). That makes the
 *   central property a *differential* one rather than an absolute one --
 *   every beat is checked twice, and `dut_off` doubles as the proof that the
 *   addition is inert when switched off, i.e. that the adapter still behaves
 *   exactly like the reference `ct_tip_adapter` for a future core that
 *   reports CSR writes itself.
 *
 *     (a) control-flow fields pass through untouched, in BOTH instances --
 *         the doorbell must not disturb the instruction stream
 *     (b) ordinary store: dtype=STORE, daddr/sdata forwarded, tip.data = 0
 *         (the reference adapter's split-data contract)
 *     (c) ordinary load: dretire=0, lresp/ldata forwarded (the TGC5B reports
 *         loads via lresp, NOT via dretire -- see the KV260 example README)
 *     (d) DOORBELL store -> dtype=CSR_READ_WRITE, daddr=0x0B10,
 *         tip.data = the stored word, sdata cleared.
 *         `tip.data` is the one that matters: ACT-CAP decodes `data`, so an
 *         adapter that forwarded the word on `sdata` only would decode every
 *         command as ACT_CAP_ST_NONE -- a silent no-op with no error
 *         anywhere. This case is the guard against that.
 *     (e) the SAME beat in `dut_off` is NOT converted -- the differential
 *         proof that (d) is caused by the addition and not by something else
 *     (f) a store to an address NEAR the doorbell is not converted (no
 *         partial address decode)
 *     (g) a LOAD from the doorbell address is not converted (the trigger is
 *         a store, and a load carries no data to convert)
 *     (h) `actcap_count` counts exactly the converted beats and `actcap_hit`
 *         pulses with them -- the number the host compares against the
 *         records it received
 *     (i) no X on the TIP fields the adapter drives
 */

module tb_actcap_adapter;
	import tip_pkg::*;

	localparam logic [31:0] DOORBELL = 32'h4000_0000;

	logic clk = 1'b0;
	logic rst = 1'b1;
	always #5 clk = ~clk;

	// -- H2E stimulus ------------------------------------------------------
	logic [3:0]  i_itype, i_cause, d_dtype;
	logic [31:0] i_tval, i_iaddr, d_daddr, d_sdata, d_ldata;
	logic [2:0]  i_priv;
	logic [1:0]  i_context, i_ctype, i_ilastsize, d_lresp;
	logic [63:0] i_time;
	logic        i_iretire, d_dretire;
	logic [7:0]  d_dsize;

	tip_if tip_on ();
	tip_if tip_off ();
	logic        hit_on,  hit_off;
	logic [31:0] cnt_on,  cnt_off;

	int checks;

	ct_tip_adapter_actcap #(.DOORBELL_ADDR(DOORBELL), .EN_DOORBELL(1'b1)) dut_on (
		.clk(clk), .rst(rst),
		.h2e_inst_itype(i_itype), .h2e_inst_cause(i_cause), .h2e_inst_tval(i_tval),
		.h2e_inst_priv(i_priv), .h2e_inst_iaddr(i_iaddr), .h2e_inst_context(i_context),
		.h2e_inst_time(i_time), .h2e_inst_ctype(i_ctype), .h2e_inst_iretire(i_iretire),
		.h2e_inst_ilastsize(i_ilastsize),
		.h2e_data_dtype(d_dtype), .h2e_data_daddr(d_daddr), .h2e_data_dsize(d_dsize),
		.h2e_data_dretire(d_dretire), .h2e_data_sdata(d_sdata),
		.h2e_data_lresp(d_lresp), .h2e_data_ldata(d_ldata),
		.tip(tip_on), .actcap_hit(hit_on), .actcap_count(cnt_on)
	);

	ct_tip_adapter_actcap #(.DOORBELL_ADDR(DOORBELL), .EN_DOORBELL(1'b0)) dut_off (
		.clk(clk), .rst(rst),
		.h2e_inst_itype(i_itype), .h2e_inst_cause(i_cause), .h2e_inst_tval(i_tval),
		.h2e_inst_priv(i_priv), .h2e_inst_iaddr(i_iaddr), .h2e_inst_context(i_context),
		.h2e_inst_time(i_time), .h2e_inst_ctype(i_ctype), .h2e_inst_iretire(i_iretire),
		.h2e_inst_ilastsize(i_ilastsize),
		.h2e_data_dtype(d_dtype), .h2e_data_daddr(d_daddr), .h2e_data_dsize(d_dsize),
		.h2e_data_dretire(d_dretire), .h2e_data_sdata(d_sdata),
		.h2e_data_lresp(d_lresp), .h2e_data_ldata(d_ldata),
		.tip(tip_off), .actcap_hit(hit_off), .actcap_count(cnt_off)
	);

	task automatic chk(input string what, input logic cond);
		if (!cond) $fatal(1, "FAIL: %s", what);
		checks++;
	endtask

	// Drive one H2E beat and settle (the adapter is combinational, the
	// counter is not -- so we sample after the edge).
	task automatic beat(input logic        dretire,
	                    input logic [3:0]  dtype,
	                    input logic [31:0] daddr,
	                    input logic [31:0] sdata,
	                    input logic [1:0]  lresp = 2'b00,
	                    input logic [31:0] ldata = 32'h0);
		d_dretire = dretire;
		d_dtype   = dtype;
		d_daddr   = daddr;
		d_sdata   = sdata;
		d_lresp   = lresp;
		d_ldata   = ldata;
		d_dsize   = 8'd2;
		#1;                                  // combinational settle
	endtask

	task automatic idle();
		beat(1'b0, 4'd0, 32'h0, 32'h0);
		@(posedge clk);
		#1;
	endtask

	initial begin : main
		// A recognisable instruction context, constant across the run so any
		// disturbance of the control-flow half is visible immediately.
		i_itype     = 4'd5;                  // TAKEN_BRANCH
		i_cause     = 4'd0;
		i_tval      = 32'h0;
		i_priv      = 3'b011;
		i_iaddr     = 32'h0000_1234;
		i_context   = 2'b01;
		i_time      = 64'd987_654;
		i_ctype     = 2'b00;
		i_iretire   = 1'b1;
		i_ilastsize = 2'b01;
		checks      = 0;
		beat(1'b0, 4'd0, 32'h0, 32'h0);

		repeat (4) @(posedge clk);
		rst <= 1'b0;
		repeat (2) @(posedge clk);
		#1;

		// ---- (a) control flow untouched in both ---------------------------
		chk("(a) on itype",     tip_on.itype     === TAKEN_BRANCH);
		chk("(a) on iaddr",     tip_on.iaddr     === 32'h0000_1234);
		chk("(a) on _time",     tip_on._time     === 64'd987_654);
		chk("(a) on iretire",   tip_on.iretire   === 1'b1);
		chk("(a) on ilastsize", tip_on.ilastsize === 2'b01);
		chk("(a) on priv",      tip_on.priv      === 3'b011);
		chk("(a) off itype",    tip_off.itype    === TAKEN_BRANCH);
		chk("(a) off iaddr",    tip_off.iaddr    === 32'h0000_1234);
		$display("TB (a) control flow untouched : OK");

		// ---- (b) ordinary store -------------------------------------------
		beat(1'b1, 4'd1, 32'h0000_2000, 32'hFEED_FACE);
		chk("(b) dretire", tip_on.dretire === 1'b1);
		chk("(b) dtype STORE", tip_on.dtype === STORE);
		chk("(b) daddr", tip_on.daddr === 32'h0000_2000);
		chk("(b) sdata", tip_on.sdata === 32'hFEED_FACE);
		chk("(b) data stays 0 (split-data contract)", tip_on.data === '0);
		chk("(b) no conversion", hit_on === 1'b0);
		$display("TB (b) ordinary store         : OK");

		// ---- (c) ordinary load --------------------------------------------
		beat(1'b0, 4'd0, 32'h0000_3000, 32'h0, 2'b10, 32'h1234_5678);
		chk("(c) dretire 0 (TGC5B reports loads via lresp)", tip_on.dretire === 1'b0);
		chk("(c) lresp", tip_on.lresp === 2'b10);
		chk("(c) ldata", tip_on.ldata === 32'h1234_5678);
		chk("(c) no conversion", hit_on === 1'b0);
		$display("TB (c) ordinary load          : OK");

		// ---- (d)+(e) doorbell store, differential -------------------------
		beat(1'b1, 4'd1, DOORBELL, 32'h00AB_CD41);   // Cmd=1, Sink=1, tag
		chk("(d) dretire", tip_on.dretire === 1'b1);
		chk("(d) dtype CSR_READ_WRITE", tip_on.dtype === CSR_READ_WRITE);
		chk("(d) daddr 0x0B10", tip_on.daddr === 32'h0000_0B10);
		chk("(d) DATA carries the command word", tip_on.data === tip_data_t'(32'h00AB_CD41));
		chk("(d) sdata cleared", tip_on.sdata === '0);
		chk("(d) hit pulses", hit_on === 1'b1);
		// the differential half: EN_DOORBELL=0 must be untouched
		chk("(e) off dtype still STORE", tip_off.dtype === STORE);
		chk("(e) off daddr unchanged", tip_off.daddr === DOORBELL);
		chk("(e) off sdata forwarded", tip_off.sdata === 32'h00AB_CD41);
		chk("(e) off data still 0", tip_off.data === '0);
		chk("(e) off no hit", hit_off === 1'b0);
		@(posedge clk); #1;
		chk("(h) count 1", cnt_on === 32'd1);
		chk("(h) off count stays 0", cnt_off === 32'd0);
		$display("TB (d) doorbell -> CSR beat   : OK");
		$display("TB (e) EN_DOORBELL=0 inert    : OK");

		// ---- (f) neighbouring address -------------------------------------
		idle();
		beat(1'b1, 4'd1, DOORBELL + 4, 32'h1111_2222);
		chk("(f) not converted", tip_on.dtype === STORE);
		chk("(f) daddr unchanged", tip_on.daddr === DOORBELL + 4);
		chk("(f) no hit", hit_on === 1'b0);
		beat(1'b1, 4'd1, DOORBELL - 4, 32'h3333_4444);
		chk("(f') not converted", tip_on.dtype === STORE);
		chk("(f') no hit", hit_on === 1'b0);
		@(posedge clk); #1;
		chk("(f) count unchanged", cnt_on === 32'd1);
		$display("TB (f) neighbour not converted: OK");

		// ---- (g) LOAD from the doorbell address ---------------------------
		idle();
		beat(1'b0, 4'd0, DOORBELL, 32'h0, 2'b10, 32'hAAAA_BBBB);
		chk("(g) no conversion", hit_on === 1'b0);
		chk("(g) dretire still 0", tip_on.dretire === 1'b0);
		// and a dtype=STORE beat WITHOUT dretire must not convert either
		beat(1'b0, 4'd1, DOORBELL, 32'h5555_6666);
		chk("(g') dretire=0 store not converted", hit_on === 1'b0);
		@(posedge clk); #1;
		chk("(g) count unchanged", cnt_on === 32'd1);
		$display("TB (g) load/no-dretire        : OK");

		// ---- (h) counting a run of doorbells ------------------------------
		for (int n = 0; n < 5; n++) begin
			idle();
			beat(1'b1, 4'd1, DOORBELL, 32'h0000_0300 + n);
			chk("(h) hit", hit_on === 1'b1);
			chk("(h) data", tip_on.data === tip_data_t'(32'h0000_0300 + n));
			@(posedge clk); #1;
		end
		chk("(h) count 6", cnt_on === 32'd6);
		chk("(h) off still 0", cnt_off === 32'd0);
		$display("TB (h) conversion counting    : OK");

		// ---- (i) no X on what the adapter drives --------------------------
		idle();
		chk("(i) no X", !$isunknown({tip_on.itype, tip_on.iretire, tip_on.ilastsize,
		                             tip_on.dretire, tip_on.dtype, tip_on.daddr,
		                             tip_on.dsize, tip_on.data, tip_on.sdata,
		                             tip_on.lresp, tip_on.ldata, tip_on.iaddr,
		                             tip_on.ecause, tip_on.tval, tip_on.priv,
		                             tip_on._context, tip_on.ctype, tip_on.impdef}));
		$display("TB (i) no X on driven fields  : OK");

		$display("TB_PASS (tb_actcap_adapter): checks=%0d converted=%0d",
		         checks, cnt_on);
		$finish;
	end

	initial begin : watchdog
		#500_000;
		$fatal(1, "tb_actcap_adapter: watchdog");
	end

endmodule

`default_nettype wire
