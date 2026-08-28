// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief RISC-V flavor of the `nexus_vendor` and shared `nexus` packages.
 *
 * @details
 *   Vendor-specific parameters, message/field widths, TCODE enums and helper
 *   functions used by the CTTE encoder.
 */

package nexus_vendor;

	// Build profile: see ct_pkg (compiled first); widths below derive from
	// it via explicit ct_pkg:: scoping (no mirror -- avoids import clashes).

	localparam NEXUS_MSG_SOURCE_WIDTH   = 4;
	// Timestamp width is a build knob (ct_pkg::CT_TS_WIDTH; the TIP-side
	// tip_time_t stays 64 bit for interface stability -- the eTIP/message
	// path truncates). With timestamps disabled the wire stream is
	// identical for any width (the TSTAMP field carries 0 either way).
	localparam NEXUS_MSG_TSTAMP_WIDTH   = ct_pkg::CT_TS_WIDTH;
	localparam NEXUS_MSG_MAP_WIDTH      = 1;
	// Address field width = the architectural address width of the attached
	// hart (ct_pkg::CT_XLEN, X2a). The ON-WIRE F-ADDR / U-ADDR fields stay
	// variable-length (Nexus MDO with leading-zero suppression), so a 32-bit
	// build emits exactly the historical bytes; this constant sizes the
	// internal field arrays, the message union and the eTIP payload.
	localparam NEXUS_MSG_ADDRESS_WIDTH  = ct_pkg::CT_XLEN;

	// Right-shift applied to PC-carrying FADDR / UADDR fields before encoding.
	localparam NEXUS_MSG_PC_ADDR_SHIFT  = 1;
	localparam NEXUS_MSG_DSZ_WIDTH      = 4;
	localparam NEXUS_MSG_ELSZ_WIDTH     = 3;

	// Only DAQ-class messages need >64-bit field payloads -- both CT_EN_DAQ
	// and CT_EN_ACT produce them (ACT-CAP packs up to 3x64-bit elements
	// into DQDATA). Data trace needs the 64-bit tip data value; a
	// control-flow-only profile floors at the 32-bit address width -- the
	// whole message path (field arrays, buffer, bit slicer) narrows with it.
	localparam bit NEXUS_HAS_DAQ_MSGS   = ct_pkg::CT_EN_DAQ || ct_pkg::CT_EN_ACT;
	localparam NEXUS_MSG_DATA_WIDTH     = NEXUS_HAS_DAQ_MSGS       ? 192
	                                    : ct_pkg::CT_EN_DATA_TRACE ?  64 : 32;
	localparam NEXUS_MSG_I_CNT_WIDTH    = 8;
	// Widened internal ICNT plumbing (Accemic): nexus_icnt_t below is sized
	// for the CSR-selectable wide cap (trTeInstFeatures.InstEnWideIcnt).
	// The ON-WIRE ICNT field stays variable-length (Nexus MDO), so a narrow
	// (default) configuration is byte-identical to the original 8-bit cap;
	// only the internal accumulator/struct width grows.
	localparam NEXUS_MSG_I_CNT_WIDTH_WIDE = 16;
	localparam NEXUS_MSG_BTYPE_WIDTH    = 2;
	localparam NEXUS_MSG_ID_WIDTH       = 32;

	localparam NEXUS_MSG_DEBUG_STATUS_WIDTH = 16;
	localparam NEXUS_MSG_PROCESS_WIDTH  = 44;

	localparam NEXUS_MSG_ECODE_WIDTH    = 8;

	// Vendor config message TCODE 58 payload widths (SPEC_config_message.md
	// v1 -- CFGVER is a fixed 4-bit field, CAPS/ENAB/P0..P3 are var fields
	// with these maximum widths; forward-compat rule: append-only).
	localparam NEXUS_MSG_CFGVER_WIDTH   = 4;
	localparam NEXUS_MSG_CFG_CAPS_WIDTH = 24; // 19 (P2) + 19 DEVICE_ID / 20 WATCHPOINT_MSG (P4) + 21 DF_ADDR_COMPRESS (P3) + 22 DF_DROP (P7) + 23 ADDR64 (X2a, append-only)
	localparam NEXUS_MSG_CFG_P0_WIDTH   = 16;
	localparam NEXUS_MSG_CFG_P1_WIDTH   = 12;
	localparam NEXUS_MSG_CFG_P2_WIDTH   = 12;
	localparam NEXUS_MSG_CFG_P3_WIDTH   = 13;

	localparam NEXUS_MSG_SYNC_I_CNT_WIDTH= 1;
	localparam NEXUS_MSG_WPHIT_WIDTH    = 32;
	// Watchpoint message (TCODE 15, P4): CTTE reports the 16 ACT-ST
	// watchpoint slots, so the payload the encoder carries internally is 16
	// bit wide (trWpMask.WEM). The ON-WIRE WPHIT field stays variable-length
	// (Nexus MDO, leading zeros stripped), so this width bounds the internal
	// eTIP/message payload only -- it is not a wire property.
	localparam NEXUS_MSG_WPHIT_IMPL_WIDTH = 16;
	// Device ID message (TCODE 1, P4): the ID field width. IEEE-ISTO 5001
	// Table 4-7 specifies "Fixed 32"; CTTE emits it as a VENDOR_VARIABLE
	// field (see ct_pkg::CT_EN_DEVICE_ID and doc/trace-format.adoc for the
	// deviation rationale), so this is the maximum, not the emitted length.
	localparam NEXUS_MSG_DEVID_WIDTH    = 32;

	localparam NEXUS_MSG_RCODE_WIDTH    = 4;
	localparam NEXUS_MSG_RDATA_WIDTH    = 30;

	localparam NEXUS_MSG_HIST_WIDTH     = 30;

	localparam NEXUS_MSG_EVCODE_WIDTH   = 4;
	localparam NEXUS_MSG_CDATA_WIDTH    = 30;

	localparam NEXUS_MSG_CKSRC_WIDTH    = 0;
	localparam NEXUS_MSG_CKDF_WIDTH     = 0;
	localparam NEXUS_MSG_CKDATA_WIDTH   = NEXUS_HAS_DAQ_MSGS       ? 128
	                                    : ct_pkg::CT_EN_DATA_TRACE ?  64 : 32;
	localparam NEXUS_MSG_SYNC_REASON_WIDTH  = 4;

	localparam NEXUS_MSG_XMAP_WIDTH     = 1;
	localparam NEXUS_AUX_ADDRESS_WIDTH  = 1;

	localparam NEXUS_MSG_ST_WIDTH        = 2;

	localparam NEXUS_DQDATA_WIDTH       = NEXUS_MSG_DATA_WIDTH;
	localparam NEXUS_IDTAG_WIDTH        = 12;

	localparam NEXUS_MAX_DATA_SIZE      = NEXUS_MSG_CKDATA_WIDTH+NEXUS_MSG_CKSRC_WIDTH+NEXUS_MSG_CKDF_WIDTH;

	localparam MAX_ICT_DATA_FIELDS      = 3; // CDM Including Cycles
	localparam NEXUS_MAX_PACKET_WIDTH   = 32; // CDM Data
	// Widest single message field: DATA/CKDATA payloads, the TSTAMP field
	// (CT_TS_WIDTH knob) and the 32-bit address fields. Everything else
	// (HIST/RDATA 30, ICNT 16, IDTAG 12, ...) is below the address width.
	localparam NEXUS_MAX_FIELD_DATA_WIDTH_DK = (NEXUS_MSG_DATA_WIDTH > NEXUS_MSG_CKDATA_WIDTH) ? NEXUS_MSG_DATA_WIDTH : NEXUS_MSG_CKDATA_WIDTH;
	localparam NEXUS_MAX_FIELD_DATA_WIDTH_DT = (NEXUS_MAX_FIELD_DATA_WIDTH_DK > NEXUS_MSG_TSTAMP_WIDTH) ? NEXUS_MAX_FIELD_DATA_WIDTH_DK : NEXUS_MSG_TSTAMP_WIDTH;
	localparam NEXUS_MAX_FIELD_DATA_WIDTH    = (NEXUS_MAX_FIELD_DATA_WIDTH_DT > NEXUS_MSG_ADDRESS_WIDTH) ? NEXUS_MAX_FIELD_DATA_WIDTH_DT : NEXUS_MSG_ADDRESS_WIDTH;
	// The generic message union must fit its WIDEST variant, not just the
	// DF/DAQ one: with slim profiles (small DATA_WIDTH) the CF variant
	// (sync+btype+rcode+2*addr+icnt+2*rdata = 150 bit net) becomes the
	// driver. +1 keeps every variant's _pad width >= 1.
	localparam NEXUS_MSG_CF_NET_WIDTH   = NEXUS_MSG_SYNC_REASON_WIDTH + NEXUS_MSG_BTYPE_WIDTH
	                                    + NEXUS_MSG_RCODE_WIDTH + 2*NEXUS_MSG_ADDRESS_WIDTH
	                                    + NEXUS_MSG_I_CNT_WIDTH_WIDE + 2*NEXUS_MSG_RDATA_WIDTH;
	localparam NEXUS_MSG_DF_NET_WIDTH   = NEXUS_MSG_DSZ_WIDTH + NEXUS_MSG_ELSZ_WIDTH
	                                    + NEXUS_MSG_ADDRESS_WIDTH + NEXUS_MSG_DATA_WIDTH;
	localparam NEXUS_MSG_SUB_WIDTH      = ((NEXUS_MSG_DF_NET_WIDTH > NEXUS_MSG_CF_NET_WIDTH)
	                                       ? NEXUS_MSG_DF_NET_WIDTH : NEXUS_MSG_CF_NET_WIDTH) + 1;
	localparam NEXUS_MAX_HIST_DATA_WIDTH = 32;

	localparam NEXUS_MAX_PACKET_COUNT   = 5;//Indirect branch history with sync

	localparam NEXUS_MAX_FIELDS         = 10;   // max # of fields within a nexus message
	localparam NEXUS_MAX_PARALLEL_MSG   = 3;    // max # of messages generated per TIP
	localparam NEXUS_MDO_WIDTH          = 6;    // 6, 14 and 30 is supported
	localparam NEXUS_CHUNK_WIDTH        = NEXUS_MDO_WIDTH + 2;
	localparam NEXUS_MAX_CHUNKS         = 20;   // max # of chunks per message (chank consists of 6, 14, or 30 MDO bits and 2 MSEO bits)
	localparam ICNT_THRESHOLD           = 32'h10000000;

	localparam CSR_ACT_CAP_BASE         = 32'h0B10;             // CSR ID of ACT_CAP CSR range (core-specific CSR window 0xB10 – 0xB9F)
	localparam CSR_CT_ACT_CAP_WIDTH     = 32;

	localparam ACT_CAP_CMD              = CSR_ACT_CAP_BASE + 0;

	typedef logic [NEXUS_MSG_SOURCE_WIDTH-1:0]  nexus_src_t;
	typedef logic [NEXUS_MSG_ECODE_WIDTH-1:0]   nexus_vendor_ecode_t;
	typedef logic [NEXUS_MSG_ADDRESS_WIDTH-1:0] nexus_addr_t;
	typedef logic [NEXUS_MSG_I_CNT_WIDTH_WIDE-1:0] nexus_icnt_t;
	typedef logic [NEXUS_IDTAG_WIDTH-1:0]       nexus_idtag_t;
	typedef logic [NEXUS_MSG_RDATA_WIDTH-1:0]   nexus_rdata_t;
	typedef logic [NEXUS_MSG_TSTAMP_WIDTH-1:0]  nexus_ts_t;

