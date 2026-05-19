// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @brief RISC-V flavor of the `nexus_vendor` package and the shared `nexus`
 *        package: vendor-specific parameters, message/field widths, TCODE
 *        enums and helper functions used by the ctrace encoder.
 *
 * Copyright (c) 2025 Accemic Technologies GmbH
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 */

package nexus_vendor;
	localparam NEXUS_MSG_SOURCE_WIDTH	= 4;
	localparam NEXUS_MSG_TSTAMP_WIDTH	= 64;
	localparam NEXUS_MSG_MAP_WIDTH		= 1;
	localparam NEXUS_MSG_ADDRESS_WIDTH	= 32;
	
	// Right-shift applied to PC-carrying FADDR / UADDR fields before encoding.
	localparam NEXUS_MSG_PC_ADDR_SHIFT	= 1;
	localparam NEXUS_MSG_DSZ_WIDTH		= 4;
	localparam NEXUS_MSG_ELSZ_WIDTH		= 3;

	localparam NEXUS_MSG_DATA_WIDTH		= 192; // Vendor-specific DAQ messages require > 64 bit
	localparam NEXUS_MSG_I_CNT_WIDTH	= 8;
	localparam NEXUS_MSG_BTYPE_WIDTH	= 2;
	localparam NEXUS_MSG_ID_WIDTH		= 32;

	localparam NEXUS_MSG_DEBUG_STATUS_WIDTH = 16;
	localparam NEXUS_MSG_PROCESS_WIDTH	= 44;

	localparam NEXUS_MSG_ECODE_WIDTH	= 8;

	localparam NEXUS_MSG_SYNC_I_CNT_WIDTH= 1;
	localparam NEXUS_MSG_WPHIT_WIDTH	= 32;

	localparam NEXUS_MSG_RCODE_WIDTH	= 4;
	localparam NEXUS_MSG_RDATA_WIDTH	= 30;

	localparam NEXUS_MSG_HIST_WIDTH		= 30;

	localparam NEXUS_MSG_EVCODE_WIDTH	= 4;
	localparam NEXUS_MSG_CDATA_WIDTH	= 30;

	localparam NEXUS_MSG_CKSRC_WIDTH	= 0;
	localparam NEXUS_MSG_CKDF_WIDTH		= 0;
	localparam NEXUS_MSG_CKDATA_WIDTH	= 128;
	localparam NEXUS_MSG_SYNC_REASON_WIDTH	= 4;

	localparam NEXUS_MSG_XMAP_WIDTH		= 1;
	localparam NEXUS_AUX_ADDRESS_WIDTH	= 1;

	localparam NEXUS_MSG_ST_WIDTH	     = 2;

	localparam NEXUS_DQDATA_WIDTH 		= NEXUS_MSG_DATA_WIDTH;
	localparam NEXUS_IDTAG_WIDTH 		= 12;

	localparam NEXUS_MAX_DATA_SIZE	  	= NEXUS_MSG_CKDATA_WIDTH+NEXUS_MSG_CKSRC_WIDTH+NEXUS_MSG_CKDF_WIDTH;

	localparam MAX_ICT_DATA_FIELDS		= 3; // CDM Including Cycles
	localparam NEXUS_MAX_PACKET_WIDTH 	= 32; // CDM Data
	localparam NEXUS_MAX_FIELD_DATA_WIDTH = (NEXUS_MSG_DATA_WIDTH > NEXUS_MSG_CKDATA_WIDTH) ? NEXUS_MSG_DATA_WIDTH : NEXUS_MSG_CKDATA_WIDTH;
	localparam NEXUS_MSG_SUB_WIDTH		= NEXUS_MSG_DSZ_WIDTH + NEXUS_MSG_ELSZ_WIDTH + NEXUS_MSG_ADDRESS_WIDTH + NEXUS_MSG_DATA_WIDTH;
	localparam NEXUS_MAX_HIST_DATA_WIDTH = 32;

	localparam NEXUS_MAX_PACKET_COUNT 	= 5;//Indirect branch history with sync

	localparam NEXUS_MAX_FIELDS			= 10;	// max # of fields within a nexus message
	localparam NEXUS_MAX_PARALLEL_MSG	= 3;	// max # of messages generated per TIP
	localparam NEXUS_MDO_WIDTH			= 6; 	// 6, 14 and 30 is supported
