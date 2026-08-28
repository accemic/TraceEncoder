// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
 *
 * @brief    CEDARtools.TraceEncoder control/status register block (Wishbone CSR access + CDC).
 *
 * @details
 *   Distributes the control/status signals to the respective pipeline stages
 *   and exposes them over Wishbone via the generated CPUIF:
 *   - CDC into the tip_clk, proc_clk and atb.aclk domains
 *   - several signals need no CDC but are only writable while trTeControl.Enable = 0
 */

`undef  MY_DEBUG
`ifdef  MY_DEBUG
`define MY_MARK_DEBUG (* MARK_DEBUG = "TRUE" *)
`else
`define MY_MARK_DEBUG
`endif

module ct_cs_cpuif_wb #(
	// Back end of the enclosing ct_encoder instance (P9): the protocol is a
	// synthesis parameter, and the discovery registers must report the truth
	// of THIS instance -- in a mixed SoC a profile-wide constant would lie.
	bit EN_ETRACE = ct_pkg::CT_EN_ETRACE
) (
	input uwire             wb_clk,        // wishbone clock
	input uwire             wb_rst,        // wishbone reset
	input uwire             ct_cs_rst,     // ct_cs reset
	input uwire             tip_clk,       // TIP clock
	input uwire             tip_rst,       // TIP reset
	input uwire             proc_clk,      // TE processing stage clk
	input uwire             proc_rst,      // TE processing stage clk
	ct_cs_tipclk_if.master  cs_tip,        // control / status registers for tip.clk domain
	ocram_write_if.client   act_st_wext,   // write interface for memory in tip.clk domain
	ocram_write_if.client   df_range_wext, // write interface for memory in tip.clk domain
	ct_cs_procclk_if.master cs_proc,       // control / status registers for proc_clk domain
	ct_cs_atbclk_if.master  cs_atb,        // control / status registers for atb_clk domain
	ct_cs_decclk_if.master  cs_dec,        // control / status registers for decoder clk domain
	wb_if.slave             wb             // wishbone
);

	import ct_cs_cpuif_pkg::*;

	logic        s_cpuif_req;
	logic        s_cpuif_req_is_wr;
	logic [14:0] s_cpuif_addr;
	logic [31:0] s_cpuif_wr_data;
	logic [31:0] s_cpuif_wr_biten;
	logic        s_cpuif_req_stall_wr;
	logic        s_cpuif_req_stall_rd;
	logic        s_cpuif_rd_ack;
	logic        s_cpuif_rd_err;
	logic [31:0] s_cpuif_rd_data;
	logic        s_cpuif_wr_ack;
	logic        s_cpuif_wr_err;

	// wb to cpuif bridge
	wb_to_cpuif #(
		.ADDR_WIDTH     (32),
		.DATA_WIDTH     (32),
		.IMPLEMENTATION ("COMB"))
	wb_to_cpuif_inst (
		.clk (wb_clk),
		.rst (wb_rst),
		.wb,
		.s_cpuif_req,
		.s_cpuif_req_is_wr,
		.s_cpuif_addr,
		.s_cpuif_wr_data,
		.s_cpuif_wr_biten,
		.s_cpuif_req_stall_wr,
		.s_cpuif_req_stall_rd,
		.s_cpuif_rd_ack,
		.s_cpuif_rd_err,
		.s_cpuif_rd_data,
		.s_cpuif_wr_ack,
		.s_cpuif_wr_err
	);

	// ----------------------------------------------------------------
	// WARL legalization for trTeControl.InstMode (@ te 0x000, bits [6:4]).
	// N-Trace requires trTeInstMode to be settable to 3 (BTM) or 6 (HTM).
	// Legal values: 6 (ITR_BRANCH_HIST, HTM) always; 3 (ITR_BRANCH, BTM)
	// iff the CT_EN_BTM build switch is set. Any other write value -- and a
	// write of 3 when CT_EN_BTM=0 -- is legalized to 6 BEFORE it reaches
	// the regblock, so the field always reads back a legal value; a strict
	// N-Trace tool probing an unsupported mode sees the honest legalized
	// answer instead of a silently-stored illegal mode, 2026-07-19;
	// BTM added. With CT_EN_BTM the "3 OR 6 settable" requirement
	// (Table 8) is fully met. Partial writes (wr_biten not covering [6:4])
	// are unaffected: biten masks the substituted bits away like any others.
	// ----------------------------------------------------------------
	uwire logic [2:0] s_instmode_wr = s_cpuif_wr_data[6:4];
	uwire logic [2:0] s_instmode_legal =
		(ct_pkg::CT_EN_BTM
		 && (s_instmode_wr == ct_cs_cpuif__te__trTeControl__trTeInstMode_e__ITR_BRANCH))
			? 3'd3 : 3'd6;

	// ----------------------------------------------------------------
	// WARL legalization for trTeDataControl.DataAddrCompress (@ te 0x010,
	// bits [19:18]) -- same pattern as InstMode above. Legal values: 0
	// (DTR_ADDR_FULL) always; 1 (DTR_ADDR_XOR) iff the
	// CT_EN_DF_ADDR_COMPRESS build switch is set. Modes 2/3 are not
	// implemented (E-P3-2: DIFF sign problem / dynamic mode not decodable
	// without an extra wire bit) -- any such write, and an XOR write on a
	// build without the feature, legalizes to 0 BEFORE it reaches the
	// regblock, so the field always reads back a legal value.
	// ----------------------------------------------------------------
	uwire logic [1:0] s_daddrcmp_wr = s_cpuif_wr_data[19:18];
	uwire logic [1:0] s_daddrcmp_legal =
		(ct_pkg::CT_EN_DF_ADDR_COMPRESS
		 && (s_daddrcmp_wr == 2'(ct_cs_cpuif__te__trTeDataControl__trTeDataAddrCompress_e__DTR_ADDR_XOR)))
			? 2'd1 : 2'd0;
	// ----------------------------------------------------------------
	// WARL legalization for trTeControl.SendDeviceId (@ te 0x000, bits
	// [29:28], P4) -- same pattern again. Legal values: 0 (DID_NONE)
	// always; 1 (DID_ONCE) iff the CT_EN_DEVICE_ID build switch is set.
	// 2/3 are undefined encodings of a 2-bit field whose enum has two
	// members, so they legalize to 0 as well -- that keeps the value the
	// cs_tip/cs_proc bundles carry (a 1-bit enum, PeakRDL sizes it by the
	// largest member) identical to the value software reads back.
	// ----------------------------------------------------------------
	uwire logic [1:0] s_senddevid_wr = s_cpuif_wr_data[29:28];
	uwire logic [1:0] s_senddevid_legal =
		(ct_pkg::CT_EN_DEVICE_ID
		 && (s_senddevid_wr == 2'(ct_cs_cpuif__te__trTeControl__trTeSendDeviceIdMode_e__DID_ONCE)))
			? 2'd1 : 2'd0;
	// ----------------------------------------------------------------
	// WARL legalization for trTeTrigExtInControl.ExtInAction0 (@ te 0x054,
	// bits [3:0], P7) -- same pattern once more. Legal values per TCI
	// Table 20: 0 (no action), 2 (trace-on), 3 (trace-off) and 4
	// (trace-notify); 1 and 5..15 are reserved. Action 4 additionally needs
	// the CT_EN_TRIG_SYNC build switch -- it IS that marker path -- and
	// without CT_EN_TRIG_REGS every value legalizes to 0, which is exactly
	// the TCI answer for a trigger input that cannot act. The action fields
	// of inputs #1..7 (bits [31:4]) are sw=r in the RDL, so the regblock
	// already ignores writes to them; nothing to legalize there.
	// ----------------------------------------------------------------
	uwire logic [3:0] s_extinact_wr = s_cpuif_wr_data[3:0];
	uwire logic       s_extinact_ok = ct_pkg::CT_EN_TRIG_REGS
		&& (  (s_extinact_wr == 4'(ct_cs_cpuif__te__trTeTrigExtInControl__trTeTrigAction_e__TRIG_ACT_ON))
		   || (s_extinact_wr == 4'(ct_cs_cpuif__te__trTeTrigExtInControl__trTeTrigAction_e__TRIG_ACT_OFF))
		   || (ct_pkg::CT_EN_TRIG_SYNC
		       && (s_extinact_wr == 4'(ct_cs_cpuif__te__trTeTrigExtInControl__trTeTrigAction_e__TRIG_ACT_NOTIFY))));
	uwire logic [3:0] s_extinact_legal = s_extinact_ok ? s_extinact_wr : 4'd0;

	uwire logic [31:0] s_cpuif_wr_data_warl =
		(s_cpuif_addr == 15'h0000)
			? {s_cpuif_wr_data[31:30], s_senddevid_legal, s_cpuif_wr_data[27:7],
			   s_instmode_legal, s_cpuif_wr_data[3:0]}
		: (s_cpuif_addr == 15'h0010)
			? {s_cpuif_wr_data[31:20], s_daddrcmp_legal, s_cpuif_wr_data[17:0]}
		: (s_cpuif_addr == 15'h0054)
			? {s_cpuif_wr_data[31:4], s_extinact_legal}
			: s_cpuif_wr_data;

	ct_cs_cpuif__in_t        hwif_in;
	uwire ct_cs_cpuif__out_t hwif_out;

	// CT_MICRO_CSR (O2): hand-written CF-only-slim drop-in vs. generated
	// regblock -- identical ports/hwif, identical SW contract (see
	// ct_cs_micro header). Default 0 = generated block (RDL = SSOT).
	if (ct_pkg::CT_MICRO_CSR) begin : genMicroCsr
		ct_cs_micro ct_cs_cpuif_inst (
			.clk (wb_clk),
			.rst (ct_cs_rst),
			.s_cpuif_req,
			.s_cpuif_req_is_wr,
			.s_cpuif_addr,
			.s_cpuif_wr_data (s_cpuif_wr_data_warl),
			.s_cpuif_wr_biten,
			.s_cpuif_req_stall_wr,
			.s_cpuif_req_stall_rd,
			.s_cpuif_rd_ack,
			.s_cpuif_rd_err,
			.s_cpuif_rd_data,
			.s_cpuif_wr_ack,
			.s_cpuif_wr_err,
			.hwif_in,
			.hwif_out
		);
	end
	else begin : genRdlCsr
		ct_cs_cpuif ct_cs_cpuif_inst (
			.clk (wb_clk),
			.rst (ct_cs_rst),
			.s_cpuif_req,
			.s_cpuif_req_is_wr,
			.s_cpuif_addr,
			.s_cpuif_wr_data (s_cpuif_wr_data_warl),
			.s_cpuif_wr_biten,
			.s_cpuif_req_stall_wr,
			.s_cpuif_req_stall_rd,
			.s_cpuif_rd_ack,
			.s_cpuif_rd_err,
			.s_cpuif_rd_data,
			.s_cpuif_wr_ack,
			.s_cpuif_wr_err,
			.hwif_in,
			.hwif_out
		);
	end

	// SWWE gating ("configuration fields are accessible only while
	// trTeControl.Enable=0") is expressed declaratively in the RDL via
	// `<path>->swwel = te.trTeControl.Enable;` dynamic assignments at the end
	// of ct_cs_cpuif.rdl. PeakRDL-regblock 1.3.x honours those references and
	// generates the internal write gate directly in ct_cs_cpuif.sv, so no
	// hwif_in.*.swwe inputs exist anymore and no wrapper-side plumbing is
	// needed. The TIP-FIFO clear bits intentionally stay always-writable by
	// not listing them in the RDL swwel block.

	// act_st table load path (watchpoints) -- INDIRECT (C0b).
	// The direct 0x4100 window is gone: 1023 entries x 8 B would span
	// 0x4100-0x60F7 and overlap the df component at 0x5000 (PeakRDL
	// refuses the map). Protocol: trWpIndex.Idx picks the slot, a
	// trWpDataLow write stages the Addr, a trWpDataHigh write COMMITS
	// {Addr, Cmd} to slot Idx and increments Idx (wrap at NUM_ACT_ST-1).
	// Readback: trWpReadLow/High return the shadow entry at Idx; a
	// trWpReadHigh read also increments Idx (trTeTipFifoHistData pattern).

	// Consistency guard (C0b audit B-1): the wrap arithmetic below uses
	// the GENERATED register-map capacity (ct_cs_cpuif_pkg::NUM_ACT_ST,
	// from rdl/ct_cs_cpuif.rdl) while the search tree and the shadow are
	// sized from ct_pkg::M0_N/M0_STAGES. A register map regenerated
	// against a stale NUM_ACT_ST would wrap the index at the wrong slot
	// and let trWpCap advertise a wrong capacity -- SILENTLY. The poison
	// instance keeps the violation fatal on backends that demote $fatal
	// to a warning (Verilator under abc's blanket -Wno-fatal).
	if (ct_pkg::M0_N != ct_cs_cpuif_pkg::NUM_ACT_ST) begin : genWpCapConsistencyGuard
		$fatal(1, "ct_cs_cpuif_wb: ct_pkg::M0_N (%0d) != ct_cs_cpuif_pkg::NUM_ACT_ST (%0d) -- rerun `make rdl` after changing M0_DIM (rdl/ct_cs_cpuif.rdl NUM_ACT_ST must follow)", ct_pkg::M0_N, ct_cs_cpuif_pkg::NUM_ACT_ST);
		ct_elab_guard_violation poison ();
	end

	typedef struct packed {
		logic [31:0] key;
		logic [31:0] value;
	} tp_watchpoints_t;

	// M0_STAGES is the act_st_wext.addr width by construction (ct_encoder
	// declares the interface with .A_BITS(M0_STAGES)); Verilator cannot
	// evaluate $bits() of an interface-port member in a constant context.
	localparam int WATCHPOINTS_DEPTH = 1 << ct_pkg::M0_STAGES;

	logic [$bits(act_st_wext.addr)-1:0]  WrAddrWatchpoints = '0;
	logic                                WrWatchpoints     = 1'b0;
	tp_watchpoints_t                     WpWrData          = '0;

	// Watchpoints commit path + SW-readback shadow: only with the ACT
	// blocks (their target memory is inside act_st).
	if (ct_pkg::CT_EN_ACT) begin : genWpShadow
		// DEPTH 1024 -> the shadow must be a true BRAM: synchronous read,
		// NO reset loop (the old reset-cleared variant infers 65k
		// flip-flops at this depth). Content is zero-initialized at
		// configuration load (FPGA BRAM INIT / simulator initial); a SOFT
		// reset does not clear it. That matches the search tree itself:
		// its ocram keeps content over a soft reset too, and the
		// programming rules require software to rewrite ALL slots anyway.
		(* ram_style = "block" *) tp_watchpoints_t ActStMemShadow [0:WATCHPOINTS_DEPTH-1];
		tp_watchpoints_t WpShadowRd;
		logic            WpCommit = 1'b0;

		initial begin
			for (int idx = 0; idx < WATCHPOINTS_DEPTH; idx++) begin
				ActStMemShadow[idx] = '0;
			end
		end

		uwire [$bits(act_st_wext.addr)-1:0] wp_idx_addr =
			hwif_out.trWpIndex.Idx.value[$bits(act_st_wext.addr)-1:0];
		// Staged Cmd word in RDL bit layout ({DirectData, Sink, Cmd}), the
		// same 32-bit image the old +0x4 window write carried.
		uwire logic [31:0] wp_cmd_word = { hwif_out.trWpDataHigh.DirectData.value,
		                                   hwif_out.trWpDataHigh.Sink.value,
		                                   hwif_out.trWpDataHigh.Cmd.value };

		// Commit control. swmod pulses in the bus-write cycle; one cycle
		// later the staged storage (DataLow written earlier, DataHigh in
		// that very write) is stable and the entry is committed. The
		// explicit !Enable gate is REQUIRED, not decoration: the generated
		// swmod strobe fires on the write ACCESS regardless of the swwel
		// lock (verified in the regenerated ct_cs_cpuif.sv), so without it
		// a locked write would still commit the STALE staging content.
		always_ff @(posedge wb_clk) begin
			if (wb_rst || ct_cs_rst) begin
				WpCommit          <= 1'b0;
				WrAddrWatchpoints <= '0;
				WrWatchpoints     <= 1'b0;
				WpWrData          <= '0;
			end
			else begin
				WpCommit      <= hwif_out.trWpDataHigh.Cmd.swmod
				              && !hwif_out.te.trTeControl.Enable.value;
				WrWatchpoints <= 1'b0;
				if (WpCommit) begin
					WrAddrWatchpoints <= wp_idx_addr;
					WpWrData          <= '{ key:   hwif_out.trWpDataLow.Value.value,
					                        value: wp_cmd_word };
					WrWatchpoints     <= 1'b1;
				end
			end
		end

		// Shadow BRAM: write on commit, read continuously at Idx (simple
		// dual port, read-first; no reset -- see the block comment above).
		// The 1-cycle read latency is invisible at bus speed: Idx moves at
		// least one whole Wishbone transaction before the next readback.
		always_ff @(posedge wb_clk) begin
			if (WpCommit) begin
				ActStMemShadow[wp_idx_addr] <= '{ key:   hwif_out.trWpDataLow.Value.value,
				                                  value: wp_cmd_word };
			end
			WpShadowRd <= ActStMemShadow[wp_idx_addr];
		end

		// Readback registers are hw-driven wires from the shadow.
		assign hwif_in.trWpReadLow.Value.next       = WpShadowRd.key;
		assign hwif_in.trWpReadHigh.Cmd.next        = WpShadowRd.value[5:0];
		assign hwif_in.trWpReadHigh.Sink.next       = WpShadowRd.value[7:6];
		assign hwif_in.trWpReadHigh.DirectData.next = WpShadowRd.value[31:8];

		// Idx autoincrement: on commit AND on serial readback (trWpReadHigh
		// read). Wrap at the last implemented slot, which also normalizes
		// an out-of-range software value back into the table.
		assign hwif_in.trWpIndex.Idx.we   = WpCommit
		                                  || hwif_out.trWpReadHigh.Cmd.swacc;
		assign hwif_in.trWpIndex.Idx.next =
			(32'(hwif_out.trWpIndex.Idx.value) >= NUM_ACT_ST - 1)
				? 16'd0
				: hwif_out.trWpIndex.Idx.value + 16'd1;
	end
	else begin : genWpShadowStub
		always_comb begin
			WrAddrWatchpoints = '0;
			WrWatchpoints     = 1'b0;
			WpWrData          = '0;
		end
		assign hwif_in.trWpReadLow.Value.next       = '0;
		assign hwif_in.trWpReadHigh.Cmd.next        = '0;
		assign hwif_in.trWpReadHigh.Sink.next       = '0;
		assign hwif_in.trWpReadHigh.DirectData.next = '0;
		assign hwif_in.trWpIndex.Idx.we             = 1'b0;
		assign hwif_in.trWpIndex.Idx.next           = '0;
	end

	assign act_st_wext.ce   = WrWatchpoints;
	assign act_st_wext.we   = WrWatchpoints;
	assign act_st_wext.addr = WrAddrWatchpoints;
	// Field-by-field, not a struct assignment: the write interface carries
	// m0_kr_t, whose key half is CT_XLEN wide (ct_pkg), while the CSR side
	// stays a pair of 32-bit words. At XLEN = 32 this is bit-identical to
	// the historical direct-window packing; at 64 an implicit zero-extension
	// would SHIFT the fields instead of widening the key, so the packing is
	// spelled out. The upper key half is 0 -- see the M0_K comment in
	// ct_pkg.sv for what that means for the reachable watchpoint range.
	assign act_st_wext.d    = { M0_K'(WpWrData.key), M0_R'(WpWrData.value) };

	// df_mem interface (mem1)
	// Lower 32-bit word at base+0x0: key0
	// Upper 32-bit word at base+0x4: key1

	typedef struct packed {
		logic [31:0] key;
		logic [31:0] value;
	} tp_mem1_t;

	localparam int MEM1_WORD_SEL_BIT   = $clog2(32/8);
	localparam int MEM1_ENTRY_ADDR_LSB = $clog2($bits(tp_mem1_t)/8);
	localparam int MEM1_DEPTH          = 1 << ($bits(hwif_out.mem1.addr) - MEM1_ENTRY_ADDR_LSB);

	tp_mem1_t                             TpMem1     = '0;
	logic [$bits(df_range_wext.addr)-1:0] WrAddrMem1 = '0;
	logic                                 WrMem1     = 1'b0;
	uwire [$bits(df_range_wext.addr)-1:0] rd_addr_mem1 = hwif_out.mem1.addr >> MEM1_ENTRY_ADDR_LSB;
	tp_mem1_t mem1_rd_entry;

	// DF-range write path + SW-readback shadow: only with the data-trace
	// feature group (target memory is inside df_range). Profile-gated the
	// shadow saves ~1k FFs.
	//
	// The write is Enable-locked, and here rather than in the RDL because
	// SystemRDL `swwel` applies to FIELDS, not to a `mem` -- the same reason
	// the watchpoint COMMIT above needs an explicit gate (U10 F-3). The rule
	// is the one trWpDataHigh states for the twin table: both tables feed a
	// `vector_binary_search` tree whose contract is a SORTED, non-overlapping
	// key array (ct_L23_preproc_df_range.sv:88), and a mid-trace write does
	// not merely change one entry -- an out-of-order key at an inner node
	// sends every concurrent lookup down the wrong branch, so ranges nobody
	// touched stop matching. Until 2026-08-16 mem1 was the one configuration
	// store in this block with no lock at all (found by an external register
	// read/write audit, row 18); the twin was locked twice. Cost: none -- programming a filter table with tracing
	// disabled is what every caller in this repository already does.
	if (ct_pkg::CT_EN_DATA_TRACE) begin : genMem1Shadow
		uwire mem1_wr_allowed = !hwif_out.te.trTeControl.Enable.value;

		(* ram_style = "block" *) tp_mem1_t DfRangeMemShadow [0:MEM1_DEPTH-1];

		always_ff @(posedge wb_clk) begin
			if (wb_rst || ct_cs_rst) begin
				TpMem1     <= '0;
				WrAddrMem1 <= '0;
				WrMem1     <= 1'b0;
				for (int idx = 0; idx < MEM1_DEPTH; idx++) begin
					DfRangeMemShadow[idx] <= '0;
				end
			end
			else begin
				WrMem1 <= 1'b0;
				if (hwif_out.mem1.req && hwif_out.mem1.req_is_wr && mem1_wr_allowed) begin
					if (hwif_out.mem1.addr[MEM1_WORD_SEL_BIT] == 0) begin // lower 32-bit word, store key
						TpMem1.key <= hwif_out.mem1.wr_data;
					end
					else begin
						TpMem1.value <= hwif_out.mem1.wr_data;
						WrAddrMem1   <= hwif_out.mem1.addr >> MEM1_ENTRY_ADDR_LSB;
						WrMem1       <= 1'b1;
						DfRangeMemShadow[hwif_out.mem1.addr >> MEM1_ENTRY_ADDR_LSB].key   <= TpMem1.key;
						DfRangeMemShadow[hwif_out.mem1.addr >> MEM1_ENTRY_ADDR_LSB].value <= hwif_out.mem1.wr_data;
					end
				end
			end
		end
		assign mem1_rd_entry = DfRangeMemShadow[rd_addr_mem1];
	end
	else begin : genMem1ShadowStub
		always_comb begin
			TpMem1     = '0;
			WrAddrMem1 = '0;
			WrMem1     = 1'b0;
		end
		assign mem1_rd_entry = '0;
	end

	assign df_range_wext.ce   = WrMem1;
	assign df_range_wext.we   = WrMem1;
	assign df_range_wext.addr = WrAddrMem1;
	// Explicit packing, same reason as act_st_wext.d above: m1_kr_t holds
	// two CT_XLEN-wide keys, the CSR side two 32-bit words. Bit-identical to
	// the historical `= TpMem1` at XLEN = 32.
	assign df_range_wext.d    = { M1_K'(TpMem1.key), M1_K'(TpMem1.value) };

	always_comb begin
		// External memory read-data muxes
		hwif_in.mem1.wr_ack  = hwif_out.mem1.req &&  hwif_out.mem1.req_is_wr;
		hwif_in.mem1.rd_ack  = hwif_out.mem1.req && !hwif_out.mem1.req_is_wr;
		hwif_in.mem1.rd_data = (hwif_out.mem1.addr[MEM1_WORD_SEL_BIT] == 0)
			? mem1_rd_entry.key
			: mem1_rd_entry.value;

		// ----------------------------------------------------------------------------------------------------
		// Trace Encoder - tip_clk domain
		// (tip_clk / proc_clk / atb_clk consumers are only sampled while trTeControl.Enable = 0,
		//  so these fields do not need CDC.)
		// ----------------------------------------------------------------------------------------------------
		cs_tip.trTeActive       = hwif_out.te.trTeControl.Active.value;
		cs_tip.trTeContext      = hwif_out.te.trTeControl.Context.value;
		cs_tip.trTeSendConfig   = ct_cs_cpuif__te__trTeControl__trTeSendConfigMode_e_e'(
		                            ct_pkg::CT_EN_CONFIG_MSG ? hwif_out.te.trTeControl.SendConfig.value : 2'd0);
		// P4: Device ID emission mode + watchpoint slot mask. Same no-CDC
		// class as the fields above (programming contract: written only
		// while trTeControl.Enable = 0); compiled out they fold to their
		// reset values (DID_NONE / all-zero mask) and every consumer with
		// them.
		cs_tip.trTeSendDeviceId = ct_cs_cpuif__te__trTeControl__trTeSendDeviceIdMode_e_e'(
		                            ct_pkg::CT_EN_DEVICE_ID ? hwif_out.te.trTeControl.SendDeviceId.value[0] : 1'b0);
		cs_tip.trWpWEM          = ct_pkg::CT_EN_WATCHPOINT_MSG ? hwif_out.trWpMask.WEM.value : 16'd0;
		cs_tip.trTeInstMode     = ct_cs_cpuif__te__trTeControl__trTeInstMode_e_e'    (hwif_out.te.trTeControl.InstMode.value);
		cs_tip.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e_e'(hwif_out.te.trTeControl.InstSyncMode.value);
		cs_tip.trTeInstSyncMax  = hwif_out.te.trTeControl.InstSyncMax.value;
		cs_tip.trTeInstFilters  = hwif_out.te.trTeInstFilters.Filters.value;
		cs_tip.trTeInstEnWideIcnt = hwif_out.te.trTeInstFeatures.InstEnWideIcnt.value;
		cs_tip.trTeInstEnBranchPrediction = hwif_out.te.trTeInstFeatures.InstEnBranchPrediction.value;
		cs_tip.trTeDataFilters  = hwif_out.te.trTeDataFilters.Filters.value;

		// CT_EN_TIMESTAMP=0: no TS hardware -- constants fold, the ts unit's
		// control inputs (and with them the unit itself) trim away.
		cs_tip.trTsReset    = ct_pkg::CT_EN_TIMESTAMP ? hwif_out.te.trTsControl.Reset.value : 1'b0;
		cs_tip.trTsType     = ct_cs_cpuif__te__trTsControl__trTsType_e_e'(
		                        ct_pkg::CT_EN_TIMESTAMP ? hwif_out.te.trTsControl.Type.value : '0);
		cs_tip.trTsPrescale = ct_pkg::CT_EN_TIMESTAMP ? hwif_out.te.trTsControl.Prescale.value : '0;

		cs_tip.trPcIFetchThreshold = hwif_out.pc.trPerfCntControl.IFetchThreshold.value;
		cs_tip.trPcDataRdThreshold = hwif_out.pc.trPerfCntControl.DataWrThreshold.value;
	end

	for (genvar i = 0; i < NUM_TRACE_FILTER; i++) begin
		always_comb begin
			cs_tip.trTeFilterEnable[i]                = hwif_out.te.trTeFilter[i].Control.Enable.value;
			cs_tip.trTeFilterMatchPrivilege[i]        = hwif_out.te.trTeFilter[i].Control.MatchPrivilege.value;
			cs_tip.trTeFilterMatchEcause[i]           = hwif_out.te.trTeFilter[i].Control.MatchEcause.value;
			cs_tip.trTeFilterMatchInterrupt[i]        = hwif_out.te.trTeFilter[i].Control.MatchInterrupt.value;
			cs_tip.trTeFilterMatchComp[i][0]          = hwif_out.te.trTeFilter[i].Control.MatchComp1.value;
			cs_tip.trTeFilterComp[i][0]               = hwif_out.te.trTeFilter[i].Control.Comp1.value;
			cs_tip.trTeFilterMatchComp[i][1]          = hwif_out.te.trTeFilter[i].Control.MatchComp2.value;
			cs_tip.trTeFilterComp[i][1]               = hwif_out.te.trTeFilter[i].Control.Comp2.value;
			cs_tip.trTeFilterMatchComp[i][2]          = hwif_out.te.trTeFilter[i].Control.MatchComp3.value;
			cs_tip.trTeFilterComp[i][2]               = hwif_out.te.trTeFilter[i].Control.Comp3.value;
			cs_tip.trTeFilterMatchImpdef[i]           = hwif_out.te.trTeFilter[i].Control.Impdef.value;
			cs_tip.trTeFilterMatchDtype[i]            = hwif_out.te.trTeFilter[i].Control.Dtype.value;
			cs_tip.trTeFilterMatchDsize[i]            = hwif_out.te.trTeFilter[i].Control.Dsize.value;
			cs_tip.trTeFilterMatchChoicePrivilege[i]  = hwif_out.te.trTeFilter[i].Match.ChoicePrivilege.value;
			cs_tip.trTeFilterMatchValueInterrupt[i]   = ct_cs_cpuif__te__trTeFilter__Match__trTeFilterMatchInstExInt_e_e'(hwif_out.te.trTeFilter[i].Match.ValueInterrupt.value);
			cs_tip.trTeFilterMatchChoiceEcauseLow[i]  = hwif_out.te.trTeFilter[i].MatchChoiceEcauseLow.Value.value;
			cs_tip.trTeFilterMatchChoiceEcauseHigh[i] = hwif_out.te.trTeFilter[i].MatchChoiceEcauseHigh.Value.value;
			cs_tip.trTeFilterMatchValueImpdef[i]      = hwif_out.te.trTeFilter[i].MatchValueImpdef.Value.value;
			cs_tip.trTeFilterMatchMaskImpdef[i]       = hwif_out.te.trTeFilter[i].MatchMaskImpdef.Value.value;
			cs_tip.trTeFilterMatchChoiceDtype[i]      = hwif_out.te.trTeFilter[i].MatchChoiceData.Dtype.value;
			cs_tip.trTeFilterMatchChoiceDsize[i]      = hwif_out.te.trTeFilter[i].MatchChoiceData.Dsize.value;
		end
	end

	for (genvar i = 0; i < NUM_TRACE_COMPARATORS; i++) begin
		always_comb begin
			// PInput/SInput must be mapped here. Without them
			// cs_tip.trTeCompPInput/SInput stay at their IADDR reset value
			// and the CONTEXT/TVAL/DADDR comparator inputs have no effect.
			// The field default is 0 = IADDR, so adding the mapping leaves
			// every previously produced stream byte-identical.
			cs_tip.trTeCompPInput[i]     = ct_cs_cpuif__te__trTeComp__Control__trTeCompInput_e_e'(hwif_out.te.trTeComp[i].Control.PInput.value);
			cs_tip.trTeCompSInput[i]     = ct_cs_cpuif__te__trTeComp__Control__trTeCompInput_e_e'(hwif_out.te.trTeComp[i].Control.SInput.value);
			cs_tip.trTeCompPFunction[i]  = ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e_e'(hwif_out.te.trTeComp[i].Control.PFunction.value);
			cs_tip.trTeCompSFunction[i]  = ct_cs_cpuif__te__trTeComp__Control__trTeCompSFunction_e_e'(hwif_out.te.trTeComp[i].Control.SFunction.value);
			cs_tip.trTeCompMatchMode[i]  = ct_cs_cpuif__te__trTeComp__Control__trTeCompMatchMode_e_e'(hwif_out.te.trTeComp[i].Control.MatchMode.value);
			cs_tip.trTeCompPNotify[i]    = hwif_out.te.trTeComp[i].Control.PNotify.value;
			cs_tip.trTeCompSNotify[i]    = hwif_out.te.trTeComp[i].Control.SNotify.value;
			cs_tip.trTeCompPMatchLow[i]  = hwif_out.te.trTeComp[i].PMatchLow.Value.value;
			cs_tip.trTeCompPMatchHigh[i] = hwif_out.te.trTeComp[i].PMatchHigh.Value.value;
			cs_tip.trTeCompSMatchLow[i]  = hwif_out.te.trTeComp[i].SMatchLow.Value.value;
			cs_tip.trTeCompSMatchHigh[i] = hwif_out.te.trTeComp[i].SMatchHigh.Value.value;
			cs_tip.trTeCompSMaskLow[i]   = hwif_out.te.trTeComp[i].SMaskLow.Value.value;
			cs_tip.trTeCompSMaskHigh[i]  = hwif_out.te.trTeComp[i].SMaskHigh.Value.value;
		end
	end

	for (genvar i = 0; i < NUM_PERFCNT_IFETCH_TH_RANGES; i++) begin
		always_comb begin
			cs_tip.trTePerfCntIFetchRangeLow[i]  = hwif_out.pc.trTePerfCntIFetchRange[i].Low.Value.value;
			cs_tip.trTePerfCntIFetchRangeHigh[i] = hwif_out.pc.trTePerfCntIFetchRange[i].High.Value.value;
		end
	end

	for (genvar i = 0; i < NUM_PERFCNT_DATA_RD_TH_RANGES; i++) begin
		always_comb begin
			cs_tip.trTePerfCntDataRdThRangeLow[i]  = hwif_out.pc.trTePerfCntDataRdThRange[i].Low.Value.value;
			cs_tip.trTePerfCntDataRdThRangeHigh[i] = hwif_out.pc.trTePerfCntDataRdThRange[i].High.Value.value;
		end
	end

	for (genvar i = 0; i < NUM_PERFCNT_DATA_RD_RANGES; i++) begin
		always_comb begin
			cs_tip.trTePerfCntDataRdRangeLow[i]  = hwif_out.pc.trTePerfCntDataRdRange[i].Low.Value.value;
			cs_tip.trTePerfCntDataRdRangeHigh[i] = hwif_out.pc.trTePerfCntDataRdRange[i].High.Value.value;
		end
	end

	for (genvar i = 0; i < NUM_PERFCNT_DATA_WR_RANGES; i++) begin
		always_comb begin
			cs_tip.trTePerfCntDataWrRangeLow[i]  = hwif_out.pc.trTePerfCntDataWrRange[i].Low.Value.value;
			cs_tip.trTePerfCntDataWrRangeHigh[i] = hwif_out.pc.trTePerfCntDataWrRange[i].High.Value.value;
		end
	end

	always_comb begin
		// ----------------------------------------------------------------------------------------------------
		// Trace Encoder - proc_clk domain
		// ----------------------------------------------------------------------------------------------------
		cs_proc.trTeActive           = hwif_out.te.trTeControl.Active.value;
		cs_proc.trTeInstMode         = ct_cs_cpuif__te__trTeControl__trTeInstMode_e_e'(hwif_out.te.trTeControl.InstMode.value);
		cs_proc.trTeContext          = hwif_out.te.trTeControl.Context.value;
		cs_proc.trTeInhibitSrc       = hwif_out.te.trTeControl.InhibitSrc.value;
		cs_proc.trTeInstSyncMode     = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e_e'(hwif_out.te.trTeControl.InstSyncMode.value);
		cs_proc.trTeInstSyncMax      = hwif_out.te.trTeControl.InstSyncMax.value;
		cs_proc.trTeSrcID            = hwif_out.te.trTeInstFeatures.SrcID.value;
		cs_proc.trTeSrcBits          = hwif_out.te.trTeInstFeatures.SrcBits.value;
		cs_proc.trTeInstEnImplicitReturn = hwif_out.te.trTeInstFeatures.InstEnImplicitReturn.value;
		// Compiled-in back end (P9): a synthesis parameter, not a runtime
		// select -- the same constant software reads back from
		// trTeProtocolSel.Protocol.
		cs_proc.trTeProtocolSel      = EN_ETRACE;
		cs_proc.trTeInstEnBranchPrediction = hwif_out.te.trTeInstFeatures.InstEnBranchPrediction.value;
		cs_proc.trTeInstEnRepeatedHistory = hwif_out.te.trTeInstFeatures.InstEnRepeatedHistory.value;
		cs_proc.trTeInstEnRepeatBranch = hwif_out.te.trTeInstFeatures.InstEnRepeatBranch.value;
		cs_proc.trTeInstEnJumpTargetCache = hwif_out.te.trTeInstFeatures.InstEnJumpTargetCache.value;
		cs_proc.trTeInstEnWideIcnt   = hwif_out.te.trTeInstFeatures.InstEnWideIcnt.value;
		cs_proc.trTeInstEnIbhs       = hwif_out.te.trTeInstFeatures.InstEnIbhs.value;
		cs_proc.trTeInstEnRepeatInstr = hwif_out.te.trTeInstFeatures.InstEnRepeatInstr.value;
		cs_proc.trTeDataAddrCompress = ct_cs_cpuif__te__trTeDataControl__trTeDataAddrCompress_e_e'(hwif_out.te.trTeDataControl.DataAddrCompress.value);

		// Config-message ENAB/P2 sources (TCODE 58, C2): quasi-static config
		// values (programming contract: written only while Enable = 0), read
		// by the formatter/packer at emission time -- same no-CDC class as
		// the fields above. DataTracing reflects the SW-programmed start
		// value (ACT-CAP runtime overrides are visible on-wire anyway).
		cs_proc.trTeInstTrigEnable    = ct_pkg::CT_EN_TRIG_SYNC
		                              ? hwif_out.te.trTeControl.InstTrigEnable.value : 1'b0;
		cs_proc.trTeInstSeqSyncEnable = ct_pkg::CT_EN_SEQ_SYNC
		                              ? hwif_out.te.trTeControl.InstSeqSyncEnable.value : 1'b0;
		cs_proc.trTeSendDeviceId      = ct_cs_cpuif__te__trTeControl__trTeSendDeviceIdMode_e_e'(
		                                  ct_pkg::CT_EN_DEVICE_ID ? hwif_out.te.trTeControl.SendDeviceId.value[0] : 1'b0);
		cs_proc.trWpWEM               = ct_pkg::CT_EN_WATCHPOINT_MSG
		                              ? hwif_out.trWpMask.WEM.value : 16'd0;
		cs_proc.trTeDataTracing       = ct_pkg::CT_EN_DATA_TRACE
		                              ? hwif_out.te.trTeDataControl.DataTracing.value : 1'b0;
		// DataDropEna (P7, ENAB.22): a runtime policy rather than a config
		// field, but the config message is only ever emitted at a trace start
		// or a sync -- sampling it here with the other ENAB sources is the
		// same no-CDC class (a mid-stream arm is simply reported by the NEXT
		// config message).
		cs_proc.trTeDataDropEna       = ct_pkg::CT_EN_DF_DROP
		                              ? hwif_out.te.trTeDataControl.DataDropEna.value : 1'b0;
		cs_proc.trTsType              = ct_cs_cpuif__te__trTsControl__trTsType_e_e'(
		                                  ct_pkg::CT_EN_TIMESTAMP ? hwif_out.te.trTsControl.Type.value : '0);
		cs_proc.trTsPrescale          = ct_pkg::CT_EN_TIMESTAMP ? hwif_out.te.trTsControl.Prescale.value : '0;
		cs_proc.trTsWidth             = ct_pkg::CT_EN_TIMESTAMP ? hwif_out.te.trTsControl.Width.value : '0;

		// ----------------------------------------------------------------------------------------------------
		// atb_clk domain
		// ----------------------------------------------------------------------------------------------------
		cs_atb.trAtbId                    = hwif_out.atb.trAtbBridgeControl.ID.value;
		cs_atb.trTeProtocolSel            = EN_ETRACE;
		hwif_in.te.trTeControl.Empty.next = cs_atb.trTeEmpty;

		// ----------------------------------------------------------------------------------------------------
		// dec_clk domain (decoder clock - simulation only)
		// ----------------------------------------------------------------------------------------------------
		cs_dec.trTdInhibitSrc = cs_proc.trTeInhibitSrc;
		cs_dec.trTdSrcBits    = cs_proc.trTeSrcBits;
	end

	// ----------------------------------------------------------------------------------------------------
	// trTeInstSyncReq (P8/G11): sw write-1 requests an instruction sync. The
	// RDL field is `sw = w; singlepulse;`, so `value` is a ONE-CYCLE wb_clk
	// pulse and the bit reads back as 0 -- the self-clear lives in the
	// generated block, no hwif_in tie-off here (the house idiom, same as
	// trTeTipFifoHistCtrl.RdRewind; P8 audit B-4).
	//
	// The pacing itself is ct_sync_req_pacer -- a module of its own, because
	// formal/preproc_sync instantiates THAT source to prove P-SYNC-9/10/12.
	// What crosses is a four-phase LEVEL handshake, not a pair of strobes:
	// see its header for why (a strobe cannot survive a reset of the
	// consumer's domain alone -- P8 closing audit B-N1).
	//
	// What the pacing means for software, precisely: one request is in flight
	// and ONE further write is remembered. A write while a request is still
	// outstanding is NOT swallowed -- it is launched as its own request after
	// the acknowledgement and produces its own synchronization message. Only a
	// write arriving when one is already queued collapses into that queued
	// request. (The earlier documentation claimed the second write was
	// absorbed; that described the discarded level design, not this one --
	// P8 audit A-1.)
	//
	// Compiled out (CT_EN_INST_SYNC_REQ = 0) the pacer and the crossings trim
	// away and the write is inert again -- the pre-P8 behaviour.
	// ----------------------------------------------------------------------------------------------------
	uwire logic sync_req_ack_wb;    // consumer's "served" LEVEL, crossed into wb_clk
	uwire logic sync_req_lvl_wb;    // wb_clk LEVEL: one request is owed
	if (ct_pkg::CT_EN_INST_SYNC_REQ) begin : genInstSyncReq
		ct_sync_req_pacer sync_req_pacer (
			.clk   (wb_clk),
			.rst   (wb_rst),
			.write (hwif_out.te.trTeControl.InstSyncReq.value),
			.ack   (sync_req_ack_wb),
			.req   (sync_req_lvl_wb)
		);
	end
	else begin : genNoInstSyncReq
		assign sync_req_lvl_wb = 1'b0;
		uwire logic unused_inst_sync_req = hwif_out.te.trTeControl.InstSyncReq.value
		                                || sync_req_ack_wb;
	end

	// Protocol discovery (P9): both fields are sw=r/hw=w and report the back
	// end that was actually built into THIS instance. Constants, so they cost
	// nothing; they exist so a mixed-protocol SoC (one N-Trace encoder next
	// to an E-Trace one) tells software the truth per encoder instead of a
	// profile-wide guess. 1 = N-Trace 1.x, 2 = E-Trace 2.x.
	assign hwif_in.te.trTeProtocolSel.Protocol.next = EN_ETRACE;
	assign hwif_in.te.trTeImpl.ProtocolMajor.next   = EN_ETRACE ? 4'd2 : 4'd1;

	// ----------------------------------------------------------------------------------------------------
	// Sticky overflow/drop status (P7/G12): the RW1C bits
	// te.trTeControl.InstStallOrOverflow, te.trTeDataControl.DataStallOrOverflow
	// and te.trTeDataControl.DataDrop. Set by a ONE-CYCLE event strobe from
	// tip_clk (crossed below), cleared by a software write of 1 -- and cleared
	// by hardware while the encoder is disabled, so each trace session starts
	// from a known-clear bit ("clear on enable").
	// The set term is gated with the same Enable level: hwset outranks hwclr in
	// the generated field logic, and a strobe that crosses the domain a few
	// cycles after Enable fell must not resurrect the bit for the next session.
	// ----------------------------------------------------------------------------------------------------
	uwire logic status_enable   = hwif_out.te.trTeControl.Enable.value;
	uwire logic ovf_event_wb;    // eTIP overflow ERROR message generated
	uwire logic df_drop_event_wb; // DataDropEna policy dropped data-trace messages
	assign hwif_in.te.trTeControl.InstStallOrOverflow.hwset       = ovf_event_wb && status_enable;
	assign hwif_in.te.trTeControl.InstStallOrOverflow.hwclr       = !status_enable;
	assign hwif_in.te.trTeDataControl.DataStallOrOverflow.hwset   = (ovf_event_wb || df_drop_event_wb) && status_enable;
	assign hwif_in.te.trTeDataControl.DataStallOrOverflow.hwclr   = !status_enable;
	assign hwif_in.te.trTeDataControl.DataDrop.hwset              = df_drop_event_wb && status_enable;
	assign hwif_in.te.trTeDataControl.DataDrop.hwclr              = !status_enable;

	// ----------------------------------------------------------------------------------------------------
	// Domain-crossing block. CT_SINGLE_CLOCK=1 (O4 diet, 2026-07-19):
	// wb/tip/proc run on ONE clock by integrator contract -- every
	// synchronizer/handshake below degenerates to a plain wire (passthrough
	// is exactly correct, there is no metastability domain to protect).
	// The only behavioral difference is 2-3 cycles less signal latency;
	// asynchronous-edge placement effects fall into the documented
	// robustness classification class (verified via md5 regression).
	// ----------------------------------------------------------------------------------------------------
	if (ct_pkg::CT_SINGLE_CLOCK) begin : genCsrSingleClk
		// ACT-CAP hwclr/hwset/value triples: strobes and level pass through.
		// P7: the external trigger's trace-on/off actions (TCI Table 20
		// actions 2/3) are a SECOND source of the very same set/clear
		// strobes -- OR-ed in here, so the ACT-CAP contract is untouched.
		assign hwif_in.te.trTeControl.InstTracing.hwclr = cs_tip.trTeInstTracingClr | cs_tip.trTeTrigTracingClr;
		assign hwif_in.te.trTeControl.InstTracing.hwset = cs_tip.trTeInstTracingSet | cs_tip.trTeTrigTracingSet;
		assign cs_tip.trTeInstTracing = hwif_out.te.trTeControl.InstTracing.value;

		assign hwif_in.te.trTeDataControl.DataTracing.hwclr = cs_tip.trTeDataTracingClr;
		assign hwif_in.te.trTeDataControl.DataTracing.hwset = cs_tip.trTeDataTracingSet;
		assign cs_tip.trTeDataTracing = hwif_out.te.trTeDataControl.DataTracing.value;

		assign cs_tip.trTeEnable  = hwif_out.te.trTeControl.Enable.value;
		assign cs_proc.trTsEnable = ct_pkg::CT_EN_TIMESTAMP
		                          ? hwif_out.te.trTsControl.Enable.value : 1'b0;
		assign cs_tip.trTsActive  = ct_pkg::CT_EN_TIMESTAMP
		                          ? hwif_out.te.trTsControl.Active.value : 1'b0;
		assign cs_tip.trTsCount   = ct_pkg::CT_EN_TIMESTAMP
		                          ? hwif_out.te.trTsControl.Count.value : 1'b0;

		assign cs_tip.trTeTipFifoMaxFillClear =
			hwif_out.te.trTeTipFifoStatus.trTeTipFifoMaxFillClear.value;
		assign cs_tip.trTeTipFifoNumOverflowsClear =
			hwif_out.te.trTeTipFifoStatus.trTeTipFifoNumOverflowsClear.value;

		assign hwif_in.te.trTsCounterHigh.Value.next = ct_pkg::CT_EN_TIMESTAMP
		                                             ? cs_tip.trTeTs[63:32] : '0;
		assign hwif_in.te.trTsCounterLow.Value.next  = ct_pkg::CT_EN_TIMESTAMP
		                                             ? cs_tip.trTeTs[31:0] : '0;
		assign hwif_in.te.trTeTipFifoStatus.trTeTipFifoMaxFill.next
			= cs_tip.trTeTipFifoMaxFill;
		assign hwif_in.te.trTeTipFifoStatus.trTeTipFifoNumOverflows.next
			= cs_tip.trTeTipFifoNumOverflows;
		if (ct_pkg::CT_EN_SYNC_STATUS) begin : genSyncStatusSingleClk
			assign hwif_in.te.trTeSyncStatus.SyncReqSource.next
				= cs_tip.trTeSyncReqSource;
		end
		assign cs_tip.trTeInstTrigEnable    = ct_pkg::CT_EN_TRIG_SYNC
			? hwif_out.te.trTeControl.InstTrigEnable.value : 1'b0;
		assign cs_tip.trTeInstSeqSyncEnable = ct_pkg::CT_EN_SEQ_SYNC
			? hwif_out.te.trTeControl.InstSeqSyncEnable.value : 1'b0;
		// P7: trigger action select + data-trace drop policy (levels) and the
		// two status event strobes -- all plain wires in a single-clock build.
		assign cs_tip.trTeTrigExtInAction0 = ct_pkg::CT_EN_TRIG_REGS
			? hwif_out.te.trTeTrigExtInControl.ExtInAction0.value : 4'd0;
		assign cs_tip.trTeDataDropEna      = ct_pkg::CT_EN_DF_DROP
			? hwif_out.te.trTeDataControl.DataDropEna.value : 1'b0;
		assign ovf_event_wb     = cs_tip.trTeInstOverflowEvent;
		assign df_drop_event_wb = cs_tip.trTeDataDropEvent;
		// P8: the sync request and its acknowledgement -- both LEVELS of the
		// four-phase handshake, both plain wires in a single-clock build.
		assign cs_tip.trTeInstSyncReq = sync_req_lvl_wb;
		assign sync_req_ack_wb        = cs_tip.trTeInstSyncReqAck;
	end
	else begin : genCsrCdc
	// ----------------------------------------------------------------------------------------------------
	// CDC for ACT-CAP controlled signals (set, clr via ACT-CAP)
	// ----------------------------------------------------------------------------------------------------
	// P7: the external trigger's trace-on/off actions (TCI Table 20 actions
	// 2/3) are a SECOND source of the same set/clear strobes -- OR-ed into
	// the ext side, so the ACT-CAP contract and its CDC stay untouched.
	ct_hwif_ext_signal_cdc trTeInstTracing_cdc (
		.hwif_clk   (wb_clk),
		.hwif_rst   (wb_rst),
		.hwif_hwclr (hwif_in.te.trTeControl.InstTracing.hwclr),
		.hwif_hwset (hwif_in.te.trTeControl.InstTracing.hwset),
		.hwif_value (hwif_out.te.trTeControl.InstTracing.value),
		.ext_clk    (tip_clk),
		.ext_rst    (tip_rst),
		.ext_hwclr  (cs_tip.trTeInstTracingClr | cs_tip.trTeTrigTracingClr),
		.ext_hwset  (cs_tip.trTeInstTracingSet | cs_tip.trTeTrigTracingSet),
		.ext_value  (cs_tip.trTeInstTracing)
	);

	ct_hwif_ext_signal_cdc trTeDataTracing_cdc (
		.hwif_clk   (wb_clk),
		.hwif_rst   (wb_rst),
		.hwif_hwclr (hwif_in.te.trTeDataControl.DataTracing.hwclr),
		.hwif_hwset (hwif_in.te.trTeDataControl.DataTracing.hwset),
		.hwif_value (hwif_out.te.trTeDataControl.DataTracing.value),
		.ext_clk    (tip_clk),
		.ext_rst    (tip_rst),
		.ext_hwclr  (cs_tip.trTeDataTracingClr),
		.ext_hwset  (cs_tip.trTeDataTracingSet),
		.ext_value  (cs_tip.trTeDataTracing)
	);

	// CDC for trTeControl.Enable: master enable for the trace encoder.
	// SW transition 1->0 must trigger an automatic flush in the tip_clk
	// pipeline (handled inside ct_L23_preproc_composer_etip.sv via a
	// falling-edge detector).
	signal_cdc signal_cdc_trTeEnable (
		.clk (tip_clk),
		.rst (tip_rst),
		.in  (hwif_out.te.trTeControl.Enable.value),
		.out (cs_tip.trTeEnable)
	);

	// CDC for the trTs* control levels; without TS hardware the levels are
	// constant 0 and the synchronizers disappear with their loads.
	if (ct_pkg::CT_EN_TIMESTAMP) begin : genTsCdc
		// CDC for trTsEnable
		signal_cdc signal_cdc_trTsEnable (
			.clk (proc_clk),
			.rst (proc_rst),
			.in  (hwif_out.te.trTsControl.Enable.value),
			.out (cs_proc.trTsEnable)
		);

		// CDC for trTsActive
		signal_cdc signal_cdc_trTsActive (
			.clk (tip_clk),
			.rst (tip_rst),
			.in  (hwif_out.te.trTsControl.Active.value),
			.out (cs_tip.trTsActive)
		);

		// CDC for trTsCount
		signal_cdc signal_cdc_trTsCount (
			.clk (tip_clk),
			.rst (tip_rst),
			.in  (hwif_out.te.trTsControl.Count.value),
			.out (cs_tip.trTsCount)
		);
	end
	else begin : genNoTsCdc
		assign cs_proc.trTsEnable = 1'b0;
		assign cs_tip.trTsActive  = 1'b0;
		assign cs_tip.trTsCount   = 1'b0;
	end

	// Cross the 64-bit trTeTs counter from tip_clk (where it is generated by
	// ct_L23_preproc_ts) into wb_clk, then split into the High/Low readback
	// registers. vector_cdc2 uses a req/ack toggle handshake so sw always reads
	// a coherent snapshot rather than a half-updated value.
	if (ct_pkg::CT_EN_TIMESTAMP) begin : genTsReadbackCdc
		uwire logic [63:0] trTeTsWb;
		vector_cdc2 #(.DATA_WIDTH(64)) cdc_trTeTs (
			.d_clk  (tip_clk),
			.d_rst  (tip_rst),
			.d_data (cs_tip.trTeTs),
			.q_clk  (wb_clk),
			.q_rst  (wb_rst),
			.q_data (trTeTsWb)
		);
		assign hwif_in.te.trTsCounterHigh.Value.next = trTeTsWb[63:32];
		assign hwif_in.te.trTsCounterLow.Value.next  = trTeTsWb[31:0];
	end
	else begin : genNoTsReadback
		assign hwif_in.te.trTsCounterHigh.Value.next = '0;
		assign hwif_in.te.trTsCounterLow.Value.next  = '0;
	end

	// CDC for trTeTipFifoMaxFill (tip_clk -> wb_clk): coherent snapshot.
	uwire logic [14:0] trTeTipFifoMaxFillWb;
	vector_cdc2 #(.DATA_WIDTH(15)) cdc_trTeTipFifoMaxFill (
		.d_clk  (tip_clk),
		.d_rst  (tip_rst),
		.d_data (cs_tip.trTeTipFifoMaxFill),
		.q_clk  (wb_clk),
		.q_rst  (wb_rst),
		.q_data (trTeTipFifoMaxFillWb)
	);
	assign hwif_in.te.trTeTipFifoStatus.trTeTipFifoMaxFill.next = trTeTipFifoMaxFillWb;

	// CDC for trTeTipFifoMaxFillClear (wb_clk -> tip_clk): level, synchronised.
	signal_cdc signal_cdc_trTeTipFifoMaxFillClear (
		.clk (tip_clk),
		.rst (tip_rst),
		.in  (hwif_out.te.trTeTipFifoStatus.trTeTipFifoMaxFillClear.value),
		.out (cs_tip.trTeTipFifoMaxFillClear)
	);

	// CDC for trTeTipFifoNumOverflows (tip_clk -> wb_clk): gray-coded coherent snapshot.
	uwire logic [14:0] trTeTipFifoNumOverflowsWb;
	vector_cdc2 #(.DATA_WIDTH(15)) cdc_trTeTipFifoNumOverflows (
		.d_clk  (tip_clk),
		.d_rst  (tip_rst),
		.d_data (cs_tip.trTeTipFifoNumOverflows),
		.q_clk  (wb_clk),
		.q_rst  (wb_rst),
		.q_data (trTeTipFifoNumOverflowsWb)
	);
	assign hwif_in.te.trTeTipFifoStatus.trTeTipFifoNumOverflows.next = trTeTipFifoNumOverflowsWb;

	// CDC for trTeTipFifoNumOverflowsClear (wb_clk -> tip_clk): level, synchronised.
	signal_cdc signal_cdc_trTeTipFifoNumOverflowsClear (
		.clk (tip_clk),
		.rst (tip_rst),
		.in  (hwif_out.te.trTeTipFifoStatus.trTeTipFifoNumOverflowsClear.value),
		.out (cs_tip.trTeTipFifoNumOverflowsClear)
	);

	// CDC for the runtime enable levels InstTrigEnable / InstSeqSyncEnable
	// (wb_clk -> tip_clk): plain level synchronizers; without the feature
	// the level is constant 0 and the synchronizer folds away.
	if (ct_pkg::CT_EN_TRIG_SYNC) begin : genTrigEnCdc
		signal_cdc signal_cdc_trTeInstTrigEnable (
			.clk (tip_clk),
			.rst (tip_rst),
			.in  (hwif_out.te.trTeControl.InstTrigEnable.value),
			.out (cs_tip.trTeInstTrigEnable)
		);
	end
	else begin : genNoTrigEnCdc
		assign cs_tip.trTeInstTrigEnable = 1'b0;
	end
	if (ct_pkg::CT_EN_SEQ_SYNC) begin : genSeqSyncEnCdc
		signal_cdc signal_cdc_trTeInstSeqSyncEnable (
			.clk (tip_clk),
			.rst (tip_rst),
			.in  (hwif_out.te.trTeControl.InstSeqSyncEnable.value),
			.out (cs_tip.trTeInstSeqSyncEnable)
		);
	end
	else begin : genNoSeqSyncEnCdc
		assign cs_tip.trTeInstSeqSyncEnable = 1'b0;
	end

	// CDC for trTeSyncReqSource (tip_clk -> wb_clk): quasi-static 3-bit
	// status, coherent snapshot like the FIFO watermark above. Omitted with
	// CT_EN_SYNC_STATUS=0 (the register is dropped from the regblock, no
	// hwif_in port -- §4a slim reclaim via register omission).
	if (ct_pkg::CT_EN_SYNC_STATUS) begin : genSyncStatusCdc
		uwire logic [2:0] trTeSyncReqSourceWb;
		vector_cdc2 #(.DATA_WIDTH(3)) cdc_trTeSyncReqSource (
			.d_clk  (tip_clk),
			.d_rst  (tip_rst),
			.d_data (cs_tip.trTeSyncReqSource),
			.q_clk  (wb_clk),
			.q_rst  (wb_rst),
			.q_data (trTeSyncReqSourceWb)
		);
		assign hwif_in.te.trTeSyncStatus.SyncReqSource.next = trTeSyncReqSourceWb;
	end

	// CDC for the trigger action select (wb_clk -> tip_clk, P7): quasi-static
	// 4-bit configuration (swwel-gated on trTeControl.Enable), crossed as a
	// coherent snapshot like SyncReqSource -- a half-updated action code could
	// transiently read as a DIFFERENT legal action. Without the feature the
	// value is constant 0 and the synchronizer folds away.
	if (ct_pkg::CT_EN_TRIG_REGS) begin : genTrigActCdc
		uwire logic [3:0] trTeTrigExtInAction0Wb =
			hwif_out.te.trTeTrigExtInControl.ExtInAction0.value;
		vector_cdc2 #(.DATA_WIDTH(4)) cdc_trTeTrigExtInAction0 (
			.d_clk  (wb_clk),
			.d_rst  (wb_rst),
			.d_data (trTeTrigExtInAction0Wb),
			.q_clk  (tip_clk),
			.q_rst  (tip_rst),
			.q_data (cs_tip.trTeTrigExtInAction0)
		);
	end
	else begin : genNoTrigActCdc
		assign cs_tip.trTeTrigExtInAction0 = 4'd0;
	end

	// CDC for the data-trace drop policy level (wb_clk -> tip_clk, P7): a
	// plain level synchronizer -- unlike the config fields this bit may be
	// armed while the trace runs, and a one-shot late/early arrival only
	// shifts the first suppressed message by two cycles.
	if (ct_pkg::CT_EN_DF_DROP) begin : genDfDropEnaCdc
		signal_cdc signal_cdc_trTeDataDropEna (
			.clk (tip_clk),
			.rst (tip_rst),
			.in  (hwif_out.te.trTeDataControl.DataDropEna.value),
			.out (cs_tip.trTeDataDropEna)
		);
	end
	else begin : genNoDfDropEnaCdc
		assign cs_tip.trTeDataDropEna = 1'b0;
	end

	// CDC for the two sticky-status event strobes (tip_clk -> wb_clk, P7/G12):
	// strobe_cdc turns each one-cycle tip pulse into exactly one wb pulse, so
	// the RW1C bits are set once per event and stay clear after a SW clear.
	strobe_cdc strobe_cdc_trTeInstOverflowEvent (
		.clk1 (tip_clk),
		.rst1 (tip_rst),
		.stb1 (cs_tip.trTeInstOverflowEvent),
		.clk2 (wb_clk),
		.rst2 (wb_rst),
		.stb2 (ovf_event_wb)
	);
	strobe_cdc strobe_cdc_trTeDataDropEvent (
		.clk1 (tip_clk),
		.rst1 (tip_rst),
		.stb1 (cs_tip.trTeDataDropEvent),
		.clk2 (wb_clk),
		.rst2 (wb_rst),
		.stb2 (df_drop_event_wb)
	);

	// CDC for the sync request and its acknowledgement (P8): a LEVEL each way
	// through the standard two-flop synchronizer, not a strobe pair. Both
	// levels change only once per handshake phase and the pacing keeps two
	// requests a full round trip apart, so the crossing is lossless in the
	// plain quasi-static sense -- and, unlike a toggle pair, it re-converges
	// after a reset of either domain alone: `req` up with `ack` down simply
	// means "a request is owed", whoever was reset (P8 closing audit B-N1,
	// formal target P-SYNC-12). Without the feature both levels are constant
	// 0 and the synchronizers fold away.
	if (ct_pkg::CT_EN_INST_SYNC_REQ) begin : genSyncReqCdc
		signal_cdc signal_cdc_trTeInstSyncReq (
			.clk (tip_clk),
			.rst (tip_rst),
			.in  (sync_req_lvl_wb),
			.out (cs_tip.trTeInstSyncReq)
		);
		signal_cdc signal_cdc_trTeInstSyncReqAck (
			.clk (wb_clk),
			.rst (wb_rst),
			.in  (cs_tip.trTeInstSyncReqAck),
			.out (sync_req_ack_wb)
		);
	end
	else begin : genNoSyncReqCdc
		assign cs_tip.trTeInstSyncReq = 1'b0;
		assign sync_req_ack_wb        = 1'b0;
	end
	end

	// ----------------------------------------------------------------------------------------------------
	// eTIP FIFO fill histogram (I-02, 2026-07-20): deliberately NO CDC in
	// EITHER clock arrangement -- the tip_clk counters are wired straight to
	// the wb read path and the wb-side clear level straight into tip_clk.
	// Read/clear contract: trace quiescent only (trTeControl.Enable=0);
	// reads during tracing may tear (documented in the RDL). The registers
	// exist only with CT_EN_FIFO_HIST=1 (RDL register omission, I-01 pattern).
	// ----------------------------------------------------------------------------------------------------
	if (ct_pkg::CT_EN_FIFO_HIST) begin : genFifoHist
		// SERIAL read-out (AW): one data CSR + wb-side read pointer. Each
		// trTeTipFifoHistData read (swacc pulse on the Lo field) returns the
		// bin pair [2*RdIdx, 2*RdIdx+1] and advances the pointer (wrap after
		// BINS/2). HistClear resets pointer AND counters; RdRewind
		// (singlepulse) only the pointer. The pair mux crosses tip->wb
		// combinationally -- covered by the documented quiescent-read
		// contract (no CDC by design).
		localparam int unsigned HIST_PAIRS = ct_pkg::CT_FIFO_HIST_BINS / 2;
		logic [4:0] HistRdIdx = '0;
		always_ff @(posedge wb_clk) begin
			if (wb_rst
			    || hwif_out.te.trTeTipFifoHistCtrl.HistClear.value
			    || hwif_out.te.trTeTipFifoHistCtrl.RdRewind.value) begin
				HistRdIdx <= '0;
			end
			else if (hwif_out.te.trTeTipFifoHistData.Lo.swacc) begin
				// (field is sw=r -- every software access IS a read)
				HistRdIdx <= (32'(HistRdIdx) == HIST_PAIRS - 1) ? 5'd0 : HistRdIdx + 1'b1;
			end
		end
		// Explicitly sized bin indices (XSIM 2022.1's LLVM codegen crashes
		// on a width-mismatched concat select into a 2-D packed array).
		localparam int unsigned HIST_IDXW =
			(ct_pkg::CT_FIFO_HIST_BINS <= 2) ? 1 : $clog2(ct_pkg::CT_FIFO_HIST_BINS);
		uwire logic [HIST_IDXW-1:0] hist_lo_idx = HIST_IDXW'(32'(HistRdIdx) * 2);
		uwire logic [HIST_IDXW-1:0] hist_hi_idx = HIST_IDXW'(32'(HistRdIdx) * 2 + 1);
		assign hwif_in.te.trTeTipFifoHistData.Lo.next
			= cs_tip.trTeTipFifoHist[hist_lo_idx];
		assign hwif_in.te.trTeTipFifoHistData.Hi.next
			= cs_tip.trTeTipFifoHist[hist_hi_idx];
		assign hwif_in.te.trTeTipFifoHistCtrl.RdIdx.next = HistRdIdx;
		assign cs_tip.trTeTipFifoHistClear
			= hwif_out.te.trTeTipFifoHistCtrl.HistClear.value;
	end
	else begin : genNoFifoHist
		assign cs_tip.trTeTipFifoHistClear = 1'b0;
	end

endmodule // ct_cs_cpuif_wb

`undef MY_MARK_DEBUG
`undef MY_DEBUG
`default_nettype wire
