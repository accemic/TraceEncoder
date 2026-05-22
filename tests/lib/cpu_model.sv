// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
/**
* Copyright (c) 2026 Accemic Technologies GmbH
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @brief    Scripted RISC-V CPU model that drives the TIP interface.
*
* @details
*   Testbenches call this module's tasks to "execute" a program. Each
*   task drives the encoder-facing TIP signals with the right itype /
*   iaddr / daddr / ... AND logs a high-level event into `event_q`
*   that the scoreboard cross-checks against the encoder's decoded
*   output.
*
*   Time advances implicitly: every retired instruction takes
*   `CYCLES_PER_INSTR` tip_clk cycles. The knob lets tests stress
*   timestamp behaviour by spreading retirements out.
*
*   Conventions per the RISC-V Trace Spec ingress port
*   (https://github.com/riscv-non-isa/riscv-trace-spec/blob/main/ingressPort.adoc):
*
*     - SR (single-retirement) mode: `iretire` is a 1-bit strobe (high
*       for exactly one tip_clk cycle per retired instruction). Set by
*       `tip_pkg::TIP_IRETIRE_WIDTH == 1`.
*     - `ilastsize` carries log2 of the instruction size in halfwords:
*         0 => 1 halfword (16-bit, RVC)
*         1 => 2 halfwords (32-bit, the default in this model)
*     - `iaddr` is always the SOURCE PC of the retired instruction
*       (the branch / call / return / jump itself, not the target).
*     - For `INTERRUPT` and `EXCEPTION_TRAP` itypes the Accemic
*       encoder treats the trap notification itself as a retirement
*       (iretire=1, iaddr = PC of the trapping instruction). `cause`
*       is the 4-bit lower portion of mcause/scause (the high "is
*       interrupt" bit is conveyed by itype, not ecause).
*     - `tval` is only meaningful for `EXCEPTION_TRAP`; carries
*       mtval/stval (faulting address etc.). Zero everywhere else.
*     - When `iretire == 0` all other TIP signals are "don't care" per
*       spec. This model holds them at their last-driven value.
*
*   API surface:
*     enter / exit_trace                   lifecycle
*     run                                  straight-line execution
*     jump_to / uninferable_jump           direct / indirect jumps
*     branch_taken / branch_not_taken      conditional branches
*     call_to / ret                        function call / return
*     interrupt / exception_trap / mret    traps
*     load_data / store_data               data accesses
*     csr_write                            HSI events (CSR side-effects)
*     set_priv / set_context               priv-level / context tracking
*     idle                                 pass time without retiring
*
*   See tests/lib/README.md and tests/instruction/01_basic/ for usage.
*/

