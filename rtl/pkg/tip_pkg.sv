// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
* Copyright (c) 2023 by Accemic Technologies GmbH Kiefersfelden Germany
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @author   Alexander Weiss <aweiss@accemic.com>
* @author	Albert Schulz <aschulz@accemic.com>
* @author	Alexander Lange <alange@accemic.com>
*
* @brief    TIP (Trace Ingress Port) Package
*/

package tip_pkg;

	import nexus::*;
	import nexus_vendor::*;
	import ct_cs_cpuif_pkg::*;
	import ct_cs_cpuif_types_pkg::*;

	localparam TIP_ITYPE_WIDTH		=  4;			// width of the itype bus
	localparam TIP_ICAUSE_WIDTH		=  4;			// width of the interrupt cause bus
	localparam TIP_ECAUSE_WIDTH		=  4;			// width of the exception cause bus
	localparam TIP_IADDRESS_WIDTH	= 32;			// width of the instruction address bus
	localparam TIP_PRIVILEGE_WIDTH	=  3;			// width of the privilege bus
	localparam TIP_CONTEXT_WIDTH	=  2;			// width of the context bus
	localparam TIP_TIME_WIDTH		= 64;			// width of the time bus
	localparam TIP_CTYPE_WIDTH		=  2;			// width of the ctype bus
	localparam TIP_IRETIRE_WIDTH	=  1;			// width of the iretire bus
	localparam TIP_ILASTSIZE_WIDTH	=  2;			// width of the ilastsize bus
	localparam TIP_ICNT_WIDTH		= 32;			// width of i-cnt
	localparam TIP_IMPDEF_WIDTH		=  8;			// width of implementation-specific sideband channels
	localparam TIP_DRETIRE_WIDTH	=  1;
	localparam TIP_DTYPE_WIDTH		=  4;
	localparam TIP_DADDRESS_WIDTH	= 32;
	localparam TIP_DSIZE_WIDTH	 	=  6;
	localparam TIP_DATA_WIDTH	 	= 64;
	localparam TIP_IADDR_LSBS_WIDTH	=  8;
	localparam TIP_DBLOCK_WIDTH		=  8;
	localparam TIP_LRID_WIDTH		=  8;
	localparam TIP_LRESP_WIDTH		=  2;
	localparam TIP_SDATA_WIDTH		= 32;
	localparam TIP_LDATA_WIDTH		= 32;
	localparam TIP_ISYNC_MAX_WIDTH  =  4;
	localparam PERFCOUNTER_WIDTH		 = 32;

	localparam TIP_DEFAULT_IADDR           = 32'h1ADD_0000;
	localparam TIP_DEFAULT_DADDR           = 32'hDADD_0000;
	localparam TIP_DEFAULT_DATA            = 64'h1111_2222_DA7A_0000;
	localparam TIP_DEFAULT_CONTEXT         = 32'hDEFA_0000;
	localparam TIP_DEFAULT_ILASTSIZE       = 2;


	typedef logic [TIP_DADDRESS_WIDTH-1:0]  	tip_daddr_t;
	typedef logic [TIP_IADDRESS_WIDTH-1:0]  	tip_iaddr_t;
	typedef logic [TIP_DATA_WIDTH-1:0]  		tip_data_t;
	typedef logic [TIP_DSIZE_WIDTH-1:0]  		tip_dsize_t;
	typedef logic [TIP_PRIVILEGE_WIDTH-1:0]  	tip_priv_t;
	typedef logic [TIP_CONTEXT_WIDTH-1:0]  		tip_context_t;
	typedef logic [TIP_TIME_WIDTH-1:0]  		tip_time_t;
	typedef logic [TIP_ICNT_WIDTH-1:0]  		tip_icnt_t;
	typedef logic [TIP_CTYPE_WIDTH-1:0]  		tip_ctype_t;
	typedef logic [TIP_IRETIRE_WIDTH-1:0]  		tip_iretire_t;
	typedef logic [TIP_DRETIRE_WIDTH-1:0]  		tip_dretire_t;
	typedef logic [TIP_ILASTSIZE_WIDTH-1:0]  	tip_ilastsize_t;
	typedef logic [TIP_IMPDEF_WIDTH-1:0]  		tip_impdef_t;
	typedef logic [TIP_ECAUSE_WIDTH-1:0]  		tip_ecause_t;
	typedef logic [31:0]   						tip_ecause_vector_t;  // in default configuration only bits 0..15 are used.
	typedef logic [TIP_DTYPE_WIDTH-1:0]  		tip_dtype_t;
	typedef logic [TIP_ISYNC_MAX_WIDTH-1:0]		tip_isync_max_t;

	typedef struct packed {								// merge DType and DSize for ETIP and AXIS composer
		tip_dtype_t    			Dtype;
		tip_dsize_t             DSize;
	}  tip_dtype_dsize_t;

	localparam TIP_XADDR_WIDTH   		 = (TIP_IADDRESS_WIDTH > TIP_DADDRESS_WIDTH) ? TIP_IADDRESS_WIDTH : TIP_DADDRESS_WIDTH;
	localparam TIP_XADDR_DATA_WIDTH_TEMP = (TIP_XADDR_WIDTH > TIP_DATA_WIDTH)     ? TIP_XADDR_WIDTH : TIP_DATA_WIDTH;
	localparam TIP_XADDR_DATA_WIDTH		 = (TIP_XADDR_DATA_WIDTH_TEMP > $bits(tip_dtype_dsize_t)) ? TIP_XADDR_DATA_WIDTH_TEMP : $bits(tip_dtype_dsize_t);

	typedef logic [TIP_XADDR_WIDTH-1:0]			tip_xaddr_t;		// contains tip_daddr_t or tip_iaddr_t
	typedef logic [TIP_XADDR_DATA_WIDTH-1:0]	tip_xaddr_data_t;	// contains tip_xaddr_t or tip_data_t or tip_dtype_dsize_t

	typedef enum logic [TIP_ITYPE_WIDTH-1:0] {
		OTHER    	 	 		= 0,			// Final instruction in the block is none of the other named itype codes
		EXCEPTION_TRAP	 		= 1,			// An exception that traps occurred following the final retired instruction in the block
		INTERRUPT  	 	 		= 2,			// An interrupt that traps occurred following the final retired instruction in the block
		EXCEPTION_IR	 	 	= 3,			// Exception-return or interrupt-return
		NOT_TAKEN_BRANCH	 	= 4,			// Nontaken branch
		TAKEN_BRANCH    	 	= 5,			// Taken branch
		UNINFERABLE_JUMP  		= 6,			// Uninferable jump if itype_width_p is 3, reserved otherwise
		RESERVED			 	= 7,			// reserved
		UNINFERABLE_CALL  		= 8,			// Uninferable call
		INFERRABLE_CALL  		= 9,			// Inferrable call
		UNINFERABLE_TAIL_CALL  	= 10,			// Uninferable tail-call
		INFERRABLE_TAIL_CALL  	= 11,			// Inferrable tail-call
		CO_ROUTINE_SWAP  		= 12,			// Co-routine swap
		RETURN  				= 13,			// Return
		OTHER_UNINFERABLE_JUMP  = 14,			// Other uninferable jump
		OTHER_INFERABLE_JUMP   	= 15 			// Other inferable jump
	}tip_itype_e;

	// interrupt cause
	typedef enum logic [TIP_ICAUSE_WIDTH-1:0] {
		USOFT   	 	 		= 0,			// User Software Interrupt
		SSOFT 					= 1, 			// Supervisor Software Interrupt
		MSOFT 					= 3, 			// Machine Software Interrupt
		UTIMER 					= 4, 			// User Timer Interrupt
		STIMER 					= 5, 			// Supervisor Timer Interrupt
		MTIMER 					= 7, 			// Machine Timer Interrupt
		UEXT 					= 8,			// User External Interrupt
		SEXT 					= 9,			// Supervisor External Interrupt
		MEXT 					= 11,			// Machine External Interrupt
		ICAUSE_NONE				= 15			// For easier interpretation of the simulation chart
	}icause_e;

	// exception cause
	typedef enum logic [TIP_ECAUSE_WIDTH-1:0] {
		MISALIGNED_INSTR		= 0,			// Misaligned instruction fetch address
		INSTR_FETCH_FAULT		= 1,			// Instruction fetch access fault
		ILLEGAL_INSTR			= 2,			// Illegal instruction
		BREAKPOINT				= 3,			// Breakpoint
		MISALIGNED_LOAD			= 4,			// Misaligned load address
		LOAD_FAULT				= 5,			// Load access fault
		MISALIGNED_STORE		= 6,			// Misaligned store address
		STORE_FAULT				= 7,			// Store access fault
		ECALL_FROM_M			= 11,			// Ecall from M-mode
		ECAUSE_NONE				= 15			// For easier interpretation of the simulation chart
	}tip_ecause_e;

	// context type
	typedef enum logic [TIP_CTYPE_WIDTH-1:0] {
		UNREPORTED				= 0,			// No action (don’t report context)
		IMPRECISELY				= 1,			// Report context imprecisely
		PRECISELY				= 2,			// Report context precisely
		ASYNC					= 3				// Report context as an asynchronous discontinuity
	}tip_ctype_e;

	typedef enum logic [TIP_DTYPE_WIDTH-1:0] {
		LOAD	   	 	 		= 0,			// Load
		STORE			 		= 1,			// Store
		CSR_READ_WRITE	 		= 4,			// CSR read-write
		CSR_READ_SET	 	 	= 5,			// CSR read-set
		CSR_READ_CLEAR		 	= 6,			// CSR read-clear
		ATOMIC_SWAP	    	 	= 8,			// Atomic swap
		ATOMIC_ADD	    	 	= 9,			// Atomic add
		ATOMIC_AND	    	 	= 10,			// Atomic AND
		ATOMIC_OR	    	 	= 11,			// Atomic OR
		ATOMIC_XOR	    	 	= 12,			// Atomic XOR
		ATOMIC_MAX	    	 	= 13,			// Atomic max
		ATOMIC_MIN	    	 	= 14,			// Atomic min
		COND_STORE_FAILURE		= 15			// Conditional store failure
	}tip_dtype_e;

	typedef struct packed
	{
		logic					do_sync;			// do generate sync message
		logic					is_error;
		logic					do_send_ownership;
		nexus_etype_e			etype;
		nexus_vendor_ecode_t	ecode;
		logic					do_flush;
		logic					do_send_config;
	}trace_ctrl_t;

	typedef struct packed
	{
		logic					valid;
		tip_time_t				_time;			// core time
		// control flow
		tip_itype_e				itype;			// instruction type
		tip_ecause_e			ecause;			// exception or interrupt cause
		tip_iaddr_t				tval;			// trap value
		tip_priv_t				priv;			// privilege level
		tip_iaddr_t				iaddr;			// instruction address
		tip_context_t			_context;		// context
		tip_ctype_t				ctype; 			// reporting behavior for context
		tip_iretire_t			iretire;		// number of instructions / halfwords retired
		tip_ilastsize_t			ilastsize; 		// size of the retired instruction
		// data flow
		tip_dretire_t			dretire;		// data access retired
		tip_dtype_e				dtype;			// data access type
		tip_daddr_t				daddr;			// data access address
		tip_dsize_t				dsize;			// data access size is 2^dsize bytes
		tip_data_t				data;			// data (legacy: unused in split-load mode)
		// split-load data flow (H2E v1.1 / TGC5C AXI4)
		logic [TIP_SDATA_WIDTH-1:0]	sdata;		// store data (valid at dretire for STORE)
		logic [TIP_LRESP_WIDTH-1:0]	lresp;		// load response: 2=OK, 3=error (valid when lresp[1]=1)
		logic [TIP_LDATA_WIDTH-1:0]	ldata;		// load data (valid when lresp[1]=1)
		// other
		tip_impdef_t			impdef; 		// implementation defined sideband signals
	} tip_t;

	typedef struct packed
	{
		tip_t					tip;
//		logic					valid;
		tip_iaddr_t 			next_iaddr;
		tip_icnt_t				icnt;			// sum retired instruction half words since last valid
		logic [63:0] 			cycles;			// CPU clock cycles
		nexus_sync_reason_e		sync_reason;	// sync reason
//		tip_itype_e				itype;			// instruction type
//		tip_ecause_e			ecause;			// exception or interrupt cause
//		tip_iaddr_t				tval;			// trap value
//		tip_priv_t				priv;			// privilege level
//		tip_iaddr_t				iaddr;			// instruction address
//		tip_context_t			_context; 		// context
//		tip_time_t				_time; 			// core time
//		tip_ctype_t				ctype; 			// reporting behavior for context
//		logic			    	sijump;			// sequentially inferable
//		tip_iretire_t			iretire;		// number of instructions / halfwords retired in this block
//		tip_ilastsize_t			ilastsize; 		// size of the retired instruction
//		tip_impdef_t			impdef; 		// implementation defined sideband signals
//		logic [1:0]				trigger;		// trigger
//		logic					hart_halted;	// hart is halted
//		logic					hart_reset;		// hart is in reset
//		logic					hart_stall;		// stall request to hart

		// data trace
//		tip_dretire_t						dretire;		// data access retired
//		tip_dtype_e							dtype;			// data access type
//		tip_daddr_t							daddr;			// data access address
//		tip_dsize_t							dsize;			// data access size is 2^dsize bytes
//		tip_data_t							data;			// data
//		logic [TIP_IADDR_LSBS_WIDTH-1:0]	iaddr_lsbs;		// LSBs of the data access instruction address
//		logic [TIP_DBLOCK_WIDTH-1:0]		dblock;			// instruction block in which the data access instruction is retired
//		logic [TIP_LRID_WIDTH-1:0]			lrid;			// load request ID
//		logic [TIP_LRESP_WIDTH-1:0]			lresp;			// load response
//		logic [TIP_LRID_WIDTH-1:0]			lid;			// split load ID
//		logic [TIP_SDATA_WIDTH-1:0]			sdata;			// store data
//		logic [vLDATA_WIDTH-1:0]			ldata;			// load data

		// clocks (for dumping and replay)
//		logic							sys_clk; 		// system clock @ tip clock domain
//		logic							ext_clk; 		// external clock @ tip clock domain
//		logic							shared_clk; 	// shared clock @ tip clock domain

		// trace generation control
		trace_ctrl_t					ctrl;

		// Timestamp
		logic[63:0]						ts;

		// trace config
//		trace_config_t		cfg;

		// for debug
		int								num_instr;			// number of retired instructions

	} tip_msg_struct_t;

	// TIP dump items (current instruction address is dumped always)
	localparam DUMP_NONE			= 32'h00;	// current instruction address only
	localparam DUMP_PCINFO_TYPE		= 32'h01;	// PC Info type
	localparam DUMP_DEST 			= 32'h02;	// dest address
	localparam DUMP_ITYPE			= 32'h04; 	// tip itype as number
	localparam DUMP_ITYPE_STRING	= 32'h08; 	// tip itype as string
	localparam DUMP_TS				= 32'h10; 	// tip timestamp
	localparam DUMP_IRETIRE			= 32'h20; 	// tip iretire
	localparam DUMP_DATA  			= 32'h40;	// tip data access

	// NexRV instruction type
	// see NexRv Tool (Nexus trace for RISC-V) Description page
	typedef enum logic [3:0] {
		L	= 0,	// Linear
		BD	= 1,	// Branch Direct
		JD	= 2,	// Jump Direct
		JI	= 3,	// Jump Indirect
		CD	= 4,	// Call Direct
		CI	= 5,	// Call Indirect
		R 	= 6,	// Return
		E 	= 7,	// Exception
		XX 	= 8		// Unknown
	} tip_pcinfo_itype_e;

	typedef struct packed {			// instruction information for tip generator and tip_dump
		tip_pcinfo_itype_e	pcinfo_itype;
		tip_itype_e			itype;
		int					length;
		tip_iaddr_t			addr;
		tip_iaddr_t			target_addr;
		tip_itype_e			target_addr_itype;
		tip_dtype_e			dtype;
		tip_daddr_t			daddr;
		tip_dsize_t			dsize;
		tip_data_t			data;
		int					cnt_jump_in;
		int					cnt_jump_out;
		int					dbranch_id;
		int 				i; 			// Sum of Entry/Exit at address
		int					e;			// Taken-Count
		int					n; 			// Not-Taken-Count
	} tip_instr_t;

	typedef struct packed {
		int											cnt_jump_out;
	} tip_dbranch_t;


	// Is TIP message pertinent for trace message generation?
	function logic TipCFMsgIsValid (input tip_iretire_t iretire, input tip_itype_e itype);
		TipCFMsgIsValid =    iretire
						  || (itype == EXCEPTION_TRAP)
						  || (itype == INTERRUPT);
	endfunction

	// translate tip.itype to short type (for tip_dump, compatibility with PCINFO and PCSEQ format)
	function tip_pcinfo_itype_e GetPCInfoType (input tip_itype_e itype);
		case (itype)
			OTHER:					GetPCInfoType = L;
			EXCEPTION_TRAP:	 		GetPCInfoType = E;
			INTERRUPT:   	 		GetPCInfoType = E;
			EXCEPTION_IR:	 	 	GetPCInfoType = R;
			NOT_TAKEN_BRANCH:	 	GetPCInfoType = L;
			TAKEN_BRANCH:    	 	GetPCInfoType = BD;
			UNINFERABLE_JUMP:  		GetPCInfoType = JI;
			RESERVED:			 	GetPCInfoType = XX;
			UNINFERABLE_CALL:  		GetPCInfoType = CI;
			INFERRABLE_CALL:  		GetPCInfoType = CD;
			UNINFERABLE_TAIL_CALL:  GetPCInfoType = CI;
			INFERRABLE_TAIL_CALL:  	GetPCInfoType = CD;
			CO_ROUTINE_SWAP:  		GetPCInfoType = XX;
			RETURN:  				GetPCInfoType = R;
			OTHER_UNINFERABLE_JUMP: GetPCInfoType = JI;
			OTHER_INFERABLE_JUMP:   GetPCInfoType = JD;
		endcase
	endfunction

	// Determine whether this instruction is a control-flow instruction.
	// Control-flow instructions modify the program counter, which diverts execution away from the next sequential instruction.
	// Examples include conditional or unconditional jumps, subroutine calls, and returns.
	function logic IsControlFlowInstruction (input tip_itype_e itype);
		case (itype)
			OTHER,
			RESERVED: 	IsControlFlowInstruction = 0;
			default:	IsControlFlowInstruction = 1;
		endcase
	endfunction

	// Determine whether this instruction has changed the control-flow.
	function logic HasChangedControlFlow (input tip_itype_e itype);
		case (itype)
			OTHER,
			NOT_TAKEN_BRANCH,
			RESERVED: 	HasChangedControlFlow = 0;
			default:	HasChangedControlFlow = 1;
		endcase
	endfunction

	// Convert a ct_cs_cpuif__trActCapStCmd__out_t struct into a bit vector (tip_data_t),
	// matching the RDL bit layout of the trActCapStCmd CSR @ 0x0B10 so that a RISC-V
	// `csrw 0xB10, x` and a testbench-synthesised write produce the same TIP payload:
	//   [5:0]   Cmd.value        (6b)
	//   [7:6]   Sink.value       (2b)
	//   [31:8]  DirectData.value (24b)
	// High TIP bits above 32 are zero-padded.
	function automatic tip_data_t cmd_to_tip_data(ct_cs_cpuif__trActCapStCmd__out_t cmd);
		localparam int CMD_W = 32;
		logic [CMD_W-1:0] cmd_packed;
		cmd_packed        = '0;
		cmd_packed[5:0]   = cmd.Cmd.value;
		cmd_packed[7:6]   = cmd.Sink.value;
		cmd_packed[31:8]  = cmd.DirectData.value;
		return { {(TIP_DATA_WIDTH - CMD_W){1'b0}}, cmd_packed };
	endfunction

	// Inverse of cmd_to_tip_data — interprets tip_data as a trActCapStCmd CSR write.
	function automatic ct_cs_cpuif__trActCapStCmd__out_t tip_data_to_cmd(tip_data_t tip_data);
		localparam int CMD_W = 32;
		logic [CMD_W-1:0] cmd_packed;
		ct_cs_cpuif__trActCapStCmd__out_t cmd;
		cmd_packed = tip_data[CMD_W-1:0];
		cmd = '{default:'0};
		cmd.Cmd.value        = cmd_packed[5:0];
		cmd.Sink.value       = cmd_packed[7:6];
		cmd.DirectData.value = cmd_packed[31:8];
		return cmd;
	endfunction

endpackage // tip_pkg
