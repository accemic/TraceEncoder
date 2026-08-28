// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief  Protocol-as-synthesis-parameter leg (cli_etrace_test.sh mixed).
 *
 * @details
 *   P9 replaced the runtime protocol select with a per-INSTANCE synthesis
 *   parameter, so the property to prove is no longer "one encoder can be
 *   flipped" but "two encoders in ONE netlist can speak DIFFERENT
 *   protocols, and each reports its own truth" -- the Trio/mixed-SoC case.
 *
 *   Two ct_encoder instances are elaborated side by side out of the same
 *   sources, one N-Trace (EN_NTRACE=1/EN_ETRACE=0), one E-Trace
 *   (EN_NTRACE=0/EN_ETRACE=1), each with its own Wishbone CSR port. The
 *   test checks, per instance:
 *     - `atb_te_raw`, the ATB framing advertisement toward a funnel/sink
 *       (0 = Nexus MSEO/MDO chunks, 1 = E-Trace reference-raw te_inst),
 *     - `trTeProtocolSel.Protocol` @ 0x030 (read-only discovery),
 *     - `trTeImpl.ProtocolMajor` @ 0x004 (1 = N-Trace 1.x, 2 = E-Trace 2.x),
 *     - the READ-ONLYness of that discovery: writing the opposite protocol
 *       into an instance must leave both mirrors untouched.
 *
 *   The discovery registers are hardware-driven (sw=r/hw=w) exactly so
 *   they cannot lie here: a profile-wide RDL constant would report the
 *   same protocol for both instances, and a writable field would let
 *   software install a second truth next to the netlist.
 *
 *   Build profile: this leg runs in the E-Trace profile (ct_pkg
 *   CT_EN_ETRACE=1) because ct_pkg is the NETLIST master for the eTIP
 *   sideband widths -- an E-Trace back end needs the full ecause/tval/
 *   priv/ilastsize sideband. The N-Trace instance is unaffected by the
 *   wider sideband.
 *
 *   No stimulus and no ATB stream: the trace datapaths are exercised by
 *   the protocol-specific legs of this suite. What is unique here is the
 *   ELABORATION of two differently parameterised encoders plus their
 *   per-instance discovery -- neither is observable in a single-instance
 *   testbench.
 */

