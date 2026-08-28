// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>
 *
 * @file    cva6_trace_wrap.sv
 * @brief   CVA6 (cv32a60x) + cva6_rvfi + cva6_iti as one block.
 *
 * @details
 *   Gate C0/C2 of the CVA6-trio plan.
 *   Wraps the upstream chain  cva6 (rvfi_probes_o) -> cva6_rvfi
 *   (rvfi_to_iti_o) -> cva6_iti (iti_to_encoder_o)  following the pattern of
 *   corev_apu/src/ariane.sv + corev_apu/tb/ariane_testharness.sv (vendored
 *   pin: examples' third_party/cva6_ref, CVA6_PIN.md) and exposes:
 *
 *    - the core's AXI4 master (flat, widths from CVA6Cfg: cv32a60x uses
 *      ADDR/DATA 64/64, ID 4, USER 32) -- target on the board: PS S_AXI_HP (DDR4).
 *    - the ITI output flat (NrCommitPorts==1 is enforced via an assertion --
 *      exactly the cv32a60x config; multiple ports would need a serializer).
 *
 *   The CTTE connection (tip_if) happens OUTSIDE, in
 *   cva6_iti_to_ctte_tip -- this wrapper stays CTTE-free so it can be
 *   characterized 1:1 against upstream behavior (Gate C1).
 *
 *   CVXIF: cv32a60x has CvxifEn=1 + COPRO_EXAMPLE -- like ariane.sv, the
 *   example coprocessor is instantiated (tying it off would be wrong: the
 *   decoder reports illegal instructions via CVXIF, and commit would hang
 *   without a response).
 *
 *   NOTE ON VENDORED DEPENDENCIES: unlike the MicroBlaze V and Rocket
 *   adapters, this wrapper instantiates the upstream `cva6`, `cva6_rvfi`
 *   and `cva6_iti` modules by name -- it is the ONLY file in this adapter
 *   directory that does. Those modules are not vendored here (per the
 *   TraceEncoder consolidation plan's "do not vendor reference cores"
 *   decision); they are supplied at elaboration time from wherever the
 *   CVA6-with-ITI fork is fetched for a given build (examples/ fetch.sh
 *   pattern). This file has no self-contained unit testbench for exactly
 *   that reason -- see rtl/adapters/cva6/README.md.
 */