//	localparam NEXUS_CHUNK_BYTES		= (NEXUS_MDO_WIDTH+2)/8;
	localparam NEXUS_CHUNK_WIDTH		= NEXUS_MDO_WIDTH + 2;
	localparam NEXUS_MAX_CHUNKS			= 20;	// max # of chunks per message (chank consists of 6, 14, or 30 MDO bits and 2 MSEO bits)
	localparam ICNT_THRESHOLD			= 32'h10000000;

	localparam CSR_ACT_CAP_BASE			= 32'h0B10; 			// CSR ID of ACT_CAP CSR range (EMSA5: 0xB10 – 0xB9F)
	localparam CSR_CT_ACT_CAP_WIDTH 	= 32;

	localparam ACT_CAP_CMD            	= CSR_ACT_CAP_BASE + 0;

	typedef logic [NEXUS_MSG_SOURCE_WIDTH-1:0]	nexus_src_t;
	typedef logic [NEXUS_MSG_ECODE_WIDTH-1:0] 	nexus_vendor_ecode_t;
	typedef logic [NEXUS_MSG_ADDRESS_WIDTH-1:0]	nexus_addr_t;
	typedef logic [NEXUS_MSG_I_CNT_WIDTH-1:0]	nexus_icnt_t;
	typedef logic [NEXUS_IDTAG_WIDTH-1:0]		nexus_idtag_t;
	typedef logic [NEXUS_MSG_RDATA_WIDTH-1:0]	nexus_rdata_t;
	typedef logic [NEXUS_MSG_TSTAMP_WIDTH-1:0]	nexus_ts_t;

endpackage : nexus_vendor