module cpu_model #(
	// tip_clk cycles per retired instruction. Larger = more time between
	// retirements = more timestamp messages.
	parameter int CYCLES_PER_INSTR = 4,
	// Default size of a retired instruction, in log2(halfwords) per spec.
	// 1 = 32-bit (RV32I), 0 = 16-bit (RVC). Tests can override per-task.
	parameter int DEFAULT_ILASTSIZE = 1,
	// Optional path for a NexRv PCInfo file derived from the scripted
	// scenario. Format (one line per retired instruction):
	//   0x<src_pc>,<type><length_bytes>[,0x<target_pc>]
	// Type codes: L=Linear, BD=Branch Direct, JD=Jump Direct,
	// JI=Jump Indirect, CD=Call Direct, R=Return. NexRv loads this
	// as a dense, sorted array — entries are sorted and gaps in the
	// address range are filled with sentinel L entries. Written on
	// simulation end. Empty = no file.
	parameter string NEXRV_INFO_PATH    = "",
	// Optional path for an execution-ordered "expected PC sequence"
	// file, one PC per line in the order the cpu_model executed them.
	// This is what the decoded NexRv output should match
	// line-for-line. Empty = no file.
	parameter string EXPECTED_PCS_PATH  = "",
	// Optional path for an execution-ordered "expected data trace"
	// file. One line per data access:
	//   LOAD|STORE,0x<daddr>,<size_bytes>
	// Used by scripts/decode_and_check_data.sh to verify the encoder
	// emitted exactly the load/store sequence the cpu_model issued.
	// Empty = no file.
	parameter string EXPECTED_DATA_PATH = "",
	// Optional path for an execution-ordered "expected CTXP" file — the
	// C-Trace eXPort records (SYNC / BRANCH_* / CALL / RETURN / MEMREAD_n /
	// MEMWRITE_n / DAQ_*) the NexRv reference decoder should produce from the
	// trace, in program order. Compared (normalized) against NexRv's CTXP text
	// export by scripts/decode_and_check.sh --ctxp. Empty = no file.
	parameter string EXPECTED_CTXP_PATH = ""
) (
	input  uwire logic clk,    // tip_clk
	input  uwire logic rst,    // tip_rst (active high)
	tip_if.master      tip
);

	import tip_pkg::*;
	import cpu_model_pkg::*;
	import nexus_vendor::*;   // ACT_CAP_CMD (CSR id of the ACT-CAP command register)

	// ------------------------------------------------------------------
	// Output regs (continuously assigned to the TIP interface)
	// ------------------------------------------------------------------
	tip_iretire_t   r_iretire   = 0;
	tip_itype_e     r_itype     = OTHER;
	tip_ecause_e    r_ecause    = tip_ecause_e'(0);
	tip_iaddr_t     r_tval      = 0;
	tip_priv_t      r_priv      = 3;    // M-mode by default
	tip_iaddr_t     r_iaddr     = TIP_DEFAULT_IADDR;
	tip_context_t   r_context   = 0;
	tip_time_t      r_time      = 0;
	tip_ctype_t     r_ctype     = 0;
	// ilastsize: log2(halfwords). 1 = 32-bit, 0 = RVC (16-bit). Per
	// RISC-V trace-spec ingressPort.adoc the encoder treats the
	// instruction size as 2^ilastsize halfwords.
	tip_ilastsize_t r_ilastsize = tip_ilastsize_t'(DEFAULT_ILASTSIZE);
	tip_impdef_t    r_impdef    = 0;

	tip_dretire_t   r_dretire   = 0;
	tip_dtype_e     r_dtype     = LOAD;
	tip_daddr_t     r_daddr     = TIP_DEFAULT_DADDR;
	tip_dsize_t     r_dsize     = 2;    // word
	tip_data_t      r_data      = TIP_DEFAULT_DATA;
	logic [TIP_SDATA_WIDTH-1:0] r_sdata = 0;
	logic [TIP_LRESP_WIDTH-1:0] r_lresp = 0;
	logic [TIP_LDATA_WIDTH-1:0] r_ldata = 0;

	assign tip.iretire   = r_iretire;
	assign tip.itype     = r_itype;
	assign tip.ecause    = r_ecause;
	assign tip.tval      = r_tval;
	assign tip.priv      = r_priv;
	assign tip.iaddr     = r_iaddr;
	assign tip._context  = r_context;
	assign tip._time     = r_time;
	assign tip.ctype     = r_ctype;
	assign tip.ilastsize = r_ilastsize;
	assign tip.impdef    = r_impdef;
	assign tip.dretire   = r_dretire;
	assign tip.dtype     = r_dtype;
	assign tip.daddr     = r_daddr;
	assign tip.dsize     = r_dsize;
	assign tip.data      = r_data;
	assign tip.sdata     = r_sdata;
	assign tip.lresp     = r_lresp;
	assign tip.ldata     = r_ldata;

	// Free-running time counter (TIP time signal)
	always_ff @(posedge clk) begin
		if (rst) r_time <= 0;
		else     r_time <= r_time + 1;
	end

	// Defensive reset of retirement strobes
	always_ff @(posedge clk) begin
		if (rst) begin
			r_iretire <= 0;
			r_dretire <= 0;
		end
	end

	// ------------------------------------------------------------------
	// Internal program / event state
	// ------------------------------------------------------------------
	tip_iaddr_t cur_pc        = 0;
	tip_iaddr_t call_stack[$];     // inferable-call return addresses
	tip_iaddr_t trap_stack[$];     // mepc-style trap return addresses
	logic       enabled       = 0;
	// TB-side mirror of "instruction tracing active". The test sets this
	// (via set_inst_traced) to match when it programs trTeControl.InstTracing/
	// Enable, so events retired during an instruction-tracing pause are tagged
	// untraced and excluded from the expected-PC reference. Default: traced.
	bit         inst_traced   = 1'b1;
	// TB-side mirror of "data tracing active" (trTeDataControl.DataTracing).
	// Tests with data trace off (e.g. the ACT-CAP test, which still issues
	// loads/stores to feed the DAQ data-context commands) set this 0 so those
	// accesses are NOT emitted as standalone CTXP MEM records. Default: traced.
	bit         data_traced   = 1'b1;

	cpu_event_t event_q[$];

	function automatic int event_count();
		return event_q.size();
	endfunction

	function automatic cpu_event_t pop_event();
		cpu_event_t e = event_q[0];
		event_q.delete(0);
		return e;
	endfunction

	function automatic cpu_event_t peek_event(int idx = 0);
		return event_q[idx];
	endfunction

	function automatic void log_event(
		cpu_event_kind_e kind,
		tip_iaddr_t      pc,
		tip_iaddr_t      target  = '0,
		longint unsigned payload = 0,
		int unsigned     size    = 0
	);
		cpu_event_t e;
		e.kind    = kind;
		e.pc      = pc;
		e.target  = target;
		e.payload = payload;
		e.size    = size;
		e.traced      = inst_traced;
		e.data_traced = data_traced;
		event_q.push_back(e);
	endfunction

	// Mirror the encoder's instruction-tracing enable state for expected-PC
	// bookkeeping. Call with 0 just before driving instructions that execute
	// while instruction tracing is paused (InstTracing=0 / Enable=0), and with
	// 1 again after tracing resumes. Events logged while 0 are kept in the
	// event log (for liveness/debug) but omitted from the expected-PC list.
	task automatic set_inst_traced(input bit on);
		inst_traced = on;
	endtask

	// Mirror the encoder's data-tracing enable state (trTeDataControl.DataTracing)
	// for the expected-CTXP reference. Call with 0 when data tracing is off so
	// loads/stores are not emitted as CTXP MEM records (they may still run to
	// feed ACT-CAP DAQ data-context commands). Default: data-traced.
	task automatic set_data_traced(input bit on);
		data_traced = on;
	endtask

	// ------------------------------------------------------------------
	// Low-level pulse helper: drive one retired instruction for one
	// clock cycle, pad with idle cycles up to CYCLES_PER_INSTR.
	//
	// iretire is a 1-bit strobe (SR mode). ilastsize is log2(halfwords).
	// ecause / tval are meaningful only when itype is INTERRUPT (ecause)
	// or EXCEPTION_TRAP (ecause + tval).
	// ------------------------------------------------------------------
	task automatic drive_instr_pulse(
		input tip_itype_e     itype_,
		input tip_iaddr_t     iaddr_,
		input tip_ilastsize_t ilastsize_ = tip_ilastsize_t'(DEFAULT_ILASTSIZE),
		input tip_ecause_e    ecause_    = tip_ecause_e'(0),
		input tip_iaddr_t     tval_      = '0
	);
		// Idle padding before retirement (so each instruction occupies
		// CYCLES_PER_INSTR cycles total).
		repeat (CYCLES_PER_INSTR - 1) @(posedge clk);
		// Drive the retirement on the next clock edge.
		@(negedge clk);
		r_iretire   = 1;
		r_itype     = itype_;
		r_iaddr     = iaddr_;
		r_ilastsize = ilastsize_;
		r_ecause    = ecause_;
		r_tval      = tval_;
		@(posedge clk);
		@(negedge clk);
		r_iretire   = 0;
		r_dretire   = 0;
		// Clear ecause/tval after the trap pulse so they don't leak
		// into the next retirement.
		r_ecause    = tip_ecause_e'(0);
		r_tval      = '0;
	endtask

	// ------------------------------------------------------------------
	// Lifecycle
	// ------------------------------------------------------------------
	task automatic enter(input tip_iaddr_t start_pc);
		cur_pc  = start_pc;
		r_iaddr = start_pc;
		enabled = 1;
		log_event(CPU_ENTER, start_pc);
	endtask

	task automatic exit_trace();
		enabled = 0;
		log_event(CPU_EXIT, cur_pc);
	endtask

	// Run `cycles` clock cycles without retiring anything.
	task automatic idle(input int cycles);
		repeat (cycles) @(posedge clk);
	endtask

	// ------------------------------------------------------------------
	// Straight-line execution
	// ------------------------------------------------------------------
	// Retire enough 32-bit instructions to cover `n_bytes`. (Compressed
	// 16-bit RVC is not modelled here; instructions are 4 bytes each.
	// For RVC scenarios construct your own loop with the desired
	// ilastsize_ on each pulse.)
	task automatic run(input int n_bytes);
		int n_instr;
		n_instr = (n_bytes + 3) / 4;
		for (int i = 0; i < n_instr; i++) begin
			drive_instr_pulse(.itype_(OTHER), .iaddr_(cur_pc));
			log_event(CPU_RUN, cur_pc);
			cur_pc = cur_pc + 4;
		end
	endtask

	// ------------------------------------------------------------------
	// Control flow
	// ------------------------------------------------------------------
	task automatic jump_to(input tip_iaddr_t target);
		drive_instr_pulse(.itype_(UNINFERABLE_JUMP), .iaddr_(cur_pc));
		log_event(CPU_JUMP, cur_pc, target);
		cur_pc = target;
	endtask

	task automatic branch_taken(input tip_iaddr_t target);
		drive_instr_pulse(.itype_(TAKEN_BRANCH), .iaddr_(cur_pc));
		log_event(CPU_BRANCH_TAKEN, cur_pc, target);
		cur_pc = target;
	endtask

	// A not-taken conditional branch. `target` is the address the branch
	// WOULD jump to if taken — recorded in PCInfo as the BD target even
	// though execution falls through to cur_pc+4. Defaults to cur_pc+8.
	task automatic branch_not_taken(input tip_iaddr_t target = '0);
		tip_iaddr_t tgt;
		tgt = (target == '0) ? (cur_pc + 8) : target;
		drive_instr_pulse(.itype_(NOT_TAKEN_BRANCH), .iaddr_(cur_pc));
		log_event(CPU_BRANCH_NOT_TAKEN, cur_pc, tgt);
		cur_pc = cur_pc + 4;
	endtask

	task automatic call_to(input tip_iaddr_t target);
		drive_instr_pulse(.itype_(INFERRABLE_CALL), .iaddr_(cur_pc));
		call_stack.push_back(cur_pc + 4);
		log_event(CPU_CALL, cur_pc, target);
		cur_pc = target;
	endtask

	task automatic ret();
		tip_iaddr_t ret_pc;
		if (call_stack.size() == 0) begin
			$error("[cpu_model] ret() with empty call stack at pc=%08x", cur_pc);
			return;
		end
		drive_instr_pulse(.itype_(RETURN), .iaddr_(cur_pc));
		ret_pc = call_stack[$];
		call_stack.pop_back();
		log_event(CPU_RET, cur_pc, ret_pc);
		cur_pc = ret_pc;
	endtask

	task automatic uninferable_jump(input tip_iaddr_t target);
		drive_instr_pulse(.itype_(UNINFERABLE_JUMP), .iaddr_(cur_pc));
		log_event(CPU_UNINFERABLE_JUMP, cur_pc, target);
		cur_pc = target;
	endtask

	// ------------------------------------------------------------------
	// Exceptions / interrupts
	//
	// `cause` is the 4-bit low-order portion of mcause/scause. The "is
	// interrupt" high bit is conveyed by `itype` (INTERRUPT vs
	// EXCEPTION_TRAP), so it isn't repeated in ecause.
	//
	// `tval` is meaningful only for EXCEPTION_TRAP (mtval/stval — the
	// faulting address for page faults, etc.). Interrupts ignore it.
	// ------------------------------------------------------------------
	task automatic interrupt(input int cause, input tip_iaddr_t handler);
		// Asynchronous interrupt: the iaddr instruction retired, then
		// the trap fired. Resume at the NEXT pc on mret so we don't
		// re-classify the trap PC as both E (here) and L (after mret).
		drive_instr_pulse(
			.itype_  (INTERRUPT),
			.iaddr_  (cur_pc),
			.ecause_ (tip_ecause_e'(cause))
		);
		trap_stack.push_back(cur_pc + 4);
		log_event(CPU_INTERRUPT, cur_pc, handler, cause);
		cur_pc = handler;
	endtask

	task automatic exception_trap(
		input int         cause,
		input tip_iaddr_t handler,
		input tip_iaddr_t tval = '0
	);
		// Synchronous exception: the faulting instruction did NOT
		// retire. In real RISC-V the handler fixes the cause and the
		// instruction is re-executed. For PCInfo compatibility we
		// simplify and resume at pc+4, treating the fault as a
		// non-recoverable diagnostic in trace.
		drive_instr_pulse(
			.itype_  (EXCEPTION_TRAP),
			.iaddr_  (cur_pc),
			.ecause_ (tip_ecause_e'(cause)),
			.tval_   (tval)
		);
		trap_stack.push_back(cur_pc + 4);
		log_event(CPU_EXCEPTION, cur_pc, handler, cause);
		cur_pc = handler;
	endtask

	task automatic mret();
		tip_iaddr_t ret_pc;
		if (trap_stack.size() == 0) begin
			$error("[cpu_model] mret() with empty trap stack at pc=%08x", cur_pc);
			return;
		end
		drive_instr_pulse(.itype_(EXCEPTION_IR), .iaddr_(cur_pc));
		ret_pc = trap_stack[$];
		trap_stack.pop_back();
		log_event(CPU_MRET, cur_pc, ret_pc);
		cur_pc = ret_pc;
	endtask

	// ------------------------------------------------------------------
	// Data trace
	//
	// A load/store-bearing instruction asserts BOTH iretire (the
	// instruction completed) and dretire (the data access completed) in
	// the same cycle. dsize is log2(byte count): 0=B, 1=H, 2=W, 3=D.
	// ------------------------------------------------------------------
	task automatic drive_dretire_pulse(
		input tip_dtype_e dtype_,
		input tip_iaddr_t daddr_,
		input tip_dsize_t dsize_,
		input tip_data_t  data_ = '0
	);
		repeat (CYCLES_PER_INSTR - 1) @(posedge clk);
		@(negedge clk);
		r_iretire   = 1;
		r_itype     = OTHER;
		r_iaddr     = cur_pc;
		r_ilastsize = tip_ilastsize_t'(DEFAULT_ILASTSIZE);
		r_dretire   = 1;
		r_dtype     = dtype_;
		r_daddr     = daddr_;
		r_dsize     = dsize_;
		r_data      = data_;
		r_sdata     = data_[TIP_SDATA_WIDTH-1:0];
		@(posedge clk);
		@(negedge clk);
		r_iretire = 0;
		r_dretire = 0;
	endtask

	// size: log2 of byte count (0=B, 1=H, 2=W, 3=D, ...)
	task automatic load_data(input tip_iaddr_t addr, input int size);
		drive_dretire_pulse(LOAD, addr, tip_dsize_t'(size));
		log_event(CPU_LOAD, cur_pc, addr, 0, size);
		cur_pc = cur_pc + 4;
	endtask

	task automatic store_data(input tip_iaddr_t addr, input int size, input tip_data_t data);
		drive_dretire_pulse(STORE, addr, tip_dsize_t'(size), data);
		log_event(CPU_STORE, cur_pc, addr, data, size);
		cur_pc = cur_pc + 4;
	endtask

	// ------------------------------------------------------------------
	// CSR writes (drive HSI events from software-side stimulus). The
	// actual Wishbone write is issued by csr_helper in the testbench;
	// this task only updates the cpu_model's event log so the scoreboard
	// knows a CSR write happened.
	// ------------------------------------------------------------------
	task automatic csr_write(input int csr_addr, input tip_data_t val);
		log_event(CPU_CSR_WRITE, cur_pc, tip_iaddr_t'(csr_addr), val);
	endtask

	// ------------------------------------------------------------------
	// ACT-CAP (CSR Access Protocol) command — CSR-based instrumentation.
	//
	// Models the CPU executing `csrw ACT_CAP_CMD, x`: a functional NOP
	// (no system-bus side effect) whose write the encoder observes on the
	// TIP data channel. The ACT-CAP preprocessor (ct_L23_preproc_act_cap)
	// fires on (dretire && dtype==CSR_READ_WRITE && daddr==ACT_CAP_CMD)
	// and decodes tip.data with the RDL bit layout of trActCapStCmd
	// @ 0x0B10 (see tip_pkg::cmd_to_tip_data / tip_data_to_cmd):
	//   data[5:0]  = Cmd         (trActCapStCmd_e)
	//   data[7:6]  = Sink        (trActCapStSink_e: NEXUS / AXIS / AXIS_NEXUS / TE)
	//   data[31:8] = DirectData  (24-bit payload)
	// The retiring csrw itself is reported as an OTHER instruction so the
	// instruction stream stays well-formed.
	// ------------------------------------------------------------------
	task automatic act_cap_cmd(input logic [5:0]  cmd,
	                           input logic [1:0]  sink,
	                           input logic [23:0] direct_data = '0);
		tip_data_t d;
		d        = '0;
		d[5:0]   = cmd;
		d[7:6]   = sink;
		d[31:8]  = direct_data;
		drive_dretire_pulse(CSR_READ_WRITE, tip_iaddr_t'(ACT_CAP_CMD),
		                    tip_dsize_t'(2) /* word */, d);
		log_event(CPU_CSR_WRITE, cur_pc, tip_iaddr_t'(ACT_CAP_CMD), d);
		cur_pc = cur_pc + 4;
	endtask

	// ------------------------------------------------------------------
	// Privilege / context state — held until the next call. Per spec,
	// priv reflects the privilege level of all instructions in the next
	// retired block. context is reported under the policy set by ctype.
	// ------------------------------------------------------------------
	task automatic set_priv(input tip_priv_t p);
		r_priv = p;
	endtask

	task automatic set_context(input tip_context_t ctx, input tip_ctype_t ct = 2 /* precise */);
		r_context = ctx;
		r_ctype   = ct;
	endtask

	// ------------------------------------------------------------------
	// NexRv PCInfo writer
	//
	// Walks event_q and produces a NexRv-format PCInfo file describing
	// the scripted scenario as a sequence of retired instructions. The
	// NexRv reference decoder uses this file as its "program memory"
	// when validating encoder output messages.
	//
	// Type-code mapping (matches tip_pkg::GetPCInfoType in the encoder):
	//   CPU_RUN, CPU_LOAD, CPU_STORE, CPU_BRANCH_NOT_TAKEN  -> L
	//   CPU_BRANCH_TAKEN                                    -> BD
	//   CPU_JUMP                                            -> JD
	//   CPU_UNINFERABLE_JUMP                                -> JI
	//   CPU_CALL                                            -> CD
	//   CPU_RET, CPU_MRET                                   -> R
	//   CPU_INTERRUPT, CPU_EXCEPTION                        -> E
	//   CPU_ENTER, CPU_EXIT, CPU_CSR_*                      -> skipped
	//
	// Length is `1 << (DEFAULT_ILASTSIZE + 1)` bytes (4 for RV32I,
	// 2 for RVC). All instructions in the current scenario share the
	// same length; extend the event_q to carry per-event size if RVC
	// support is needed.
	// ------------------------------------------------------------------
	// Maps a cpu_event to the static PCInfo type code the NexRv decoder
	// expects (single character of L/B/J/C/R/E, plus the D/I direct /
	// indirect qualifier where it matters).
	function automatic string pcinfo_type_str(cpu_event_kind_e k);
		// NEXRV pcinfo is a STATIC instruction-type table. The
		// interrupt/exception semantics are carried by the trace
		// messages themselves (TCODE), not by an E entry in pcinfo,
		// so we report the underlying instruction type (Linear) for
		// trap PCs — the decoder doesn't need to know "an interrupt
		// CAN happen here" to decode the trace.
		case (k)
			// CPU_CSR_WRITE models a `csrw` (e.g. an ACT-CAP command @0x0B10)
			// — a normal retired instruction (itype=OTHER) from the trace's
			// point of view, so it occupies a Linear PCInfo slot and a PC in
			// the executed stream.
			CPU_RUN, CPU_LOAD, CPU_STORE, CPU_CSR_WRITE,
			CPU_INTERRUPT, CPU_EXCEPTION: return "L";
			// A conditional branch is a "BD" (Branch Direct) in PCInfo
			// whether or not it was taken at runtime — the HIST bit in
			// the trace resolves the direction. A not-taken branch
			// continues to pc+len (no gap); a taken branch jumps to the
			// PCInfo target.
			CPU_BRANCH_TAKEN,
			CPU_BRANCH_NOT_TAKEN:    return "BD";
			CPU_JUMP:                return "JD";
			CPU_UNINFERABLE_JUMP:    return "JI";
			CPU_CALL:                return "CD";
			CPU_RET, CPU_MRET:       return "R";
			default:                 return "";   // skipped
		endcase
	endfunction

	function automatic int write_nexrv_info(input string path);
		// NexRv loads the PCInfo into an array indexed by
		// (addr - base) / 4. Entries MUST be sorted by address and
		// each address MUST appear at most once. Build a sorted
		// (pc, type, target) table here, dedupe, then emit.
		int fd;
		int n_written = 0;
		int unsigned len_bytes = 1 << (DEFAULT_ILASTSIZE + 1);
		tip_iaddr_t  pcs        [$];
		string       types_at   [tip_iaddr_t];   // associative array pc -> type
		tip_iaddr_t  targets_at [tip_iaddr_t];

		if (path == "") return 0;

		// Build the (pc -> type, target) map in event order. First
		// observation of a PC wins; later visits with the same type
		// are no-ops, later visits with a DIFFERENT type are a test
		// authoring error and are flagged.
		foreach (event_q[i]) begin
			string t;
			t = pcinfo_type_str(event_q[i].kind);
			if (t == "") continue;
			if (types_at.exists(event_q[i].pc)) begin
				if (types_at[event_q[i].pc] != t) begin
					$error("[cpu_model] write_nexrv_info: PC 0x%08x has conflicting types '%s' and '%s' — NexRv pcinfo requires one type per PC. Restructure the test scenario.",
						event_q[i].pc, types_at[event_q[i].pc], t);
				end
				continue;
			end
			types_at[event_q[i].pc]   = t;
			targets_at[event_q[i].pc] = event_q[i].target;
			pcs.push_back(event_q[i].pc);
		end

		// Sort PCs ascending.
		pcs.sort();

		fd = $fopen(path, "w");
		if (fd == 0) begin
			$error("[cpu_model] failed to open '%s' for NexRv info write", path);
			return 0;
		end

		// NexRv loads pcinfo as a dense array indexed by
		// (addr - base) / len_bytes. Any 4-byte slot in [base..top]
		// that the cpu_model never visited must still be present in
		// the file or array lookups break. Fill those with a
		// neutral L4 sentinel — the trace will never reference these
		// addresses, so the sentinel type is irrelevant.
		begin
			automatic tip_iaddr_t base = pcs[0];
			automatic tip_iaddr_t top  = pcs[pcs.size() - 1];
			automatic int        n_gap = 0;
			for (tip_iaddr_t a = base; a <= top; a += len_bytes) begin
				if (types_at.exists(a)) begin
					automatic string t = types_at[a];
					if (t == "L" || t == "R") begin
						$fwrite(fd, "0x%08x,%s%0d\n", a, t, len_bytes);
					end else begin
						$fwrite(fd, "0x%08x,%s%0d,0x%08x\n", a, t, len_bytes, targets_at[a]);
					end
				end else begin
					$fwrite(fd, "0x%08x,L%0d\n", a, len_bytes);  // gap-fill sentinel
					n_gap++;
				end
				n_written++;
			end
			if (n_gap > 0)
				$display("*** INFO (%m, line %0d) nexrv_info: %0d gap-fill L sentinels inserted",
					`__LINE__, n_gap);
		end
		$fclose(fd);
		$display("*** INFO (%m, line %0d) nexrv_info saved to %s (%0d entries)",
			`__LINE__, path, n_written);
		return n_written;
	endfunction

	// Execution-ordered list of PCs the cpu_model actually retired (no
	// dedup, no sort, no gap-fill). This is the reference the NexRv
	// decoder output is compared against.
	function automatic int write_expected_pcs(input string path);
		int fd;
		int n_written = 0;
		if (path == "") return 0;
		fd = $fopen(path, "w");
		if (fd == 0) begin
			$error("[cpu_model] failed to open '%s' for expected-PC write", path);
			return 0;
		end
		foreach (event_q[i]) begin
			if (pcinfo_type_str(event_q[i].kind) == "") continue;
			// Instructions retired while instruction tracing was paused are
			// not in the trace, so they are not in the decoded PC stream.
			if (!event_q[i].traced) continue;
			$fwrite(fd, "0x%08x\n", event_q[i].pc);
			n_written++;
		end
		$fclose(fd);
		$display("*** INFO (%m, line %0d) expected_pcs saved to %s (%0d entries)",
			`__LINE__, path, n_written);
		return n_written;
	endfunction

	// Execution-ordered list of data accesses the cpu_model issued.
	// Format per line:  LOAD|STORE,0x<daddr>,<size_bytes>
	// size_bytes is in DECIMAL (1/2/4/8) — same encoding NexRv prints
	// in its data-message decode, so the two are diff-able as-is.
	function automatic int write_expected_data(input string path);
		int fd;
		int n_written = 0;
		if (path == "") return 0;
		fd = $fopen(path, "w");
		if (fd == 0) begin
			$error("[cpu_model] failed to open '%s' for expected-data write", path);
			return 0;
		end
		foreach (event_q[i]) begin
			automatic int unsigned size_bytes = 1 << event_q[i].size;
			case (event_q[i].kind)
				CPU_LOAD:  begin
					$fwrite(fd, "LOAD,0x%08x,%0d\n", event_q[i].target, size_bytes);
					n_written++;
				end
				CPU_STORE: begin
					$fwrite(fd, "STORE,0x%08x,%0d\n", event_q[i].target, size_bytes);
					n_written++;
				end
				default: ;
			endcase
		end
		$fclose(fd);
		$display("*** INFO (%m, line %0d) expected_data saved to %s (%0d entries)",
			`__LINE__, path, n_written);
		return n_written;
	endfunction

	// ------------------------------------------------------------------
	// Execution-ordered "expected CTXP" reference. Replays the event log
	// the way the encoder + NexRv reference decoder produce CTXP records,
	// so NexRv's CTXP text export can be diffed against it (normalized for
	// the trailing "@ <cycle>" and hex leading zeros; see
	// scripts/decode_and_check.sh --ctxp).
	//
	// Record set (matches NexRv's NexRvCTXP / NexRvDeco mapping):
	//   - instruction control flow (gated on .traced): SYNC at trace entry,
	//     BRANCH_TAKEN / BRANCH_NOTTAKEN / CALL / RETURN / INTERRUPT / RFI;
	//   - data accesses (gated on .data_traced): MEMREAD_n / MEMWRITE_n;
	//   - ACT-CAP DAQ commands (CPU_CSR_WRITE @ ACT_CAP_CMD, sink -> Nexus):
	//     DAQ_DATA / SYNC / DAQ_LAST_PC / MEMx_n / DAQ_COUNTER per command.
	// ------------------------------------------------------------------
	// ACT-CAP command codes (rdl/ct_cs_cpuif.rdl trActCapStCmd_e).
	localparam int unsigned CMD_PC_CURR      = 1;
	localparam int unsigned CMD_PC_CURR_LAST = 2;
	localparam int unsigned CMD_DIRECT_DATA  = 3;
	localparam int unsigned CMD_DATA         = 4;
	localparam int unsigned CMD_DADDR        = 5;
	localparam int unsigned CMD_DATA_DADDR   = 6;
	localparam int unsigned CMD_IFETCH_TH    = 8;
	localparam int unsigned CMD_DATA_RD_TH   = 9;
	localparam int unsigned CMD_DATA_WR      = 10;
	localparam int unsigned CMD_DATA_RD      = 11;
	localparam int unsigned CMD_CF_SYNC      = 12;

	function automatic int write_expected_ctxp(input string path);
		int fd;
		int n_written = 0;
		int unsigned ilen_bytes = 1 << (DEFAULT_ILASTSIZE + 1);   // 32-bit -> 4
		// Captured data-access context, mirroring the composer's Prev* tracking.
		tip_daddr_t      prev_daddr   = '0;
		longint unsigned prev_data    = '0;
		int unsigned     prev_sz_log2 = 0;
		bit              prev_write   = 0;
		tip_iaddr_t      prev_iaddr   = '0;   // last retired instruction PC
		tip_iaddr_t      last_pc_exc  = '0;   // PC before the last exception/interrupt

		if (path == "") return 0;
		fd = $fopen(path, "w");
		if (fd == 0) begin
			$error("[cpu_model] failed to open '%s' for expected-CTXP write", path);
			return 0;
		end

		foreach (event_q[i]) begin
			automatic cpu_event_t e = event_q[i];
			automatic int unsigned bytes;
			automatic string rw;
			case (e.kind)
				CPU_ENTER: begin
					if (e.traced) begin
						$fwrite(fd, "#0:SYNC::0x%0h\n", e.pc); n_written++;
					end
				end
				CPU_BRANCH_TAKEN: begin
					if (e.traced) begin
						$fwrite(fd, "#0:BRANCH_TAKEN:0x%0h:0x%0h\n", e.pc, e.target); n_written++;
					end
					prev_iaddr = e.pc;
				end
				CPU_BRANCH_NOT_TAKEN: begin
					if (e.traced) begin
						$fwrite(fd, "#0:BRANCH_NOTTAKEN:0x%0h:0x%0h\n", e.pc, e.pc + ilen_bytes); n_written++;
					end
					prev_iaddr = e.pc;
				end
				CPU_JUMP, CPU_UNINFERABLE_JUMP: begin
					if (e.traced) begin
						$fwrite(fd, "#0:BRANCH_TAKEN:0x%0h:0x%0h\n", e.pc, e.target); n_written++;
					end
					prev_iaddr = e.pc;
				end
				CPU_CALL: begin
					if (e.traced) begin
						$fwrite(fd, "#0:CALL:0x%0h:0x%0h\n", e.pc, e.target); n_written++;
					end
					prev_iaddr = e.pc;
				end
				CPU_RET: begin
					if (e.traced) begin
						$fwrite(fd, "#0:RETURN:0x%0h:0x%0h\n", e.pc, e.target); n_written++;
					end
					prev_iaddr = e.pc;
				end
				CPU_INTERRUPT, CPU_EXCEPTION: begin
					last_pc_exc = prev_iaddr;
					if (e.traced) begin
						$fwrite(fd, "#0:INTERRUPT:0x%0h:0x%0h\n", prev_iaddr, e.target); n_written++;
					end
					prev_iaddr = e.target;
				end
				CPU_MRET: begin
					if (e.traced) begin
						$fwrite(fd, "#0:RFI:0x%0h:0x%0h\n", e.pc, e.target); n_written++;
					end
					prev_iaddr = e.pc;
				end
				CPU_LOAD: begin
					if (e.data_traced) begin
						$fwrite(fd, "#0:MEMREAD_%0d:0x%0h:0x%0h\n", 1 << e.size, e.target, e.payload);
						n_written++;
					end
					prev_daddr = e.target; prev_data = e.payload;
					prev_sz_log2 = e.size; prev_write = 0; prev_iaddr = e.pc;
				end
				CPU_STORE: begin
					if (e.data_traced) begin
						$fwrite(fd, "#0:MEMWRITE_%0d:0x%0h:0x%0h\n", 1 << e.size, e.target, e.payload);
						n_written++;
					end
					prev_daddr = e.target; prev_data = e.payload;
					prev_sz_log2 = e.size; prev_write = 1; prev_iaddr = e.pc;
				end
				CPU_CSR_WRITE: begin
					if (e.target == tip_iaddr_t'(ACT_CAP_CMD)) begin
						automatic int unsigned cmd  = e.payload[5:0];
						automatic int unsigned sink = e.payload[7:6];
						automatic longint unsigned dd = e.payload[31:8];
						// sink: 0=NEXUS, 1=AXIS, 2=AXIS_NEXUS, 3=TE. Nexus DAQ
						// records appear only for NEXUS / AXIS_NEXUS.
						if (sink == 0 || sink == 2) begin
							bytes = 1 << prev_sz_log2;
							rw    = prev_write ? "WRITE" : "READ";
							case (cmd)
								CMD_PC_CURR: begin
									if (dd != 0) begin $fwrite(fd, "#0:DAQ_DATA::0x%0h\n", dd); n_written++; end
									$fwrite(fd, "#0:SYNC::0x%0h\n", e.pc); n_written++;
								end
								CMD_PC_CURR_LAST: begin
									if (dd != 0) begin $fwrite(fd, "#0:DAQ_DATA::0x%0h\n", dd); n_written++; end
									$fwrite(fd, "#0:DAQ_LAST_PC::0x%0h\n", last_pc_exc); n_written++;
									$fwrite(fd, "#0:SYNC::0x%0h\n", e.pc); n_written++;
								end
								CMD_DIRECT_DATA: begin
									$fwrite(fd, "#0:DAQ_DATA::0x%0h\n", dd); n_written++;
								end
								CMD_DATA: begin
									if (dd != 0) begin $fwrite(fd, "#0:DAQ_DATA::0x%0h\n", dd); n_written++; end
									$fwrite(fd, "#0:MEM%s_%0d::0x%0h\n", rw, bytes, prev_data); n_written++;
								end
								CMD_DADDR: begin
									if (dd != 0) begin $fwrite(fd, "#0:DAQ_DATA::0x%0h\n", dd); n_written++; end
									$fwrite(fd, "#0:MEM%s_0:0x%0h:\n", rw, prev_daddr); n_written++;
								end
								CMD_DATA_DADDR: begin
									if (dd != 0) begin $fwrite(fd, "#0:DAQ_DATA::0x%0h\n", dd); n_written++; end
									$fwrite(fd, "#0:MEM%s_%0d:0x%0h:0x%0h\n", rw, bytes, prev_daddr, prev_data); n_written++;
								end
								CMD_IFETCH_TH:  begin $fwrite(fd, "#0:DAQ_COUNTER:0x0:0x%0h\n", 0 << 19); n_written++; end
								CMD_DATA_RD_TH: begin $fwrite(fd, "#0:DAQ_COUNTER:0x0:0x%0h\n", 1 << 19); n_written++; end
								CMD_DATA_WR:    begin $fwrite(fd, "#0:DAQ_COUNTER:0x0:0x%0h\n", 2 << 19); n_written++; end
								CMD_DATA_RD:    begin $fwrite(fd, "#0:DAQ_COUNTER:0x0:0x%0h\n", 3 << 19); n_written++; end
								CMD_CF_SYNC:    begin $fwrite(fd, "#0:SYNC::0x%0h\n", e.pc); n_written++; end
								default: ;
							endcase
						end
						// The csrw itself is a CSR_READ_WRITE data access: it
						// updates the captured context for the next DAQ command.
						prev_daddr = tip_daddr_t'(ACT_CAP_CMD); prev_data = e.payload;
						prev_sz_log2 = 2 /* word */; prev_write = 1;
					end
					prev_iaddr = e.pc;
				end
				CPU_RUN: prev_iaddr = e.pc;
				default: ;
			endcase
		end
		$fclose(fd);
		$display("*** INFO (%m, line %0d) expected_ctxp saved to %s (%0d records)",
			`__LINE__, path, n_written);
		return n_written;
	endfunction

	// Auto-write on simulation end if a path was supplied.
	final begin
		if (NEXRV_INFO_PATH    != "") void'(write_nexrv_info(NEXRV_INFO_PATH));
		if (EXPECTED_PCS_PATH  != "") void'(write_expected_pcs(EXPECTED_PCS_PATH));
		if (EXPECTED_DATA_PATH != "") void'(write_expected_data(EXPECTED_DATA_PATH));
		if (EXPECTED_CTXP_PATH != "") void'(write_expected_ctxp(EXPECTED_CTXP_PATH));
	end

	// ------------------------------------------------------------------
	// Debug print
	// ------------------------------------------------------------------
	function automatic void dump_events();
		$display("[cpu_model] event log (%0d entries):", event_q.size());
		foreach (event_q[i]) begin
			$display("  %4d: %-18s pc=%08x target=%08x payload=%016x size=%0d",
				i,
				event_kind_str(event_q[i].kind),
				event_q[i].pc,
				event_q[i].target,
				event_q[i].payload,
				event_q[i].size);
		end
	endfunction

endmodule : cpu_model

`default_nettype wire