`include "rvfi_types.svh"
`include "cvxif_types.svh"
`include "iti_types.svh"

module cva6_trace_wrap #(
	// CVA6 names this parameter itself: `CVA6Cfg` is the identifier the
	// vendored core's own modules and config package use, and this wrapper
	// passes it straight through. ALL_CAPS here would diverge from upstream
	// for a style rule.
	// verilog_lint: waive parameter-name-style
	parameter config_pkg::cva6_cfg_t CVA6Cfg = build_config_pkg::build_config(
		cva6_config_pkg::cva6_cfg
	)
) (
	input uwire logic clk_i,
	input uwire logic rst_ni,

	input uwire logic [CVA6Cfg.VLEN-1:0] boot_addr_i,
	input uwire logic [CVA6Cfg.XLEN-1:0] hart_id_i,

	// {[1]=m-ext, [0]=m-sw} -- level-sensitive, like cva6.irq_i
	input uwire logic [1:0] irq_i,
	input uwire logic ipi_i,
	input uwire logic time_irq_i,
	input uwire logic debug_req_i,

	// --- AXI4 master (flat; target: PS S_AXI_HP / sim RAM) -------------------
	output logic [CVA6Cfg.AxiIdWidth-1:0]     m_axi_awid,
	output logic [CVA6Cfg.AxiAddrWidth-1:0]   m_axi_awaddr,
	output logic [7:0]                        m_axi_awlen,
	output logic [2:0]                        m_axi_awsize,
	output logic [1:0]                        m_axi_awburst,
	output logic                              m_axi_awlock,
	output logic [3:0]                        m_axi_awcache,
	output logic [2:0]                        m_axi_awprot,
	output logic [5:0]                        m_axi_awatop,
	output logic                              m_axi_awvalid,
	input uwire logic                              m_axi_awready,
	output logic [CVA6Cfg.AxiDataWidth-1:0]   m_axi_wdata,
	output logic [CVA6Cfg.AxiDataWidth/8-1:0] m_axi_wstrb,
	output logic                              m_axi_wlast,
	output logic                              m_axi_wvalid,
	input uwire logic                              m_axi_wready,
	input uwire logic [CVA6Cfg.AxiIdWidth-1:0]     m_axi_bid,
	input uwire logic [1:0]                        m_axi_bresp,
	input uwire logic                              m_axi_bvalid,
	output logic                              m_axi_bready,
	output logic [CVA6Cfg.AxiIdWidth-1:0]     m_axi_arid,
	output logic [CVA6Cfg.AxiAddrWidth-1:0]   m_axi_araddr,
	output logic [7:0]                        m_axi_arlen,
	output logic [2:0]                        m_axi_arsize,
	output logic [1:0]                        m_axi_arburst,
	output logic                              m_axi_arlock,
	output logic [3:0]                        m_axi_arcache,
	output logic [2:0]                        m_axi_arprot,
	output logic                              m_axi_arvalid,
	input uwire logic                              m_axi_arready,
	input uwire logic [CVA6Cfg.AxiIdWidth-1:0]     m_axi_rid,
	input uwire logic [CVA6Cfg.AxiDataWidth-1:0]   m_axi_rdata,
	input uwire logic [1:0]                        m_axi_rresp,
	input uwire logic                              m_axi_rlast,
	input uwire logic                              m_axi_rvalid,
	output logic                              m_axi_rready,

	// --- RVFI golden (flat; config_pkg::NRET==1) -- reference for C1/C3 -----
	output logic                    rvfi_valid_o,
	output logic [CVA6Cfg.XLEN-1:0] rvfi_pc_o,
	output logic [CVA6Cfg.XLEN-1:0] rvfi_pc_wdata_o,
	output logic [31:0]             rvfi_insn_o,
	output logic                    rvfi_trap_o,
	output logic [CVA6Cfg.XLEN-1:0] rvfi_cause_o,
	output logic [CVA6Cfg.XLEN-1:0] rvfi_intr_o,

	// --- ITI output (flat; NrCommitPorts==1) ------------------------------
	output logic                                iti_valid_o,
	output logic [iti_pkg::IRETIRE_LEN-1:0]     iti_iretire_o,
	output logic                                iti_ilastsize_o,
	output logic [iti_pkg::ITYPE_LEN-1:0]       iti_itype_o,
	output logic [iti_pkg::CAUSE_LEN-1:0]       iti_cause_o,
	output logic [CVA6Cfg.XLEN-1:0]             iti_tval_o,
	output logic [1:0]                          iti_priv_o,
	output logic [CVA6Cfg.XLEN-1:0]             iti_iaddr_o,
	output logic [63:0]                         iti_cycles_o,

	// --- Context (W2): the core's satp.ASID ----------------------------------
	// The ITI output itself carries NO context (rvfi_to_iti_t has no field
	// for it, neither upstream nor here). The source is the RVFI CSR shadow
	// path that cva6_rvfi builds anyway -- `satp` is already connected there
	// (core/cva6_rvfi.sv, CONNECT_RVFI_SAME(RVS, satp)), this wrapper simply
	// left the port unexposed until now. So NO delta is needed in the
	// vendored CVA6 tree.
	//
	// Width = CVA6Cfg.ASIDW, the ARCHITECTURAL field (16 for Sv39/Sv48, 9
	// for Sv32) -- not CVA6Cfg.ASID_WIDTH, which only says how many bits
	// this implementation actually stores (RV64: 16, RV32: 1). Whoever
	// traces the identifier wants to see the architectural field; the
	// unimplemented bits read back as 0 anyway.
	//
	// A wrapper that does not name the port stays unchanged: the shadow
	// flops are then dead and get optimized away -- exactly as today, where
	// rvfi_csr_o is not connected at all.
	output logic [CVA6Cfg.ASIDW-1:0]            satp_asid_o
);

	initial begin
		if (CVA6Cfg.NrCommitPorts != 1)
			$fatal(1, "cva6_trace_wrap: NrCommitPorts==1 expected (cv32a60x); the ITI flat port is otherwise invalid.");
	end

	// --- Types as in ariane_testharness.sv ---------------------------------
	localparam type rvfi_instr_t = `RVFI_INSTR_T(CVA6Cfg);
	localparam type rvfi_csr_elmt_t = `RVFI_CSR_ELMT_T(CVA6Cfg);
	localparam type rvfi_csr_t = `RVFI_CSR_T(CVA6Cfg, rvfi_csr_elmt_t);
	localparam type rvfi_to_iti_t = `RVFI_TO_ITI_T(CVA6Cfg);
	localparam type iti_to_encoder_t = `ITI_TO_ENCODER_T(CVA6Cfg);
	localparam type rvfi_probes_instr_t = `RVFI_PROBES_INSTR_T(CVA6Cfg);
	localparam type rvfi_probes_csr_t = `RVFI_PROBES_CSR_T(CVA6Cfg);
	localparam type rvfi_probes_t = struct packed {
		rvfi_probes_csr_t   csr;
		rvfi_probes_instr_t instr;
	};

	// CVXIF types (ariane.sv pattern)
	localparam type readregflags_t = `READREGFLAGS_T(CVA6Cfg);
	localparam type writeregflags_t = `WRITEREGFLAGS_T(CVA6Cfg);
	localparam type id_t = `ID_T(CVA6Cfg);
	localparam type hartid_t = `HARTID_T(CVA6Cfg);
	localparam type x_compressed_req_t = `X_COMPRESSED_REQ_T(CVA6Cfg, hartid_t);
	localparam type x_compressed_resp_t = `X_COMPRESSED_RESP_T(CVA6Cfg);
	localparam type x_issue_req_t = `X_ISSUE_REQ_T(CVA6Cfg, hartid_t, id_t);
	localparam type x_issue_resp_t = `X_ISSUE_RESP_T(CVA6Cfg, writeregflags_t, readregflags_t);
	localparam type x_register_t = `X_REGISTER_T(CVA6Cfg, hartid_t, id_t, readregflags_t);
	localparam type x_commit_t = `X_COMMIT_T(CVA6Cfg, hartid_t, id_t);
	localparam type x_result_t = `X_RESULT_T(CVA6Cfg, hartid_t, id_t, writeregflags_t);
	localparam type cvxif_req_t =
		`CVXIF_REQ_T(CVA6Cfg, x_compressed_req_t, x_issue_req_t, x_register_t, x_commit_t);
	localparam type cvxif_resp_t =
		`CVXIF_RESP_T(CVA6Cfg, x_compressed_resp_t, x_issue_resp_t, x_result_t);

	// --- Core ---------------------------------------------------------------
	rvfi_probes_t rvfi_probes;
	cvxif_req_t   cvxif_req;
	cvxif_resp_t  cvxif_resp;

	// noc_req_t/noc_resp_t stay at the cva6 parameter defaults (AXI structs
	// built self-consistently from CVA6Cfg) -- mirrored locally here only.
	typedef struct packed {
		logic [CVA6Cfg.AxiIdWidth-1:0]   id;
		logic [CVA6Cfg.AxiAddrWidth-1:0] addr;
		axi_pkg::len_t                   len;
		axi_pkg::size_t                  size;
		axi_pkg::burst_t                 burst;
		logic                            lock;
		axi_pkg::cache_t                 cache;
		axi_pkg::prot_t                  prot;
		axi_pkg::qos_t                   qos;
		axi_pkg::region_t                region;
		logic [CVA6Cfg.AxiUserWidth-1:0] user;
	} axi_ar_chan_t;
	typedef struct packed {
		logic [CVA6Cfg.AxiIdWidth-1:0]   id;
		logic [CVA6Cfg.AxiAddrWidth-1:0] addr;
		axi_pkg::len_t                   len;
		axi_pkg::size_t                  size;
		axi_pkg::burst_t                 burst;
		logic                            lock;
		axi_pkg::cache_t                 cache;
		axi_pkg::prot_t                  prot;
		axi_pkg::qos_t                   qos;
		axi_pkg::region_t                region;
		axi_pkg::atop_t                  atop;
		logic [CVA6Cfg.AxiUserWidth-1:0] user;
	} axi_aw_chan_t;
	typedef struct packed {
		logic [CVA6Cfg.AxiDataWidth-1:0]     data;
		logic [(CVA6Cfg.AxiDataWidth/8)-1:0] strb;
		logic                                last;
		logic [CVA6Cfg.AxiUserWidth-1:0]     user;
	} axi_w_chan_t;
	typedef struct packed {
		logic [CVA6Cfg.AxiIdWidth-1:0]   id;
		axi_pkg::resp_t                  resp;
		logic [CVA6Cfg.AxiUserWidth-1:0] user;
	} b_chan_t;
	typedef struct packed {
		logic [CVA6Cfg.AxiIdWidth-1:0]   id;
		logic [CVA6Cfg.AxiDataWidth-1:0] data;
		axi_pkg::resp_t                  resp;
		logic                            last;
		logic [CVA6Cfg.AxiUserWidth-1:0] user;
	} r_chan_t;
	typedef struct packed {
		axi_aw_chan_t aw;
		logic         aw_valid;
		axi_w_chan_t  w;
		logic         w_valid;
		logic         b_ready;
		axi_ar_chan_t ar;
		logic         ar_valid;
		logic         r_ready;
	} noc_req_t;
	typedef struct packed {
		logic    aw_ready;
		logic    ar_ready;
		logic    w_ready;
		logic    b_valid;
		b_chan_t b;
		logic    r_valid;
		r_chan_t r;
	} noc_resp_t;

	noc_req_t  noc_req;
	noc_resp_t noc_resp;

	cva6 #(
		.CVA6Cfg      (CVA6Cfg),
		.rvfi_probes_instr_t(rvfi_probes_instr_t),
		.rvfi_probes_csr_t  (rvfi_probes_csr_t),
		.rvfi_probes_t      (rvfi_probes_t),
		.axi_ar_chan_t(axi_ar_chan_t),
		.axi_aw_chan_t(axi_aw_chan_t),
		.axi_w_chan_t (axi_w_chan_t),
		.b_chan_t     (b_chan_t),
		.r_chan_t     (r_chan_t),
		.noc_req_t    (noc_req_t),
		.noc_resp_t   (noc_resp_t)
	) i_cva6 (
		.clk_i        (clk_i),
		.rst_ni       (rst_ni),
		.boot_addr_i  (boot_addr_i),
		.hart_id_i    (hart_id_i),
		.irq_i        (irq_i),
		.ipi_i        (ipi_i),
		.time_irq_i   (time_irq_i),
		.debug_req_i  (debug_req_i),
		.rvfi_probes_o(rvfi_probes),
		.cvxif_req_o  (cvxif_req),
		.cvxif_resp_i (cvxif_resp),
		.noc_req_o    (noc_req),
		.noc_resp_i   (noc_resp)
	);

	// CVXIF: cv32a60x has CvxifEn=1 + COPRO_EXAMPLE, but the example
	// coprocessor crashes xelab 2026.1 (EXCEPTION_ACCESS_VIOLATION in
	// VlogCompiler::transform on compressed_instr_decoder). Use the
	// ariane.sv COPRO_NONE tie-off instead: ready=1 + accept=0 -> every
	// offloaded (= not decodable) instruction comes back as an illegal
	// exception. Our software uses no custom instructions; behavior for
	// every standard instruction is identical.
	if (CVA6Cfg.CvxifEn) begin : gen_cvxif_tieoff
		assign cvxif_resp = '{compressed_ready: 1'b1, issue_ready: 1'b1,
		                      register_ready: 1'b1, default: '0};
	end else begin : gen_no_cvxif
		assign cvxif_resp = '0;
	end

	// --- AXI, flat ----------------------------------------------------------
	assign m_axi_awid    = noc_req.aw.id;
	assign m_axi_awaddr  = noc_req.aw.addr;
	assign m_axi_awlen   = noc_req.aw.len;
	assign m_axi_awsize  = noc_req.aw.size;
	assign m_axi_awburst = noc_req.aw.burst;
	assign m_axi_awlock  = noc_req.aw.lock;
	assign m_axi_awcache = noc_req.aw.cache;
	assign m_axi_awprot  = noc_req.aw.prot;
	assign m_axi_awatop  = noc_req.aw.atop;
	assign m_axi_awvalid = noc_req.aw_valid;
	assign m_axi_wdata   = noc_req.w.data;
	assign m_axi_wstrb   = noc_req.w.strb;
	assign m_axi_wlast   = noc_req.w.last;
	assign m_axi_wvalid  = noc_req.w_valid;
	assign m_axi_bready  = noc_req.b_ready;
	assign m_axi_arid    = noc_req.ar.id;
	assign m_axi_araddr  = noc_req.ar.addr;
	assign m_axi_arlen   = noc_req.ar.len;
	assign m_axi_arsize  = noc_req.ar.size;
	assign m_axi_arburst = noc_req.ar.burst;
	assign m_axi_arlock  = noc_req.ar.lock;
	assign m_axi_arcache = noc_req.ar.cache;
	assign m_axi_arprot  = noc_req.ar.prot;
	assign m_axi_arvalid = noc_req.ar_valid;
	assign m_axi_rready  = noc_req.r_ready;

	assign noc_resp.aw_ready = m_axi_awready;
	assign noc_resp.ar_ready = m_axi_arready;
	assign noc_resp.w_ready  = m_axi_wready;
	assign noc_resp.b_valid  = m_axi_bvalid;
	assign noc_resp.b.id     = m_axi_bid;
	assign noc_resp.b.resp   = m_axi_bresp;
	assign noc_resp.b.user   = '0;
	assign noc_resp.r_valid  = m_axi_rvalid;
	assign noc_resp.r.id     = m_axi_rid;
	assign noc_resp.r.data   = m_axi_rdata;
	assign noc_resp.r.resp   = m_axi_rresp;
	assign noc_resp.r.last   = m_axi_rlast;
	assign noc_resp.r.user   = '0;

	// --- RVFI -> ITI ---------------------------------------------------------
	rvfi_to_iti_t    rvfi_to_iti;
	iti_to_encoder_t iti_to_encoder;
	rvfi_instr_t     rvfi_instr;
	rvfi_csr_t       rvfi_csr;

	cva6_rvfi #(
		.CVA6Cfg            (CVA6Cfg),
		.rvfi_instr_t       (rvfi_instr_t),
		.rvfi_csr_t         (rvfi_csr_t),
		.rvfi_probes_instr_t(rvfi_probes_instr_t),
		.rvfi_probes_csr_t  (rvfi_probes_csr_t),
		.rvfi_probes_t      (rvfi_probes_t),
		.rvfi_to_iti_t      (rvfi_to_iti_t)
	) i_cva6_rvfi (
		.clk_i        (clk_i),
		.rst_ni       (rst_ni),
		.rvfi_probes_i(rvfi_probes),
		.rvfi_instr_o (rvfi_instr),
		.rvfi_to_iti_o(rvfi_to_iti),
		.rvfi_csr_o   (rvfi_csr)
	);

	// satp layout (privileged spec): RV64 {MODE[63:60], ASID[59:44],
	// PPN[43:0]}, RV32 {MODE[31], ASID[30:22], PPN[21:0]}. Without S-mode
	// the register does not exist: cva6_rvfi then leaves
	// rvfi_csr.satp.rdata UNDRIVEN (the write block sits inside
	// `if (CVA6Cfg.RVS)`), so an ungated tap here would be X -- and X on a
	// context level is a filter with an undefined hit, not just an ugly
	// waveform. Hence a generate block, not a ternary.
	if (CVA6Cfg.RVS) begin : gen_satp_asid
		// MODE is four bits wide on RV64, exactly one on RV32 -- a shared
		// formula with a literal "4" would have pointed at bit 19 instead
		// of 22 on RV32 and produced a plausible-looking, wrong ASID.
		localparam int unsigned SATP_MODE_W  = (CVA6Cfg.XLEN == 64) ? 4 : 1;
		localparam int unsigned SATP_ASID_LSB = CVA6Cfg.XLEN - SATP_MODE_W - CVA6Cfg.ASIDW;
		assign satp_asid_o = rvfi_csr.satp.rdata[SATP_ASID_LSB +: CVA6Cfg.ASIDW];
	end else begin : gen_no_satp_asid
		assign satp_asid_o = '0;
	end

	assign rvfi_valid_o    = rvfi_instr.valid;
	assign rvfi_pc_o       = rvfi_instr.pc_rdata;
	assign rvfi_pc_wdata_o = rvfi_instr.pc_wdata;
	assign rvfi_insn_o     = rvfi_instr.insn;
	assign rvfi_trap_o     = rvfi_instr.trap;
	assign rvfi_cause_o    = rvfi_instr.cause;
	assign rvfi_intr_o     = rvfi_instr.intr;

	cva6_iti #(
		.CVA6Cfg         (CVA6Cfg),
		.CAUSE_LEN       (iti_pkg::CAUSE_LEN),
		.ITYPE_LEN       (iti_pkg::ITYPE_LEN),
		.IRETIRE_LEN     (iti_pkg::IRETIRE_LEN),
		.block_mode      (0),
		.rvfi_to_iti_t   (rvfi_to_iti_t),
		.iti_to_encoder_t(iti_to_encoder_t)
	) i_cva6_iti (
		.clk_i           (clk_i),
		.rst_ni          (rst_ni),
		.valid_i         (rvfi_to_iti.valid),
		.rvfi_to_iti_i   (rvfi_to_iti),
		.valid_o         (),
		.iti_to_encoder_o(iti_to_encoder)
	);

	assign iti_valid_o     = iti_to_encoder.valid[0];
	assign iti_iretire_o   = iti_to_encoder.iretire[0];
	assign iti_ilastsize_o = iti_to_encoder.ilastsize[0];
	assign iti_itype_o     = iti_to_encoder.itype[0];
	assign iti_cause_o     = iti_to_encoder.cause;
	assign iti_tval_o      = iti_to_encoder.tval;
	assign iti_priv_o      = iti_to_encoder.priv;
	assign iti_iaddr_o     = iti_to_encoder.iaddr[0];
	assign iti_cycles_o    = iti_to_encoder.cycles;

endmodule

`default_nettype wire
