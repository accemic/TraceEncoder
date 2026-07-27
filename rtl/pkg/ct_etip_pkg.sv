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

	localparam ETIP_CF_MSG_NET_LEN     =   $bits(nexus_sync_reason_e)
										 + $bits(nexus_btype_e)
										 + $bits(nexus_rcode_e)
										 + $bits(tip_itype_e)
										 + $bits(tip_iaddr_t)
										 + $bits(etip_icnt_t)
										 + $bits(nexus_rdata_t)
										 + $bits(nexus_rdata_t);

	localparam ETIP_DF_MSG_NET_LEN     =   $bits(tip_data_t)
										 + $bits(tip_dtype_e)
										 + $bits(nexus_dsz_e)
										 + $bits(nexus_elsz_e)
										 + $bits(nexus_addr_t);

	localparam ETIP_DAQ_MSG_NET_LEN    =   $bits(tip_xaddr_data_t) * MAX_DAQ_DATA_ELEMENTS
										 + $bits(nexus_addr_t);

	localparam ETIP_OTHER_MSG_NET_LEN  =   $bits(nexus_tcode_e)
										 + $bits(nexus_etype_e)
										 + $bits(nexus_vendor_ecode_t);

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

	typedef struct packed {
		nexus_sync_reason_e                 sync_reason;
		nexus_btype_e                       btype;
		nexus_rcode_e                       rcode;
		tip_itype_e                         itype;
		tip_iaddr_t                         iaddr;
		etip_icnt_t                         icnt;
		nexus_rdata_t                       rdata0;
		nexus_rdata_t                       rdata1;
		logic [ETIP_CF_MSG_EXTRA_LEN-1:0]   _pad;
	} etip_cf_msg_struct_t;

	typedef struct packed {
		tip_data_t                          data;
		tip_dtype_e                         dtype;
		nexus_dsz_e                         dsz;
		nexus_elsz_e                        elsz;
		nexus_addr_t                        addr_idtag;
		logic [ETIP_DF_MSG_EXTRA_LEN-1:0]   _pad;
	} etip_df_msg_struct_t;

	typedef struct packed {
		tip_xaddr_data_t [MAX_DAQ_DATA_ELEMENTS-1:0]  data;
		nexus_addr_t                                  addr_idtag;
		logic [ETIP_DAQ_MSG_EXTRA_LEN-1:0]            _pad;
	} etip_daq_msg_struct_t;

	typedef struct packed {
		nexus_tcode_e                          tcode;
		nexus_etype_e                          etype;
		nexus_vendor_ecode_t                   ecode;
		logic [ETIP_OTHER_MSG_EXTRA_LEN-1:0]   _pad;
	} etip_other_msg_struct_t;

	typedef struct packed {
		ct_sub_type_e   sub_type;
		logic           do_flush;
		tip_time_t      ts;
		union packed {
			etip_cf_msg_struct_t      cf;
			etip_df_msg_struct_t      df;
			etip_daq_msg_struct_t     daq;
			etip_other_msg_struct_t   other;
		}               sub;
	} etip_msg_struct_t;

endpackage

`default_nettype wire
