// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
 *
 * @brief    CEDARtools.TraceEncoder RISC-V trace encoder top level (N-Trace and/or E-Trace).
 *
 * @details
 *   Consumes the core's Trace Ingress Port (TIP/ITI) and emits a compressed
 *   trace stream on ATB, plus an uncompressed AXI-Stream event path for
 *   on-chip processing.
 *
 *   Two output protocols are implemented; which of them is built is a
 *   synthesis choice via the EN_NTRACE / EN_ETRACE parameters (defaulting
 *   to ct_pkg::CT_EN_NTRACE / CT_EN_ETRACE). EXACTLY ONE of them must be
 *   set:
 *
 *     - N-Trace  : Nexus messages per the RISC-V N-Trace specification
 *                  (https://github.com/riscv-non-isa/tg-nexus-trace),
 *                  produced by ct_L2_msg_gen and serialized onto ATB either
 *                  by ct_L2_nexus_formatter + ct_L2_mseo_mdo_formatter or,
 *                  in CF-only profiles, by ct_L2_compact_packer.
 *     - E-Trace  : te_inst packets per the RISC-V Efficient Trace (E-Trace)
 *                  specification, produced by ct_L2_te_inst_gen and framed
 *                  onto ATB by ct_L2_te_packetizer.
 *
 *   The protocol is not runtime-switchable: the back end is picked by a
 *   generate, and trTeProtocolSel.Protocol / trTeImpl.ProtocolMajor are
 *   hardware-driven read-only discovery mirrors of that parameter. Because
 *   the choice is per INSTANCE, a multi-encoder SoC builds one encoder as
 *   N-Trace and the next as E-Trace from the same sources; `atb_te_raw`
 *   advertises this instance's framing to a downstream funnel/sink.
 *
 *   Everything upstream of the back end is protocol-agnostic: the layer-2/3
 *   preprocessor (ct_L23_preproc) turns TIP beats into the internal eTIP
 *   event stream that both generators consume.
 *
 *   The control/status register layout accessed via the Wishbone port is
 *   defined in rdl/ct_cs_cpuif.rdl.
 *
 *   The module spans five clock domains (tip_clk, proc_clk, atb_atclk,
 *   wb_clk, wall_clk), crossed internally by CDC logic.
 */

module ct_encoder #(
	// Select split-load data trace path.
	// 0 = legacy dretire-combined mode (tip.data at retirement)
	// 1 = split-load mode (tip.sdata for STOREs; tip.lresp/ldata for LOADs)
	bit SPLIT_DATA_ACCESS = 0,
	// Core integration attribute: the attached core's ingress uses the
	// sequentially-implicit-jump convention (decoder PCInfo must carry
	// -sijump). Advertised as config-message CAPS.6 only; MBV adapter: 1.
	bit CT_SIJUMP         = 0,
	// Device ID (TCODE 1, P4) of THIS encoder instance -- a per-instance
	// integration attribute like CT_SIJUMP, so a multi-encoder SoC gives
	// every encoder its own identity. Layout per IEEE-ISTO 5001 Table B-5
	// (RN | PN | MID). The default 0 means "no device ID assigned"; nothing
	// reaches the wire until software sets trTeControl.SendDeviceId
	// (reset DID_NONE), and the value is only sampled at the emission site.
	logic [nexus_vendor::NEXUS_MSG_DEVID_WIDTH-1:0] CT_DEVICE_ID = '0,
	// Per-INSTANCE back-end selection (synthesis parameter). Defaults to the
	// build profile, so an unparameterised instantiation behaves exactly as
	// the profile prescribes; a multi-encoder SoC overrides them per
	// instance (one N-Trace encoder next to an E-Trace one out of the same
	// netlist sources). EXACTLY ONE of the two must be set -- elaboration
	// guard below; the historical dual build with a runtime protocol select
	// is retired (AW directive 2026-08-04).
	bit EN_ETRACE         = ct_pkg::CT_EN_ETRACE,
	bit EN_NTRACE         = ct_pkg::CT_EN_NTRACE,
	// Core integration attribute (P0-07): the architectural address width
	// (RISC-V XLEN) of the hart THIS instance's TIP is wired to. It is not a
	// knob of this netlist -- the netlist's own width is ct_pkg::CT_XLEN --
	// it is the integrator's DECLARATION of what the adapter feeds in, and
	// the guard below refuses to build when the two disagree.
	//
	// It has to be declared because nothing else can see the mismatch:
	// tip_if is a parameterless interface whose iaddr/daddr/tval are sized
	// by ct_pkg::CT_XLEN, so an adapter that drives a 64-bit PC into a
	// 32-bit netlist has its upper address bits truncated by SystemVerilog's
	// silent width adaptation BEFORE the encoder sees anything. Inside the
	// encoder those bits never existed; no assertion, no capture and no
	// decoder downstream can miss them. The declaration is the only place
	// where both widths are known at once.
	//
	// The default is 0 = UNDECLARED and is itself an elaboration error. A
	// default of ct_pkg::CT_XLEN would always match and would therefore be
	// no gate at all: an integrator who says nothing would keep exactly the
	// silent truncation this parameter exists to stop.
	int unsigned CORE_XLEN = 0
) (
	// TIP (Trace Ingress Port; CPU-side trace input)
	input uwire logic tip_clk,
	input uwire logic tip_rst,
	tip_if.slave      tip,

	// Wishbone (CSR access) + CSR shim reset
	input uwire logic wb_clk,
	input uwire logic wb_rst,
	wb_if.slave       wb,
	input uwire logic ct_cs_rst,

	// AXIS
	axis_if.master    axis,

	// ATB (Nexus trace output)
	input uwire logic atb_atclk,
	input uwire logic atb_atresetn,
	atb_if.master     atb,
	// Framing of the ATB stream this instance produces, in the ATB clock
	// domain: 0 = Nexus MSEO/MDO chunks (N-Trace), 1 = E-Trace
	// reference-raw te_inst bytes. Constant per instance (= EN_ETRACE) and
	// the same truth trTeProtocolSel reports to software, so a downstream
	// funnel/sink parses the framing the netlist actually produces instead
	// of a second, software-programmed copy.
	output uwire logic atb_te_raw,

	// Processing clock (internal pipeline)
	input uwire logic proc_clk,
	input uwire logic proc_rst,

	// Wall clock (free-running timestamp reference)
	input uwire logic wall_clk,
	input uwire logic wall_clk_rst
);

	import nexus_vendor::*;
	import nexus::*;
	import tip_pkg::*;
	import ct_etip_pkg::*;
	import ct_pkg::*;

	// ------------------------------------------------------------------
	// Global cross-stage interfaces and signals
	// ------------------------------------------------------------------
	// CSR interfaces driven by ct_cs_cpuif_wb, consumed by every stage.
	ct_cs_tipclk_if  cs_tip ();
	ct_cs_procclk_if cs_proc();
	ct_cs_atbclk_if  cs_atb ();
	ct_cs_decclk_if  cs_dec ();

	// Framing advertisement (see port comment): a compile-time constant of
	// the selected back end -- no runtime select exists.
	assign atb_te_raw = EN_ETRACE;

	// Reverse-flow signals (driver is downstream of the consumer, so they
	// live up here rather than next to their drivers). The N-Trace-only
	// backpressure nets live inside genNtrace instead.
	//   - synq_req_trace_byte_count / synq_req_trace_msg_count: egress
	//     module -> preproc, held trace-quota overflow levels (P2)
	//   - quota_cnt_clr: preproc (sync generator) -> egress quota
	//     counters, crossed SyncCntClr rearm (proc_clk domain)
	uwire logic synq_req_trace_byte_count;
	uwire logic synq_req_trace_msg_count;
	uwire logic quota_cnt_clr;

	// ------------------------------------------------------------------
	// CSR shim (Wishbone -> cs_*/wext interfaces)
	// ------------------------------------------------------------------
	ocram_write_if #(.A_BITS(M0_STAGES), .T(m0_kr_t)) act_st_wext   (wb_clk);
	ocram_write_if #(.A_BITS(M1_STAGES), .T(m1_kr_t)) df_range_wext (wb_clk);

	ct_cs_cpuif_wb #(.EN_ETRACE(EN_ETRACE)) ct_cs_cpuif_wb_inst (
		.wb_clk,   .wb_rst,   .wb,
		.ct_cs_rst,
		.tip_clk,  .tip_rst,
		.proc_clk, .proc_rst,
		.cs_tip,
		.act_st_wext,
		.df_range_wext,
		.cs_proc,  .cs_atb,   .cs_dec
	);

	// ------------------------------------------------------------------
	// Preprocessor (drives etip_q, next_iaddr_q, internal_delay_preproc)
	// ------------------------------------------------------------------
	source_if #(.T(etip_msg_struct_t), .STOP_ON_UNDERRUN(1)) etip_q       (.clk(proc_clk), .rst(proc_rst));
	source_if #(.T(ct_etip_pkg::etip_next_iaddr_t), .STOP_ON_UNDERRUN(1)) next_iaddr_q (.clk(proc_clk), .rst(proc_rst));

	// Every stage inside the preprocessor reports its own pipeline latency
	// upwards (`internal_delay`), so a later stage can align against the ones
	// before it; ct_L23_preproc aggregates them into this one number. At THIS
	// level there is nothing left to align against, and no CSR exposes the
	// value -- so the aggregate deliberately ends here. Kept as a named net
	// rather than left unconnected: it is what a waveform is read against
	// when a latency question comes up.
	delay_t internal_delay_preproc; // read by nobody, on purpose (see above)

	ct_L23_preproc #(.SPLIT_DATA_ACCESS(SPLIT_DATA_ACCESS))
	preproc_inst (
		.tip_clk,   .tip_rst,      .tip,
		.wall_clk,  .wall_clk_rst,
		.proc_clk,  .proc_rst,
		.axis,
		.etip_q,
		.next_iaddr_q,
		.atb_afvalid (atb.afvalid),
		.atb_syncreq (atb.syncreq),
		.synq_req_trace_byte_count,
		.synq_req_trace_msg_count,
		.quota_cnt_clr,
		.cs_tip,
		.wext_clk       (wb_clk),
		.act_st_wext,
		.df_range_wext,
		.internal_delay (internal_delay_preproc)
	);

	// ------------------------------------------------------------------
	// L2 backend (generate-select on the EN_ETRACE/EN_NTRACE parameters):
	//   EN_ETRACE: E-Trace backend -- te_inst generator + packetizer consume
	//      the eTIP stream directly; the ATB byte stream carries
	//      reference-raw framed te_inst packets (see ct_L2_te_packetizer).
	//   EN_NTRACE: N-Trace backend (msg_gen + formatter/packer).
	//
	// Elaboration guard: exactly one back end per instance (same
	// elaboration-$fatal pattern as the formatter's profile guards). Dual
	// builds with a runtime protocol select were retired -- the protocol is
	// a synthesis parameter, chosen per instance.
	// ------------------------------------------------------------------
	if (!EN_ETRACE && !EN_NTRACE) begin : genNoBackend
		$fatal(1, "ct_encoder: exactly one of EN_NTRACE/EN_ETRACE must be set (both are 0)");
	end
	if (EN_ETRACE && EN_NTRACE) begin : genDualBackend
		$fatal(1, "ct_encoder: exactly one of EN_NTRACE/EN_ETRACE must be set (dual protocol builds are retired -- select the protocol per instance)");
	end

	// Netlist-master guard: the eTIP sideband fields (privilege, ecause,
	// tval, last-instruction size) are sized by ct_pkg::CT_EN_ETRACE
	// (ct_etip_pkg ETIP_PRIV_W / ETIP_TRAP_EC_W / ETIP_TRAP_TVAL_W /
	// ETIP_ILS_W) -- a PACKAGE cannot be parameterised per instance, so
	// ct_pkg stays the netlist master for the widths while the parameter
	// picks the back end per instance. Without this check an E-Trace
	// instance in a netlist built with CT_EN_ETRACE=0 would elaborate
	// cleanly and then emit te_inst format 3.x messages built from 1-bit
	// stubs (truncated priv/ecause/tval) -- a SILENTLY wrong stream. The
	// mixed/Trio case therefore needs CT_EN_ETRACE=1 in ct_pkg even if only
	// one of the instances speaks E-Trace.
	//
	// No mirror guard for EN_NTRACE without ct_pkg::CT_EN_NTRACE: that
	// switch sizes nothing (it is only this parameter's default; grep
	// CT_EN_NTRACE -- ct_pkg declaration, this default, profile scripts).
	// An N-Trace instance is complete in any netlist, which is exactly what
	// the mixed build needs: tests/instruction/24_protocol_param runs in
	// the E-Trace profile (CT_EN_ETRACE=1, CT_EN_NTRACE=0) and its N-Trace
	// instance is correct there.
	if (EN_ETRACE && !ct_pkg::CT_EN_ETRACE) begin : genEtraceNoSideband
		$fatal(1, "ct_encoder: EN_ETRACE=1 requires ct_pkg::CT_EN_ETRACE=1 -- the eTIP sideband fields (priv/ecause/tval/ilastsize) are 1-bit stubs otherwise and te_inst format 3.x would carry truncated values");
	end

	// Address width (X2a): only the two architectural RISC-V values are
	// implemented. Anything else would elaborate -- every width below is an
	// expression over CT_XLEN -- and produce a stream no decoder can read
	// (the on-wire ADDR64 capability bit is a BOOLEAN; there is no place to
	// advertise "43 bits"). Rejecting it here is cheaper than discovering it
	// in a capture.
	if ((ct_pkg::CT_XLEN != 32) && (ct_pkg::CT_XLEN != 64)) begin : genBadXlen
		$fatal(1, "ct_encoder: ct_pkg::CT_XLEN must be 32 or 64 -- the config message advertises the width as the single CAPS bit 23 (ADDR64), so no other value can be described on-wire");
	end

	// Core/encoder width agreement (P0-07). The two widths that have to
	// match are known at DIFFERENT places and only meet at the
	// instantiation: this netlist's is ct_pkg::CT_XLEN, the attached hart's
	// is whatever the adapter drives. Once they disagree the loss is
	// unobservable everywhere downstream -- the adapter's assignment to the
	// narrower tip_if.iaddr drops the upper bits without a warning, the
	// encoder emits a well-formed stream of plausible low addresses, the
	// config message honestly advertises ADDR64 = 0, and the decoder
	// reconstructs exactly what it was given. There is no capture, no
	// assertion and no decoder check that can recover the difference, which
	// is why this is an elaboration guard and not a runtime one: the only
	// moment at which the mismatch is still visible is BEFORE the build.
	//
	// The undeclared case is rejected as well. It is the common one: an
	// integrator who never thought about the width is exactly the one whose
	// adapter truncates, so treating "said nothing" as "agrees" would let
	// the default carry the failure.
	// Both legs carry the guard TWICE, and the duplication is the point.
	//
	//   * the bare `$fatal` is the elaboration system task (IEEE 1800
	//     §20.11). It is what makes the wrong netlist non-existent: Vivado
	//     xelab and synthesis stop on it, before anything is built.
	//   * the `initial $fatal` twin stops the SIMULATION at time 0, before
	//     the first TIP beat and therefore before the first captured byte.
	//
	// The twin is not belt-and-braces, it closes a real hole: the repo's
	// simulation backend runs Verilator through abc-flow, and abc-flow
	// passes `-Wno-fatal` (abc/_abcflow/verilator.py). Under that flag an
	// elaboration `$fatal` is demoted to a warning and the run CONTINUES --
	// measured 2026-08-12 on this guard: the message was printed and the
	// testbench then traced 15 ATB transfers out of a declared 64-bit hart
	// on a 32-bit ingress. A guard that only prints is exactly the state
	// this work package exists to end, so the refusal must not depend on
	// the caller's warning flags.
	if (CORE_XLEN == 0) begin : genCoreXlenUndeclared
		$fatal(1, "ct_encoder: parameter CORE_XLEN is 0 (undeclared) -- state the XLEN of the hart this instance is wired to, e.g. ct_encoder #(.CORE_XLEN(64)). The build cannot infer it: tip_if.iaddr is sized by this netlist (%0d bit) and a wider core is truncated by the adapter before the encoder sees it", ct_pkg::CT_XLEN);
		initial $fatal(1, "ct_encoder: parameter CORE_XLEN is 0 (undeclared) -- state the XLEN of the hart this instance is wired to, e.g. ct_encoder #(.CORE_XLEN(64)). The build cannot infer it: tip_if.iaddr is sized by this netlist (%0d bit) and a wider core is truncated by the adapter before the encoder sees it", ct_pkg::CT_XLEN);
	end
	if ((CORE_XLEN != 0) && (CORE_XLEN != ct_pkg::CT_XLEN)) begin : genCoreXlenMismatch
		$fatal(1, "ct_encoder: CORE_XLEN=%0d does not match this netlist's trace ingress width of %0d bit -- a %0d-bit hart on a %0d-bit ingress loses its upper address bits in the adapter, silently and with no downstream symptom (the stream stays well-formed and advertises the netlist's own width in CAPS bit 23). Rebuild the encoder with ct_pkg::CT_XLEN = %0d, or attach a %0d-bit hart", CORE_XLEN, ct_pkg::CT_XLEN, CORE_XLEN, ct_pkg::CT_XLEN, CORE_XLEN, ct_pkg::CT_XLEN);
		initial $fatal(1, "ct_encoder: CORE_XLEN=%0d does not match this netlist's trace ingress width of %0d bit -- a %0d-bit hart on a %0d-bit ingress loses its upper address bits in the adapter, silently and with no downstream symptom (the stream stays well-formed and advertises the netlist's own width in CAPS bit 23). Rebuild the encoder with ct_pkg::CT_XLEN = %0d, or attach a %0d-bit hart", CORE_XLEN, ct_pkg::CT_XLEN, CORE_XLEN, ct_pkg::CT_XLEN, CORE_XLEN, ct_pkg::CT_XLEN);
	end

	// Context width (W2): the Ownership message carries tip._context in the
	// 44-bit PROCESS field of nexus_process_t. A wider context bus would be
	// truncated by that cast WITHOUT a warning -- the resulting stream looks
	// perfectly well-formed and names the wrong process, which is the most
	// expensive failure mode this feature has. Zero is equally rejected: a
	// 0-bit bus makes every width expression below degenerate and the
	// Ownership FORMAT=2 arm meaningless.
	if ((ct_pkg::CT_CONTEXT_WIDTH < 1)
	 || (ct_pkg::CT_CONTEXT_WIDTH > nexus_vendor::NEXUS_MSG_PROCESS_WIDTH)) begin : genBadCtxWidth
		$fatal(1, "ct_encoder: ct_pkg::CT_CONTEXT_WIDTH must be 1..%0d -- the Ownership PROCESS field is that wide and a wider context bus would be truncated silently", nexus_vendor::NEXUS_MSG_PROCESS_WIDTH);
	end

	// Block ingress width (R1.3 / gap X1). Two independent bounds, both
	// silent failures if unchecked:
	//
	//  * lower: a block ingress with a 1-bit iretire is the SR ingress with
	//    extra machinery -- every derivation in tip_pkg would still be
	//    correct, but the port could never report more than one halfword,
	//    i.e. not even one 32-bit instruction. That is not a configuration,
	//    it is a mistake.
	//  * upper: the composer's ICNT pre-drain fires at
	//    2^NEXUS_MSG_I_CNT_WIDTH and then restarts the accumulator AT this
	//    beat's halfwords. A beat that alone reaches the threshold leaves
	//    the accumulator above it, and msg_gen's
	//    cf_indirect_hist_overflow_hold re-fires for ever. The bound is
	//    therefore a HARD contract, not a tuning preference: an adapter
	//    whose core emits longer linear runs (CVA6's ITI accumulates
	//    unbounded, IRETIRE_LEN = 32) splits them into several
	//    itype = OTHER blocks, which cost nothing on the wire.
	if (ct_pkg::CT_EN_BLOCK_TIP
	 && ((ct_pkg::CT_IRETIRE_WIDTH < 2)
	  || (ct_pkg::CT_IRETIRE_WIDTH > nexus_vendor::NEXUS_MSG_I_CNT_WIDTH))) begin : genBadIretireWidth
		$fatal(1, "ct_encoder: ct_pkg::CT_IRETIRE_WIDTH must be 2..%0d when CT_EN_BLOCK_TIP=1 -- a wider bus lets ONE beat reach the ICNT pre-drain threshold, which wedges the indirect-branch history hold", nexus_vendor::NEXUS_MSG_I_CNT_WIDTH);
	end

	// The E-Trace back end has its OWN address plumbing (ct_L2_te_inst_gen
	// packs differential addresses at fixed bit positions derived from
	// CT_ETRACE_ADDR_BITS = 31, and tools/etrace/etrace_common.py mirrors
	// exactly those positions). X2a widened the N-Trace path only; a
	// 64-bit E-Trace build is X2b. Without this guard such a build would
	// elaborate and emit te_inst packets whose addresses are silently
	// truncated to 31 bits -- the class of failure the E-Trace sideband
	// guard above exists to prevent, one field further down.
	if (EN_ETRACE && ct_pkg::CT_ADDR64) begin : genEtrace64
		$fatal(1, "ct_encoder: EN_ETRACE=1 with ct_pkg::CT_XLEN=64 is not implemented (X2b) -- te_inst address fields are sized by CT_ETRACE_ADDR_BITS=31 and would truncate silently");
	end

	if (EN_ETRACE) begin : genEtrace
		uwire logic [ct_pkg::CT_ETRACE_PKT_MAX_BITS-1:0] te_pkt_payload;
		uwire logic [7:0] te_pkt_nbits;
		uwire logic [1:0] te_pkt_mtype;
		uwire logic       te_pkt_valid;
		uwire logic       te_pkt_ready;
		uwire logic       te_gen_idle;

		ct_L2_te_inst_gen te_inst_gen_inst (
			.proc_clk, .proc_rst,
			.cs_proc,
			.etip_q,
			.next_iaddr_q,
			.pkt_payload (te_pkt_payload),
			.pkt_nbits   (te_pkt_nbits),
			.pkt_mtype   (te_pkt_mtype),
			.pkt_valid   (te_pkt_valid),
			.pkt_ready   (te_pkt_ready),
			.gen_idle    (te_gen_idle)
		);

		ct_L2_te_packetizer te_packetizer_inst (
			.proc_clk,   .proc_rst,
			.pkt_payload (te_pkt_payload),
			.pkt_nbits   (te_pkt_nbits),
			.pkt_mtype   (te_pkt_mtype),
			.pkt_valid   (te_pkt_valid),
			.pkt_ready   (te_pkt_ready),
			.atb_atclk,  .atb_atresetn,  .atb,
			.cs_atb,     .cs_proc,
			// P2/D9: the E-Trace backend carries the quota levels itself
			// (parity with the N-Trace egress -- the former genEtrace
			// tie-off is gone).
			.synq_req_trace_byte_count,
			.synq_req_trace_msg_count,
			.quota_cnt_clr,
			// trTeControl.Empty chain: the upstream term covers the
			// preprocessor's CDC FIFOs plus whatever te_inst_gen still holds
			// back; the ATB tail module appends its own stages and produces
			// the ATB-domain verdict.
			.upstream_empty (!etip_q.valid && !next_iaddr_q.valid && te_gen_idle),
			.chain_empty    (cs_atb.trTeEmpty)
		);
	end
	else begin : genNtrace

	// ------------------------------------------------------------------
	// Message generator (drives trace_msg)
	// ------------------------------------------------------------------
	uwire nexus_msg_struct_t trace_msg;
	// Backpressure nets of the N-Trace chain (driver is downstream of the
	// consumer, so they live at the top of this arm):
	//   - nexus_formatter_ready:    formatter/packer   -> msg_gen
	//   - mseo_mdo_formatter_ready: mseo_mdo_formatter -> nexus_formatter
	uwire logic nexus_formatter_ready;
	uwire logic mseo_mdo_formatter_ready;
	// trTeControl.Empty chain -- see genEtrace.
	uwire logic msg_gen_idle;
	uwire logic upstream_empty_n = !etip_q.valid && !next_iaddr_q.valid && msg_gen_idle;

	ct_L2_msg_gen msg_gen_inst (
		.proc_clk, .proc_rst,
		.ready_in (nexus_formatter_ready),
		.cs_proc,
		.etip_q,
		.next_iaddr_q,
		.trace_msg,
		.msg_gen_idle
	);

	// ------------------------------------------------------------------
	// Message formatting backend (generate-select, ct_pkg::CT_COMPACT_PACKER):
	//   0 (historical): nexus_formatter (10-field array) -> MSEO/MDO
	//     formatter (message buffer + barrel bit slicer + chunk packer)
	//   1 (compact, CF-only profiles): single-module packer producing the
	//     MDO/MSEO chunks directly from a per-TCODE layout table
	//     (single-module packer pattern); byte-identical wire stream.
	// ------------------------------------------------------------------
	if (CT_COMPACT_PACKER) begin : genCompactPacker
		ct_L2_compact_packer #(
			.MDO_WIDTH (NEXUS_MDO_WIDTH),
			.CT_SIJUMP (CT_SIJUMP),
			.CT_DEVICE_ID (CT_DEVICE_ID)
		) compact_packer_inst (
			.proc_clk,   .proc_rst,
			.atb_atclk,  .atb_atresetn,  .atb,
			.trace_msg,  // generic trace msg input (from msg_gen)
			.cs_proc,    .cs_atb,
			.synq_req_trace_byte_count,
			.synq_req_trace_msg_count,
			.quota_cnt_clr,
			.ready_out (nexus_formatter_ready),
			.upstream_empty (upstream_empty_n),
			.chain_empty    (cs_atb.trTeEmpty)
		);

		// mseo_mdo_formatter_ready exists only for the historical chain.
		assign mseo_mdo_formatter_ready = 1'b0;
	end
	else begin : genNexusFormat
		// ------------------------------------------------------------------
		// Nexus formatter (drives nexus_msg; nexus_formatter_ready declared above)
		// ------------------------------------------------------------------
		uwire nexus_message_t nexus_msg;

		ct_L2_nexus_formatter #(
			.CT_SIJUMP (CT_SIJUMP),
			.CT_DEVICE_ID (CT_DEVICE_ID)
		) nexus_formatter_inst (
			.proc_clk, .proc_rst,
			.ready_in  (mseo_mdo_formatter_ready),
			.ready_out (nexus_formatter_ready),
			.cs_proc,
			.trace_msg,  // generic trace msg input
			.nexus_msg   // nexus msg output
		);

		// ------------------------------------------------------------------
		// MSEO/MDO formatter
		//   - drives mseo_mdo_formatter_ready + synq_req_trace_byte_count (declared above)
		// ------------------------------------------------------------------
		ct_L2_mseo_mdo_formatter #(
			.NEXUS_MAX_FIELDS           (NEXUS_MAX_FIELDS),
			.NEXUS_MAX_FIELD_DATA_WIDTH (NEXUS_MAX_FIELD_DATA_WIDTH),
			.MDO_WIDTH                  (NEXUS_MDO_WIDTH)
		) ct_L2_mseo_mdo_formatter_inst (
			.proc_clk,   .proc_rst,
			.nexus_msg,
			.atb_atclk,  .atb_atresetn,  .atb,
			.cs_proc,    .cs_atb,
			.synq_req_trace_byte_count,
			.synq_req_trace_msg_count,
			.quota_cnt_clr,
			.ready_out (mseo_mdo_formatter_ready),
			.upstream_empty (upstream_empty_n),
			.chain_empty    (cs_atb.trTeEmpty)
		);
	end

	end // genNtrace

endmodule // ct_encoder

`default_nettype wire
