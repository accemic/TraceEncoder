// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

// Ported from the archive tree (packages C1a/C1b);
// the body is unchanged in substance. What changed with the move:
//
//   * PROG_HEX / HITS_FILE now default to the artifacts in this example's
//     own sw/ directory, spelled relative to the simulator work dir
//     (bld/<task>.vsim), the same way examples/kv260/common/tgc5b/test/ct_soc_tb.sv
//     spells its program. The PowerShell runner used to copy them into the
//     run directory under the name prog.hex; nothing copies anything now.
//   * The file list comes from the .abc graph
//     (examples/kv260/tgc5b2_axis_wp/rtl/tgc5b2_axis_soc_top.abc), not from
//     a hand-maintained list in a runner script. `import @rtl : ct_encoder`
//     is THIS repository's encoder -- the archive bound a vendored copy
//     under third_party/CTTE, which no longer exists.
//   * Both legs are two-line wrapper modules, because `abc -sim` cannot pass
//     parameters (the runner did it with xelab -generic_top):
//       tb_tgc5b2_axis_soc_c1a.sv  defaults (13 real WPs, no TS checks)
//       tb_tgc5b2_axis_soc_c1b.sv  FULL_WP=1, CHECK_TS=1 (full oracle + TS)
//
// The comments and $display texts below were German until 2026-08-19 (the
// archive's verbatim wording). They are English now; the machine-checkable
// markers C1A_ALL_PASS / C1B_ALL_PASS, every number, every register offset
// and every log tag ([c1a_tb], [c1b_tb], [d2_tb], [t2_tb], [u1_tb], [u6_tb],
// [u9_tb]) are unchanged, so the recorded evidence under verification/evidence/ --
// which still carries the German lines -- stays comparable item for item.

// tb_tgc5b2_axis_soc -- package C1a: dual-TGC5b chain simulation of the AXIS
// watchpoint testbed (docs/PLAN_axis_wp_testbed.md §3 line C1).
//
// Sequence (devmem flow, after the tb_duo_ps_devmem pattern):
//   1. both RAMs loaded via INIT_FILE with sw/axis_wp_demo/axis_wp_demo.hex
//      (the runner copies the .hex as prog.hex into the XSIM run dir); the
//      loader path is verified by a read/write probe (RAM[0] == first hex
//      word, WALK_CTRL @0xE800 := 0 -- that cell lies OUTSIDE the image and
//      would otherwise read X, and main.c:114 branches on it).
//   2. with core_run=0, load the WP table for BOTH encoders -- since the
//      M0 sync (encoder = merge state 22ee86a366) ALWAYS over the INDIRECT
//      path (the direct window 0x4100 no longer exists, C0b BREAKING CHANGE
//      f612baff07): 13 real entry addresses (the 13 distinct P0 entries from
//      expected_hits.txt, hit early) on slots 0..12 + odd fillers up to slot
//      N_SLOTS-1 (rule: fill ALL trWpCap slots), strictly ascending; real
//      slots get Cmd = DAQ_PC_CURR(1)/Sink = AXIS(1)/DirectData = slot index
//      (the W1 cross-check), fillers get Cmd = ACT_CAP_ST_NONE; then the
//      trWpCap check + readback spot checks (both legs).
//   3. encoder base configuration as in the duo TB: trTeInstFeatures
//      SrcID=0/1 SrcBits=2 (RMW), then trTeControl = 0x0106_0067
//      (Active|Enable|InstTracing, InstMode=6, InstSyncMode=6, InhibitSrc=0)
//      -- the N-Trace stream is NOT a gate (capture trace_beats>0), and
//      ACT-ST itself is ungated by trTeControl in the vendored encoder
//      (handoff C1 §Analysis).
//   4. start the cores, let 64 walk phases run (E0: WALK_TOTAL_PHASES=64 of
//      2000 cycles each); the scoreboard collects the shim records of both
//      cores with a random-ready sink and compares the PC sequence EXACTLY
//      against the oracle sequence filtered onto the loaded addresses
//      (expected_hits.txt; both cores run the same program -> identical
//      sequence); W3 meta (core_id, tid=1, tstrb=0xFFF -- 3 elements,
//      CT_EN_AXIS_TS=1 in the synced encoder; the elem2 VALUE follows
//      trTsControl.Type, C1a leaves it at reset TR_TS_NONE and does not
//      check W2) and 0 drops in the ready case.
//   5. drop scenario: reprogram the WP table (cores in reset,
//      trTeControl=0) onto the halt address sampled from core_trace_pc,
//      stall the sink -> a 1-instruction loop floods the 256-entry FIFO ->
//      drop_count>0 + overflow_sticky; then resume, and every delivered
//      record is well formed again (drop granularity = whole record).
//
// THE TS CHECKS ARE PARAMETERISED (CHECK_TS): the synced encoder carries
// CT_EN_AXIS_TS=1 and ALWAYS strobes elem2 on DAQ_PC_CURR (tstrb=0xFFF,
// composer_axis -- only the VALUE follows trTsControl.Type, reset
// TR_TS_NONE delivers 0); C1a leaves Type at its reset and does not check
// W2, C1b switches CHECK_TS=1 on (TR_TS_CORE + W2 monotonicity +
// cross-core).
//
// C1b (FULL_WP=1, CHECK_TS=1 -- same vendored encoder, only the TB scope
// differs):
//   - ALL distinct expected_hits addresses are loaded (= wp_set∩hits, 364)
//     + odd fillers with Cmd=ACT_CAP_ST_NONE (the RDL padding rule) up to
//     N_SLOTS, strictly ascending (indirect path: trWpIndex@0x400C /
//     trWpDataLow@0x4010 / trWpDataHigh@0x4014; the high write commits and
//     increments Idx, wrapping at N_SLOTS-1).
//   - readback spot checks of slot 0 / N_SLOTS/2 / N_SLOTS-1 over
//     trWpReadLow/High@0x4018/1C (serial readback: ReadHigh.swacc = Idx++,
//     incl. wrap check) + trWpCap@0x4020 == N_SLOTS (both run in BOTH legs).
//   - negative probe: a commit attempt while trTeControl.Enable=1 must move
//     NOTHING (swwel lock + the !Enable commit gate of the C0b shim).
//   - trTsControl@0x040: Type=TR_TS_CORE (tip._time = fabric_time of both
//     encoders), RMW before the enable (Type is swwel-locked); CHECK_TS=1:
//     elem2 valid (tstrb 0xFFF), STRICTLY monotonic per core, cross-core
//     |ts0[k]-ts1[k]| <= TS_XTOL + merge monotonicity (ties allowed).
//   - FULL oracle: all 851 expected hits per core, in order, W1 = slot
//     index cross-check against the NEW 1023-slot ordering.
// The indirect load/readback checks log as [c1b_tb] (the historical tag of
// the C0b checks; they run in both legs since the M0 sync); the remaining
// shared paths keep [c1a_tb] verbatim.
//
// D2 (CHECK_DDR, default 1, both legs): the DDR4 sink (since T2 part of the
// three-sink subsystem ct_trace_sinks at the funnel output, CTRL 0x18..0x38)
// is armed before the ring clear (one-shot, reset window) and proven after
// the capture: DDR_BEATS (since T2 @0x38) == TRACE_BEATS, WPTR == 4*beats
// (drain poll), 0 drops/errors, model beats equal, first 16 words word-for-
// word identical ring<->DDR model (tag [d2_tb]).
//
// U1 (both legs, between the main and the drop scenario, tag [u1_tb]): the
// per-core run bits CONTROL b8/b9. For this the walk runs ENDLESSLY
// (WALK_CTRL != 0), so that "core 0 is still running" stays a property of
// the hardware and does not become a question of the clock; afterwards
// WALK_CTRL is set back to 0 (the drop scenario needs the halt parking
// spot). Proven: only core 0 runs -> core 1 delivers EXACTLY 0 records
// while its RAM window stays loadable (per-core loader gate); core 1
// started afterwards -> delivers from the start of the program, core 0 runs
// on; core 1 stopped on its own -> its records freeze, core 0 and the shared
// trace path keep running; STATUS b9/b8 mirrors the effective run state at
// every step.
//
// T2 (CHECK_PIB, default 1, both legs): PIB smoke test at the parallel port
// -- (a) calibration pattern gate in the quiet window (STANDARD AA/55/00/FF
// + MOVING_ONE/ZERO sampled at the pib_clk edges, the duo TB pattern);
// (b) trace mode: the monitor deserialises the DDR nibbles (beat phase via
// the verification hook dut.sinks.g_pib.pib.frame_dbg), then the balance
// deserialised beats + PIB_DROPS@0x30 == TRACE_BEATS and a prefix word
// comparison against the ring (tag [t2_tb]).