module protocol_param_tb;

	import ct_cs_cpuif_wb_pkg::*;

	localparam int WB_DATA_WIDTH = 32;
	localparam int WB_ADDR_WIDTH = 32;

	// ------------------------------------------------------------------
	// Clocks / resets (one domain -- nothing here is timing sensitive)
	// ------------------------------------------------------------------
	logic clk          = 0;
	logic tip_rst      = 1;
	logic proc_rst     = 1;
	logic wb_rst       = 1;
	logic ct_cs_rst    = 1;
	logic wall_clk_rst = 1;
	logic atb_atresetn = 0;

	initial forever #5ns clk = ~clk;

	initial begin
		#80ns;
		@(posedge clk); tip_rst      <= 0;
		@(posedge clk); atb_atresetn <= 1;
		@(posedge clk); proc_rst     <= 0;
		@(posedge clk); wb_rst       <= 0;
		@(posedge clk); ct_cs_rst    <= 0;
		@(posedge clk); wall_clk_rst <= 0;
	end

	// ------------------------------------------------------------------
	// Interfaces (one set per encoder)
	// ------------------------------------------------------------------
	tip_if  tip_n ();
	tip_if  tip_e ();
	wb_if  #(.DATA_WIDTH(WB_DATA_WIDTH), .ADDR_WIDTH(WB_ADDR_WIDTH)) wb_n ();
	wb_if  #(.DATA_WIDTH(WB_DATA_WIDTH), .ADDR_WIDTH(WB_ADDR_WIDTH)) wb_e ();
	axis_if axis_n (.aclk(clk), .aresetn(~wb_rst));
	axis_if axis_e (.aclk(clk), .aresetn(~wb_rst));
	atb_if  atb_n ();
	atb_if  atb_e ();

	uwire logic te_raw_n;
	uwire logic te_raw_e;

	// Idle TIP / always-ready sinks. The encoders are never enabled, so
	// this only keeps every input at a defined level (no X into the SVA
	// invariants). Written out per interface rather than through a virtual
	// interface handle -- Verilator (coverage flow) does not support those.
	`define CT_IDLE_TIP(t) \
		t.itype      = tip_pkg::tip_itype_e'(0); \
		t.ecause     = tip_pkg::tip_ecause_e'(0); \
		t.tval       = '0; \
		t.priv       = '0; \
		t.iaddr      = '0; \
		t._context   = '0; \
		t._time      = '0; \
		t.ctype      = '0; \
		t.iretire    = '0; \
		t.ilastsize  = '0; \
		t.impdef     = '0; \
		t.dretire    = '0; \
		t.dtype      = tip_pkg::tip_dtype_e'(0); \
		t.daddr      = '0; \
		t.dsize      = '0; \
		t.data       = '0; \
		t.sdata      = '0; \
		t.lresp      = '0; \
		t.ldata      = '0; \
		t.debug_mode = '0; \
		t.evti       = '0; \
		t.power_down = '0; \
		t.trigger    = '0;

	initial begin
		`CT_IDLE_TIP(tip_n)
		`CT_IDLE_TIP(tip_e)
		atb_n.atready = 1'b1; atb_n.afvalid = 1'b0; atb_n.syncreq = 1'b0;
		atb_e.atready = 1'b1; atb_e.afvalid = 1'b0; atb_e.syncreq = 1'b0;
		axis_n.tready = 1'b1;
		axis_e.tready = 1'b1;
	end

	// ------------------------------------------------------------------
	// DUTs -- SAME sources, DIFFERENT back end per instance
	// ------------------------------------------------------------------
	// CORE_XLEN (P0-07): both instances are driven by TIP interfaces of this
	// netlist's width -- same waiver as tests/lib/ct_env.sv, tracked by
	// scripts/check_core_xlen.py.
	ct_encoder #(.EN_NTRACE(1), .EN_ETRACE(0), .CORE_XLEN(ct_pkg::CT_XLEN)) enc_n (
		.tip_clk (clk), .tip_rst, .tip (tip_n),
		.wb_clk  (clk), .wb_rst,  .wb  (wb_n),  .ct_cs_rst,
		.axis    (axis_n),
		.atb_atclk (clk), .atb_atresetn, .atb (atb_n), .atb_te_raw (te_raw_n),
		.proc_clk (clk), .proc_rst,
		.wall_clk (clk), .wall_clk_rst
	);

	ct_encoder #(.EN_NTRACE(0), .EN_ETRACE(1), .CORE_XLEN(ct_pkg::CT_XLEN)) enc_e (
		.tip_clk (clk), .tip_rst, .tip (tip_e),
		.wb_clk  (clk), .wb_rst,  .wb  (wb_e),  .ct_cs_rst,
		.axis    (axis_e),
		.atb_atclk (clk), .atb_atresetn, .atb (atb_e), .atb_te_raw (te_raw_e),
		.proc_clk (clk), .proc_rst,
		.wall_clk (clk), .wall_clk_rst
	);

	ct_cs_cpuif_wb_helper csr_n (.clk (clk), .wb (wb_n.master));
	ct_cs_cpuif_wb_helper csr_e (.clk (clk), .wb (wb_e.master));

	// ------------------------------------------------------------------
	// Checks
	// ------------------------------------------------------------------
	int errors = 0;

	task automatic chk(input string what, input int unsigned got, input int unsigned exp);
		if (got !== exp) begin
			$display("[protocol_param_tb] FAIL: %s = %0d (expected %0d)", what, got, exp);
			errors++;
		end
		else begin
			$display("[protocol_param_tb] ok:   %s = %0d", what, got);
		end
	endtask

	initial begin
		logic [31:0] d;

		wait (wb_rst == 1'b0);
		wait (ct_cs_rst == 1'b0);
		repeat (8) @(posedge clk);
		csr_n.clear();
		csr_e.clear();
		repeat (4) @(posedge clk);

		// Framing advertisement toward the funnel (ATB domain constant).
		chk("enc_n.atb_te_raw", te_raw_n, 0);
		chk("enc_e.atb_te_raw", te_raw_e, 1);

		// Per-instance discovery over the instance's own CSR port.
		csr_n.read(ADDR_TE_TRTEPROTOCOLSEL, d);
		chk("enc_n trTeProtocolSel.Protocol", d[BITPOS_te_trTeProtocolSel_Protocol], 0);
		csr_e.read(ADDR_TE_TRTEPROTOCOLSEL, d);
		chk("enc_e trTeProtocolSel.Protocol", d[BITPOS_te_trTeProtocolSel_Protocol], 1);

		csr_n.read(ADDR_TE_TRTEIMPL, d);
		chk("enc_n trTeImpl.ProtocolMajor", d[BITPOS_te_trTeImpl_ProtocolMajor_MSB -: 4], 1);
		csr_e.read(ADDR_TE_TRTEIMPL, d);
		chk("enc_e trTeImpl.ProtocolMajor", d[BITPOS_te_trTeImpl_ProtocolMajor_MSB -: 4], 2);

		// --- negative leg: the discovery register is READ-ONLY ----------
		// The field is sw=r/hw=w, so a software write must be swallowed.
		// Each instance is written the OPPOSITE protocol -- the value that
		// would make its own discovery register lie -- once alone and once
		// with every other bit of the word set. The guard exists because
		// the register WAS writable before P9 (runtime protocol select):
		// an RDL regen that restores sw=rw would resurrect a second,
		// software-programmed truth next to the netlist, and nothing else
		// in the suite would notice.
		csr_n.write(ADDR_TE_TRTEPROTOCOLSEL, 32'h0000_0001);
		repeat (4) @(posedge clk);
		csr_n.read(ADDR_TE_TRTEPROTOCOLSEL, d);
		chk("enc_n Protocol after write 1", d[BITPOS_te_trTeProtocolSel_Protocol], 0);
		csr_n.write(ADDR_TE_TRTEPROTOCOLSEL, 32'hffff_ffff);
		repeat (4) @(posedge clk);
		csr_n.read(ADDR_TE_TRTEPROTOCOLSEL, d);
		chk("enc_n Protocol after write ffffffff", d[BITPOS_te_trTeProtocolSel_Protocol], 0);

		csr_e.write(ADDR_TE_TRTEPROTOCOLSEL, 32'h0000_0000);
		repeat (4) @(posedge clk);
		csr_e.read(ADDR_TE_TRTEPROTOCOLSEL, d);
		chk("enc_e Protocol after write 0", d[BITPOS_te_trTeProtocolSel_Protocol], 1);
		csr_e.write(ADDR_TE_TRTEPROTOCOLSEL, 32'hffff_fffe);
		repeat (4) @(posedge clk);
		csr_e.read(ADDR_TE_TRTEPROTOCOLSEL, d);
		chk("enc_e Protocol after write fffffffe", d[BITPOS_te_trTeProtocolSel_Protocol], 1);

		// The write must not have disturbed the second discovery mirror
		// either (same hw-driven pattern, different register).
		csr_n.read(ADDR_TE_TRTEIMPL, d);
		chk("enc_n ProtocolMajor after writes", d[BITPOS_te_trTeImpl_ProtocolMajor_MSB -: 4], 1);
		csr_e.read(ADDR_TE_TRTEIMPL, d);
		chk("enc_e ProtocolMajor after writes", d[BITPOS_te_trTeImpl_ProtocolMajor_MSB -: 4], 2);

		if (errors == 0)
			$display("[protocol_param_tb] PASS -- two encoders, two protocols, one netlist");
		else
			$display("[protocol_param_tb] FAIL -- %0d check(s) failed", errors);

		$finish;
	end

	// Watchdog: a hung Wishbone read must not look like a pass.
	initial begin
		#200us;
		$display("[protocol_param_tb] FAIL -- watchdog timeout");
		$finish;
	end

endmodule

`undef CT_IDLE_TIP

`default_nettype wire