package nexus;

	import nexus_vendor::*;

	typedef enum logic [2:0]{
		NEXUS_STATE_IDLE 	 	=0,
		NEXUS_STATE_START_MSG  	=1,
		NEXUS_STATE_NORMAL 	 	=2,
		NEXUS_STATE_END_PACKET 	=3,
		NEXUS_STATE_END_MSG 	=4
	} nexus_mseo_state_e;

	typedef enum logic [5:0]{
		NEXUS_MSG_DEBUG_STATUS							=6'd0,
		NEXUS_MSG_DEVICE_ID								=6'd1,
		NEXUS_MSG_OWNERSHIP_TRACE						=6'd2,
		NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH			=6'd3,
		NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH			=6'd4,
		NEXUS_MSG_DATA_TRACE_WRITE						=6'd5,
		NEXUS_MSG_DATA_TRACE_READ						=6'd6,
		NEXUS_MSG_DATA_ACQUISITION						=6'd7,
		NEXUS_MSG_ERROR									=6'd8,

		NEXUS_MSG_PROGRAM_TRACE_SYNC					=6'd9,
		NEXUS_MSG_PROGRAM_TRACE_CORRECTION				=6'd10,
		NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH_SYNC		=6'd11,
		NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_SYNC	=6'd12,

		NEXUS_MSG_DATA_TRACE_WRITE_SYNC					=6'd13,
		NEXUS_MSG_DATA_TRACE_READ_SYNC					=6'd14,

		NEXUS_MSG_WATCHPOINT							=6'd15,

		NEXUS_MSG_PORT_REPLACEMENT_OUT					=6'd20,
		NEXUS_MSG_PORT_REPLACEMENT_IN					=6'd21,

		NEXUS_MSG_AUX_READ								=6'd22,
		NEXUS_MSG_AUX_WRITE								=6'd23,
		NEXUS_MSG_AUX_READ_NEXT							=6'd24,
		NEXUS_MSG_AUX_WRITE_NEXT						=6'd25,
		NEXUS_MSG_AUX_RESPONSE							=6'd26,

		NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL			=6'd27,
		NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY	=6'd28,
		NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY_SYNC	=6'd29,
		NEXUS_MSG_PROGRAM_TRACE_REPEAT_BRANCH			=6'd30,
		NEXUS_MSG_PROGRAM_TRACE_REPEAT_INSTRUCTION		=6'd31,
		NEXUS_MSG_PROGRAM_TRACE_REPEAT_INSTRUCTION_SYNC	=6'd32,
		NEXUS_MSG_PROGRAM_TRACE_CORRELATION				=6'd33,

		NEXUS_MSG_INCIRCUIT_TRACE						=6'd34,
		NEXUS_MSG_INCIRCUIT_TRACE_SYNC					=6'd35,
		NEXUS_MSG_FLUSH									=6'd36,		// 'h24: internal use only for signalling flush		Msg consists of TCODE only
//	 	NEXUS_MSG_VENDOR_1_START						=6'd56,
		NEXUS_MSG_VENDOR_CONFIG							=6'd56,		// vendor specific message providing the trace encoder configuration to the decoding device
		NEXUS_MSG_VENDOR_1_END							=6'd62,
		NEXUS_MSG_VENDOR_EXT							=6'd63
	} nexus_tcode_e;

	typedef enum logic [NEXUS_MSG_SYNC_REASON_WIDTH-1:0]{		// link:../../references/84_IEEE-ISTO-5001-2012-v3.0.1-Nexus-Standard.pdf#page=51
		NEXUS_SYNC_EVTI		 				=  0, //4'b0000,	// External Trace Trigger
		NEXUS_SYNC_EXIT_FROM_SYS_RST		=  1, //4'b0001,	// Exit from Reset
		NEXUS_SYNC_PERIODIC					=  2, //4'b0010,	// Periodic Synchronization *implemented*
		NEXUS_SYNC_EXIT_FROM_DEBUG			=  3, //4'b0011,	// Exit from Debug Mode
		NEXUS_SYNC_SEQ_INSTR_COUNTER		=  4, //4'b0100,	// Sequential Instruction Counter (I-CNT overflow)
		NEXUS_SYNC_TRACE_ENABLE				=  5, //4'b0101,	// Trace Enable *implemented*
		NEXUS_SYNC_WATCHPOINT				=  6, //4'b0110,	// Trace Event
		NEXUS_SYNC_FIFO_OVERRUN				=  7, //4'b0111,	// Restart from FIFO overrun
		NEXUS_SYNC_RESERVED_0				=  8, //4'b1000,	// (Reserved)
		NEXUS_SYNC_EXIT_FROM_POWERDOWN		=  9, //4'b1001,	// Exit from Powerdown
		NEXUS_SYNC_RESERVED_1				= 10, //4'b1010,	// (Reserved)
		NEXUS_SYNC_MSG_CONTENTION			= 11, //4'b1011,	// Contention with higher priority messages caused message(s) to be lost
		NEXUS_SYNC_REQ_CSR					= 12, //4'b1100,	// (Reserved) 		C-Trace commercial: Synq request via CSR
		NEXUS_SYNC_REQ_ATB					= 13, //4'b1101,	// (Reserved)		C-Trace commercial: Synq request via APB
		NEXUS_SYNC_TRACE_QUOTA				= 14, //4'b1110,	// (Vendor Defined)	C-Trace commercial: Synq request due to trace quota limit (# of trace messages / # of trace bytes)
		NEXUS_SYNC_NONE						= 15  //4'b1111		// (Vendor Defined)	for better self-explaining code
	} nexus_sync_reason_e;

	typedef enum logic [NEXUS_MSG_RCODE_WIDTH-1:0]	{			// link:../../references/84_IEEE-ISTO-5001-2012-v3.0.1-Nexus-Standard.pdf#page=53
		NEXUS_RCODE_ICNT_OVERFLOW			=  0, //4'b0000,
		NEXUS_RCODE_HIST_OVERFLOW			=  1, //4'b0001,
		NEXUS_RCODE_HIST_OVERFLOW_REPEATED	=  2, //4'b0010,	// link:../../references/147_RISC-V-N-Trace-Specification.pdr#page=27
		NEXUS_RCODE_NONE					= 15  //4'b1111		// for debug
	} nexus_rcode_e;

	typedef enum logic [NEXUS_MSG_BTYPE_WIDTH-1:0]{				// link:../../references/84_IEEE-ISTO-5001-2012-v3.0.1-Nexus-Standard.pdf#page=51
		NEXUS_BTYPE_IBRANCH					=  0, //2'b00,
		NEXUS_BTYPE_EXCEPTION_INTERRUPT		=  1, //2'b01,
		NEXUS_BTYPE_EXCEPTION				=  2, //2'b10,
		NEXUS_BTYPE_INTERRUPT				=  3  //2'b11
	} nexus_btype_e;

	// Ownership Message Fields
	typedef enum logic [1:0]{									// link:../../references/147_RISC-V-N-Trace-Specification.pdr#page=24
		CONTEXT_V_PRV						= 0,
		CONTEXT_SCONTEXT					= 2,
		CONTEXT_HCONTEXT					= 3
	} nexus_context_format_e;

	typedef enum logic [1:0]{									// link:../../references/147_RISC-V-N-Trace-Specification.pdr#page=24
		CONTEXT_PRV_U						= 0,
		CONTEXT_PRV_S						= 1,
		CONTEXT_PRV_M						= 3
	} nexus_context_prv_e;

	typedef struct packed {
		logic [NEXUS_MSG_PROCESS_WIDTH-1:0]	_context;	// 44
		logic								v;			// 1
		nexus_context_prv_e					prv;		// 2
		nexus_context_format_e				format;		// 2
	} nexus_process_t;									// 49

	typedef enum logic [NEXUS_MSG_DSZ_WIDTH-1:0]{				// link:../../references/84_IEEE-ISTO-5001-2012-v3.0.1-Nexus-Standard.pdf#page=63
		NEXUS_DSZ_0						=  0, //4'b0000,		// 0-byte (Implied data instructions may support a “zero-data” size)
		NEXUS_DSZ_1						=  1, //4'b0001,		// 1-byte
		NEXUS_DSZ_2						=  2, //4'b0010,		// 2-byte / halfword
		NEXUS_DSZ_3						=  3, //4'b0011,		// 3-byte / string
		NEXUS_DSZ_4						=  4, //4'b0100,		// 4-byte / word
	//	NEXUS_DSZ_5						=  5, //4'b0101,		// 5-byte / Mis-aligned accesses
	//	NEXUS_DSZ_6						=  6, //4'b0110,		// 6-byte / Mis-aligned accesses
	//	NEXUS_DSZ_7						=  7, //4'b0111,		// 7-byte / Mis-aligned accesses
		NEXUS_DSZ_8						=  8  //4'b1000			// 64-bit / double
	//	NEXUS_DSZ_16					=  9, //4'b1001,		// 16-byte
	//	NEXUS_DSZ_32					= 10, //4'b1010,		// 32-byte
	//	NEXUS_DSZ_64					= 11  //4'b1011			// 64-byte
	} nexus_dsz_e;

	typedef enum logic [NEXUS_MSG_ELSZ_WIDTH-1:0]{				// link:../../references/84_IEEE-ISTO-5001-2012-v3.0.1-Nexus-Standard.pdf#page=64
		NEXUS_ELSZ_DSZ					=  0, //3'b000,			// 0-byte (Implied data instructions may support a “zero-data” size)
		NEXUS_ELSZ_1					=  1, //3'b001,			// 1-byte
		NEXUS_ELSZ_2					=  2, //3'b010,			// 2-byte / halfword
		NEXUS_ELSZ_4					=  3, //3'b011,			// 4-byte / word
		NEXUS_ELSZ_8					=  4  //3'b100			// 64-bit / double
//		NEXUS_ELSZ_16					=  5  //3'b101			// 16-byte
	} nexus_elsz_e;

	typedef enum logic [3:0] {
		NEXUS_ETYPE_QUEUE_OVERRUN		= 4'h0,					// Queue Overrun caused messages (one or more) to be lost
		NEXUS_ETYPE_HIGH_PRIO			= 4'h1					// Contention with higher priority messages caused message(s) to be lost
	} nexus_etype_e;

