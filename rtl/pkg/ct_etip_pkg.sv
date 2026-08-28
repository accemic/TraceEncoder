// SPDX-FileCopyrightText: 2023 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
 *
 * @brief    CEDARtools.TraceEncoder internal "Extended TIP" (Trace Ingress Port) definitions
 */

package ct_etip_pkg;

	import nexus::*;
	import nexus_vendor::*;
	import tip_pkg::*;
	import ct_pkg::*;

	// Internal etip_cf icnt is the cumulated halfword count between two
	// CF eTIPs from the composer. It is NOT the wire ICNT field. Long
	// spans of OTHER instructions (e.g. CSR_WRITE-heavy bodies) can push
	// the cumulated count well past nexus_icnt_t's 8-bit range before
	// the next CF event arrives; truncating here would silently drop
	// halfwords. msg_gen's CurrICnt + ICNT_OVERFLOW path (RCODE=0,
	// rdata is nexus_rdata_t = 30 b) handles arbitrary cumulated counts,
	// so size the internal field to match.
	typedef logic [NEXUS_MSG_RDATA_WIDTH-1:0] etip_icnt_t;

	// Internal timestamp rides every eTIP FIFO entry -- width is the
	// CT_TS_WIDTH build knob (the TIP-side tip_time_t stays 64 bit; the
	// composer truncates on capture).
	typedef logic [ct_pkg::CT_TS_WIDTH-1:0] etip_ts_t;

	// Profile-dependent payload widths: variants of compiled-out feature
	// groups shrink to 1 bit so they stop driving the packed-union width
	// (the DAQ variant is 224 bit -- without this, a control-flow-only
	// profile would still pay it in every FIFO entry). The matching
	// composer arms are hard-gated by the same switches.
	localparam int ETIP_DF_DATA_W  = ct_pkg::CT_EN_DATA_TRACE ? $bits(tip_data_t) : 1;
	localparam int ETIP_DF_ADDR_W  = ct_pkg::CT_EN_DATA_TRACE ? $bits(nexus_addr_t) : 1;
	localparam int ETIP_DAQ_ELEM_W = (ct_pkg::CT_EN_DAQ || ct_pkg::CT_EN_ACT) ? $bits(tip_xaddr_data_t) : 1;
	localparam int ETIP_DAQ_ADDR_W = (ct_pkg::CT_EN_DAQ || ct_pkg::CT_EN_ACT) ? $bits(nexus_addr_t) : 1;

	localparam ETIP_CF_MSG_NET_LEN     =   $bits(nexus_sync_reason_e)
										 + $bits(nexus_btype_e)
										 + $bits(nexus_rcode_e)
										 + $bits(tip_itype_e)
										 + $bits(tip_iaddr_t)
										 + $bits(etip_icnt_t)
										 + ETIP_TRAP_EC_W
										 + ETIP_TRAP_TVAL_W
										 + ETIP_PRIV_W
										 + ETIP_ILS_W;

	localparam ETIP_DF_MSG_NET_LEN     =   ETIP_DF_DATA_W
										 + $bits(tip_dtype_e)
										 + $bits(nexus_dsz_e)
										 + $bits(nexus_elsz_e)
										 + ETIP_DF_ADDR_W;

	localparam ETIP_DAQ_MSG_NET_LEN    =   ETIP_DAQ_ELEM_W * MAX_DAQ_DATA_ELEMENTS
										 + ETIP_DAQ_ADDR_W;

	// Ownership payload: the PROCESS content rides the OTHER
	// variant; without the feature it shrinks to 1 bit (union stays slim).
	localparam int ETIP_OWN_PROC_W     = ct_pkg::CT_EN_OWNERSHIP
	                                   ? $bits(nexus_process_t) : 1;
	// Watchpoint payload (P4, TCODE 15): WPHIT rides the SAME generic OTHER
	// payload slot as the Ownership PROCESS -- the two are mutually
	// exclusive per message, so the slot is sized by the WIDEST user
	// instead of getting a field of its own (a separate field would cost
	// its width in EVERY eTIP FIFO entry, P times per slot, also in
	// profiles that never emit a watchpoint).
	localparam int ETIP_WPHIT_W        = ct_pkg::CT_EN_WATCHPOINT_MSG
	                                   ? NEXUS_MSG_WPHIT_IMPL_WIDTH : 1;
	localparam int ETIP_OTHER_PAYLOAD_W = (ETIP_OWN_PROC_W > ETIP_WPHIT_W)
	                                    ? ETIP_OWN_PROC_W : ETIP_WPHIT_W;

	// E-Trace sideband (2026-07-24): te_inst format 3.0/3.1 carry privilege,
	// ecause and tval, and the retirement tracking needs the last retired
	// instruction's size -- none of which the N-Trace path uses, so the
	// fields shrink to 1 bit each without CT_EN_ETRACE (4 dead bits in the
	// CF variant; no union growth in the DF/DAQ-dominated full profile).
	localparam int ETIP_TRAP_EC_W   = ct_pkg::CT_EN_ETRACE ? $bits(tip_pkg::tip_ecause_e)   : 1;
	localparam int ETIP_TRAP_TVAL_W = ct_pkg::CT_EN_ETRACE ? $bits(tip_pkg::tip_iaddr_t)    : 1;
	localparam int ETIP_PRIV_W      = ct_pkg::CT_EN_ETRACE ? $bits(tip_pkg::tip_priv_t)     : 1;
	localparam int ETIP_ILS_W       = ct_pkg::CT_EN_ETRACE ? $bits(tip_pkg::tip_ilastsize_t) : 1;

	localparam ETIP_OTHER_MSG_NET_LEN  =   $bits(nexus_tcode_e)
										 + $bits(nexus_etype_e)
										 + $bits(nexus_vendor_ecode_t)
										 + ETIP_OTHER_PAYLOAD_W;

	localparam int ETIP_MAX_MSG_NET_LEN     = (ETIP_CF_MSG_NET_LEN > ETIP_DF_MSG_NET_LEN) ?
											  ((ETIP_CF_MSG_NET_LEN > ETIP_DAQ_MSG_NET_LEN) ? ETIP_CF_MSG_NET_LEN : ETIP_DAQ_MSG_NET_LEN) :
											  ((ETIP_DF_MSG_NET_LEN > ETIP_DAQ_MSG_NET_LEN) ? ETIP_DF_MSG_NET_LEN : ETIP_DAQ_MSG_NET_LEN);
	localparam int ETIP_MAX_MSG_NET_LEN_ALL = (ETIP_MAX_MSG_NET_LEN > ETIP_OTHER_MSG_NET_LEN)
											  ? ETIP_MAX_MSG_NET_LEN : ETIP_OTHER_MSG_NET_LEN;

	// +1 keeps every variant's _pad width >= 1, so the [N-1:0] vector is
	// always well-formed (Vivado treats [-1:0] inconsistently). All variants
	// land at ETIP_MAX_MSG_NET_LEN_ALL+1 — required for the union packed below.
	localparam ETIP_CF_MSG_EXTRA_LEN    = ETIP_MAX_MSG_NET_LEN_ALL - ETIP_CF_MSG_NET_LEN    + 1;
	localparam ETIP_DF_MSG_EXTRA_LEN    = ETIP_MAX_MSG_NET_LEN_ALL - ETIP_DF_MSG_NET_LEN    + 1;
	localparam ETIP_DAQ_MSG_EXTRA_LEN   = ETIP_MAX_MSG_NET_LEN_ALL - ETIP_DAQ_MSG_NET_LEN   + 1;
	localparam ETIP_OTHER_MSG_EXTRA_LEN = ETIP_MAX_MSG_NET_LEN_ALL - ETIP_OTHER_MSG_NET_LEN + 1;

	// Slimmed 2026-07-18 (resource pass): rdata0/rdata1 were only ever
	// written '0 (dead weight in the CDC FIFO entry), and the implicit-
	// return prediction travels as a single ret_predicted FLAG on the
	// next_iaddr sideband (etip_next_iaddr_t below) instead of a full
	// 32-bit predicted_ret here -- the compare moved into the composer.
	typedef struct packed {
		nexus_sync_reason_e                 sync_reason;
		nexus_btype_e                       btype;
		nexus_rcode_e                       rcode;
		tip_itype_e                         itype;
		tip_iaddr_t                         iaddr;
		etip_icnt_t                         icnt;
		// E-Trace sideband (1-bit stubs without CT_EN_ETRACE, see above);
		// assigned at the composer's main CF arm, consumed only by
		// ct_L2_te_inst_gen (msg_gen ignores them -- wire bytes unchanged).
		logic [ETIP_TRAP_EC_W-1:0]          trap_ecause;
		logic [ETIP_TRAP_TVAL_W-1:0]        trap_tval;
		logic [ETIP_PRIV_W-1:0]             priv;
		logic [ETIP_ILS_W-1:0]              ilastsize;
		logic [ETIP_CF_MSG_EXTRA_LEN-1:0]   _pad;
	} etip_cf_msg_struct_t;

	// next_iaddr sideband entry (composer -> msg_gen): the captured target
	// address of the preceding control-flow event, plus the implicit-return
	// prediction result (Accemic): 1 = the CF event was a RETURN and the
	// composer's return-address stack predicted exactly this target.
	typedef struct packed {
		logic                               ret_predicted;
		tip_iaddr_t                         addr;
	} etip_next_iaddr_t;

	typedef struct packed {
		logic [ETIP_DF_DATA_W-1:0]          data;
		tip_dtype_e                         dtype;
		nexus_dsz_e                         dsz;
		nexus_elsz_e                        elsz;
		logic [ETIP_DF_ADDR_W-1:0]          addr_idtag;
		logic [ETIP_DF_MSG_EXTRA_LEN-1:0]   _pad;
	} etip_df_msg_struct_t;

	typedef struct packed {
		logic [MAX_DAQ_DATA_ELEMENTS-1:0][ETIP_DAQ_ELEM_W-1:0]  data;
		logic [ETIP_DAQ_ADDR_W-1:0]                             addr_idtag;
		logic [ETIP_DAQ_MSG_EXTRA_LEN-1:0]                      _pad;
	} etip_daq_msg_struct_t;

	typedef struct packed {
		nexus_tcode_e                          tcode;
		nexus_etype_e                          etype;
		nexus_vendor_ecode_t                   ecode;
		// Slot-neutral payload: interpreted by TCODE -- Ownership (2)
		// PROCESS, Watchpoint (15) WPHIT. Messages whose payload is sampled
		// at the EMISSION site (Device ID 1, Vendor Config 58) leave it '0;
		// the slot only carries the trigger for those.
		logic [ETIP_OTHER_PAYLOAD_W-1:0]       payload;
		logic [ETIP_OTHER_MSG_EXTRA_LEN-1:0]   _pad;
	} etip_other_msg_struct_t;

	typedef struct packed {
		ct_sub_type_e   sub_type;
		logic           do_flush;
		etip_ts_t       ts;
		union packed {
			etip_cf_msg_struct_t      cf;
			etip_df_msg_struct_t      df;
			etip_daq_msg_struct_t     daq;
			etip_other_msg_struct_t   other;
		}               sub;
	} etip_msg_struct_t;

endpackage

`default_nettype wire