`default_nettype none

module tb_tgc5b2_axis_soc #(
	parameter string PROG_HEX  = "../../examples/kv260/tgc5b2_axis_wp/sw/axis_wp_demo.hex",
	parameter string HITS_FILE = "../../examples/kv260/tgc5b2_axis_wp/sw/expected_hits.txt",
	parameter bit    CHECK_TS  = 1'b0,       // C1b: 1 (W2/cross-core TS checks)
	parameter bit    FULL_WP   = 1'b0,       // C1b: 1 (full oracle + TS + negative probe)
	parameter int unsigned N_SLOTS = 1023,   // vendored M0_DIM=10 since the M0 sync (both legs)
	parameter bit    CHECK_DDR = 1'b1,       // D2: DDR sink armed + beat/drain/data evidence
	parameter bit    CHECK_PIB = 1'b1        // T2: PIB calib gate + beat balance at the parallel port
);

	localparam logic [21:0] CTRL_BASE  = 22'h00_0000;
	localparam logic [21:0] ENC0_BASE  = 22'h01_0000;
	localparam logic [21:0] ENC1_BASE  = 22'h02_0000;
	localparam logic [21:0] RAM1_BASE  = 22'h08_0000;
	localparam logic [21:0] RAM0_BASE  = 22'h10_0000;
	localparam logic [21:0] TRACE_BASE = 22'h20_0000;

	localparam int unsigned N_REAL_C1A = 13;      // C1a: real addresses (>= 8 required)
	int n_real;                                   // real addresses loaded (runtime)

	// C0b indirect path + TS registers (rdl/ct_cs_cpuif.rdl @78460f0d4e)
	localparam logic [21:0] OFF_WP_INDEX   = 22'h400C;
	localparam logic [21:0] OFF_WP_DATA_LO = 22'h4010;
	localparam logic [21:0] OFF_WP_DATA_HI = 22'h4014;
	localparam logic [21:0] OFF_WP_READ_LO = 22'h4018;
	localparam logic [21:0] OFF_WP_READ_HI = 22'h401C;
	localparam logic [21:0] OFF_WP_CAP     = 22'h4020;
	localparam logic [21:0] OFF_TS_CONTROL = 22'h040;

	// Cross-core TS tolerance (cycles): both cores run the same program,
	// started in the same cycle, against the ONE fabric_time counter --
	// delta 0 is expected; the tolerance covers any per-core pipeline skew
	// without letting a real time-base offset through.
	localparam logic [31:0] TS_XTOL = 32'd64;

	localparam logic [31:0] CMD_DAQ_PC_AXIS = {24'd0, 2'b01, 6'd1}; // Sink=AXIS, Cmd=DAQ_PC_CURR

	// Expected W3 meta: {8'h00, core_id, tstrb, tid}; tid = Cmd value (1).
	// CT_EN_AXIS_TS=1 in the synced encoder: DAQ_PC_CURR ALWAYS strobes elem2
	// (composer_axis sets 12'hFFF independently of trTsControl.Type; only the
	// VALUE follows Type, reset TR_TS_NONE -> 0). CHECK_TS therefore gates
	// the W2/cross-core checks alone, not the W3 expectation.
	localparam logic [11:0] EXP_TSTRB = 12'hFFF;
	localparam logic [7:0]  EXP_TID   = 8'h01;

	localparam int unsigned MAIN_CAP_CYCLES = 400_000;  // 64 phases of 2000 + margin
	localparam int unsigned DROP_CAP_CYCLES = 400_000;  // walk rerun + FIFO fill

	// U1 (per-core start/stop): records a core has to deliver in the
	// evidence phase. 13 = the number of hits in walk phase P0 -- identical
	// in BOTH legs (C1a loads exactly those 13 addresses, C1b loads all 364
	// and P0 contains 13 hits), so a freshly started core reaches the mark
	// in its FIRST phase (~2000 cycles).
	localparam int unsigned U1_RECS = 13;

	logic clk = 0;
	logic resetn = 0;
	always #6667ps clk = ~clk;                    // ~75 MHz

	logic [21:0] awaddr;  logic awvalid;  uwire awready;
	logic [31:0] wdata;   logic [3:0] wstrb; logic wvalid; uwire wready;
	uwire [1:0]  bresp;   uwire bvalid;    logic bready;
	logic [21:0] araddr;  logic arvalid;   uwire arready;
	uwire [31:0] rdata;   uwire [1:0] rresp; uwire rvalid; logic rready;

	// Shim record streams + status.
	uwire        m0_tvalid, m1_tvalid;
	logic        m0_tready, m1_tready;
	uwire [31:0] m0_tdata,  m1_tdata;
	uwire [3:0]  m0_tkeep,  m1_tkeep;
	uwire        m0_tlast,  m1_tlast;
	uwire [31:0] drop0, drop1, fill0, fill1;
	uwire        ovf0, ovf1;

	// D2: DDR sink AXI (model below; awready/wready constantly 1).
	uwire        ddr_awvalid, ddr_wvalid, ddr_wlast, ddr_bready;
	uwire [31:0] ddr_awaddr, ddr_wdata;
	uwire [7:0]  ddr_awlen;
	logic        ddr_bvalid;

	// T2: PIB port (monitor below).
	uwire        pib_clk_w;
	uwire [3:0]  pib_data_w;

	tgc5b2_axis_soc_top #(
		.MEM_INIT_FILE0 (PROG_HEX),
		.MEM_INIT_FILE1 (PROG_HEX),
		.TRACE_DEPTH    (65536)
	) dut (
		.clk (clk), .resetn (resetn),
		.s_axi_awaddr (awaddr), .s_axi_awprot (3'b0), .s_axi_awvalid (awvalid), .s_axi_awready (awready),
		.s_axi_wdata (wdata), .s_axi_wstrb (wstrb), .s_axi_wvalid (wvalid), .s_axi_wready (wready),
		.s_axi_bresp (bresp), .s_axi_bvalid (bvalid), .s_axi_bready (bready),
		.s_axi_araddr (araddr), .s_axi_arprot (3'b0), .s_axi_arvalid (arvalid), .s_axi_arready (arready),
		.s_axi_rdata (rdata), .s_axi_rresp (rresp), .s_axi_rvalid (rvalid), .s_axi_rready (rready),
		.m0_axis_tvalid (m0_tvalid), .m0_axis_tready (m0_tready),
		.m0_axis_tdata (m0_tdata), .m0_axis_tkeep (m0_tkeep), .m0_axis_tlast (m0_tlast),
		.shim0_drop_count (drop0), .shim0_overflow_sticky (ovf0), .shim0_fill_level (fill0),
		.m1_axis_tvalid (m1_tvalid), .m1_axis_tready (m1_tready),
		.m1_axis_tdata (m1_tdata), .m1_axis_tkeep (m1_tkeep), .m1_axis_tlast (m1_tlast),
		.shim1_drop_count (drop1), .shim1_overflow_sticky (ovf1), .shim1_fill_level (fill1),
		.m_axi_awaddr (ddr_awaddr), .m_axi_awlen (ddr_awlen),
		.m_axi_awsize (), .m_axi_awburst (),
		.m_axi_awvalid (ddr_awvalid), .m_axi_awready (1'b1),
		.m_axi_wdata (ddr_wdata), .m_axi_wstrb (),
		.m_axi_wlast (ddr_wlast), .m_axi_wvalid (ddr_wvalid), .m_axi_wready (1'b1),
		.m_axi_bresp (2'b00), .m_axi_bvalid (ddr_bvalid), .m_axi_bready (ddr_bready),
		.pib_clk (pib_clk_w), .pib_data (pib_data_w)
	);

	// ---- Random-ready sinks (stall_mode overridden to 0) -----------------
	logic stall0 = 0, stall1 = 0;
	always_ff @(posedge clk) begin
		m0_tready <= stall0 ? 1'b0 : ($urandom_range(0, 3) != 0);   // ~75 % ready
		m1_tready <= stall1 ? 1'b0 : ($urandom_range(0, 3) != 0);
	end

	// ---- Record collectors (protocol checks inline) ------------------------
	// One record = 4 words W0..W3, tlast on W3, tkeep constantly 4'hF.
	logic [31:0] rec_w [2][0:3];
	int          rec_idx [2];
	logic [127:0] recq [2][$];      // {W3,W2,W1,W0}
	initial begin rec_idx[0] = 0; rec_idx[1] = 0; end

	task automatic collect(input int c, input logic [31:0] d,
	                       input logic [3:0] keep, input logic last);
		if (keep !== 4'hF)
			$fatal(1, "[c1a_tb] core%0d: tkeep %h != F (word %0d)", c, keep, rec_idx[c]);
		if (last !== (rec_idx[c] == 3))
			$fatal(1, "[c1a_tb] core%0d: tlast %b at word %0d", c, last, rec_idx[c]);
		rec_w[c][rec_idx[c]] = d;
		if (rec_idx[c] == 3) begin
			recq[c].push_back({rec_w[c][3], rec_w[c][2], rec_w[c][1], rec_w[c][0]});
			rec_idx[c] = 0;
		end
		else rec_idx[c] = rec_idx[c] + 1;
	endtask

	always @(posedge clk) begin
		if (resetn) begin
			if (m0_tvalid && m0_tready) collect(0, m0_tdata, m0_tkeep, m0_tlast);
			if (m1_tvalid && m1_tready) collect(1, m1_tdata, m1_tkeep, m1_tlast);
		end
	end

	// ---- D2: DDR model (AXI4 write slave, always ready) --------------------
	// Mirrors the sink writes word by word (index = (address-base)/4) and
	// counts W beats -- cross-check against DDR_BEATS and the URAM ring. In
	// ct_soc_ddr_sink, AW and the first W beat never share a cycle (S_AW ->
	// S_W), so the cur_addr assignments cannot collide.
	// U6: address plan v4 -- reset default of ct_trace_sinks (0x5000_0000,
	// 256 MiB). Both constants MUST match the RTL reset; the drift guard in
	// step 3b checks that against the registers instead of relying on
	// somebody changing both places together.
	localparam logic [31:0] DDR_MODEL_BASE = 32'h5000_0000;   // reset default DDR_BASE
	localparam logic [31:0] DDR_MODEL_SIZE = 32'h1000_0000;   // reset default DDR_SIZE
	logic [31:0] ddr_model_mem [0:65535];      // 256 KiB mirror from the base
	logic [31:0] ddr_model_beats;
	logic [31:0] ddr_cur_addr;

	always_ff @(posedge clk) begin
		if (!resetn) begin
			ddr_bvalid <= 1'b0;
			ddr_model_beats <= '0;
			ddr_cur_addr <= '0;
		end
		else begin
			if (ddr_bvalid && ddr_bready) ddr_bvalid <= 1'b0;
			if (ddr_awvalid) begin         // awready constant 1
				ddr_cur_addr <= ddr_awaddr;
				if (ddr_awaddr < DDR_MODEL_BASE ||
				    ddr_awaddr >= DDR_MODEL_BASE + DDR_MODEL_SIZE)
					$fatal(1, "[d2_tb] DDR model: AWADDR 0x%08x outside the resmem window",
					       ddr_awaddr);
			end
			if (ddr_wvalid) begin          // wready constant 1
				if (((ddr_cur_addr - DDR_MODEL_BASE) >> 2) < 32'd65536)
					ddr_model_mem[(ddr_cur_addr - DDR_MODEL_BASE) >> 2] <= ddr_wdata;
				ddr_cur_addr <= ddr_cur_addr + 32'd4;
				ddr_model_beats <= ddr_model_beats + 1'b1;
				if (ddr_wlast) ddr_bvalid <= 1'b1;
			end
		end
	end

	// ---- T2: PIB monitor (duo TB pattern): DDR nibbles -> beat reconstruction
	// Convention (ct_soc_pib, = reference PIB_PAR_4): the rising pib_clk edge
	// samples the LOW nibble, the falling one the HIGH nibble; the beat phase
	// comes from the verification hook dut.sinks.g_pib.pib.frame_dbg (no pin).
	byte pib_bytes [$];
	logic [7:0] pib_cur;
	int pib_nib_in_beat = -1;   // -1 = idle, otherwise 0..7 (nibble within the beat)
	always @(posedge pib_clk_w) begin
		if (dut.sinks.g_pib.pib.frame_dbg) pib_nib_in_beat = 0;   // beat start
		if (pib_nib_in_beat >= 0 && (pib_nib_in_beat % 2) == 0) begin
			pib_cur[3:0] = pib_data_w;
			pib_nib_in_beat = pib_nib_in_beat + 1;
		end
	end
	always @(negedge pib_clk_w) begin
		if (pib_nib_in_beat >= 1 && (pib_nib_in_beat % 2) == 1) begin
			pib_cur[7:4] = pib_data_w;
			pib_bytes.push_back(pib_cur);
			if (pib_nib_in_beat == 7) pib_nib_in_beat = -1;   // beat complete
			else pib_nib_in_beat = pib_nib_in_beat + 1;
		end
	end

	// T2: PIB calibration gate (duo TB pattern, fatal-gated here): switch the
	// pattern on, sample 8 nibbles at the edges, check the sequence against
	// the reference definition (any phase).
	task automatic check_pib_pattern(input logic [1:0] pat);
		logic [3:0] nib [0:7];
		int errs; string name;
		name = (pat == 2'd1) ? "MOVING_ONE" : (pat == 2'd2) ? "MOVING_ZERO" : "STANDARD";
		axi_write(CTRL_BASE + 22'h18, 32'h0000_0150 | (32'(pat) << 12)); // pib_en|calib|div1
		repeat (6) @(posedge pib_clk_w);                 // let the pattern settle
		for (int k = 0; k < 8; k += 2) begin
			@(posedge pib_clk_w); #1; nib[k]   = pib_data_w;
			@(negedge pib_clk_w); #1; nib[k+1] = pib_data_w;
		end
		errs = 0;
		case (pat)
			2'd1: begin
				if (!(nib[0] inside {4'h1, 4'h2, 4'h4, 4'h8})) errs++;
				for (int k = 1; k < 8; k++)
					if (nib[k] !== {nib[k-1][2:0], nib[k-1][3]}) errs++;
			end
			2'd2: begin
				if (!(nib[0] inside {4'hE, 4'hD, 4'hB, 4'h7})) errs++;
				for (int k = 1; k < 8; k++)
					if (nib[k] !== ~{~nib[k-1][2:0], ~nib[k-1][3]}) errs++;
			end
			default: begin
				// AA 55 00 FF: nibble stream A,A,5,5,0,0,F,F (cyclic, any phase)
				int off = -1;
				logic [3:0] ref8 [0:7];
				ref8[0]=4'hA; ref8[1]=4'hA; ref8[2]=4'h5; ref8[3]=4'h5;
				ref8[4]=4'h0; ref8[5]=4'h0; ref8[6]=4'hF; ref8[7]=4'hF;
				for (int o = 0; o < 8 && off < 0; o++) begin
					int ok = 1;
					for (int k = 0; k < 8; k++)
						if (nib[k] !== ref8[(k+o) % 8]) ok = 0;
					if (ok) off = o;
				end
				if (off < 0) errs++;
			end
		endcase
		if (errs)
			$fatal(1, "[t2_tb] PIB-CALIB %s FAIL: %h %h %h %h %h %h %h %h",
			       name, nib[0],nib[1],nib[2],nib[3],nib[4],nib[5],nib[6],nib[7]);
		$display("[t2_tb] PIB-CALIB %s PASS (%h%h%h%h%h%h%h%h)",
		         name, nib[0],nib[1],nib[2],nib[3],nib[4],nib[5],nib[6],nib[7]);
	endtask

	// ---- AXI tasks (1:1 tb_duo_ps_devmem) ----------------------------------
	task automatic axi_write(input logic [21:0] a, input logic [31:0] d);
		@(posedge clk);
		awaddr <= a; awvalid <= 1'b1; wdata <= d; wstrb <= 4'hF; wvalid <= 1'b1;
		do @(posedge clk); while (!bvalid);
		awvalid <= 1'b0; wvalid <= 1'b0;
	endtask

	task automatic axi_read(input logic [21:0] a, output logic [31:0] d);
		@(posedge clk);
		araddr <= a; arvalid <= 1'b1;
		do @(posedge clk); while (!rvalid);
		d = rdata; arvalid <= 1'b0;
	endtask

	// ---- Oracle: parse expected_hits.txt -----------------------------------
	// Format per line: "P<phase> <seq> 0x<addr8> <name>", '#' = comment.
	logic [31:0] hits_all [$];      // all entry hits in file order
	logic [31:0] wp_tbl [0:N_SLOTS-1];   // loaded slots, sorted ascending
	logic [31:0] exp_pc [$];        // oracle subset (filtered sequence)
	int          exp_slot [$];      // slot index per expected record (W1 check)

	// Binary search (after build_oracle the table is sorted strictly ascending;
	// the only caller runs after it). O(log N) instead of O(N) -- with 1023
	// slots x 851 hits, that is what makes the oracle build xsim-viable.
	function automatic int slot_of(input logic [31:0] a);
		int lo, hi, mid;
		lo = 0; hi = int'(N_SLOTS) - 1;
		while (lo <= hi) begin
			mid = (lo + hi) / 2;
			if (wp_tbl[mid] == a)     return mid;
			else if (wp_tbl[mid] < a) lo = mid + 1;
			else                      hi = mid - 1;
		end
		return -1;
	endfunction

	// Cmd word per slot for the indirect path: a real (even) address ->
	// DAQ_PC_CURR/Sink=AXIS, a filler (odd) -> ACT_CAP_ST_NONE
	// (the RDL padding rule of the C0b state); DirectData = slot index (on
	// real slots the W1 cross-check, irrelevant on fillers but deterministic).
	function automatic logic [31:0] cmd_of(input logic [31:0] a, input int slot);
		return (a[0] ? 32'h0 : CMD_DAQ_PC_AXIS) | (32'(slot) << 8);
	endfunction

	task automatic build_oracle();
		int fd, k, ph, seq;
		logic [31:0] addr, maxa;
		logic [31:0] distinct [$];
		logic        seen_aa [bit [31:0]];   // set semantics (851x364 would be O(N^2))
		string line, name;
		logic [31:0] tmp;

		fd = $fopen(HITS_FILE, "r");
		if (fd == 0) $fatal(1, "[c1a_tb] oracle missing: %s", HITS_FILE);
		while (!$feof(fd)) begin
			if ($fgets(line, fd) == 0) break;
			if (line.len() < 8) continue;
			if (line.substr(0, 0) == "#") continue;
			k = $sscanf(line, "P%d %d 0x%h %s", ph, seq, addr, name);
			if (k < 3) continue;
			hits_all.push_back(addr);
		end
		$fclose(fd);
		if (hits_all.size() < 100)
			$fatal(1, "[c1a_tb] oracle implausible: only %0d hits", hits_all.size());

		// Loaded set: C1a = the first N_REAL_C1A DISTINCT addresses in file
		// order (= the 13 P0 entries, hit early);
		// C1b (FULL_WP) = ALL distinct addresses (= wp_set∩hits, 364).
		foreach (hits_all[i]) begin
			if (!seen_aa.exists(hits_all[i])) begin
				seen_aa[hits_all[i]] = 1'b1;
				distinct.push_back(hits_all[i]);
			end
			if (!FULL_WP && distinct.size() == N_REAL_C1A) break;
		end
		n_real = distinct.size();
		if (!FULL_WP && n_real != int'(N_REAL_C1A))
			$fatal(1, "[c1a_tb] only %0d distinct addresses", n_real);
		if (FULL_WP && (n_real < 300 || n_real > int'(N_SLOTS) - 2))
			$fatal(1, "[c1b_tb] implausible number of distinct addresses %0d (N_SLOTS=%0d)",
			       n_real, N_SLOTS);

		// Sort the real addresses (strictly ascending, programming rule 2); the
		// fillers are added above the maximum afterwards -- the result is
		// identical to the historical whole-table sort.
		for (int i = 0; i < n_real; i++) wp_tbl[i] = distinct[i];
		for (int i = 0; i < n_real; i++)
			for (int j = i + 1; j < n_real; j++)
				if (wp_tbl[j] < wp_tbl[i]) begin
					tmp = wp_tbl[i]; wp_tbl[i] = wp_tbl[j]; wp_tbl[j] = tmp;
				end
		maxa = wp_tbl[n_real-1];

		// Odd fillers above the maximum (never reachable: PCs are 4-aligned, the
		// core enforces PC[0]=0) -- rule: fill ALL slots.
		if (FULL_WP) begin
			for (int i = n_real; i < int'(N_SLOTS); i++)
				wp_tbl[i] = (maxa & ~32'h3) + 32'h5 + 32'(2 * (i - n_real));
		end
		else begin
			// C1a: slots 13/14 keep the historically documented +7/+9, above that it
			// continues odd and ascending up to slot 1022 (since the M0 sync here
			// too: fill ALL trWpCap slots). The record oracle stays identical --
			// records depend on the loaded REAL set (13 addresses, slots 0..12), not
			// on the load path and not on the fillers, which can never be reached.
			//
			for (int i = n_real; i < int'(N_SLOTS); i++)
				wp_tbl[i] = (maxa & ~32'h3) + 32'h7 + 32'(2 * (i - n_real));
		end
		for (int i = 1; i < int'(N_SLOTS); i++)
			if (wp_tbl[i] <= wp_tbl[i-1])
				$fatal(1, "[c1a_tb] slots not strictly ascending (slot %0d)", i);

		// Expected record sequence = the oracle filtered onto the loaded set
		// (FULL_WP: every line matches -- the FULL oracle).
		foreach (hits_all[i]) begin
			int s = slot_of(hits_all[i]);
			if (s >= 0) begin
				// Fillers can never match -- s always points at a real address
				// here, because hits_all only holds real PCs.
				exp_pc.push_back(hits_all[i]);
				exp_slot.push_back(s);
			end
		end
		if (FULL_WP && exp_pc.size() != hits_all.size())
			$fatal(1, "[c1b_tb] full oracle incomplete: %0d of %0d hits loaded",
			       exp_pc.size(), hits_all.size());
		$display("[c1a_tb] oracle: %0d hits in total, %0d after filtering onto %0d loaded addresses",
		         hits_all.size(), exp_pc.size(), n_real);
	endtask

	// ---- Load the WP table over the INDIRECT C0b path (both legs) ----------
	// The historical direct window 0x4100 (task wp_program) went away with the
	// M0 sync -- the merged encoder only knows the indirect path
	// (C0b BREAKING CHANGE f612baff07).
	// Protocol (C0b, rdl/ct_cs_cpuif.rdl): set Idx once, then per slot
	// trWpDataLow (addr) + trWpDataHigh (cmd) -- the high write commits
	// {low, high} into slot Idx and increments Idx (wrap at N_SLOTS-1).
	// After N_SLOTS commits from 0, Idx must read 0 again: autoincrement and
	// wrap evidence in one check (the RDL calls it "cheap load verification").
	task automatic wp_program_ind(input logic [21:0] enc_base,
	                              input logic [31:0] tbl [0:N_SLOTS-1]);
		logic [31:0] rb;
		axi_write(enc_base + OFF_WP_INDEX, 32'h0);
		for (int i = 0; i < int'(N_SLOTS); i++) begin
			axi_write(enc_base + OFF_WP_DATA_LO, tbl[i]);
			axi_write(enc_base + OFF_WP_DATA_HI, cmd_of(tbl[i], i));
		end
		axi_read(enc_base + OFF_WP_INDEX, rb);
		if (rb[15:0] !== 16'd0)
			$fatal(1, "[c1b_tb] ENC@0x%06x: Idx %0d != 0 after %0d commits (autoincrement/wrap)",
			       enc_base, rb[15:0], N_SLOTS);
	endtask

	// ---- C1b: readback spot check of one slot (serial readback contract) ---
	// ReadLow does not move Idx; ReadHigh (swacc) increments -- afterwards Idx
	// must sit at slot+1 (or at 0 after the last slot: the wrap).
	task automatic wp_verify_slot(input logic [21:0] enc_base, input int slot,
	                              input logic [31:0] exp_lo);
		logic [31:0] rb;
		logic [15:0] exp_next;
		axi_write(enc_base + OFF_WP_INDEX, 32'(slot));
		axi_read(enc_base + OFF_WP_READ_LO, rb);
		if (rb !== exp_lo)
			$fatal(1, "[c1b_tb] ENC@0x%06x slot %0d: ReadLow 0x%08x != 0x%08x",
			       enc_base, slot, rb, exp_lo);
		axi_read(enc_base + OFF_WP_READ_HI, rb);
		if (rb !== cmd_of(exp_lo, slot))
			$fatal(1, "[c1b_tb] ENC@0x%06x slot %0d: ReadHigh 0x%08x != 0x%08x",
			       enc_base, slot, rb, cmd_of(exp_lo, slot));
		exp_next = (slot == int'(N_SLOTS) - 1) ? 16'd0 : 16'(slot + 1);
		axi_read(enc_base + OFF_WP_INDEX, rb);
		if (rb[15:0] !== exp_next)
			$fatal(1, "[c1b_tb] ENC@0x%06x slot %0d: Idx after ReadHigh %0d != %0d",
			       enc_base, slot, rb[15:0], exp_next);
	endtask

	// ---- C1b: capacity discovery + spot checks (0 / middle / last) --------
	task automatic wp_readback_probes(input logic [21:0] enc_base);
		logic [31:0] rb;
		axi_read(enc_base + OFF_WP_CAP, rb);
		if (rb[15:0] !== 16'(N_SLOTS))
			$fatal(1, "[c1b_tb] ENC@0x%06x: trWpCap %0d != %0d", enc_base, rb[15:0], N_SLOTS);
		wp_verify_slot(enc_base, 0,                 wp_tbl[0]);                    // real
		wp_verify_slot(enc_base, int'(N_SLOTS)/2,   wp_tbl[int'(N_SLOTS)/2]);      // 511: filler
		wp_verify_slot(enc_base, int'(N_SLOTS)-1,   wp_tbl[int'(N_SLOTS)-1]);      // 1022 + Idx wrap
	endtask

	// ---- C1b: TS unit to TR_TS_CORE (RMW -- Width=63 is preserved) --------
	// TR_TS_CORE = plain pass-through of tip._time (ct_L23_preproc_ts.sv),
	// here the shared fabric_time counter of both encoders. Must be written
	// BEFORE trTeControl.Enable (Type/Prescale are swwel-locked).
	// Enable(bit15)=0: no wire TSTAMP -- the AXIS element follows Type, not
	// Enable (C0a semantics); Active(bit0) concerns only the internal
	// counter and is set along with it, following the documented semantics.
	task automatic ts_config(input logic [21:0] enc_base);
		logic [31:0] v;
		axi_read(enc_base + OFF_TS_CONTROL, v);
		v[0]    = 1'b1;      // Active
		v[6:4]  = 3'd3;      // Type = TR_TS_CORE
		v[15]   = 1'b0;      // Enable: wire TSTAMP off
		axi_write(enc_base + OFF_TS_CONTROL, v);
	endtask

	// ---- C1b: negative probe -- commit attempt while trTeControl.Enable=1 --
	// Expectation: all three load registers are swwel-locked AND the C0b shim
	// suppresses the commit explicitly (!Enable gate; per the C0b finding the
	// swmod pulse fires even when the write is locked). Evidence here: Idx
	// does not move (no autoincrement = no commit); the caller checks the
	// slot content against the original after disarming.
	task automatic wp_negative_probe(input logic [21:0] enc_base);
		logic [31:0] rb;
		axi_read(enc_base + OFF_WP_INDEX, rb);
		if (rb[15:0] !== 16'd0)
			$fatal(1, "[c1b_tb] negative probe: Idx beforehand %0d != 0", rb[15:0]);
		axi_write(enc_base + OFF_WP_INDEX,   32'd5);                            // swwel-locked
		axi_write(enc_base + OFF_WP_DATA_LO, 32'hDEAD_BEE0);                    // swwel-locked
		axi_write(enc_base + OFF_WP_DATA_HI, CMD_DAQ_PC_AXIS | 32'h0000_AA00);  // commit attempt
		axi_read(enc_base + OFF_WP_INDEX, rb);
		if (rb[15:0] !== 16'd0)
			$fatal(1, "[c1b_tb] negative probe: Idx %0d != 0 -- a write got through the swwel lock, or a commit despite Enable=1",
			       rb[15:0]);
	endtask

	// ---- Arm the encoder (SRC field as in the duo TB) ----------------------
	task automatic enc_arm(input logic [21:0] base, input logic [11:0] srcid);
		logic [31:0] feat;
		axi_read(base + 22'h8, feat);                       // trTeInstFeatures
		feat[31:28] = 4'd2;                                 // SrcBits = 2
		feat[27:16] = srcid;                                // SrcID
		axi_write(base + 22'h8, feat);
		axi_write(base + 22'h0, 32'h0106_0067);             // on, InhibitSrc=0
	endtask

	// ---- Record scoreboard (main scenario) ---------------------------------
	task automatic check_records(input int c);
		logic [127:0] r;
		logic [31:0] w0, w1, w3;
		if (recq[c].size() != exp_pc.size())
			$fatal(1, "[c1a_tb] core%0d: %0d records != %0d expected",
			       c, recq[c].size(), exp_pc.size());
		foreach (exp_pc[k]) begin
			r  = recq[c][k];
			w0 = r[31:0]; w1 = r[63:32]; w3 = r[127:96];
			if (w0 !== exp_pc[k])
				$fatal(1, "[c1a_tb] core%0d record %0d: PC 0x%08x != oracle 0x%08x",
				       c, k, w0, exp_pc[k]);
			if (w1 !== 32'(exp_slot[k]))
				$fatal(1, "[c1a_tb] core%0d record %0d: W1(DirectData) 0x%08x != slot %0d",
				       c, k, w1, exp_slot[k]);
			if (w3 !== {8'h00, 4'(c), EXP_TSTRB, EXP_TID})
				$fatal(1, "[c1a_tb] core%0d record %0d: W3 0x%08x != 0x%08x",
				       c, k, w3, {8'h00, 4'(c), EXP_TSTRB, EXP_TID});
			// W2 (element 2): only defined with CHECK_TS=1 (C1b) -- the vendored
			// encoder does not write element 2 on DAQ_PC_CURR.
			// STRICTLY monotonic: the fabric_time counter counts every cycle,
			// and an AXIS master emits at most one beat per cycle.
			if (CHECK_TS && k > 0) begin
				logic [31:0] w2p, w2c;
				w2p = recq[c][k-1][95:64]; w2c = r[95:64];
				if (w2c <= w2p)
					$fatal(1, "[c1a_tb] core%0d record %0d: TS not strictly monotonic (0x%08x after 0x%08x)",
					       c, k, w2c, w2p);
			end
		end
		$display("[c1a_tb] core%0d SCOREBOARD PASS -- %0d records == oracle subset (W0/W1/W3)",
		         c, recq[c].size());
	endtask

	// ---- C1b: cross-core TS evidence (elem2, shared time base) -------------
	// check_records covers the per-core strictness. In addition here:
	//   (a) |ts0[k] - ts1[k]| <= TS_XTOL for every record index -- both cores
	//       execute the same program, started in the same cycle, against the
	//       ONE fabric_time counter (0 expected);
	//   (b) the total stream merged on elem2 is monotonically non-decreasing
	//       (two-pointer merge, ties allowed) -- the merge formulation the
	//       assignment asked for.
	logic [31:0] ts_xmax = 0;
	task automatic check_ts_cross();
		logic [31:0] t0, t1, delta, prev, cur;
		int i0, i1;
		ts_xmax = 0;
		foreach (exp_pc[k]) begin
			t0 = recq[0][k][95:64];
			t1 = recq[1][k][95:64];
			delta = (t0 > t1) ? (t0 - t1) : (t1 - t0);
			if (delta > ts_xmax) ts_xmax = delta;
			if (delta > TS_XTOL)
				$fatal(1, "[c1b_tb] record %0d: |ts0-ts1| = %0d > %0d (ts0=0x%08x ts1=0x%08x)",
				       k, delta, TS_XTOL, t0, t1);
		end
		i0 = 0; i1 = 0; prev = '0;
		while (i0 < recq[0].size() || i1 < recq[1].size()) begin
			if (i1 >= recq[1].size() ||
			    (i0 < recq[0].size() && recq[0][i0][95:64] <= recq[1][i1][95:64])) begin
				cur = recq[0][i0][95:64]; i0++;
			end
			else begin
				cur = recq[1][i1][95:64]; i1++;
			end
			if (cur < prev)
				$fatal(1, "[c1b_tb] merge on elem2 not monotonic (0x%08x after 0x%08x)", cur, prev);
			prev = cur;
		end
		$display("[c1b_tb] TS EVIDENCE PASS -- strictly monotonic per core, cross-core max|delta|=%0d (tolerance %0d), merge monotonic (%0d+%0d records)",
		         ts_xmax, TS_XTOL, recq[0].size(), recq[1].size());
	endtask

	// ---- Main sequence ------------------------------------------------------
	logic [31:0] rd, hex_w0;
	logic [31:0] halt_pc;
	logic [31:0] drop_tbl [0:N_SLOTS-1];
	int          n_drop_rec;
	int          t;

	initial begin
		int fd;
		awvalid = 0; wvalid = 0; bready = 1; arvalid = 0; rready = 1;
		wstrb = 4'hF; awaddr = 0; araddr = 0; wdata = 0;

		build_oracle();

		// Read the first hex word as the loader reference.
		fd = $fopen(PROG_HEX, "r");
		if (fd == 0) $fatal(1, "[c1a_tb] program image missing: %s", PROG_HEX);
		if ($fscanf(fd, "%h", hex_w0) != 1) $fatal(1, "[c1a_tb] hex file unreadable");
		$fclose(fd);

		repeat (10) @(posedge clk);
		resetn <= 1'b1;
		repeat (5) @(posedge clk);
		$display("[c1a_tb] reset released");

		// 1. Cores held (reset default) -- loader probes + WALK_CTRL=0.
		//    0xE800 lies outside the image: uninitialised, the program would
		//    read X (main.c:114) -- set to 0 explicitly (a finite walk).
		axi_read(RAM0_BASE + 22'h0, rd);
		if (rd !== hex_w0) $fatal(1, "[c1a_tb] RAM0[0] 0x%08x != hex 0x%08x (INIT_FILE/loader)", rd, hex_w0);
		axi_read(RAM1_BASE + 22'h0, rd);
		if (rd !== hex_w0) $fatal(1, "[c1a_tb] RAM1[0] 0x%08x != hex 0x%08x", rd, hex_w0);
		axi_write(RAM0_BASE + 22'hE800, 32'h0);
		axi_write(RAM1_BASE + 22'hE800, 32'h0);
		axi_read(RAM0_BASE + 22'hE800, rd);
		if (rd !== 32'h0) $fatal(1, "[c1a_tb] RAM0 write probe: 0x%08x != 0", rd);
		axi_read(RAM1_BASE + 22'hE800, rd);
		if (rd !== 32'h0) $fatal(1, "[c1a_tb] RAM1 write probe: 0x%08x != 0", rd);
		$display("[c1a_tb] loader probes PASS (RAM0/RAM1 read+write, WALK_CTRL=0)");

		// 2. WP tables of BOTH encoders (trTeControl.Active/Enable still 0) over
		//    the indirect path (the only load path since C0b) + the trWpCap
		//    check / readback spot checks -- both legs.
		wp_program_ind(ENC0_BASE, wp_tbl);
		wp_program_ind(ENC1_BASE, wp_tbl);
		wp_readback_probes(ENC0_BASE);
		wp_readback_probes(ENC1_BASE);
		$display("[c1b_tb] indirect load PASS -- 2x %0d slots committed (Idx wrap evidence), trWpCap==%0d, readback 0/%0d/%0d on both encoders",
		         N_SLOTS, N_SLOTS, int'(N_SLOTS)/2, int'(N_SLOTS)-1);
		$display("[c1a_tb] WP tables loaded: %0d real + %0d fillers, slot0=0x%08x .. slot%0d=0x%08x",
		         n_real, int'(N_SLOTS) - n_real, wp_tbl[0], N_SLOTS-1, wp_tbl[N_SLOTS-1]);

		// 3. Arm the encoders (SRC 0/1) + clear the ring.
		//    C1b: TS unit to TR_TS_CORE BEFORE the enable (Type is swwel-locked);
		//    after arming, the negative probe.
		if (FULL_WP) begin
			ts_config(ENC0_BASE);
			ts_config(ENC1_BASE);
		end
		enc_arm(ENC0_BASE, 12'd0);
		enc_arm(ENC1_BASE, 12'd1);
		if (FULL_WP) begin
			// A commit attempt on the armed ENC0 must move nothing; then
			// disarm briefly (the read index is swwel-locked), check slot 0
			// against the original, arm again.
			wp_negative_probe(ENC0_BASE);
			axi_write(ENC0_BASE + 22'h0, 32'h0);
			wp_verify_slot(ENC0_BASE, 0, wp_tbl[0]);
			enc_arm(ENC0_BASE, 12'd0);
			$display("[c1b_tb] negative probe PASS -- no commit while Enable=1 (Idx unmoved, slot 0 intact)");
		end
		// 3b. D2/T2: arm the extra sinks (DDR one-shot, reset window
		//     0x6000_0000/64 MiB + PIB div=1) BEFORE the ring clear, but only
		//     after quiescence has been established: the arm/rearm syncs still
		//     drain for a few hundred cycles (C1B finding: 1 beat of skew between
		//     sink enable and ring clear). After that, ring and sinks count the
		//     same beats (evidence in 6b/6c). The PIB calibration patterns run in
		//     the same quiet window (they consume no trace).
		if (CHECK_DDR || CHECK_PIB) begin
			logic [31:0] b0, b1;
			int q;
			for (q = 0; q < 100; q++) begin
				axi_read(CTRL_BASE + 22'h8, b0);
				repeat (500) @(posedge clk);
				axi_read(CTRL_BASE + 22'h8, b1);
				if (b0 == b1) break;
			end
			if (b0 != b1)
				$fatal(1, "[d2_tb] the ATB stream does not go quiet before the sink enable (%0d != %0d)", b0, b1);
			if (CHECK_PIB) begin
				check_pib_pattern(2'd1);
				check_pib_pattern(2'd2);
				check_pib_pattern(2'd0);
			end
			// U6 drift guard: the DDR model above mirrors from
			// DDR_MODEL_BASE. If the RTL carried a different reset, the model
			// memory would silently reach past itself (negative index or beyond
			// the array) and the word comparison in 6b would be worthless --
			// which is why it is checked against the registers here.
			if (CHECK_DDR) begin
				logic [31:0] wb, ws;
				axi_read(CTRL_BASE + 22'h1C, wb);
				axi_read(CTRL_BASE + 22'h20, ws);
				if (wb !== DDR_MODEL_BASE || ws !== DDR_MODEL_SIZE)
					$fatal(1, "[u6_tb] DDR window reset 0x%08x+0x%08x != model 0x%08x+0x%08x (TB and ct_trace_sinks have drifted)",
					       wb, ws, DDR_MODEL_BASE, DDR_MODEL_SIZE);
				$display("[u6_tb] window reset PASS -- DDR_BASE 0x%08x + %0d MiB (address plan v4, == TB model)",
				         wb, ws / 32'd1048576);
			end
			axi_write(CTRL_BASE + 22'h18,
			          (CHECK_DDR ? 32'h0000_0001 : 32'h0) |
			          (CHECK_PIB ? 32'h0000_0110 : 32'h0));   // ddr_en | pib_en+div1
		end
		axi_write(CTRL_BASE, 32'h0000_0002);
		axi_write(CTRL_BASE, 32'h0000_0000);

		// 4. Start both cores; walk = 64 phases of 2000 cycles.
		axi_write(CTRL_BASE, 32'h0000_0001);
		$display("[c1a_tb] cores started (%0d records expected each)", exp_pc.size());
		for (t = 0; t < MAIN_CAP_CYCLES / 1000; t++) begin
			repeat (1000) @(posedge clk);
			if (recq[0].size() >= exp_pc.size() && recq[1].size() >= exp_pc.size()) break;
		end
		repeat (2000) @(posedge clk);   // drain margin (no further records expected)
		$display("[c1a_tb] records: core0=%0d core1=%0d (after %0d kcycles)",
		         recq[0].size(), recq[1].size(), t + 2);

		// 4b. Sample the halt PC (after the walk the program parks in a
		//    1-instruction loop). The record count may be reached BEFORE the last
		//    phase -- wait until 8 consecutive retirements show the same PC (the
		//    parking criterion), with a timeout.
		begin
			logic [31:0] s [0:7];
			int stable, tries;
			stable = 0;
			for (tries = 0; tries < 200 && !stable; tries++) begin
				for (int k = 0; k < 8; k++) begin
					do @(posedge clk); while (!dut.core0_trace_valid);
					s[k] = dut.core0_trace_pc;
				end
				stable = 1;
				for (int k = 1; k < 8; k++)
					if (s[k] !== s[0]) stable = 0;
				if (!stable) repeat (1000) @(posedge clk);
			end
			if (!stable)
				$fatal(1, "[c1a_tb] halt PC not stable after %0d attempts (does the walk not park?)", tries);
			halt_pc = s[0];
			$display("[c1a_tb] halt PC sampled: 0x%08x (after %0d attempts)", halt_pc, tries);
		end

		// 5. Stop the cores, verify walk completion (SCRATCH via the loader).
		axi_write(CTRL_BASE, 32'h0000_0000);
		axi_read(RAM0_BASE + 22'hE000, rd);   // SCRATCH[0] = phase+1
		if (rd !== 32'd64) $fatal(1, "[c1a_tb] RAM0 SCRATCH[0] %0d != 64 (walk incomplete)", rd);
		axi_read(RAM0_BASE + 22'hE008, rd);   // SCRATCH[2] = end marker
		if (rd !== 32'h0E0DDA7A) $fatal(1, "[c1a_tb] RAM0 SCRATCH[2] 0x%08x != 0x0E0DDA7A", rd);
		axi_read(RAM1_BASE + 22'hE000, rd);
		if (rd !== 32'd64) $fatal(1, "[c1a_tb] RAM1 SCRATCH[0] %0d != 64", rd);
		axi_read(RAM1_BASE + 22'hE008, rd);
		if (rd !== 32'h0E0DDA7A) $fatal(1, "[c1a_tb] RAM1 SCRATCH[2] 0x%08x != 0x0E0DDA7A", rd);
		$display("[c1a_tb] walk completion PASS (SCRATCH of both cores)");

		// 6. N-Trace capture (not a decode gate): tracing off + flush, the ring
		//    must have seen beats.
		axi_write(ENC0_BASE + 22'h0, 32'h0106_0063);
		axi_write(ENC1_BASE + 22'h0, 32'h0106_0063);
		repeat (200) @(posedge clk);
		axi_write(CTRL_BASE, 32'h0000_0004);   // trace_flush (cores stay off)
		repeat (3000) @(posedge clk);
		axi_write(CTRL_BASE, 32'h0000_0000);
		axi_read(CTRL_BASE + 22'h8, rd);
		if (rd == 0) $fatal(1, "[c1a_tb] capture empty (trace_beats=0)");
		$display("[c1a_tb] capture: %0d ATB beats (merged, SRC 0/1)", rd);

		// 6b. D2: DDR sink evidence -- every merged beat reaches the sink
		//     (DDR_BEATS == TRACE_BEATS), the AXI path drains completely
		//     (WPTR == 4*beats, polled), 0 drops/errors, equal model beat count,
		//     and the first words stand word for word in the DDR model as in the
		//     ring (data-path evidence; only while the ring has not wrapped).
		if (CHECK_DDR) begin
			logic [31:0] db, wp, dv, exp_wp;
			axi_read(CTRL_BASE + 22'h38, db);          // DDR_BEATS (since T2 @0x38)
			if (db !== rd)
				$fatal(1, "[d2_tb] DDR_BEATS %0d != TRACE_BEATS %0d", db, rd);
			exp_wp = db * 4;
			wp = 32'hFFFF_FFFF;
			for (t = 0; t < 50; t++) begin
				axi_read(CTRL_BASE + 22'h24, wp);      // DDR_WPTR
				if (wp == exp_wp) break;
				repeat (400) @(posedge clk);
			end
			if (wp !== exp_wp)
				$fatal(1, "[d2_tb] DDR_WPTR %0d != %0d bytes (drain incomplete)", wp, exp_wp);
			axi_read(CTRL_BASE + 22'h2C, dv);          // DDR_DROPS
			if (dv !== 32'd0) $fatal(1, "[d2_tb] DDR_DROPS %0d != 0", dv);
			axi_read(CTRL_BASE + 22'h28, dv);          // SINK_STAT
			if (dv[2:0] !== 3'b000)
				$fatal(1, "[d2_tb] SINK_STAT 0x%08x (full/axi_err/wrapped set)", dv);
			if (ddr_model_beats !== db)
				$fatal(1, "[d2_tb] model beats %0d != DDR_BEATS %0d", ddr_model_beats, db);
			axi_read(CTRL_BASE + 22'h4, dv);           // STATUS b0 = ring wrapped
			if (dv[0] === 1'b0) begin
				for (int k = 0; k < 16 && k < int'(db); k++) begin
					axi_read(TRACE_BASE + 22'(4 * k), dv);
					if (dv !== ddr_model_mem[k])
						$fatal(1, "[d2_tb] DDR[%0d] 0x%08x != ring 0x%08x",
						       k, ddr_model_mem[k], dv);
				end
			end
			$display("[d2_tb] DDR SINK PASS -- %0d beats == ring, WPTR=%0d B drained, 0 drops, word comparison OK",
			         db, exp_wp);
		end

		// 6c. T2: PIB evidence -- first wait for the serialiser drain (FIFO of 64
		//     beats at 16 cycles @div=1; poll for a stable byte count), then the
		//     balance: deserialised beats + PIB_DROPS == TRACE_BEATS (every
		//     offered beat is accepted OR counted as dropped), and the prefix is
		//     word-identical to the ring (drops only start once the 64-entry FIFO
		//     is full -> the first 16 beats are certainly drop-free).
		if (CHECK_PIB) begin
			logic [31:0] pd, dv2, pbeat;
			int sz_prev, pib_beats;
			for (t = 0; t < 60; t++) begin
				sz_prev = pib_bytes.size();
				repeat (2000) @(posedge clk);
				if (pib_bytes.size() == sz_prev && sz_prev > 0) break;
			end
			if (pib_nib_in_beat != -1)
				$fatal(1, "[t2_tb] PIB drain incomplete (mid-beat, nib=%0d)", pib_nib_in_beat);
			pib_beats = pib_bytes.size() / 4;
			axi_read(CTRL_BASE + 22'h30, pd);          // PIB_DROPS
			if (32'(pib_beats) + pd !== rd)
				$fatal(1, "[t2_tb] PIB balance: %0d beats + %0d drops != TRACE_BEATS %0d",
				       pib_beats, pd, rd);
			axi_read(CTRL_BASE + 22'h4, dv2);          // STATUS b0 = ring wrapped
			if (dv2[0] === 1'b0) begin
				for (int k = 0; k < 16 && k < pib_beats; k++) begin
					pbeat = {pib_bytes[4*k+3], pib_bytes[4*k+2], pib_bytes[4*k+1], pib_bytes[4*k+0]};
					axi_read(TRACE_BASE + 22'(4 * k), dv2);
					if (pbeat !== dv2)
						$fatal(1, "[t2_tb] PIB[%0d] 0x%08x != ring 0x%08x", k, pbeat, dv2);
				end
			end
			$display("[t2_tb] PIB PASS -- %0d beats + %0d drops == %0d ring beats, prefix word comparison OK",
			         pib_beats, pd, rd);
		end

		// 6d. U9-1: the window nailed down in HARDWARE (was U6: locked only while
		//     the sink was armed; regression guard for defect class B-C1-1).
		//     The starting point was a shrink of DDR_SIZE below the running write
		//     offset -- exactly one transfer ran out of the window. U6 caught
		//     that, but only while ddr_en=1; with the sink switched off the
		//     hardware accepted ANY address, and the result on the board was a
		//     DDR sink that stayed dead until the next reboot (U9 §1a).
		//     This guard therefore checks BOTH states now: armed AND disarmed,
		//     base and size must not move; the second half was green until U9-1
		//     with the OPPOSITE expected value ("writable while ddr_en=0").
		//     It runs AFTER 6b/6c, because the clear pulse zeroes the DDR
		//     counters; the PIB bits stay untouched (a pib_en switched off in the
		//     middle of the drain would have torn 6c apart).
		//
		if (CHECK_DDR) begin
			logic [31:0] sc_save, sz_save, dv3;
			axi_read(CTRL_BASE + 22'h18, sc_save);
			axi_read(CTRL_BASE + 22'h20, sz_save);
			if (!sc_save[0]) $fatal(1, "[u6_tb] precondition violated: ddr_en is 0");
			axi_write(CTRL_BASE + 22'h20, 32'h0000_1000);   // shrink while running
			axi_read(CTRL_BASE + 22'h20, dv3);
			if (dv3 !== sz_save)
				$fatal(1, "[u6_tb] DDR_SIZE changed while the sink was armed (0x%08x -> 0x%08x)", sz_save, dv3);
			axi_write(CTRL_BASE + 22'h1C, 32'h7000_0000);   // base while running
			axi_read(CTRL_BASE + 22'h1C, dv3);
			if (dv3 !== DDR_MODEL_BASE)
				$fatal(1, "[u6_tb] DDR_BASE changed while the sink was armed (0x%08x)", dv3);
			axi_read(CTRL_BASE + 22'h28, dv3);              // SINK_STAT
			if (!dv3[4])
				$fatal(1, "[u6_tb] SINK_STAT b4 (ddr_cfg_rej) not set after a rejected write (0x%08x)", dv3);
			// Disarm + clear: the sticky bit goes away, the lock does NOT.
			axi_write(CTRL_BASE + 22'h18, sc_save & ~32'h1);
			axi_write(CTRL_BASE + 22'h18, (sc_save & ~32'h1) | 32'h2);
			repeat (8) @(posedge clk);
			axi_read(CTRL_BASE + 22'h28, dv3);
			if (dv3[4]) $fatal(1, "[u6_tb] ddr_cfg_rej still set after ddr_clear (0x%08x)", dv3);
			// U9-1: the same write attempt while ddr_en=0 -- it is the field case
			// (the U8 control panel expressly advised switching the sink off
			// beforehand) and must be just as ineffective now.
			axi_write(CTRL_BASE + 22'h20, 32'h0000_1000);
			axi_read(CTRL_BASE + 22'h20, dv3);
			if (dv3 !== sz_save)
				$fatal(1, "[u9_tb] DDR_SIZE changed while ddr_en=0 (0x%08x -> 0x%08x) -- the window is NOT read-only", sz_save, dv3);
			axi_write(CTRL_BASE + 22'h1C, 32'h1000_0000);   // the field address: guest DDR
			axi_read(CTRL_BASE + 22'h1C, dv3);
			if (dv3 !== DDR_MODEL_BASE)
				$fatal(1, "[u9_tb] DDR_BASE changed while ddr_en=0 (0x%08x) -- a DMA master in the host's memory", dv3);
			axi_read(CTRL_BASE + 22'h28, dv3);              // SINK_STAT
			if (!dv3[4])
				$fatal(1, "[u9_tb] SINK_STAT b4 not set after a rejected window write while ddr_en=0 (0x%08x)", dv3);
			// Clean up: sticky bit gone, state as before 6d (the window itself
			// needs no restoring -- it never moved).
			axi_write(CTRL_BASE + 22'h18, (sc_save & ~32'h1) | 32'h2);
			repeat (8) @(posedge clk);
			$display("[u6_tb] WINDOW LOCK PASS -- base/size rejected and reported while ddr_en=1 (SINK_STAT b4), the lock report cleared via ddr_clear");
			$display("[u9_tb] WINDOW READ-ONLY PASS -- the same write attempt while ddr_en=0 moves neither base (0x%08x) nor size (0x%08x) and is reported as SINK_STAT b4",
			         DDR_MODEL_BASE, sz_save);
		end

		// 7. Scoreboard of both cores + freedom from drops in the ready case.
		//    C1b: cross-core TS on top (shared time base) -- the per-core
		//    strictness sits in check_records (CHECK_TS).
		check_records(0);
		check_records(1);
		if (CHECK_TS) check_ts_cross();
		if (drop0 !== 0 || ovf0) $fatal(1, "[c1a_tb] core0: drops=%0d ovf=%b in the ready case", drop0, ovf0);
		if (drop1 !== 0 || ovf1) $fatal(1, "[c1a_tb] core1: drops=%0d ovf=%b in the ready case", drop1, ovf1);
		$display("[c1a_tb] MAIN SCENARIO PASS -- 0 drops, both cores == oracle");

		// ================= U1: per-core start/stop =================
		// CONTROL b8/b9 start the cores INDIVIDUALLY (b0 stays the collective
		// "both" bit). Four things are shown that were impossible before U1:
		//   (a) only core 0 runs    -> records exclusively from core 0, core 1
		//       delivers EXACTLY 0 during the stop phase;
		//   (b) the RAM loader window of the STOPPED core is reachable while the
		//       other core runs (per-core gate; before this, a running core_run
		//       would have locked both windows);
		//   (c) core 1 started afterwards -> delivers its hit sequence from the
		//       start of the program (reset vector + crt0 .bss clear), while
		//       core 0 keeps running without interruption;
		//   (d) core 1 stopped on its own -> its records freeze, core 0 keeps
		//       running, and the shared trace path (funnel/sinks) keeps counting
		//       without interruption.
		// For (a)/(c)/(d) the walk runs ENDLESSLY (WALK_CTRL != 0, main.c:114)
		// -- otherwise "core 0 is still running" would be a question of the
		// clock instead of a property of the hardware. Before the drop scenario
		// WALK_CTRL is set back to 0 (that one needs the halt parking spot).
		begin
			logic [31:0] st, n0_s, n1_s, beats_a, beats_b;
			int u1_wait;

			// Endless walk into both RAMs (both cores are stopped -> both
			// loader windows open), empty the collectors.
			axi_write(RAM0_BASE + 22'hE800, 32'h1);
			axi_write(RAM1_BASE + 22'hE800, 32'h1);
			recq[0].delete(); recq[1].delete();
			rec_idx[0] = 0; rec_idx[1] = 0;

			// (a) Start ONLY core 0.
			axi_write(CTRL_BASE, 32'h0000_0100);          // b8
			axi_read(CTRL_BASE + 22'h4, st);
			if (st[9:8] !== 2'b01)
				$fatal(1, "[u1_tb] STATUS[9:8]=%b after CONTROL=0x100 (01 expected)", st[9:8]);

			// (b) RAM1 (the stopped core) stays writable and readable while
			//     core 0 runs. Like 0xE800, 0xE804 lies outside the image and
			//     below the stack guard.
			axi_read(RAM1_BASE + 22'h0, rd);
			if (rd !== hex_w0)
				$fatal(1, "[u1_tb] RAM1[0] 0x%08x != hex 0x%08x while core 0 runs", rd, hex_w0);
			axi_write(RAM1_BASE + 22'hE804, 32'hA5A5_1234);
			axi_read(RAM1_BASE + 22'hE804, rd);
			if (rd !== 32'hA5A5_1234)
				$fatal(1, "[u1_tb] RAM1 write probe 0x%08x != 0xA5A51234 (loader gate not per core)", rd);
			axi_write(RAM1_BASE + 22'hE804, 32'h0);

			// (a) Records from core 0 only: wait until core 0 has worked through
			//     the first phase (13 hits in P0 -- in BOTH legs); core 1 must
			//     stand at exactly 0 while it does.
			for (u1_wait = 0; u1_wait < 200; u1_wait++) begin
				repeat (1000) @(posedge clk);
				if (recq[0].size() >= U1_RECS) break;
			end
			if (recq[0].size() < U1_RECS)
				$fatal(1, "[u1_tb] core 0 alone: only %0d records after %0d kcycles",
				       recq[0].size(), u1_wait);
			if (recq[1].size() != 0)
				$fatal(1, "[u1_tb] core 1 is stopped but delivers %0d records", recq[1].size());
			// Core 0 carries the oracle sequence from the start of the program.
			for (int k = 0; k < U1_RECS; k++)
				if (recq[0][k][31:0] !== exp_pc[k])
					$fatal(1, "[u1_tb] core 0 record %0d: PC 0x%08x != oracle 0x%08x",
					       k, recq[0][k][31:0], exp_pc[k]);
			$display("[u1_tb] (a) core 0 alone PASS -- %0d records from core 0 == oracle prefix, core 1 exactly 0, RAM1 loadable meanwhile",
			         U1_RECS);

			// (c) Start core 1 afterwards (b8|b9); core 0 runs without a break.
			n0_s = 32'(recq[0].size());
			axi_read(CTRL_BASE + 22'h8, beats_a);         // TRACE_BEATS before
			axi_write(CTRL_BASE, 32'h0000_0300);          // b8|b9
			axi_read(CTRL_BASE + 22'h4, st);
			if (st[9:8] !== 2'b11)
				$fatal(1, "[u1_tb] STATUS[9:8]=%b after CONTROL=0x300 (11 expected)", st[9:8]);
			for (u1_wait = 0; u1_wait < 200; u1_wait++) begin
				repeat (1000) @(posedge clk);
				if (recq[1].size() >= U1_RECS) break;
			end
			if (recq[1].size() < U1_RECS)
				$fatal(1, "[u1_tb] core 1 after the late start: only %0d records after %0d kcycles",
				       recq[1].size(), u1_wait);
			for (int k = 0; k < U1_RECS; k++)
				if (recq[1][k][31:0] !== exp_pc[k])
					$fatal(1, "[u1_tb] core 1 record %0d after the late start: PC 0x%08x != oracle 0x%08x",
					       k, recq[1][k][31:0], exp_pc[k]);
			if (32'(recq[0].size()) <= n0_s)
				$fatal(1, "[u1_tb] core 0 has stood still since core 1 was started (%0d records unchanged)",
				       recq[0].size());
			$display("[u1_tb] (c) late start PASS -- core 1 delivers from the start of the program (%0d records), core 0 ran through (%0d -> %0d)",
			         recq[1].size(), n0_s, recq[0].size());

			// (d) Stop core 1 INDIVIDUALLY again. After the stop the shim FIFO
			//     still drains (up to FIFO_DEPTH records of 4 words each); only
			//     then may it freeze -- hence a drain window, then a snapshot,
			//     then the evidence window.
			axi_write(CTRL_BASE, 32'h0000_0100);          // b8 only
			axi_read(CTRL_BASE + 22'h4, st);
			if (st[9:8] !== 2'b01)
				$fatal(1, "[u1_tb] STATUS[9:8]=%b after CONTROL=0x100 again", st[9:8]);
			repeat (8000) @(posedge clk);                 // shim drain
			n0_s = 32'(recq[0].size());
			n1_s = 32'(recq[1].size());
			for (u1_wait = 0; u1_wait < 200; u1_wait++) begin
				repeat (1000) @(posedge clk);
				if (32'(recq[0].size()) > n0_s) break;
			end
			if (32'(recq[0].size()) <= n0_s)
				$fatal(1, "[u1_tb] core 0 delivers nothing after core 1 was stopped (%0d)",
				       recq[0].size());
			if (32'(recq[1].size()) !== n1_s)
				$fatal(1, "[u1_tb] core 1 stopped but keeps delivering (%0d -> %0d)",
				       n1_s, recq[1].size());
			axi_read(CTRL_BASE + 22'h8, beats_b);         // TRACE_BEATS afterwards
			if (beats_b <= beats_a)
				$fatal(1, "[u1_tb] the trace path stands still: TRACE_BEATS %0d -> %0d over the whole U1 phase",
				       beats_a, beats_b);
			$display("[u1_tb] (d) individual stop PASS -- core 1 frozen at %0d, core 0 continuing (%0d -> %0d), TRACE_BEATS %0d -> %0d",
			         n1_s, n0_s, recq[0].size(), beats_a, beats_b);

			// (e) Not one record was lost in the whole phase -- individual
			//     start/stop costs no record (and proves at the same time that
			//     the later drop counts of the drop scenario do NOT come from
			//     this phase).
			if (drop0 !== 0 || drop1 !== 0 || ovf0 || ovf1)
				$fatal(1, "[u1_tb] loss in the U1 phase: drop0=%0d ovf0=%b drop1=%0d ovf1=%b",
				       drop0, ovf0, drop1, ovf1);

			// Clean up: stop both cores, take back the endless walk (the drop
			// scenario needs the halt parking spot), empty the collectors.
			// Both cores are stopped -> both loader windows are open.
			axi_write(CTRL_BASE, 32'h0000_0000);
			axi_read(CTRL_BASE + 22'h4, st);
			if (st[9:8] !== 2'b00)
				$fatal(1, "[u1_tb] STATUS[9:8]=%b after CONTROL=0 (00 expected)", st[9:8]);
			axi_write(RAM0_BASE + 22'hE800, 32'h0);
			axi_write(RAM1_BASE + 22'hE800, 32'h0);
			recq[0].delete(); recq[1].delete();
			rec_idx[0] = 0; rec_idx[1] = 0;
			$display("[u1_tb] PER-CORE START/STOP PASS -- b8/b9 act individually, b0 stays the collective bit");
		end

		// ================= drop scenario =================
		// WP onto the halt address: the 1-instruction loop produces ~1 hit every
		// 2-3 cycles and floods the FIFO (the drain needs 4 words/record).
		// Table change by the rules: cores in reset + trTeControl=0.
		axi_write(ENC0_BASE + 22'h0, 32'h0);
		axi_write(ENC1_BASE + 22'h0, 32'h0);
		drop_tbl[0] = halt_pc;
		for (int i = 1; i < N_SLOTS; i++)
			drop_tbl[i] = (halt_pc & ~32'h3) + 32'h5 + 32'(2*(i-1));   // odd, ascending
		// Full table over the indirect path (fillers automatically get Cmd=NONE
		// via cmd_of) -- both legs.
		wp_program_ind(ENC0_BASE, drop_tbl);
		wp_program_ind(ENC1_BASE, drop_tbl);

		// Stall the sinks, empty the collectors, let the cores start again
		// (rerun: 64 phases without hits, then the halt storm). trTeControl
		// stays 0 -- ACT-ST/AXIS work independently of the N-Trace state.
		stall0 = 1; stall1 = 1;
		recq[0].delete(); recq[1].delete();
		axi_write(CTRL_BASE, 32'h0000_0001);
		$display("[c1a_tb] drop scenario: cores restarted, sinks stalled");
		for (t = 0; t < DROP_CAP_CYCLES / 1000; t++) begin
			repeat (1000) @(posedge clk);
			if (drop0 > 0 && ovf0 && drop1 > 0 && ovf1) break;
		end
		if (!(drop0 > 0 && ovf0 && drop1 > 0 && ovf1))
			$fatal(1, "[c1a_tb] drop scenario: no overflow (drop0=%0d ovf0=%b drop1=%0d ovf1=%b)",
			       drop0, ovf0, drop1, ovf1);
		$display("[c1a_tb] drops proven: core0 drop=%0d ovf=%b fill=%0d | core1 drop=%0d ovf=%b fill=%0d",
		         drop0, ovf0, fill0, drop1, ovf1, fill1);

		// Resume: let the FIFO backlog drain, then check fresh records -- every
		// delivered record must be intact (the storm keeps running, drops
		// between records are allowed; drop granularity = whole record, the
		// D0 contract).
		stall0 = 0; stall1 = 0;
		repeat (3000) @(posedge clk);
		recq[0].delete(); recq[1].delete();
		n_drop_rec = 32;
		for (t = 0; t < 20; t++) begin
			repeat (500) @(posedge clk);
			if (recq[0].size() >= n_drop_rec && recq[1].size() >= n_drop_rec) break;
		end
		for (int c = 0; c < 2; c++) begin
			if (recq[c].size() < n_drop_rec)
				$fatal(1, "[c1a_tb] core%0d: only %0d records after the resume", c, recq[c].size());
			for (int k = 0; k < n_drop_rec; k++) begin
				logic [127:0] r; logic [31:0] w0, w1, w3;
				r = recq[c][k];
				w0 = r[31:0]; w1 = r[63:32]; w3 = r[127:96];
				if (w0 !== halt_pc)
					$fatal(1, "[c1a_tb] core%0d resume record %0d: PC 0x%08x != halt 0x%08x",
					       c, k, w0, halt_pc);
				if (w1 !== 32'd0)   // Slot 0 (DirectData=0)
					$fatal(1, "[c1a_tb] core%0d resume record %0d: W1 0x%08x != 0", c, k, w1);
				if (w3 !== {8'h00, 4'(c), EXP_TSTRB, EXP_TID})
					$fatal(1, "[c1a_tb] core%0d resume record %0d: W3 0x%08x", c, k, w3);
			end
		end
		axi_write(CTRL_BASE, 32'h0000_0000);
		$display("[c1a_tb] DROP SCENARIO PASS -- overflow proven, resume records intact");

		if (FULL_WP)
			$display("C1B_ALL_PASS records_per_core=%0d wp_real=%0d wp_slots=%0d ts_xmax=%0d drops0=%0d drops1=%0d resume_records=%0d",
			         exp_pc.size(), n_real, N_SLOTS, ts_xmax, drop0, drop1, n_drop_rec);
		else
			$display("C1A_ALL_PASS records_per_core=%0d wp_real=%0d wp_slots=%0d drops0=%0d drops1=%0d resume_records=%0d",
			         exp_pc.size(), n_real, N_SLOTS, drop0, drop1, n_drop_rec);
		$finish;
	end

	initial begin
		#40ms;
		$fatal(1, "[c1a_tb] TIMEOUT");
	end

endmodule

`default_nettype wire