endpackage : nexus_vendor

package nexus;

	import nexus_vendor::*;

	typedef enum logic [2:0] {
		NEXUS_STATE_IDLE        =0,
		NEXUS_STATE_START_MSG   =1,
		NEXUS_STATE_NORMAL      =2,
		NEXUS_STATE_END_PACKET  =3,
		NEXUS_STATE_END_MSG     =4
	} nexus_mseo_state_e;

	typedef enum logic [5:0] {
		NEXUS_MSG_DEBUG_STATUS                          =6'd0,
		NEXUS_MSG_DEVICE_ID                             =6'd1,
		NEXUS_MSG_OWNERSHIP_TRACE                       =6'd2,
		NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH           =6'd3,
		NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH         =6'd4,
		NEXUS_MSG_DATA_TRACE_WRITE                      =6'd5,
		NEXUS_MSG_DATA_TRACE_READ                       =6'd6,
		NEXUS_MSG_DATA_ACQUISITION                      =6'd7,
		NEXUS_MSG_ERROR                                 =6'd8,

		NEXUS_MSG_PROGRAM_TRACE_SYNC                    =6'd9,
		NEXUS_MSG_PROGRAM_TRACE_CORRECTION              =6'd10,
		NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH_SYNC      =6'd11,
		NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_SYNC    =6'd12,

		NEXUS_MSG_DATA_TRACE_WRITE_SYNC                 =6'd13,
		NEXUS_MSG_DATA_TRACE_READ_SYNC                  =6'd14,

		NEXUS_MSG_WATCHPOINT                            =6'd15,

		NEXUS_MSG_PORT_REPLACEMENT_OUT                  =6'd20,
		NEXUS_MSG_PORT_REPLACEMENT_IN                   =6'd21,

		NEXUS_MSG_AUX_READ                              =6'd22,
		NEXUS_MSG_AUX_WRITE                             =6'd23,
		NEXUS_MSG_AUX_READ_NEXT                         =6'd24,
		NEXUS_MSG_AUX_WRITE_NEXT                        =6'd25,
		NEXUS_MSG_AUX_RESPONSE                          =6'd26,

		NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL           =6'd27,
		NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY =6'd28,
		NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY_SYNC    =6'd29,
		NEXUS_MSG_PROGRAM_TRACE_REPEAT_BRANCH           =6'd30,
		// Accemic vendor extensions (Nexus vendor TCODE range 56..62):
		//   56 = branch prediction: count of correctly predicted direct
		//        branches (both sides run a bit-identical predictor model);
		//        the branch after the counted run mispredicted.
		//   57 = IndirectBranchHist with jump-target-cache index instead
		//        of UADDR.
		NEXUS_MSG_VENDOR_BRANCH_PREDICT                 =6'd56,
		NEXUS_MSG_VENDOR_JUMP_TARGET_CACHE              =6'd57,
		NEXUS_MSG_PROGRAM_TRACE_REPEAT_INSTRUCTION      =6'd31,
		NEXUS_MSG_PROGRAM_TRACE_REPEAT_INSTRUCTION_SYNC =6'd32,
		NEXUS_MSG_PROGRAM_TRACE_CORRELATION             =6'd33,

		NEXUS_MSG_INCIRCUIT_TRACE                       =6'd34,
		NEXUS_MSG_INCIRCUIT_TRACE_SYNC                  =6'd35,
		NEXUS_MSG_FLUSH                                 =6'd36,     // 'h24: internal use only for signalling flush     Msg consists of TCODE only
		NEXUS_MSG_VENDOR_CONFIG                         =6'd58,     // vendor specific message providing the trace encoder configuration to the decoding device (SPEC_config_message.md v1; emitted per trTeControl.SendConfig since; moved 56->58 when 56 became VendorBranchPredict)
		NEXUS_MSG_VENDOR_1_END                          =6'd62,
		NEXUS_MSG_VENDOR_EXT                            =6'd63
	} nexus_tcode_e;

	typedef enum logic [NEXUS_MSG_SYNC_REASON_WIDTH-1:0] {      // https://github.com/riscv-non-isa/riscv-nexus-trace/blob/main/docs/nexus-standard/IEEE-ISTO-5001-2012-v3.0.1-Nexus-Standard.pdf#page=51
		NEXUS_SYNC_EVTI                     =  0, //4'b0000,    // External Trace Trigger
		NEXUS_SYNC_EXIT_FROM_SYS_RST        =  1, //4'b0001,    // Exit from Reset
		NEXUS_SYNC_PERIODIC                 =  2, //4'b0010,    // Periodic Synchronization *implemented*
		NEXUS_SYNC_EXIT_FROM_DEBUG          =  3, //4'b0011,    // Exit from Debug Mode
		NEXUS_SYNC_SEQ_INSTR_COUNTER        =  4, //4'b0100,    // Sequential Instruction Counter (I-CNT overflow)
		NEXUS_SYNC_TRACE_ENABLE             =  5, //4'b0101,    // Trace Enable *implemented*
		NEXUS_SYNC_WATCHPOINT               =  6, //4'b0110,    // Trace Event
		NEXUS_SYNC_FIFO_OVERRUN             =  7, //4'b0111,    // Restart from FIFO overrun
		NEXUS_SYNC_RESERVED_0               =  8, //4'b1000,    // (Reserved)
		NEXUS_SYNC_EXIT_FROM_POWERDOWN      =  9, //4'b1001,    // Exit from Powerdown
		NEXUS_SYNC_RESERVED_1               = 10, //4'b1010,    // (Reserved)
		NEXUS_SYNC_MSG_CONTENTION           = 11, //4'b1011,    // Contention with higher priority messages caused message(s) to be lost
		// N-Trace 1.0 Table 25 reserves 10..13 for FUTURE STANDARD use; only
		// 14..15 are vendor-defined. The former CTTE codes REQ_CSR(12) /
		// REQ_ATB(13) / TRACE_QUOTA(14) therefore collapse into the ONE
		// vendor code 14 = "explicit sync request" (AW decision E2,
		// 2026-07-19): the request source is irrelevant to a decoder (every
		// sync is a full re-anchor) and stays readable for diagnosis via the
		// RO CSR field te.trTeSyncStatus.SyncReqSource.
		NEXUS_SYNC_RESERVED_2               = 12, //4'b1100,    // (Reserved for future standard use -- was CTTE REQ_CSR)
		NEXUS_SYNC_RESERVED_3               = 13, //4'b1101,    // (Reserved for future standard use -- was CTTE REQ_ATB)
		NEXUS_SYNC_REQ                      = 14, //4'b1110,    // (Vendor Defined) explicit sync request (CSR / ATB / trace quota)
		NEXUS_SYNC_NONE                     = 15  //4'b1111     // (Vendor Defined) internal "no sync" marker (never on-wire)
	} nexus_sync_reason_e;

	typedef enum logic [NEXUS_MSG_RCODE_WIDTH-1:0]  {           // https://github.com/riscv-non-isa/riscv-nexus-trace/blob/main/docs/nexus-standard/IEEE-ISTO-5001-2012-v3.0.1-Nexus-Standard.pdf#page=53
		NEXUS_RCODE_ICNT_OVERFLOW           =  0, //4'b0000,
		NEXUS_RCODE_HIST_OVERFLOW           =  1, //4'b0001,
		NEXUS_RCODE_HIST_OVERFLOW_REPEATED  =  2, //4'b0010,    // link:../../references/147_RISC-V-N-Trace-Specification.pdr#page=27
		NEXUS_RCODE_TRACE_DISABLED          =  3, //4'b0011,    // [CTTE] internal marker: composer -> msg_gen, request a
															//           Program Trace Correlation Message (TCODE 33,
															//           EVCODE=Program Trace Disabled) flushing the residual ICNT/HIST
		// [CTTE] further internal correlation markers: same
		// composer->msg_gen contract as TRACE_DISABLED, but with a different
		// EVCODE on the wire. On-wire RCODEs remain 0/1/2 only -- these
		// markers are consumed by msg_gen and never leave it.
		NEXUS_RCODE_CORR_DEBUG_ENTRY        =  4, //4'b0100,    // -> Correlation EVCODE=0 (Entry into Debug Mode, Required)
		NEXUS_RCODE_CORR_LOW_POWER          =  5, //4'b0101,    // -> Correlation EVCODE=1 (Entry into Low-power Mode, optional)
		NEXUS_RCODE_NONE                    = 15  //4'b1111     // for debug
	} nexus_rcode_e;

	// EVCODE values for the Program Trace Correlation Message (TCODE 33).
	// N-Trace 1.0 Table 24: 0 = Entry into Debug Mode (Required, "do not
	// send 4 instead!"), 1 = Entry into Low-power Mode (optional), 4 =
	// Program Trace Disabled (optional; per IEEE-ISTO 5001-2012 Table 4-25).
	localparam logic [NEXUS_MSG_EVCODE_WIDTH-1:0] NEXUS_EVCODE_ENTRY_DEBUG            = 4'h0;
	localparam logic [NEXUS_MSG_EVCODE_WIDTH-1:0] NEXUS_EVCODE_ENTRY_LOW_POWER        = 4'h1;
	localparam logic [NEXUS_MSG_EVCODE_WIDTH-1:0] NEXUS_EVCODE_PROGRAM_TRACE_DISABLED = 4'h4;

	typedef enum logic [NEXUS_MSG_BTYPE_WIDTH-1:0] {                // https://github.com/riscv-non-isa/riscv-nexus-trace/blob/main/docs/nexus-standard/IEEE-ISTO-5001-2012-v3.0.1-Nexus-Standard.pdf#page=51
		NEXUS_BTYPE_IBRANCH                 =  0, //2'b00,
		NEXUS_BTYPE_EXCEPTION_INTERRUPT     =  1, //2'b01,
		NEXUS_BTYPE_EXCEPTION               =  2, //2'b10,
		NEXUS_BTYPE_INTERRUPT               =  3  //2'b11
	} nexus_btype_e;

	// Ownership Message Fields
	typedef enum logic [1:0] {                                  // link:../../references/147_RISC-V-N-Trace-Specification.pdr#page=24
		CONTEXT_V_PRV                       = 0,
		CONTEXT_SCONTEXT                    = 2,
		CONTEXT_HCONTEXT                    = 3
	} nexus_context_format_e;

	typedef enum logic [1:0] {                                  // link:../../references/147_RISC-V-N-Trace-Specification.pdr#page=24
		CONTEXT_PRV_U                       = 0,
		CONTEXT_PRV_S                       = 1,
		CONTEXT_PRV_M                       = 3
	} nexus_context_prv_e;

	typedef struct packed {
		logic [NEXUS_MSG_PROCESS_WIDTH-1:0] _context;   // 44
		logic                               v;          // 1
		nexus_context_prv_e                 prv;        // 2
		nexus_context_format_e              format;     // 2
	} nexus_process_t;                                  // 49

	typedef enum logic [NEXUS_MSG_DSZ_WIDTH-1:0] {              // https://github.com/riscv-non-isa/riscv-nexus-trace/blob/main/docs/nexus-standard/IEEE-ISTO-5001-2012-v3.0.1-Nexus-Standard.pdf#page=63
		NEXUS_DSZ_0                     =  0, //4'b0000,        // 0-byte (Implied data instructions may support a “zero-data” size)
		NEXUS_DSZ_1                     =  1, //4'b0001,        // 1-byte
		NEXUS_DSZ_2                     =  2, //4'b0010,        // 2-byte / halfword
		NEXUS_DSZ_3                     =  3, //4'b0011,        // 3-byte / string
		NEXUS_DSZ_4                     =  4, //4'b0100,        // 4-byte / word
		NEXUS_DSZ_8                     =  8  //4'b1000         // 64-bit / double
	} nexus_dsz_e;

	typedef enum logic [NEXUS_MSG_ELSZ_WIDTH-1:0] {             // https://github.com/riscv-non-isa/riscv-nexus-trace/blob/main/docs/nexus-standard/IEEE-ISTO-5001-2012-v3.0.1-Nexus-Standard.pdf#page=64
		NEXUS_ELSZ_DSZ                  =  0, //3'b000,         // 0-byte (Implied data instructions may support a “zero-data” size)
		NEXUS_ELSZ_1                    =  1, //3'b001,         // 1-byte
		NEXUS_ELSZ_2                    =  2, //3'b010,         // 2-byte / halfword
		NEXUS_ELSZ_4                    =  3, //3'b011,         // 4-byte / word
		NEXUS_ELSZ_8                    =  4  //3'b100          // 64-bit / double
	} nexus_elsz_e;

	typedef enum logic [3:0] {
		NEXUS_ETYPE_QUEUE_OVERRUN       = 4'h0,                 // Queue Overrun caused messages (one or more) to be lost
		NEXUS_ETYPE_HIGH_PRIO           = 4'h1                  // Contention with higher priority messages caused message(s) to be lost
	} nexus_etype_e;

	localparam NEXUS_ECODE_WATCHPOINT_MSG_LOST  = 8'b00000001;
	localparam NEXUS_ECODE_DF_MSG_LOST          = 8'b00000010;
	localparam NEXUS_ECODE_CF_MSG_LOST          = 8'b00000100;
	localparam NEXUS_ECODE_OWNERSHIP_MSG_LOST   = 8'b00001000;
	localparam NEXUS_ECODE_STATUS_MSG_LOST      = 8'b00010000;
	localparam NEXUS_ECODE_DAQ_MSG_LOST         = 8'b00100000;
	localparam NEXUS_ECODE_ICE_MSG_LOST         = 8'b01000000;
	localparam NEXUS_ECODE_VENDOR_MSG_LOST      = 8'b10000000;

	// Non-optimized generic trace message format for control flow (in accordance with Nexus)
	typedef struct packed {
		nexus_sync_reason_e                         sync_reason;//   4
		nexus_btype_e                               btype;      //   2
		nexus_rcode_e                               rcode;      //   4
		nexus_addr_t                                curr_iaddr; // CT_XLEN
		nexus_addr_t                                next_iaddr; // CT_XLEN
		nexus_icnt_t                                icnt;       //   8
		nexus_rdata_t                               rdata0;     //  30
		nexus_rdata_t                               rdata1;     //  30
		logic [NEXUS_MSG_SUB_WIDTH-(  $bits(nexus_sync_reason_e)
									+ $bits(nexus_btype_e)
									+ $bits(nexus_rcode_e)
									+ $bits(nexus_addr_t)
									+ $bits(nexus_addr_t)
									+ $bits(nexus_icnt_t)
									+ $bits(nexus_rdata_t)
									+ $bits(nexus_rdata_t))-1:0]    _pad;
	} nexus_cf_msg_struct_t;                                    // NEXUS_MSG_SUB_WIDTH

	// Non-optimized generic trace message format for data flow and data acquisition message (in accordance with Nexus)
	typedef struct packed {
		nexus_dsz_e                                 dsz;        //   4   Data Size (size of the write/read)
		nexus_elsz_e                                elsz;       //   3   Element Size (size of the element within the data access)
		nexus_addr_t                                addr_idtag; // CT_XLEN F-ADDR or U-ADDR (according to tcode)
		logic [NEXUS_MSG_DATA_WIDTH-1:0]            data;       // NEXUS_MSG_DATA_WIDTH
		logic [NEXUS_MSG_SUB_WIDTH-NEXUS_MSG_DF_NET_WIDTH-1:0] _pad; // union alignment (>=1)
	} nexus_df_daq_msg_struct_t;                                // NEXUS_MSG_SUB_WIDTH

	// Non-optimized generic trace message format for error message (in accordance with Nexus)
	typedef struct packed {
		nexus_etype_e                               etype;      //   4   Error Types
		nexus_vendor_ecode_t                        ecode;      //   8   Error Codes
		logic [NEXUS_MSG_SUB_WIDTH-($bits(nexus_etype_e) + $bits(nexus_vendor_ecode_t))-1:0] _pad;
	} nexus_error_msg_struct_t;                                 // NEXUS_MSG_SUB_WIDTH

	// Non-optimized generic trace message format for other messages (in accordance with Nexus)
	// wphit (P4, TCODE 15) rides next to the Ownership PROCESS payload: the
	// variant is padded to NEXUS_MSG_SUB_WIDTH (the CF/DF variants are far
	// wider), so the extra field only shortens the pad -- no width growth in
	// any profile.
	typedef struct packed {
		nexus_process_t                             _process;   //  49
		logic [NEXUS_MSG_WPHIT_IMPL_WIDTH-1:0]      wphit;      //  16
		logic [NEXUS_MSG_SUB_WIDTH-$bits(nexus_process_t)-NEXUS_MSG_WPHIT_IMPL_WIDTH-1:0] _pad;
	} nexus_other_msg_struct_t;                                 // NEXUS_MSG_SUB_WIDTH

	typedef struct packed {
		ct_pkg::ct_sub_type_e           sub_type;
		nexus_tcode_e                   tcode;
		nexus_ts_t                          ts;         // width = NEXUS_MSG_TSTAMP_WIDTH (build knob)
		logic [31:0]                        id;         // # of messages, for debug
		union packed {
			nexus_cf_msg_struct_t       cf;
			nexus_df_daq_msg_struct_t   df_daq;
			nexus_error_msg_struct_t    err;
			nexus_other_msg_struct_t    other;
		}                               sub;
	} nexus_msg_struct_t;

	typedef enum logic [2:0] {
		FIELD_INVALID       = 3'h0,     // field not valid
		VENDOR_FIXED        = 3'h1,
		VENDOR_VARIABLE     = 3'h2,
		VARIABLE            = 3'h3,
		FIXED               = 3'h4
	} nexus_field_type_e;

	typedef enum logic [5:0] {          // for debug
		INVALID             = 6'h00,
		TCODE               = 6'h01,
		SRC                 = 6'h02,
		SYNC                = 6'h03,
		ICNT                = 6'h04,
		PC_FADDR            = 6'h05,
		TSTAMP              = 6'h06,
		BTYPE               = 6'h07,
		UADDR               = 6'h08,
		RCODE               = 6'h09,
		RDATA0              = 6'h0A,
		RDATA1              = 6'h0B,
		DSZ                 = 6'h0C,
		ELSZ                = 6'h0D,
		IDTAG               = 6'h0E,
		ADDR                = 6'h0F,
		DATA                = 6'h10,
		DQDATA              = 6'h11,
		ETYPE               = 6'h12,
		ECODE               = 6'h13,
		PROCESS             = 6'h14,
		INST_MODE           = 6'h15,
		SYNC_MODE           = 6'h16,
		TS_ACTIVE           = 6'h17,
		TS_TYPE             = 6'h18,
		STATUS              = 6'h19,
		// Vendor config message TCODE 58 fields (SPEC_config_message.md v1):
		CFGVER              = 6'h1A,
		CAPS                = 6'h1B,
		ENAB                = 6'h1C,
		X                   = 6'h20,
		PARAM0              = 6'h21,   // P0 SrcID|SrcBits
		PARAM1              = 6'h22,   // P1 InhibitSrc|SyncMax|SyncMode|InstMode
		PARAM2              = 6'h23,   // P2 TsWidth|TsPrescale|TsType|TsEnable
		PARAM3              = 6'h24,   // P3 RetStackDepth|BpTableLog2|JtcIndexBits
		// P4 message fields (appended -- the enum is debug-only, but the
		// order is mirrored in tests/lib/ct_nexus_decoder.sv):
		DEVID               = 6'h25,   // Device ID (TCODE 1) ID field
		WPHIT               = 6'h26    // Watchpoint (TCODE 15) WPHIT field
	} nexus_field_name_e;

	// link:../../references/147_RISC-V-N-Trace-Specification.pdr#page=11
	// https://github.com/riscv-non-isa/riscv-nexus-trace/blob/main/docs/nexus-standard/IEEE-ISTO-5001-2012-v3.0.1-Nexus-Standard.pdf#page=77
	typedef enum logic [1:0] {                      // for debug
		START_TRANSMISSION  = 2'b00,                // The first byte of a message sends the LSBs of the message and is indicated by MSEO[1:0]=00.
													// Bytes occupied by fixed-length fields and initial parts of longer variable-length fields are sent using MSEO[1:0]=00.
		END_IDLE            = 2'b11,                // The last byte of a message is indicated by MSEO[1:0]=11.
													// It also implies an end of the last (fixed-length or variable-lenght) field of a message.
													// Idle bytes (between messages or used as padding) are indicated by MSEO[1:0]=11 and MDO[5:0]=111111 (entire byte is 0xFF).
		VAR                 = 2'b01,                // The last byte of a variable-length field is indicated by MSEO[1:0]=01.
		RES                 = 2'b10                 // Value of MSEO[1:0]=10 is reserved for future extensions.
	} nexus_mseo_e;

	typedef struct packed {
		nexus_field_name_e                              name; // for debug only
		nexus_field_type_e                              field_type;
		logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0]          data;
		logic [$clog2(NEXUS_MAX_FIELD_DATA_WIDTH):0]    data_width;
	} nexus_field_t;

	typedef struct packed {
		logic [NEXUS_MDO_WIDTH-1 :0]                    mdo;
		nexus_mseo_e                                    mseo;
	} nexus_chunk_t;

	typedef struct packed {
		nexus_field_t    [NEXUS_MAX_FIELDS-1:0]         fields;
		logic [31:0]                                        id;             // id of corresponding trace message, for debug
	} nexus_message_t;

	// get length without leading Zeros
	// return length >= 1 (also if the vector == '0)
	function int LengthWoLeadingZeros (input logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] vector);
		for (int i = NEXUS_MAX_FIELD_DATA_WIDTH-1; i >= 0; i--) begin
			if (vector[i]) begin
				return i+1;
			end
		end
		return 1; // No set bit found
	endfunction

	// nexus_addr_t (declared above) is sized by NEXUS_MSG_ADDRESS_WIDTH, so
	// the address-compression helpers follow CT_XLEN without a second
	// width literal.
	function nexus_addr_t GetUaddr(input nexus_addr_t curr_iaddr, nexus_addr_t ref_addr);
		return (curr_iaddr ^ ref_addr);
	endfunction

	// DF address compression (P3, CT_EN_DF_ADDR_COMPRESS): XOR against the
	// PREVIOUS data-trace message's address. Deliberately a separate
	// function next to GetUaddr: DF addresses are byte-granular (no
	// NEXUS_MSG_PC_ADDR_SHIFT -- data accesses carry no alignment
	// guarantee), and the DF reference register is independent of the CF
	// RefAddr (separate re-anchor contract via TCODE 13/14).
	function nexus_addr_t GetDaddrXor(input nexus_addr_t daddr, nexus_addr_t ref_daddr);
		return (daddr ^ ref_daddr);
	endfunction

	// data trace functions

	function nexus_dsz_e GetDsz(logic [7:0] dsize);
	// data access size is 2^dsize bytes
		case (dsize)
			0: return NEXUS_DSZ_1;
			1: return NEXUS_DSZ_2;
			2: return NEXUS_DSZ_4;
			3: return NEXUS_DSZ_8;
			default: begin
				// pragma translate_off
				// dsize > 7 is not supported by regular Nexus messages
				$error("*** ERROR (%m, line %0d): Unexpected dsize (for dsz): %0d", `__LINE__, dsize);
				$stop;
				// pragma translate_on
			end
		endcase
		return NEXUS_DSZ_0;
	endfunction

	function nexus_elsz_e GetElsz(logic [7:0] dsize);
	// data access size is 2^dsize bytes
		case (dsize)
			0: return NEXUS_ELSZ_1;
			1: return NEXUS_ELSZ_2;
			2: return NEXUS_ELSZ_4;
			3: return NEXUS_ELSZ_8;
			default: begin
				// pragma translate_off
				// dsize > 4 is not supported by regular Nexus messages
				$error("*** ERROR (%m, line %0d): Unexpected dsize (for elsz): %0d", `__LINE__, dsize);
				$stop;
				// pragma translate_on
			end
		endcase
		return NEXUS_ELSZ_1;
	endfunction

	function logic TcodeIsSync (logic [5:0] tcode);
		if (tcode == NEXUS_MSG_PROGRAM_TRACE_SYNC)                          return 1;
		if (tcode == NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH_SYNC)            return 1;
		if (tcode == NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_SYNC)          return 1;
		if (tcode == NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY_SYNC)  return 1;
		if (tcode == NEXUS_MSG_PROGRAM_TRACE_REPEAT_INSTRUCTION_SYNC)       return 1;
		if (tcode == NEXUS_MSG_INCIRCUIT_TRACE_SYNC)                        return 1;
		// TCODE 13/14 (P3, CT_EN_DF_ADDR_COMPRESS): the synchronizing data
		// trace forms carry the full address and an absolute TSTAMP
		// (N-Trace 8.4 rule for synchronizing messages). Compile-masked:
		// without the feature the encoder never emits them (4a zero-cost).
		if (ct_pkg::CT_EN_DF_ADDR_COMPRESS && (tcode == NEXUS_MSG_DATA_TRACE_WRITE_SYNC)) return 1;
		if (ct_pkg::CT_EN_DF_ADDR_COMPRESS && (tcode == NEXUS_MSG_DATA_TRACE_READ_SYNC))  return 1;
		return 0;
	endfunction

	// ------------------------------------------------------------------------
	// Message‐Format Descriptors (data‑driven table)
	// ------------------------------------------------------------------------
	typedef struct packed {
		nexus_field_name_e     name;
		nexus_field_type_e     field_type;
		int                    max_bits;
	} nexus_field_format_t;

	typedef struct {
		nexus_tcode_e          tcode;
		int                    num_fields;
		nexus_field_format_t   fmt [NEXUS_MAX_FIELDS];
	} nexus_msg_format_t;

	function automatic nexus_msg_format_t get_msg_format(input nexus_tcode_e tcode);
		nexus_msg_format_t fmt;

		// default initialization
		fmt.tcode      = tcode;
		fmt.num_fields = 0;
		for (int i = 0; i < NEXUS_MAX_FIELDS; i++) begin
		  fmt.fmt[i].name       = INVALID;
		  fmt.fmt[i].field_type = FIELD_INVALID;
		  fmt.fmt[i].max_bits   = 0;
		end

		unique case (tcode)

			// 4.3.11 Program Trace - Synchronization Message (TCODE = 9)
			NEXUS_MSG_PROGRAM_TRACE_SYNC: begin
				fmt.num_fields = 6;
				fmt.fmt[0] = '{ name: TCODE,     field_type: FIXED,             max_bits: 6 };
				fmt.fmt[1] = '{ name: SRC,       field_type: FIXED,             max_bits: NEXUS_MSG_SOURCE_WIDTH };
				fmt.fmt[2] = '{ name: SYNC,      field_type: FIXED,             max_bits: $bits(nexus_sync_reason_e)};
				fmt.fmt[3] = '{ name: ICNT,      field_type: VARIABLE,          max_bits: NEXUS_MSG_I_CNT_WIDTH };
				fmt.fmt[4] = '{ name: PC_FADDR,  field_type: VARIABLE,          max_bits: NEXUS_MSG_ADDRESS_WIDTH };
				fmt.fmt[5] = '{ name: TSTAMP,    field_type: VENDOR_VARIABLE,   max_bits: NEXUS_MSG_TSTAMP_WIDTH };
			end

			// 4.3.17 and 4.3.18 Data Trace - Data Write Message (TCODE = 5) and Data Read Message (TCODE = 6)
			// Field names follow the emitting arm in ct_L2_nexus_formatter
			// and the sim decoder (tests/lib/ct_nexus_decoder.sv): UADDR /
			// DQDATA (this table said ADDR/DATA before -- debug-name drift,
			// unified 2026-08-04, D-P3-9; the table has no RTL consumer).
			// With DataAddrCompress = XOR the UADDR slot carries the XOR
			// against the previous data-trace message's address; mode FULL
			// (reset) carries the unmodified address.
			NEXUS_MSG_DATA_TRACE_WRITE,
			NEXUS_MSG_DATA_TRACE_READ: begin
				fmt.num_fields = 7;
				fmt.fmt[0] = '{ name: TCODE,     field_type: FIXED,             max_bits: 6 };
				fmt.fmt[1] = '{ name: SRC,       field_type: VENDOR_FIXED,      max_bits: NEXUS_MSG_SOURCE_WIDTH };
				fmt.fmt[2] = '{ name: DSZ,       field_type: VENDOR_FIXED,      max_bits: $bits(nexus_dsz_e) };
				fmt.fmt[3] = '{ name: ELSZ,      field_type: VENDOR_FIXED,      max_bits: $bits(nexus_elsz_e) };
				fmt.fmt[4] = '{ name: UADDR,     field_type: VARIABLE,          max_bits: NEXUS_MSG_ADDRESS_WIDTH };
				fmt.fmt[5] = '{ name: DQDATA,    field_type: VARIABLE,          max_bits: NEXUS_MSG_DATA_WIDTH };
				fmt.fmt[6] = '{ name: TSTAMP,    field_type: VENDOR_VARIABLE,   max_bits: NEXUS_MSG_TSTAMP_WIDTH };
			end

			// 4.3.19 and 4.3.20 Data Trace - Data Write with Sync (TCODE =
			// 13) and Data Read with Sync Message (TCODE = 14): the
			// synchronizing counterparts of 5/6 -- same layout, but the
			// address slot carries the FULL (uncompressed) data address,
			// re-seating the DF XOR reference on both sides, and the TSTAMP
			// is absolute (synchronizing message). Emitted by the formatter
			// as the FIRST DF after a re-anchor event when DataAddrCompress
			// != FULL (P3, CT_EN_DF_ADDR_COMPRESS); msg_gen keeps selecting
			// 5/6 -- the upgrade is a formatter TCODE substitution.
			NEXUS_MSG_DATA_TRACE_WRITE_SYNC,
			NEXUS_MSG_DATA_TRACE_READ_SYNC: begin
				fmt.num_fields = 7;
				fmt.fmt[0] = '{ name: TCODE,     field_type: FIXED,             max_bits: 6 };
				fmt.fmt[1] = '{ name: SRC,       field_type: VENDOR_FIXED,      max_bits: NEXUS_MSG_SOURCE_WIDTH };
				fmt.fmt[2] = '{ name: DSZ,       field_type: VENDOR_FIXED,      max_bits: $bits(nexus_dsz_e) };
				fmt.fmt[3] = '{ name: ELSZ,      field_type: VENDOR_FIXED,      max_bits: $bits(nexus_elsz_e) };
				fmt.fmt[4] = '{ name: ADDR,      field_type: VARIABLE,          max_bits: NEXUS_MSG_ADDRESS_WIDTH };
				fmt.fmt[5] = '{ name: DQDATA,    field_type: VARIABLE,          max_bits: NEXUS_MSG_DATA_WIDTH };
				fmt.fmt[6] = '{ name: TSTAMP,    field_type: VENDOR_VARIABLE,   max_bits: NEXUS_MSG_TSTAMP_WIDTH };
			end

			// Program Trace - Correlation Message (TCODE = 33), N-Trace 1.0
			// Table 24. CTTE emits this only as the "Program Trace
			// Disabled" event (EVCODE=4) on trace-off, carrying the residual
			// ICNT and the pending HIST in the CDATA slot. N-Trace HTM rule:
			// CDF is always 1 and the HIST field is always present (empty
			// history encoded as 0x1).
			NEXUS_MSG_PROGRAM_TRACE_CORRELATION: begin
				fmt.num_fields = 6;
				fmt.fmt[0] = '{ name: TCODE,     field_type: FIXED,             max_bits: 6 };
				fmt.fmt[1] = '{ name: SRC,       field_type: FIXED,             max_bits: NEXUS_MSG_SOURCE_WIDTH };
				fmt.fmt[2] = '{ name: ETYPE,     field_type: VENDOR_FIXED,      max_bits: NEXUS_MSG_EVCODE_WIDTH };  // EVCODE
				fmt.fmt[3] = '{ name: ECODE,     field_type: VENDOR_FIXED,      max_bits: 2 };                       // CDF (always 1, N-Trace HTM rule)
				fmt.fmt[4] = '{ name: ICNT,      field_type: VARIABLE,          max_bits: NEXUS_MSG_I_CNT_WIDTH };
				fmt.fmt[5] = '{ name: RDATA0,    field_type: VENDOR_VARIABLE,   max_bits: NEXUS_MSG_HIST_WIDTH };    // CDATA = HIST (always present, 0x1 when empty)
			end

			// 4.3.2 Device ID Message (TCODE = 1), P4. IEEE-ISTO 5001
			// Table 4-7 lists ID as "Fixed 32"; CTTE emits it
			// VENDOR_VARIABLE (leading-zero suppressed) -- documented
			// deviation, see ct_pkg::CT_EN_DEVICE_ID / trace-format.adoc.
			NEXUS_MSG_DEVICE_ID: begin
				fmt.num_fields = 4;
				fmt.fmt[0] = '{ name: TCODE,     field_type: FIXED,             max_bits: 6 };
				fmt.fmt[1] = '{ name: SRC,       field_type: VENDOR_FIXED,      max_bits: NEXUS_MSG_SOURCE_WIDTH };
				fmt.fmt[2] = '{ name: DEVID,     field_type: VENDOR_VARIABLE,   max_bits: NEXUS_MSG_DEVID_WIDTH };
				fmt.fmt[3] = '{ name: TSTAMP,    field_type: VENDOR_VARIABLE,   max_bits: NEXUS_MSG_TSTAMP_WIDTH };
			end

			// 4.3.23 Watchpoint Message (TCODE = 15), P4. Field order per
			// Table 4-26: TCODE, SRC, WPHIT, TSTAMP. WPHIT is the bitmap of
			// the watchpoints that fired (CTTE: ACT-ST slot bits, masked by
			// trWpMask.WEM).
			NEXUS_MSG_WATCHPOINT: begin
				fmt.num_fields = 4;
				fmt.fmt[0] = '{ name: TCODE,     field_type: FIXED,             max_bits: 6 };
				fmt.fmt[1] = '{ name: SRC,       field_type: VENDOR_FIXED,      max_bits: NEXUS_MSG_SOURCE_WIDTH };
				fmt.fmt[2] = '{ name: WPHIT,     field_type: VENDOR_VARIABLE,   max_bits: NEXUS_MSG_WPHIT_IMPL_WIDTH };
				fmt.fmt[3] = '{ name: TSTAMP,    field_type: VENDOR_VARIABLE,   max_bits: NEXUS_MSG_TSTAMP_WIDTH };
			end

			// 4.3.21 Data Acquisition Message (TCODE = 7)
			NEXUS_MSG_DATA_ACQUISITION: begin
				fmt.num_fields = 5;
				fmt.fmt[0] = '{ name: TCODE,     field_type: FIXED,             max_bits: 6 };
				fmt.fmt[1] = '{ name: SRC,       field_type: FIXED,             max_bits: NEXUS_MSG_SOURCE_WIDTH };
				fmt.fmt[2] = '{ name: IDTAG,     field_type: VENDOR_FIXED,      max_bits: NEXUS_IDTAG_WIDTH };
				fmt.fmt[3] = '{ name: DQDATA,    field_type: VENDOR_VARIABLE,   max_bits: NEXUS_DQDATA_WIDTH };
				fmt.fmt[4] = '{ name: TSTAMP,    field_type: VENDOR_VARIABLE,   max_bits: NEXUS_MSG_TSTAMP_WIDTH };
			end

			default: begin
				// leave num_fields = 0
			end
		endcase

		return fmt;
	endfunction


endpackage : nexus

`default_nettype wire