/*	typedef enum logic [NEXUS_MSG_ECODE_WIDTH-1:0] {		// 8
		NEXUS_ECODE_NONE                = 8'b00000000,
		NEXUS_ECODE_WATCHPOINT_MSG_LOST	= 8'bXXXXXXX1,			// Watchpoint Message(s) lost (one or more)
		NEXUS_ECODE_DF_MSG_LOST  		= 8'bXXXXXX1X,			// Data Trace Message(s) lost
		NEXUS_ECODE_CF_MSG_LOST  		= 8'bXXXXX1XX,			// Program Trace Message(s) lost
		NEXUS_ECODE_OWNERSHIP_MSG_LOST  = 8'bXXXX1XXX,			// Ownership Trace Message(s) lost
		NEXUS_ECODE_STATUS_MSG_LOST  	= 8'bXXX1XXXX,			// Status Message(s) lost (i.e. Debug Status)
		NEXUS_ECODE_DAQ_MSG_LOST  		= 8'bXX1XXXXX,			// Data Acquisition Message(s) lost
		NEXUS_ECODE_ICE_MSG_LOST  		= 8'bX1XXXXXX,			// In-Circuit Trace Message(s) lost
		NEXUS_ECODE_VENDOR_MSG_LOST  	= 8'b1XXXXXXX			// Vendor Defined Message(s) lost
	} nexus_ecode_e;
*/
	localparam NEXUS_ECODE_WATCHPOINT_MSG_LOST	= 8'b00000001;
	localparam NEXUS_ECODE_DF_MSG_LOST  		= 8'b00000010;
	localparam NEXUS_ECODE_CF_MSG_LOST  		= 8'b00000100;
	localparam NEXUS_ECODE_OWNERSHIP_MSG_LOST   = 8'b00001000;
	localparam NEXUS_ECODE_STATUS_MSG_LOST  	= 8'b00010000;
	localparam NEXUS_ECODE_DAQ_MSG_LOST  		= 8'b00100000;
	localparam NEXUS_ECODE_ICE_MSG_LOST  		= 8'b01000000;
	localparam NEXUS_ECODE_VENDOR_MSG_LOST  	= 8'b10000000;

	// Non-optimized generic trace message format for control flow (in accordance with Nexus)
	typedef struct packed {
		nexus_sync_reason_e							sync_reason;//   4
		nexus_btype_e								btype;		//   2
		nexus_rcode_e								rcode;		//   4
		nexus_addr_t 								curr_iaddr;	//  32
		nexus_addr_t 								next_iaddr;	//  32
		nexus_icnt_t					 			icnt;		//   8
		nexus_rdata_t								rdata0;		//  30
		nexus_rdata_t								rdata1;		//  30
		logic [NEXUS_MSG_SUB_WIDTH-(  $bits(nexus_sync_reason_e)
									+ $bits(nexus_btype_e)
									+ $bits(nexus_rcode_e)
									+ $bits(nexus_addr_t)
									+ $bits(nexus_addr_t)
									+ $bits(nexus_icnt_t)
									+ $bits(nexus_rdata_t)
									+ $bits(nexus_rdata_t))-1:0]	_pad;
	} nexus_cf_msg_struct_t;									// NEXUS_MSG_SUB_WIDTH

	// Non-optimized generic trace message format for data flow and data acquisition message (in accordance with Nexus)
	typedef struct packed {
		nexus_dsz_e									dsz; 		//   4   Data Size (size of the write/read)
		nexus_elsz_e								elsz; 		//   3   Element Size (size of the element within the data access)
		nexus_addr_t								addr_idtag;	//  32   F-ADDR or U-ADDR (according to tcode)
		logic [NEXUS_MSG_DATA_WIDTH-1:0] 			data;		// NEXUS_MSG_DATA_WIDTH
	} nexus_df_daq_msg_struct_t;								// NEXUS_MSG_SUB_WIDTH

	// Non-optimized generic trace message format for error message (in accordance with Nexus)
	typedef struct packed {
		nexus_etype_e								etype; 		//   4   Error Types
		nexus_vendor_ecode_t						ecode; 		//   8   Error Codes
		logic [NEXUS_MSG_SUB_WIDTH-($bits(nexus_etype_e) + $bits(nexus_vendor_ecode_t))-1:0] _pad;
	} nexus_error_msg_struct_t;									// NEXUS_MSG_SUB_WIDTH

	// Non-optimized generic trace message format for other messages (in accordance with Nexus)
	typedef struct packed {
		nexus_process_t								_process;	//  49
			logic [NEXUS_MSG_SUB_WIDTH-$bits(nexus_process_t)-1:0] _pad;
		} nexus_other_msg_struct_t;									// NEXUS_MSG_SUB_WIDTH

	typedef struct packed
	{	ct_pkg::ct_sub_type_e			sub_type;
		nexus_tcode_e 					tcode;
		logic[63:0]						ts;
		logic[31:0]						id; 		// # of messages, for debug
		union packed {
			nexus_cf_msg_struct_t		cf;
			nexus_df_daq_msg_struct_t	df_daq;
			nexus_error_msg_struct_t	err;
			nexus_other_msg_struct_t	other;
		}								sub;
	} nexus_msg_struct_t;

	typedef enum logic [2:0]{
		FIELD_INVALID		= 3'h0,  	// field not valid
		VENDOR_FIXED		= 3'h1,
		VENDOR_VARIABLE		= 3'h2,
		VARIABLE			= 3'h3,
		FIXED				= 3'h4
	} nexus_field_type_e;

	typedef enum logic [5:0]{			// for debug
		INVALID 			= 6'h00,
		TCODE				= 6'h01,
		SRC					= 6'h02,
		SYNC				= 6'h03,
		ICNT				= 6'h04,
		PC_FADDR			= 6'h05,
		TSTAMP				= 6'h06,
		BTYPE				= 6'h07,
		UADDR				= 6'h08,
		RCODE				= 6'h09,
		RDATA0				= 6'h0A,
		RDATA1				= 6'h0B,
		DSZ					= 6'h0C,
		ELSZ				= 6'h0D,
		IDTAG 				= 6'h0E,
		ADDR 				= 6'h0F,
		DATA				= 6'h10,
		DQDATA				= 6'h11,
		ETYPE				= 6'h12,
		ECODE				= 6'h13,
		PROCESS				= 6'h14,
		INST_MODE			= 6'h15,
		SYNC_MODE			= 6'h16,
		TS_ACTIVE			= 6'h17,
		TS_TYPE				= 6'h18,
		STATUS				= 6'h19,
		X                   = 6'h20
	} nexus_field_name_e;

	// link:../../references/147_RISC-V-N-Trace-Specification.pdr#page=11
	// link:../../references/84_IEEE-ISTO-5001-2012-v3.0.1-Nexus-Standard.pdf#page=77
	typedef enum logic [1:0]{						// for debug
		START_TRANSMISSION	= 2'b00,				// The first byte of a message sends the LSBs of the message and is indicated by MSEO[1:0]=00.
													// Bytes occupied by fixed-length fields and initial parts of longer variable-length fields are sent using MSEO[1:0]=00.
		END_IDLE			= 2'b11,				// The last byte of a message is indicated by MSEO[1:0]=11.
													// It also implies an end of the last (fixed-length or variable-lenght) field of a message.
													// Idle bytes (between messages or used as padding) are indicated by MSEO[1:0]=11 and MDO[5:0]=111111 (entire byte is 0xFF).
		VAR					= 2'b01,				// The last byte of a variable-length field is indicated by MSEO[1:0]=01.
		RES					= 2'b10					// Value of MSEO[1:0]=10 is reserved for future extensions.
	} nexus_mseo_e;

	typedef struct packed {
		nexus_field_name_e								name; // for debug only
		nexus_field_type_e								field_type;
		logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0]			data;
		logic [$clog2(NEXUS_MAX_FIELD_DATA_WIDTH):0]	data_width;
	} nexus_field_t;

	typedef struct packed {
		logic [NEXUS_MDO_WIDTH-1 :0]					mdo;
		nexus_mseo_e									mseo;
	} nexus_chunk_t;

	typedef struct packed {
		nexus_field_t	 [NEXUS_MAX_FIELDS-1:0]			fields;
//		nexus_mdo_mseo_t [NEXUS_MAX_MSG_BYTES-1:0]		data;
//		logic[$clog2(NEXUS_MAX_MSG_BYTES+1)-1:0]		data_length;	// # of nexus_mdo_mseo_t
		logic[31:0]										id; 			// id of corresponding trace message, for debug
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

	function logic[31:0] GetUaddr(input logic[31:0] curr_iaddr, logic[31:0] ref_addr);
		return (curr_iaddr ^ ref_addr);
	endfunction

	// data trace functions

	function nexus_dsz_e GetDsz(logic [7:0] dsize);
	// data access size is 2^dsize bytes
		case (dsize)
			0: return NEXUS_DSZ_1;
			1: return NEXUS_DSZ_2;
			2: return NEXUS_DSZ_4;
			3: return NEXUS_DSZ_8;
//			4: return NEXUS_DSZ_16;
//			5: return NEXUS_DSZ_32;
//			6: return NEXUS_DSZ_64;
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
//			4: return NEXUS_ELSZ_16;
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
		if (tcode == NEXUS_MSG_PROGRAM_TRACE_SYNC) 							return 1;
		if (tcode == NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH_SYNC) 			return 1;
		if (tcode == NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_SYNC) 			return 1;
		if (tcode == NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY_SYNC) 	return 1;
		if (tcode == NEXUS_MSG_PROGRAM_TRACE_REPEAT_INSTRUCTION_SYNC) 		return 1;
		if (tcode == NEXUS_MSG_INCIRCUIT_TRACE_SYNC) 						return 1;
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
				fmt.fmt[0] = '{ name: TCODE,     field_type: FIXED,    			max_bits: 6 };
				fmt.fmt[1] = '{ name: SRC,       field_type: FIXED,    			max_bits: NEXUS_MSG_SOURCE_WIDTH };
				fmt.fmt[2] = '{ name: SYNC,      field_type: FIXED,    			max_bits: $bits(nexus_sync_reason_e)};
				fmt.fmt[3] = '{ name: ICNT,      field_type: VARIABLE, 			max_bits: NEXUS_MSG_I_CNT_WIDTH };
				fmt.fmt[4] = '{ name: PC_FADDR,  field_type: VARIABLE, 			max_bits: NEXUS_MSG_ADDRESS_WIDTH };
				fmt.fmt[5] = '{ name: TSTAMP,    field_type: VENDOR_VARIABLE, 	max_bits: NEXUS_MSG_TSTAMP_WIDTH };
			end

			// 4.3.17 and 4.3.18 Data Trace - Data Write Message (TCODE = 5) and Data Read Message (TCODE = 6)
			NEXUS_MSG_DATA_TRACE_WRITE,
			NEXUS_MSG_DATA_TRACE_READ: begin
				fmt.num_fields = 7;
				fmt.fmt[0] = '{ name: TCODE,     field_type: FIXED,    			max_bits: 6 };
				fmt.fmt[1] = '{ name: SRC,       field_type: VENDOR_FIXED, 		max_bits: NEXUS_MSG_SOURCE_WIDTH };
				fmt.fmt[2] = '{ name: DSZ,       field_type: VENDOR_FIXED, 		max_bits: $bits(nexus_dsz_e) };
				fmt.fmt[3] = '{ name: ELSZ,      field_type: VENDOR_FIXED, 		max_bits: $bits(nexus_elsz_e) };
				fmt.fmt[4] = '{ name: ADDR,      field_type: VARIABLE, 			max_bits: NEXUS_MSG_ADDRESS_WIDTH };
				fmt.fmt[5] = '{ name: DATA,      field_type: VARIABLE, 			max_bits: NEXUS_MSG_DATA_WIDTH };
				fmt.fmt[6] = '{ name: TSTAMP,    field_type: VENDOR_VARIABLE, 	max_bits: NEXUS_MSG_TSTAMP_WIDTH };
			end

			// 4.3.21 Data Acquisition Message (TCODE = 7)
			NEXUS_MSG_DATA_ACQUISITION: begin
				fmt.num_fields = 5;
				fmt.fmt[0] = '{ name: TCODE,     field_type: FIXED,    			max_bits: 6 };
				fmt.fmt[1] = '{ name: SRC,       field_type: FIXED,    			max_bits: NEXUS_MSG_SOURCE_WIDTH };
				fmt.fmt[2] = '{ name: IDTAG,     field_type: VENDOR_FIXED,  	max_bits: NEXUS_IDTAG_WIDTH };
				fmt.fmt[3] = '{ name: DQDATA,    field_type: VENDOR_VARIABLE, 	max_bits: NEXUS_DQDATA_WIDTH };
				fmt.fmt[4] = '{ name: TSTAMP,    field_type: VENDOR_VARIABLE, 	max_bits: NEXUS_MSG_TSTAMP_WIDTH };
			end

			default: begin
				// leave num_fields = 0
			end
		endcase

		return fmt;
	endfunction


endpackage : nexus



/*
		// 4.3.1 Debug Status Message (TCODE = 0)
		NEXUS_MSG_DEBUG_STATUS: begin
			fmt.num_fields = 2;
			fmt.fmt[0] = '{ name: TCODE,    field_type: FIXED,    max_bits: 6 };
			fmt.fmt[1] = '{ name: SRC,    field_type: VENDOR_FIXED, max_bits: <src_width> };
			fmt.fmt[2] = '{ name: STATUS,       field_type: VENDOR_FIXED,    max_bits: 32 };
			fmt.fmt[3] = '{ name: TSTAMP,   field_type: VARIABLE, max_bits: nexus_vendor::NEXUS_MSG_TSTAMP_WIDTH };
		end

		// 4.3.2 Device ID Message (TCODE = 1)
		NEXUS_MSG_DEVICE_ID: begin
			fmt.num_fields = 2;
			fmt.fmt[0] = '{ name: TCODE,    field_type: FIXED,    max_bits: 6 };
			fmt.fmt[1] = '{ name: ID,       field_type: FIXED,    max_bits: 32 };
		end

		// 4.3.3 Ownership Trace Message (TCODE = 2)
		NEXUS_MSG_OWNERSHIP_TRACE: begin
			fmt.num_fields = 4;
			fmt.fmt[0] = '{ name: TCODE,    field_type: FIXED,    max_bits: 6 };
			fmt.fmt[1] = '{ name: SRC,      field_type: VENDOR_FIXED, max_bits: <src_width> };
			fmt.fmt[2] = '{ name: PROCESS,  field_type: VARIABLE, max_bits: <process_id_width> };
			fmt.fmt[3] = '{ name: TSTAMP,   field_type: VARIABLE, max_bits: nexus_vendor::NEXUS_MSG_TSTAMP_WIDTH };
		end

		// 4.3.4 Program Trace - Direct Branch Message (TCODE = 3)
		NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH: begin
			fmt.num_fields = 5;
			fmt.fmt[0] = '{ name: TCODE,    field_type: FIXED,    max_bits: 6 };
			fmt.fmt[1] = '{ name: SRC,      field_type: VENDOR_FIXED, max_bits: <src_width> };
			fmt.fmt[2] = '{ name: MAP,      field_type: VENDOR_FIXED, max_bits: <map_width> };
			fmt.fmt[3] = '{ name: ICNT,     field_type: VARIABLE, max_bits: nexus_vendor::NEXUS_MSG_I_CNT_WIDTH };
			fmt.fmt[4] = '{ name: TSTAMP,   field_type: VARIABLE, max_bits: nexus_vendor::NEXUS_MSG_TSTAMP_WIDTH };
		end

		// 4.3.5 Program Trace - Indirect Branch Message (TCODE = 4)
		NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH: begin
			fmt.num_fields = 8;
			fmt.fmt[0] = '{ name: TCODE,    field_type: FIXED,    max_bits: 6 };
			fmt.fmt[1] = '{ name: SRC,      field_type: VENDOR_FIXED, max_bits: <src_width> };
			fmt.fmt[2] = '{ name: MAP,      field_type: VENDOR_FIXED, max_bits: <map_width> };
			fmt.fmt[3] = '{ name: B_TYPE,   field_type: VENDOR_FIXED, max_bits: 2 };
			fmt.fmt[4] = '{ name: ICNT,     field_type: VARIABLE, max_bits: nexus_vendor::NEXUS_MSG_I_CNT_WIDTH };
			fmt.fmt[5] = '{ name: U_ADDR,   field_type: VARIABLE, max_bits: nexus_vendor::NEXUS_MSG_ADDRESS_WIDTH };
			fmt.fmt[6] = '{ name: TSTAMP,   field_type: VARIABLE, max_bits: nexus_vendor::NEXUS_MSG_TSTAMP_WIDTH };
			// Optional vendor fixed/variable fields can be appended here as needed
		end

		// 4.3.9 Program Trace - Synchronization Message (TCODE = 9)
		NEXUS_MSG_PROGRAM_TRACE_SYNC: begin
			fmt.num_fields = 6;
			fmt.fmt[0] = '{ name: TCODE,    field_type: FIXED,    max_bits: 6 };
			fmt.fmt[1] = '{ name: SRC,      field_type: VENDOR_FIXED, max_bits: <src_width> };
			fmt.fmt[2] = '{ name: SYNC,     field_type: VENDOR_FIXED, max_bits: 4 };
			fmt.fmt[3] = '{ name: ICNT,     field_type: VARIABLE, max_bits: nexus_vendor::NEXUS_MSG_I_CNT_WIDTH };
			fmt.fmt[4] = '{ name: PC1,      field_type: VARIABLE, max_bits: nexus_vendor::NEXUS_MSG_ADDRESS_WIDTH };
			fmt.fmt[5] = '{ name: TSTAMP,   field_type: VARIABLE, max_bits: nexus_vendor::NEXUS_MSG_TSTAMP_WIDTH };
		end


		// 4.3.22 Error Message (TCODE = 8)
		NEXUS_MSG_ERROR: begin
			fmt.num_fields = 6;
			fmt.fmt[0] = '{ name: TCODE,  field_type: FIXED,    max_bits: 6 };
			fmt.fmt[1] = '{ name: SRC,    field_type: VENDOR_FIXED, max_bits: <src_width> };
			fmt.fmt[2] = '{ name: ETYPE,  field_type: FIXED,    max_bits: 4 };
			fmt.fmt[3] = '{ name: ECODE,  field_type: VENDOR_FIXED, max_bits: 12 };
			fmt.fmt[4] = '{ name: TSTAMP, field_type: VARIABLE, max_bits: nexus_vendor::NEXUS_MSG_TSTAMP_WIDTH };
			// Possible reserved/vendor-defined fields
		end
*/
